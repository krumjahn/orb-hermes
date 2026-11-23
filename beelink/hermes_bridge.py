#!/usr/bin/env python3
"""
hermes_bridge.py - bridges the "Orb Hermes" Android app to a local Hermes agent.

Runs on the Beelink next to Hermes and exposes a tiny HTTP API the phone can
reach:

    GET  /health          -> {"ok":true,"hermes":"api-server","stt":"mcode-tools","tts":"mmx"}
    POST /chat            {"text":"...","session":"..."}      -> {"reply":"..."}
    POST /stt             raw WAV bytes                       -> {"text":"..."}
    POST /tts             {"text":"...","voice":"..."}        -> audio/mpeg

Nothing here needs pip: it is standard library only. Hermes, MiniMax and
whisper are all optional and auto-detected, so the bridge degrades gracefully.

Environment:
    BRIDGE_HOST        default 0.0.0.0
    BRIDGE_PORT        default 8787
    BRIDGE_TOKEN       shared secret; when set, requests need X-Auth-Token
    HERMES_BASE_URL    default http://127.0.0.1:8642/v1   (OpenAI compatible)
    HERMES_API_KEY     bearer token for the Hermes API server
    HERMES_MODEL       default hermes-agent
    HERMES_CLI_MODEL   model id for the hermes CLI, when it needs one
    MMX_VOICE          default MiniMax voice id
    HERMES_CLI         "auto" | "hermes chat --query" style commands
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOST = os.environ.get("BRIDGE_HOST", "0.0.0.0")
PORT = int(os.environ.get("BRIDGE_PORT", "8787"))
TOKEN = os.environ.get("BRIDGE_TOKEN", "").strip()
# a comma-separated list lets a second device keep working while the token is
# being rotated
TOKENS = {part.strip() for part in TOKEN.split(",") if part.strip()}
HERMES_BASE_URL = os.environ.get("HERMES_BASE_URL", "http://127.0.0.1:8642/v1").rstrip("/")
HERMES_API_KEY = os.environ.get("HERMES_API_KEY", "").strip()
HERMES_MODEL = os.environ.get("HERMES_MODEL", "hermes-agent")
# Which backend the orb talks to.
#
# "auto" (the default) prefers the Hermes agent - the one with the tools, the
# memory and the access to this machine - and falls back to Ollama. Ollama on
# its own is only a model server: it answers from the prompt alone, so the orb
# would know nothing about the Beelink, not even the date.
# "ollama" always uses Ollama, which is what a plain Ollama host wants.
HERMES_PREFER = os.environ.get("HERMES_PREFER", "auto").strip().lower()
# How long the hermes CLI may take. An interactive hermes swallows the request
# until it times out, so it is not tried again for a while once it has failed.
#
# It has to be a long time. The agent loads its tools and its model before it
# answers, and a cold agent was measured at 232 seconds - at 45 seconds the
# bridge gave up on it, fell back to Ollama, and the orb answered without any
# of the tools. The phone waits 420 seconds, so 300 leaves room for the
# fallback to still get its answer out.
HERMES_CLI_TIMEOUT = float(os.environ.get("HERMES_CLI_TIMEOUT", "300"))
# The CLI usually has a model of its own, but not always: when it has none it
# answers "model is required" and exits with 0. The model can be pinned here
# and is then passed on the command line.
HERMES_CLI_MODEL = os.environ.get("HERMES_CLI_MODEL", "").strip()
# The user's own journal and memory live in the Hermes profiles of whoever
# runs this bridge. Nothing about the path is hardcoded: the home directory
# comes from the environment, and the profiles are looked for. JOURNAL_DIR
# overrides the search when the journal lives somewhere else.
JOURNAL_DIR = os.environ.get("JOURNAL_DIR", "").strip()
# How much of the journal goes with a question. It travels with every
# question, so it has to stay short enough to be cheap.
JOURNAL_MAX_CHARS = 6000
# An entry that carries these has no writing in it - it is the notice the
# old workspace leaves behind when a journal file is imported but not filled.
PLACEHOLDER_MARKERS = (
    "would be populated with actual content",
    "imported from a nanobot workspace",
)
# How much of the user's own notes go with a question.
CONTEXT_MAX_CHARS = 6000
# Which build is running. /health reports it, so it is always obvious which
# copy of the bridge the orb is really talking to.
BRIDGE_VERSION = os.environ.get("BRIDGE_VERSION", "2026-11-23a").strip()

# Probe results, so a missing or broken agent is not paid for on every chat.
_api_ok = False
_api_ok_until = 0.0
_cli_broken_until = 0.0
MMX_VOICE = os.environ.get("MMX_VOICE", "").strip()
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434").rstrip("/")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "")

ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

_hints = {"hermes": "unknown", "stt": "unknown", "tts": "unknown"}
# why each backend that was tried and failed did not answer - the
# fallback hides it, and without this the agent can be skipped for a
# reason nobody can see
_backend_errors: list = []
# The last backend error, so /health can say what went wrong instead of
# leaving it to be guessed from a missing answer.
_last_error = ""
# What the CLI said when it failed. The agent's own report says which model
# it started with and which provider it used, which is the only way to find
# out why it cannot answer.
_cli_report = ""
# the tail of the CLI's output - that is where the answer is, and the
# beginning is only the chrome. It is how the format of the answer can be
# seen without guessing.
_cli_tail = ""


def mask_secrets(text: str) -> str:
    """Hide anything that looks like a token before it is shown."""
    text = re.sub(r"[0-9]{8,12}:[A-Za-z0-9_-]{25,}", "<telegram-token>", text)
    text = re.sub(r"sk-[A-Za-z0-9_-]{12,}", "<api-key>", text)
    text = re.sub(r"(?i)(api[_-]?key|token|secret|password)(\s*[:=]\s*)\S{6,}", r"\1\2<set>", text)
    return text


def model_settings():
    """The settings that decide which model the agent uses.

    The values that name a model are shown; anything that could be a secret
    is only listed by name.
    """
    wanted = ("HERMES_MODEL", "HERMES_CLI_MODEL", "LLM_MODEL", "MODEL",
              "OPENROUTER_MODEL", "OLLAMA_MODEL")
    found = {}
    for key, value in sorted(os.environ.items()):
        if key in wanted:
            found[key] = value
        elif key.startswith(("HERMES_", "OPENROUTER_")) and value:
            found[key] = "<set>" if any(word in key for word in ("KEY", "TOKEN", "SECRET")) else value
    return found


def log(*args):
    print(f"[{time.strftime('%H:%M:%S')}]", *args, flush=True)


# The bridge's own settings must not reach the Hermes CLI.
#
# HERMES_BASE_URL, HERMES_MODEL and HERMES_API_KEY here describe the agent's
# API server - a server that is not running on this machine. The CLI
# inherited them, found no model on the endpoint they named, and answered
# "model is required" every time. So the orb fell back to Ollama, which
# answers from the prompt alone: no web search, no tools, no memory of its
# own. The CLI has to read its own settings from ~/.hermes/config.yaml, the
# same ones the Telegram gateway uses.
CLI_ENV_DROPPED = (
    "HERMES_BASE_URL", "HERMES_MODEL", "HERMES_API_KEY", "HERMES_PROVIDER",
    "HERMES_PREFER", "HERMES_CLI_MODEL", "HERMES_CLI_TIMEOUT",
    "OLLAMA_URL", "OLLAMA_MODEL",
    "BRIDGE_HOST", "BRIDGE_PORT", "BRIDGE_TOKEN", "WAKE_PHRASE",
)


def cli_env():
    """The environment for the Hermes CLI.

    The bridge's own settings are taken out, so the CLI uses the settings in
    ~/.hermes/config.yaml - the same ones that make the Telegram gateway
    work. Everything else, PATH and HOME among it, is left alone.
    """
    env = {}
    for key, value in os.environ.items():
        if key in CLI_ENV_DROPPED or key.startswith("HERMES_CLI_"):
            continue
        env[key] = value
    return env


def run(cmd, timeout=120, stdin_text=None, env=None):
    """Run a command, return (returncode, stdout, stderr)."""
    try:
        proc = subprocess.run(
            cmd,
            input=stdin_text,
            capture_output=True,
            text=True,
            timeout=timeout,
            stdin=None if stdin_text is not None else subprocess.DEVNULL,
            env=env,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except FileNotFoundError:
        return 127, "", f"{cmd[0]} not found"
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"
    except Exception as exc:  # noqa: BLE001
        return 1, "", str(exc)


def strip_ansi(text):
    return ANSI_RE.sub("", text or "").strip()


def have(binary):
    return shutil.which(binary) is not None


# --------------------------------------------------------------------- Hermes


def hermes_api_chat(text, session):
    """Call the Hermes OpenAI-compatible API server."""
    body = {
        "model": HERMES_MODEL,
        "messages": [{"role": "user", "content": text}],
        "stream": False,
    }
    if session:
        body["session"] = session
    req = urllib.request.Request(
        f"{HERMES_BASE_URL}/chat/completions",
        data=json.dumps(body).encode(),
        headers={
            "Content-Type": "application/json",
            **({"Authorization": f"Bearer {HERMES_API_KEY}"} if HERMES_API_KEY else {}),
        },
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        payload = json.loads(resp.read().decode())
    choices = payload.get("choices") or []
    if choices:
        message = choices[0].get("message") or {}
        content = message.get("content")
        if isinstance(content, list):  # some servers return content parts
            content = "".join(
                part.get("text", "") for part in content if isinstance(part, dict)
            )
        if content:
            return str(content).strip()
    if payload.get("reply"):
        return str(payload["reply"]).strip()
    raise RuntimeError(f"unexpected Hermes response: {str(payload)[:200]}")


# The CLI is tried in order and the first one that answers cleanly wins. When
# a model is pinned it is tried first, because a CLI without a model of its
# own answers "model is required".

def config_model_default():
    """The model the settings file names - "model.default".

    The settings file is the truth about the agent's model, and it is the
    same file the Telegram gateway reads. The stt and tts sections have
    their own "model:" keys, and those are not agent models: one of them
    ("base", the size of the whisper model) was pinned as the agent's
    model, and the agent then had no model at all and answered "model is
    required" every time.
    """
    path = os.path.join(os.path.expanduser("~"), ".hermes", "config.yaml")
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            lines = handle.read().split("\n")
    except OSError:
        return ""
    for index, line in enumerate(lines):
        if not re.match(r"^model[ \t]*:", line):
            continue
        for child in lines[index + 1:]:
            if not child.strip():
                continue
            if not child[:1].isspace():
                break
            match = re.match(r"^[ \t]+default[ \t]*:(.*)$", child)
            if match:
                value = match.group(1).strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
                    value = value[1:-1]
                return value
        return ""
    return ""


# The names of the speech models. One of them ("base") was pinned as the
# agent's model by accident, and the agent then had no model at all and
# answered "model is required" every time. A speech model is never an agent.
SPEECH_MODELS = {
    "base", "tiny", "small", "medium", "large",
    "tiny.en", "base.en", "small.en", "medium.en", "large.en",
    "distil-small", "distil-medium", "distil-large",
    "whisper", "whisper-1", "whisper-base", "whisper-small",
    "whisper-medium", "whisper-large",
}


def is_speech_model(name):
    """True when the name is a speech model rather than an agent model."""
    if not name:
        return False
    plain = name.strip().lower()
    if ":" in plain:
        plain = plain.split(":", 1)[0]
    if plain.startswith("whisper"):
        return True
    return plain in SPEECH_MODELS


_cli_help = ""


def cli_help():
    """The CLI's own help, read once and kept.

    The parser's own words say exactly which options exist and where they
    belong - "hermes [options] <command>" - so the form of the command can be
    checked instead of guessed.
    """
    global _cli_help
    if _cli_help:
        return _cli_help
    if not have("hermes"):
        return ""
    try:
        rc, out, err = run(["hermes", "--help"], timeout=30, env=cli_env())
    except Exception:
        return ""
    text = strip_ansi(out) if rc == 0 else strip_ansi(err)
    _cli_help = mask_secrets(" ".join(text.split())[:1500])
    return _cli_help


def session_models():
    """The models the agent has actually used.

    The Telegram gateway runs the same agent and leaves the model it used in
    its session files. Those names are known to work.
    """
    import glob
    home = os.path.expanduser("~")
    roots = [os.path.join(home, ".hermes", "sessions")]
    roots.extend(glob.glob(os.path.join(home, ".hermes", "profiles", "*", "sessions")))
    found = []
    for root in roots:
        try:
            paths = sorted(
                glob.glob(os.path.join(root, "*.json")),
                key=lambda path: os.path.getmtime(path),
                reverse=True,
            )
        except OSError:
            continue
        for path in paths[:20]:
            try:
                with open(path, encoding="utf-8", errors="replace") as handle:
                    text = handle.read(400_000)
            except OSError:
                continue
            for match in re.finditer(r'"model"\s*:\s*"([^"]+)"', text):
                value = match.group(1).strip()
                if value and not is_speech_model(value) and value not in found:
                    found.append(value)
            if found:
                # the newest session that names a model is enough
                return found[:3]
    return found[:3]


def ollama_models():
    """The models the model server is serving."""
    try:
        with urllib.request.urlopen(f"{OLLAMA_URL}/api/tags", timeout=3) as resp:
            payload = json.loads(resp.read().decode())
    except Exception:
        return []
    names = []
    for item in payload.get("models") or []:
        name = str(item.get("name") or item.get("model") or "").strip()
        if name and name not in names:
            names.append(name)
    # the model that carries "hermes" in its name is the agent's own
    names.sort(key=lambda name: 0 if "hermes" in name.lower() else 1)
    return names


def agent_models():
    """The models the agent could use, best first, with where each came from.

    The names the agent itself used come first: they are known to work, and
    the model server serves them. Then the settings file, then the model the
    bridge was pinned to.
    """
    models = []

    def add(model, source):
        model = (model or "").strip()
        if not model or is_speech_model(model):
            return
        for existing, _ in models:
            if existing == model:
                return
        models.append((model, source))

    served = ollama_models()
    # the exact name the agent used, when the model server has it
    for name in session_models():
        if not served or name in served:
            add(name, "hermes.sessions")
    default = config_model_default().strip()
    if default:
        add(default, "config.model.default")
        if ":" not in default:
            add(default + ":latest", "config.model.default:latest")
    add(OLLAMA_MODEL.strip(), "OLLAMA_MODEL")
    for name in served:
        add(name, "ollama.tags")
    return models


def agent_model():
    """The model the agent should use, and where that name came from."""
    models = agent_models()
    if models:
        return models[0]
    return "", ""


# The CLI is "hermes [options] <command> [args]".
#
#     hermes --model NAME chat --query "the question"
#     hermes chat --query "the question"
#     hermes -z "the question"
#
# The options belong in front of the command. "hermes chat --query X --model
# NAME" is rejected by the parser with "unrecognized arguments", and so was
# every command that put the model in the wrong place - the agent then ran
# with no model at all and the provider answered "HTTP 400: model is
# required".
CLI_FORMS = (
    ("hermes", "--model", "{model}", "chat", "--query", "{}"),
    ("hermes", "chat", "--query", "{}", "--model", "{model}"),
    ("hermes", "--model", "{model}", "chat", "{}"),
    ("hermes", "chat", "{}", "--model", "{model}"),
    ("hermes", "--model", "{model}", "-z", "{}"),
    ("hermes", "-z", "{}", "--model", "{model}"),
)

# When no model is known at all, the agent is still worth a try - it may find
# one in its own settings.
CLI_FORMS_NO_MODEL = (
    ("hermes", "chat", "--query", "{}"),
    ("hermes", "chat", "{}"),
    ("hermes", "-z", "{}"),
)


def cli_candidates():
    """The CLI commands to try, in order.

    The model comes from the sessions the agent left behind, then from the
    settings file, then from the model server. A speech model is never used:
    it is always a mistake.
    """
    models = agent_models()
    candidates = []
    for model, _source in models:
        for form in CLI_FORMS:
            candidates.append([part.replace("{model}", model) for part in form])
    if not models:
        for form in CLI_FORMS_NO_MODEL:
            candidates.append(list(form))
    return candidates


def model_report():
    """Which model the agent will use, and where that name came from.

    It is in /health so the model can be seen without a terminal on the
    Beelink - the phone and the Mac can both read it.
    """
    model, source = agent_model()
    return {
        "agent_model": model,
        "source": source,
        "pinned": HERMES_CLI_MODEL,
        "config_default": config_model_default(),
        "models": [{"model": name, "source": where} for name, where in agent_models()],
        "cli_models": [candidate[candidate.index("--model") + 1]
                       for candidate in cli_candidates() if "--model" in candidate],
        "cli_commands": [" ".join(candidate) for candidate in cli_candidates()[:4]],
    }


# The verbose agent mode can report that it has no model. Trying it again
# would not help, so it is left alone for a while and the quiet mode answers
# instead. A pinned model is still tried - it is the one that may fix it.
CLI_MODEL_BROKEN_COOLDOWN = 3600.0
# until when the broken candidate is left alone
_cli_broken_until = 0.0
# the candidate that was broken - it is not tried again while the cooldown is on
_cli_broken_signature = ()

# The Hermes CLI prints the question, the answer and a session footer around
# the reply. Only the answer belongs in the reply - the orb reads it out loud.
CLI_ANSWER_LABELS = ("☤ Hermes", "FINAL RESPONSE:")
# Newer builds of the CLI label the answer differently. A label is a short
# line of its own, and what follows it is the answer.
CLI_ANSWER_LABEL_PATTERNS = (
    re.compile(r"^\W*hermes\s*:?\s*$", re.IGNORECASE),
    re.compile(r"^\W*final response\s*:?\s*$", re.IGNORECASE),
    re.compile(r"^\W*(response|answer|reply)\s*:?\s*$", re.IGNORECASE),
)
CLI_FOOTER_MARKERS = (
    "Resume this session with:",
    "Session:",
    "Duration:",
    "Messages:",
)
# The CLI's own progress report. These lines are chrome, never the answer.
CLI_STATUS_PREFIXES = (
    "AI Agent", "Using API key", "Disabled toolset", "Final tool selection",
    "Tool Search", "Loaded ", "Some tools may not work", "Context limit",
    "User Query", "Starting conversation", "Making API call", "Request size",
    "Available tools", "Request debug dump", "Attempt ", "Fix:",
    "CONVERSATION SUMMARY", "Completed:", "API Calls:",
    "Agent execution completed",
)

# What the CLI prints when the agent itself failed. It still exits with 0, so
# the exit code cannot be trusted - the text has to be read.
CLI_FAILURE_MARKERS = (
    "model is required",
    "model not found",
    "no such model",
    "unknown model",
    "OpenRouter rejected",
    "not retryable failed",
    "Provider said:",
)

# The failures that mean the model itself is wrong. The same model is then
# left alone for a while, so the next question does not have to wait for it
# to fail again.
CLI_MODEL_FAILURES = (
    "model is required",
    "model not found",
    "no such model",
    "unknown model",
)

# The failures that mean the provider does not know this model. The next
# form of the same command would fail the same way, so it is not tried.
CLI_MODEL_REJECTED = (
    "model not found",
    "no such model",
    "unknown model",
)


def _is_rule(line: str) -> bool:
    """A line made of nothing but rules, like the one the CLI draws."""
    stripped = line.strip()
    if not stripped:
        return False
    return set(stripped) <= set("─-═_=~ ")


def _is_status_line(stripped: str) -> bool:
    """A line of the CLI's own progress report rather than an answer."""
    if not stripped:
        return False
    for prefix in CLI_STATUS_PREFIXES:
        if stripped.startswith(prefix):
            return True
    # A progress line starts with an emoji - but only when the words behind
    # it are the CLI's own report. An answer can start with an emoji too,
    # and throwing the whole answer away meant the bridge had nothing to
    # say and fell back to Ollama.
    first = stripped[0]
    if (0x1F300 <= ord(first) <= 0x1FAFF) or (0x2600 <= ord(first) <= 0x27BF):
        rest = stripped
        while rest and not (rest[0].isalnum() or rest[0] in "([{"):
            rest = rest[1:]
        for prefix in CLI_STATUS_PREFIXES:
            if rest.startswith(prefix):
                return True
    return False


def cli_output_failed(text: str) -> str:
    """The reason the agent failed, or "" when it answered."""
    for marker in CLI_FAILURE_MARKERS:
        if marker in text:
            return marker
    return ""


def clean_cli_output(text: str) -> str:
    """Take the answer out of the Hermes CLI's output.

    The CLI wraps the answer in a label and a footer:

        Query: what time is it
        ────────────────────────────
        ☤ Hermes
        It is four o'clock.
        ────────────────────────────
        Resume this session with: hermes --resume local-abc
        Session: local-abc
        Duration: 10s
        Messages: 2 (1 user, 0 tool calls)

    Only what follows the label and comes before the rule is the answer.
    When the agent failed there is no label and the output is a report
    instead: the chrome is dropped and what is left is returned, so the orb
    never reads a stack of status lines out loud.
    """
    lines = text.splitlines()

    # a failed agent has no answer to clean - returning the report would
    # have the orb read a stack of status lines out loud
    if cli_output_failed(text):
        return ""

    for label in CLI_ANSWER_LABELS:
        for index, line in enumerate(lines):
            if label not in line:
                continue
            answer = _answer_after(lines, index)
            if answer:
                return answer

    # a newer build labels the answer its own way
    for pattern in CLI_ANSWER_LABEL_PATTERNS:
        for index, line in enumerate(lines):
            if not pattern.match(line.strip()):
                continue
            answer = _answer_after(lines, index)
            if answer:
                return answer

    # no label at all: the answer is the last block before the footer
    answer = _last_block(lines)
    if answer:
        return answer

    # last resort: drop the echo of the question, the progress lines and the
    # footer, keep the rest
    kept = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("Query:"):
            continue
        if stripped.startswith(CLI_FOOTER_MARKERS):
            continue
        if _is_rule(line):
            continue
        if _is_status_line(stripped):
            continue
        kept.append(line)
    return "\n".join(kept).strip()


def _answer_after(lines, index):
    """The answer that follows the label on line [index]."""
    rest = lines[index + 1:]
    # the CLI may draw a rule under the label
    while rest and (not rest[0].strip() or _is_rule(rest[0])):
        rest.pop(0)
    answer = []
    for follow in rest:
        if _is_rule(follow):
            break
        stripped = follow.strip()
        if stripped.startswith(CLI_FOOTER_MARKERS):
            break
        if stripped.startswith("Agent execution completed"):
            break
        if _is_status_line(stripped):
            continue
        answer.append(follow)
    return "\n".join(answer).strip()


def _last_block(lines):
    """The last block of text between two rules.

    That is where the answer is when the CLI does not label it.
    """
    blocks = []
    current = []
    for line in lines:
        if _is_rule(line):
            if current:
                blocks.append(current)
                current = []
            continue
        current.append(line)
    if current:
        blocks.append(current)
    for block in reversed(blocks):
        kept = []
        for line in block:
            stripped = line.strip()
            if stripped.startswith(CLI_FOOTER_MARKERS):
                continue
            if _is_status_line(stripped):
                continue
            kept.append(line)
        text = "\n".join(kept).strip()
        if text:
            return text
    return ""


def hermes_cli_chat(text, session):
    """Shell out to the Hermes CLI (used when the API server is not running).

    The CLI is tried in order, and the first one that answers cleanly wins.

    The prompt goes in with "--query" (or "-z") and the model with "--model".
    The CLI has no "chat" subcommand: "hermes chat --query ..." prints its own
    usage and exits, so the orb fell back to Ollama every time - and Ollama
    is a model server with no tools, no memory and no web search.

    So a failed agent is not an answer: the next candidate is tried, and the
    broken one is left alone for a while so the next question does not have
    to wait for it to fail again.
    """
    global _cli_broken_until, _cli_broken_signature, _cli_report, _cli_tail
    last_error = "no hermes CLI candidate worked"
    # The whole attempt has a budget. A candidate that starts the agent loads
    # its tools with it, and several slow failures would outlast the phone's
    # patience - the orb would never get an answer.
    deadline = time.time() + HERMES_CLI_TIMEOUT
    # a model the provider does not know is not tried again in another form
    broken_models = set()
    for candidate in cli_candidates():
        binary = candidate[0]
        if not have(binary):
            continue
        model = candidate[-1] if "--model" in candidate else ""
        if model and model in broken_models:
            continue
        signature = tuple(candidate)
        if time.time() < _cli_broken_until and signature == _cli_broken_signature:
            continue
        remaining = deadline - time.time()
        if remaining <= 5:
            break
        cmd = [part.replace("{}", text) for part in candidate]
        rc, out, err = run(cmd, timeout=min(int(remaining), HERMES_CLI_TIMEOUT), env=cli_env())
        raw = strip_ansi(out)
        # The CLI exits with 0 even when the agent failed, so the text is
        # what decides: a failed agent must not be read out to the user.
        failure = cli_output_failed(raw)
        cleaned = clean_cli_output(raw)
        if rc == 0 and cleaned:
            # The agent's own report says which model it started with and
            # which tools it loaded. It is kept even when the answer is good:
            # it is the proof that the agent - with its tools - and not a plain
            # model server answered.
            _cli_report = mask_secrets(" ".join(raw.split())[:1200])
            _cli_tail = mask_secrets(" ".join(raw.split())[-600:])
            return cleaned
        if failure:
            if failure in CLI_MODEL_REJECTED:
                # the provider does not know this model - the next form of the
                # same command would fail the same way
                broken_models.add(model)
            if failure in CLI_MODEL_FAILURES:
                _cli_broken_until = time.time() + CLI_MODEL_BROKEN_COOLDOWN
                _cli_broken_signature = signature
            # the agent's own report says which model and provider it used
            _cli_report = " ".join(raw.split())[:1200]
            _cli_tail = mask_secrets(" ".join(raw.split())[-600:])
            last_error = f"{' '.join(cmd[:2])} -> the agent failed ({failure})"
        elif rc != 0:
            _cli_report = " ".join(strip_ansi(err).split())[:1200]
            _cli_tail = mask_secrets(" ".join(strip_ansi(err).split())[-600:])
            last_error = f"{' '.join(cmd[:2])} -> rc={rc} {strip_ansi(err)[:160]}"
        else:
            last_error = f"{' '.join(cmd[:2])} -> the CLI answered with nothing"
    raise RuntimeError(last_error)


def ollama_chat(text, session):
    model = OLLAMA_MODEL or HERMES_MODEL
    body = {"model": model, "messages": [{"role": "user", "content": text}], "stream": False}
    req = urllib.request.Request(
        f"{OLLAMA_URL}/api/chat", data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        payload = json.loads(resp.read().decode())
    content = (payload.get("message") or {}).get("content")
    if content:
        return str(content).strip()
    raise RuntimeError(f"unexpected Ollama response: {str(payload)[:200]}")


def hermes_available():
    """Is any Hermes backend reachable? Cheap probe, result cached briefly."""
    try:
        req = urllib.request.Request(f"{HERMES_BASE_URL}/models", method="GET")
        urllib.request.urlopen(req, timeout=3).read()
        return True
    except Exception:
        pass
    if have("hermes") or have("hermes-agent"):
        return True
    try:
        urllib.request.urlopen(f"{OLLAMA_URL}/api/tags", timeout=3).read()
        return True
    except Exception:
        return False


def hermes_api_reachable():
    """Is the Hermes agent's API server there? Cheap probe, cached briefly.

    Without this a hung server would eat the whole chat timeout before the
    orb ever got to Ollama.
    """
    global _api_ok, _api_ok_until
    now = time.time()
    if now < _api_ok_until:
        return _api_ok
    try:
        req = urllib.request.Request(f"{HERMES_BASE_URL}/models", method="GET")
        with urllib.request.urlopen(req, timeout=3) as resp:
            resp.read()
        _api_ok = True
    except Exception:
        _api_ok = False
    _api_ok_until = now + 30.0
    return _api_ok


def agent_config():
    """The agent's own configuration, the parts that decide the model.

    Only the lines that name a model, a provider or a profile are shown, and
    anything that could be a secret is left out.
    """
    import glob
    home = os.path.expanduser("~")
    patterns = (
        os.path.join(home, ".hermes", "config.yaml"),
        os.path.join(home, ".hermes", "config.yml"),
        os.path.join(home, ".hermes", "config.json"),
        os.path.join(home, ".hermes", "profiles", "*", "config.yaml"),
    )
    found = {}
    for pattern in patterns:
        for path in sorted(glob.glob(pattern)):
            try:
                with open(path, encoding="utf-8", errors="replace") as handle:
                    text = handle.read()
            except OSError:
                continue
            lines = []
            for line in text.splitlines():
                stripped = line.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                if not re.search(r"(?i)model|provider|base_url|profile", stripped):
                    continue
                if re.search(r"(?i)key|token|secret|password", stripped):
                    continue
                lines.append(stripped[:160])
            if lines:
                found[path] = lines[:20]
    return found


def hermes_home():
    """The home directory of whoever runs the bridge - the Hermes account."""
    return os.path.expanduser("~")


def profile_dirs():
    """The Hermes profiles on this machine."""
    import glob
    base = os.path.join(hermes_home(), ".hermes", "profiles")
    return [
        path for path in sorted(glob.glob(os.path.join(base, "*")))
        if os.path.isdir(path)
    ]


def journal_dirs():
    """Every journal folder: the profiles' own, and the legacy one.

    The profiles keep their journal in a folder next to their memory files,
    and the older nanobot workspace keeps one too - both are read, newest
    first.
    """
    found = []
    if JOURNAL_DIR and os.path.isdir(JOURNAL_DIR):
        found.append(JOURNAL_DIR)
    for profile in profile_dirs():
        for part in ("journal", "memory/journal"):
            path = os.path.join(profile, part)
            if os.path.isdir(path) and path not in found:
                found.append(path)
    legacy = os.path.join(hermes_home(), ".nanobot", "workspace", "journal")
    if os.path.isdir(legacy) and legacy not in found:
        found.append(legacy)
    return found


def context_files():
    """The profile's own memory files, the important ones first.

    These are the notes the agent has in every session: who the user is,
    what they are working on, the things worth remembering. Putting them in
    front of the model is what makes the orb answer like the user's own
    Hermes instead of like a stranger.

    MEMORY.md and USER.md come first, because they are in every session of
    the agent too. The rest are the topic notes the agent reads on demand -
    the schedule, the calendar, the shopping list - and they follow.
    """
    import glob
    important = []
    rest = []
    for profile in profile_dirs():
        for name in ("MEMORY.md", "USER.md"):
            path = os.path.join(profile, name)
            if os.path.isfile(path) and path not in important:
                important.append(path)
        for pattern in ("*.md", "*.txt"):
            for path in sorted(glob.glob(os.path.join(profile, pattern))):
                if path not in important and path not in rest:
                    rest.append(path)
    return important + rest


# The words that carry no meaning when they are matched against a note file.
_NOTE_STOPWORDS = {
    "what", "when", "where", "which", "who", "why", "how", "does", "did",
    "tell", "show", "give", "last", "next", "with", "from", "have", "were",
    "been", "they", "them", "then", "than", "into", "about", "there", "here",
    "some", "your", "their", "would", "could", "should", "please", "just",
    "know", "like", "much", "many", "make", "made", "over", "after", "before",
}


def _question_words(text):
    return {
        word for word in re.findall(r"[a-z0-9']{4,}", (text or "").lower())
        if word not in _NOTE_STOPWORDS
    }


def _note_relevance(name, body, question):
    """How much a note file is about what was asked.

    The topic notes are many, and they do not all fit in the budget, so
    the ones that match the question are the ones that come along.
    """
    words = _question_words(question)
    if not words:
        return 0
    haystack = (name + " " + body[:2000]).lower()
    return sum(1 for word in words if word in haystack)


def profile_context(question=""):
    """The user's own notes, with a budget - like the agent's own context."""
    files = context_files()
    if not files:
        return ""
    parts = []
    total = 0

    # who the user is, and what they remember - these always come along
    for path in files:
        name = os.path.basename(path)
        if name not in ("MEMORY.md", "USER.md"):
            continue
        body = _read_note(path)
        room = CONTEXT_MAX_CHARS - total
        if not body or room <= 0:
            continue
        body = body[:min(2200, room)]
        total += len(body)
        parts.append(f"--- {name} ---\n{body}")

    # then the topic notes, the ones the question is about first
    topics = []
    for path in files:
        name = os.path.basename(path)
        if name in ("MEMORY.md", "USER.md"):
            continue
        topics.append((path, name, _read_note(path)))
    topics.sort(key=lambda item: -_note_relevance(item[1], item[2], question))
    for path, name, body in topics:
        room = CONTEXT_MAX_CHARS - total
        if not body or room <= 0:
            continue
        body = body[:min(400, room)]
        total += len(body)
        parts.append(f"--- {name} ---\n{body}")

    if not parts:
        return ""
    return (
        "\n\n[The user's own notes follow. They are who the user is and what "
        "they have been working on - use them, so your answer sounds like it "
        "comes from the same assistant they talk to every day.]\n"
        + "\n\n".join(parts)
        + "\n[/notes]\n"
    )


def _read_note(path):
    """The text of a note file, or '' when it cannot be read."""
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read().strip()
    except OSError:
        return ""


def journal_files():
    """Every journal file that was found, with its text, newest first."""
    import glob
    found = []
    for folder in journal_dirs():
        try:
            names = os.listdir(folder)
        except OSError:
            continue
        for name in names:
            if name.startswith("."):
                continue
            path = os.path.join(folder, name)
            if os.path.isdir(path):
                inside = sorted(glob.glob(os.path.join(path, "*")))
                files = [p for p in inside if os.path.isfile(p)]
                if not files:
                    continue
                path = files[-1]
            elif not os.path.isfile(path):
                continue
            body = _read_entry_text(path)
            if not body.strip():
                continue
            try:
                mtime = os.path.getmtime(path)
            except OSError:
                continue
            found.append((path, mtime, body))
    found.sort(key=lambda item: item[1], reverse=True)
    return found


def journal_entries(limit=5):
    """The most recent journal entries that have writing in them, newest first.

    An entry is a file, or a folder with a file in it - both shapes are
    handled, because it is not known which one the journal uses.

    Entries that carry no writing are left out. A profile's journal can
    hold files that were imported from an older workspace: they say so and
    have no content, but they were written more recently than the real
    entries, so without this they would sit in front of them and the orb
    would answer that the journal is empty.
    """
    items = [item for item in journal_files() if not is_placeholder(item[2])]
    return items[:limit]


def _read_entry_text(path):
    """The text of a journal entry, or '' if the file is not text."""
    try:
        with open(path, "rb") as handle:
            head = handle.read(512)
            if b"\x00" in head:
                return ""
            rest = handle.read(20000)
    except OSError:
        return ""
    return (head + rest).decode("utf-8", errors="replace")


def is_placeholder(body):
    """Is this entry only a notice that it has no content?

    The marker is the import notice the old workspace leaves behind, and
    the length keeps a real entry that happens to mention it.
    """
    lowered = (body or "").lower()
    if not any(marker in lowered for marker in PLACEHOLDER_MARKERS):
        return False
    return len(body.strip()) < 600


def journal_wanted(text):
    """Is the question about the journal?"""
    lowered = (text or "").lower()
    return any(word in lowered for word in (
        "journal", "diary", "entry", "entries", "wrote", "write down",
        "my notes", "note I", "last time I", "yesterday I",
    ))


def journal_context(text):
    """The user's own writing, to answer a question about it with.

    The latest entry is always there; more of them come along when the
    question is clearly about the journal.
    """
    limit = 4 if journal_wanted(text) else 1
    entries = journal_entries(limit)
    if not entries:
        return ""
    parts = []
    total = 0
    for path, _, body in entries:
        body = body.strip()
        if not body:
            continue
        # the whole thing is kept short: it goes with every question
        room = JOURNAL_MAX_CHARS - total
        if room <= 0:
            break
        body = body[:min(2500, room)]
        total += len(body)
        parts.append(f"--- {os.path.basename(path)} ---\n{body}")
    if not parts:
        return ""
    return (
        "\n\n[The user's own journal follows. It is their own writing - answer "
        "questions about it from these entries, and quote them where it helps.]\n"
        + "\n\n".join(parts)
        + "\n[/journal]\n"
    )


def journal_status():
    """What the bridge found of the journal, for the health endpoint."""
    entries = journal_entries(50)
    files = journal_files()
    return {
        "folders": journal_dirs(),
        "entries": len(entries),
        "latest": os.path.basename(entries[0][0]) if entries else "",
        "skipped": len(files) - len(entries),
    }


def account_status():
    """Which account the bridge runs as, and what it found there.

    Nothing here is written down in the bridge: the paths come from the
    account that runs it, so the health endpoint shows where the notes and
    the journal are actually read from.
    """
    try:
        import getpass
        user = getpass.getuser()
    except Exception:  # noqa: BLE001
        user = os.environ.get("USER", "")
    files = context_files()
    return {
        "user": user,
        "home": hermes_home(),
        "profiles": profile_dirs(),
        "context_files": files,
        "notes_chars": len(profile_context()),
    }


def now_context():
    """The real date and time, so the model can place things in time.

    Without it a question like "what is in my last journal entry" cannot
    be answered, because the model does not know how old the entries are.
    """
    stamp = time.strftime("%A, %Y-%m-%d %H:%M", time.localtime())
    return f"\n\n[Today is {stamp}.]\n"


def hermes_chat(text, session=""):
    """Talk to the Hermes agent, and fall back to Ollama.

    The Hermes agent is the one with the tools, the memory and the access to
    this machine - it is what the orb should be talking to. Ollama on its own
    is only a model server: it answers from the prompt alone, so the orb would
    know nothing about the Beelink.

    If an Ollama model was pinned explicitly (OLLAMA_MODEL) and the caller
    asked for plain Ollama, Ollama is tried first. On a plain Ollama host the
    'hermes' command can be an interactive TUI that swallows the request until
    it times out, so a CLI that fails is not tried again for ten minutes.
    """
    global _cli_broken_until, _last_error
    errors = []
    backends = []
    # The user's own notes and journal go with the question. They are on this
    # machine, so the orb can answer a question about them even when the
    # agent itself cannot answer anything - and the answers sound like the
    # user's own Hermes, because the same notes are in front of it.
    notes = profile_context(text)
    enriched = notes + journal_context(text) + now_context() + text
    if enriched != text:
        log("the user's notes went with the question")
    if HERMES_PREFER == "ollama":
        backends.append(("ollama", ollama_chat))
        backends.append(("api-server", hermes_api_chat))
        backends.append(("cli", hermes_cli_chat))
    else:
        if hermes_api_reachable():
            backends.append(("api-server", hermes_api_chat))
        if time.time() >= _cli_broken_until and (have("hermes") or have("hermes-agent")):
            backends.append(("cli", hermes_cli_chat))
        backends.append(("ollama", ollama_chat))

    for name, backend in backends:
        try:
            reply = backend(enriched, session)
            _hints["hermes"] = name
            _last_error = ""
            _backend_errors.clear()
            return reply
        except Exception as exc:  # noqa: BLE001
            errors.append(f"{name}: {exc}")
            _backend_errors.append(f"{name}: {exc}")
            # the first error is the root cause: the agent is tried first, and
            # the fallback's own failure would only hide it
            if not _last_error:
                _last_error = f"{name}: {exc}"
            if name == "cli":
                _cli_broken_until = time.time() + 600

    raise RuntimeError(" | ".join(errors))


# ----------------------------------------------------------------- Transcribe


def _parse_transcription(payload):
    """The transcription tool returns a bare value; handle the usual shapes."""
    if isinstance(payload, str):
        return payload.strip()
    if isinstance(payload, dict):
        for key in ("text", "transcript", "transcription", "content", "result", "data"):
            value = payload.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
            if isinstance(value, dict):
                for inner in ("text", "content", "transcription"):
                    if isinstance(value.get(inner), str) and value[inner].strip():
                        return value[inner].strip()
        if isinstance(payload.get("choices"), list):
            return _parse_transcription(payload["choices"])
    return str(payload).strip()


def transcribe_mcode_tools(wav_path):
    """Upload the clip and let the MiniMax transcription tool read it."""
    if not have("mcode-tools"):
        raise RuntimeError("mcode-tools not installed")
    rc, out, err = run(
        ["mcode-tools", "upload_temp_url", str(wav_path), "--mime-type", "audio/wav"],
        timeout=120,
    )
    if rc != 0:
        raise RuntimeError(f"upload_temp_url failed: {strip_ansi(err)[:200]}")
    upload = json.loads(out)
    temp_url = upload.get("temp_url") or upload.get("url")
    if not temp_url:
        raise RuntimeError(f"no temp_url in {out[:200]}")

    args = json.dumps({"audio_info": {"url": temp_url, "mime_type": "audio/wav"}})
    rc, out, err = run(
        ["mcode-tools", "connector", "call", "connector__matrix__listen_audio", "--args", args],
        timeout=300,
    )
    if rc != 0:
        raise RuntimeError(f"listen_audio failed: {strip_ansi(err)[:200]}")
    try:
        payload = json.loads(out)
    except json.JSONDecodeError:
        return strip_ansi(out)
    return _parse_transcription(payload)


# ------------------------------------------------------- persistent whisper
#
# Loading faster-whisper costs several seconds - it reads the model weights
# from disk every time. Doing that per clip made /wake answer every ~8
# seconds, the phone's upload queue overflowed, chunks were dropped, and the
# wake word was often missed. The worker keeps the model resident and answers
# one clip at a time.

WHISPER_MODEL = os.environ.get("WHISPER_MODEL", "base")
# faster-whisper works in 16 kHz, which is also what the phone sends
WHISPER_SAMPLE_RATE = 16000
_whisper_worker = None
_whisper_worker_lock = threading.Lock()
_whisper_io_lock = threading.Lock()


def load_audio(path):
    """Read a WAV file into the float32 array faster-whisper expects.

    faster-whisper hands a file path to PyAV, and PyAV 15+ dropped the
    'metadata_errors' argument that faster-whisper still passes to av.open().
    With PyAV 19 installed, every single clip then fails with
    "TypeError: open() got an unexpected keyword argument 'metadata_errors'".

    The bridge only ever receives plain PCM WAV from the phone, so it reads
    the samples itself and never calls PyAV at all. That makes the decoder
    work on every PyAV version, including the newest one.
    """
    import numpy as np
    import wave

    with wave.open(str(path), "rb") as handle:
        channels = handle.getnchannels()
        width = handle.getsampwidth()
        rate = handle.getframerate()
        frames = handle.readframes(handle.getnframes())

    if width == 2:
        data = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
    elif width == 1:
        data = (np.frombuffer(frames, dtype=np.uint8).astype(np.float32) - 128.0) / 128.0
    elif width == 4:
        data = np.frombuffer(frames, dtype=np.int32).astype(np.float32) / 2147483648.0
    elif width == 3:
        raw = np.frombuffer(frames, dtype=np.uint8).reshape(-1, 3).astype(np.int32)
        value = raw[:, 0] | (raw[:, 1] << 8) | (raw[:, 2] << 16)
        value = np.where(value & 0x800000, value - 0x1000000, value)
        data = value.astype(np.float32) / 8388608.0
    else:
        raise ValueError(f"unsupported sample width: {width} bytes")

    if channels > 1:
        data = data.reshape(-1, channels).mean(axis=1)

    if rate and rate != WHISPER_SAMPLE_RATE and len(data) > 1:
        count = int(round(len(data) * WHISPER_SAMPLE_RATE / float(rate)))
        if count > 0:
            data = np.interp(
                np.linspace(0, len(data) - 1, count),
                np.arange(len(data)),
                data,
            ).astype(np.float32)

    return np.ascontiguousarray(data, dtype=np.float32)


def whisper_worker_main():
    """Run as a child process: load the model once, then transcribe on demand."""
    try:
        from faster_whisper import WhisperModel
    except Exception as exc:  # noqa: BLE001
        print(f"worker: faster_whisper unavailable: {exc}", file=sys.stderr, flush=True)
        return 1
    try:
        model = WhisperModel(WHISPER_MODEL, device="cpu", compute_type="int8")
    except Exception as exc:  # noqa: BLE001
        print(f"worker: could not load '{WHISPER_MODEL}': {exc}", file=sys.stderr, flush=True)
        return 1
    print("ready", flush=True)
    for line in sys.stdin:
        path = line.strip()
        if not path:
            continue
        if path == "__quit__":
            break
        try:
            # read the wav here instead of handing faster-whisper a path:
            # that keeps PyAV out of the picture entirely
            try:
                audio = load_audio(path)
            except Exception:
                audio = path
            segments, _ = model.transcribe(audio)
            text = " ".join(s.text.strip() for s in segments).strip()
            print("OK " + text, flush=True)
        except Exception as exc:  # noqa: BLE001
            print("ERR " + str(exc)[:200], flush=True)
    return 0


def _start_whisper_worker():
    """Spawn the worker, or return None when faster-whisper is not installed."""
    global _whisper_worker
    with _whisper_worker_lock:
        if _whisper_worker is not None:
            return _whisper_worker
        try:
            import faster_whisper  # noqa: F401
        except Exception:  # noqa: BLE001
            return None
        try:
            proc = subprocess.Popen(
                [sys.executable, os.path.abspath(__file__), "--whisper-worker"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, text=True, bufsize=1,
            )
            if proc.stdout.readline().strip() != "ready":
                proc.kill()
                return None
        except Exception:  # noqa: BLE001
            return None
        _whisper_worker = proc
        log(f"whisper worker up (model {WHISPER_MODEL})")
        return proc


def transcribe_whisper_worker(wav_path):
    """Transcribe through the resident worker. None means 'not available'."""
    global _whisper_worker
    proc = _start_whisper_worker()
    if proc is None:
        return None
    with _whisper_io_lock:
        try:
            proc.stdin.write(str(wav_path) + "\n")
            proc.stdin.flush()
            line = proc.stdout.readline().strip()
        except (OSError, ValueError):
            line = ""
        if not line:
            # the worker died - drop it so the next call starts a fresh one
            with _whisper_worker_lock:
                if _whisper_worker is proc:
                    _whisper_worker = None
            try:
                proc.kill()
            except OSError:
                pass
            return None
    if line.startswith("ERR "):
        raise RuntimeError(line[4:].strip()[:200])
    if line == "OK":
        return ""
    if line.startswith("OK "):
        return line[3:].strip()
    return None


def transcribe_whisper(wav_path):
    """Local whisper: a resident faster-whisper worker, then the CLI, then whisper.cpp."""
    wav_path = Path(wav_path)

    # 1. the resident worker - fast, because the model stays in memory
    try:
        text = transcribe_whisper_worker(wav_path)
    except Exception as exc:  # noqa: BLE001
        log(f"whisper worker failed: {exc}")
        text = None
    if text is not None:
        return text

    # 2. one-shot faster-whisper, in case the worker could not be started
    # it loads the bridge's own wav reader, so PyAV is never used either
    bridge_file = os.path.abspath(__file__)
    faster_whisper_snippet = (
        "import sys, importlib.util\n"
        "spec = importlib.util.spec_from_file_location('orb_bridge', sys.argv[3])\n"
        "bridge = importlib.util.module_from_spec(spec)\n"
        "spec.loader.exec_module(bridge)\n"
        "from faster_whisper import WhisperModel\n"
        "model = WhisperModel(sys.argv[2], device='cpu', compute_type='int8')\n"
        "segments, _ = model.transcribe(bridge.load_audio(sys.argv[1]))\n"
        "print(' '.join(s.text.strip() for s in segments))\n"
    )
    for python in (
        "python3",
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "venv", "bin", "python"),
        "/usr/bin/python3",
        os.path.expanduser("~/.hermes/venv/bin/python"),
    ):
        if not shutil.which(python) and not os.path.exists(python):
            continue
        rc, out, err = run(
            [python, "-c", faster_whisper_snippet, str(wav_path), "base", bridge_file],
            timeout=600,
        )
        if rc == 0 and out.strip():
            return out.strip()
        if "No module named faster_whisper" not in err:
            last = err.strip()
            if rc == 0:
                continue
    if have("whisper"):
        out_dir = Path(tempfile.mkdtemp())
        rc, out, err = run(
            ["whisper", str(wav_path), "--model", "base", "--output_format", "txt",
             "--output_dir", str(out_dir)],
            timeout=600,
        )
        produced = out_dir / (wav_path.stem + ".txt")
        if rc == 0 and produced.exists():
            text = produced.read_text().strip()
            if text:
                return text
            raise RuntimeError("whisper heard no speech in this clip")
        raise RuntimeError(f"whisper failed (rc={rc}): {strip_ansi(err)[:160]}")
    if have("whisper-cli") or have("main"):
        binary = "whisper-cli" if have("whisper-cli") else "main"
        out_file = Path(tempfile.mkdtemp()) / "out.txt"
        rc, out, err = run([binary, "-f", str(wav_path), "-otxt", "-of", str(out_file.with_suffix(""))],
                           timeout=600)
        if out_file.exists():
            text = out_file.read_text().strip()
            if text:
                return text
        raise RuntimeError(f"whisper.cpp failed: {strip_ansi(err)[:200]}")
    raise RuntimeError("no local whisper available")


def transcribe(wav_bytes, prefer_local=False):
    """Transcribe a WAV clip.

    prefer_local=True is used for wake-word chunks: local faster-whisper is
    orders of magnitude faster than a cloud transcription, and the answer only
    has to contain the wake word.
    """
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as handle:
        handle.write(wav_bytes)
        wav_path = handle.name
    try:
        if prefer_local:
            try:
                text = transcribe_whisper(wav_path)
                _hints["stt"] = "whisper"
                return text
            except Exception as exc:  # noqa: BLE001
                log(f"local transcription failed: {exc}")
        try:
            text = transcribe_mcode_tools(wav_path)
            _hints["stt"] = "mcode-tools"
            return text
        except Exception as exc:  # noqa: BLE001
            log(f"mcode-tools transcription failed: {exc}")
        try:
            text = transcribe_whisper(wav_path)
            _hints["stt"] = "whisper"
            return text
        except Exception as exc:  # noqa: BLE001
            log(f"whisper transcription failed: {exc}")
        raise RuntimeError("no speech-to-text backend available")
    finally:
        try:
            os.unlink(wav_path)
        except OSError:
            pass


def _wake_aliases(phrase):
    compact = "".join(phrase.lower().split())
    return {compact, compact + "s", compact + "es"}


WAKE_PHRASE = os.environ.get("WAKE_PHRASE", "orbit").strip().lower()
WAKE_PHRASES = _wake_aliases(WAKE_PHRASE)

# Spoken fillers that a transcriber inserts inside a word: "orbit" -> "or a bit"
FILLER_WORDS = {"a", "uh", "um", "u", "er", "erm", "the", "hmm", "mm", "h", "m"}

# Politeness words that may sit in front of the wake word: "hey orbit"
LEADING_NOISE = {"hey", "hi", "ok", "okay", "yo", "so", "well", "uh", "um"}


def _levenshtein(a, b):
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


def _spoken_form(word):
    """The word as it is actually pronounced.

    A leading h before a vowel is usually not spoken ("horbit"), and a final
    d is often a t the transcriber heard wrong ("orbid").
    """
    out = word
    if len(out) > 2 and out.startswith("h") and out[1] in "aeiou":
        out = out[1:]
    if len(out) > 2 and out.endswith("d"):
        out = out[:-1] + "t"
    return out


def _consonants(word):
    """The consonants of a word: the skeleton a listener hears.

    The endings a transcriber gets wrong are forgiven, so "orbits" and
    "orbids" have the same skeleton.
    """
    skeleton = "".join(ch for ch in word if ch not in "aeiou")
    if skeleton.endswith("ts"):
        skeleton = skeleton[:-1]
    elif skeleton.endswith("ds"):
        skeleton = skeleton[:-2] + "t"
    elif skeleton.endswith("d"):
        skeleton = skeleton[:-1] + "t"
    return skeleton


def _sounds_like(candidate, alias):
    """Does this word sound like the wake phrase?

    Whisper renders "Orbit" in ways that no spelling rule catches: "Horbid"
    (an aspirated h and a final d), "orbot" (the second vowel drifts) or
    "orbt" (the middle vowel swallowed). These rules compare how the word
    sounds rather than how it was spelled.
    """
    if not 3 <= len(candidate) <= 8:
        return False
    spoken = _spoken_form(candidate)
    if spoken == alias:
        return True
    # one letter off, but only for a word nearly as long as the phrase
    if len(spoken) >= len(alias) - 1 and _levenshtein(spoken, alias) <= 1:
        return True
    # the same consonants in the same order: "rabbit" is not "orbit"
    if _consonants(spoken) != _consonants(alias):
        return False
    if len(candidate) > len(alias) + 1:
        return False
    return _levenshtein(spoken, alias) <= 2


def _is_clipped_word(candidate, aliases):
    """A word the transcriber cut short: "Orb" instead of "Orbit".

    The fragment has to keep at least three letters and two of the phrase's
    consonants. A bare "or" is far too common in ordinary speech - "or not",
    "or maybe", "or the" all start with one - and treating it as the wake
    word woke the orb on nearly every sentence that came out of a
    television.
    """
    if len(candidate) < 3:
        return False
    spoken = _spoken_form(candidate)
    skeleton = _consonants(spoken)
    if len(skeleton) < 2:
        return False
    return any(
        len(a) > len(spoken)
        and a.startswith(spoken)
        and skeleton in _consonants(a)
        for a in aliases
    )


def _starts_utterance(words, index):
    """The wake word is said first, so only the front of the utterance counts."""
    if index == 0:
        return True
    return index == 1 and words[0] in LEADING_NOISE


def _is_bare_clipped_word(words, index, aliases):
    """The wake word was cut short to a bare "or".

    "or" is a perfectly ordinary English word, and treating it as the wake
    word woke the orb on nearly every sentence that started with one: "or
    not", "or maybe", "or the". A dictionary of 197,000 words gave 196,344
    such pairs.

    It is still a real case - whisper sometimes leaves nothing but "or"
    behind - so it counts when it is all the transcriber heard. A sentence
    that carries on after it is a sentence, not a wake word.
    """
    candidate = words[index]
    if len(candidate) != 2:
        return False
    if not any(
        len(a) > len(candidate) and a.startswith(candidate) for a in aliases
    ):
        return False
    # it has to be the whole utterance, apart from a politeness word
    if index == 0:
        return len(words) == 1
    return index == 1 and len(words) == 2 and words[0] in LEADING_NOISE


def _wake_candidates(words, start, size):
    """Candidate spellings of a run of spoken tokens.

    "orbit" may arrive as ["orbit"], ["or","bit"] or ["or","a","bit"], so a
    window is joined both as-is and with the spoken fillers removed.
    """
    window = words[start:start + size]
    if not window:
        return []
    candidates = ["".join(window)]
    stripped = [w for w in window if w not in FILLER_WORDS]
    if stripped and len(stripped) != len(window):
        candidates.append("".join(stripped))
    return candidates


def _sounds_like_joined(joined, alias):
    """Does a joined run of words sound like the phrase?

    Spelling is far too loose for a joined run: "or not" is two edits away
    from "orbit" and "for a bit" is only one, and both of them are
    ordinary English. The consonants are what a listener hears, so the run
    has to carry the same ones as the word itself.
    """
    if not 3 <= len(joined) <= 12:
        return False
    spoken = _spoken_form(joined)
    if spoken == alias:
        return True
    if _consonants(spoken) != _consonants(alias):
        return False
    return _levenshtein(spoken, alias) <= 2


def _fuzzy_wake_hit(joined, tokens):
    """Fuzzy match of one joined candidate against the wake phrase.

    A single spoken token may be one character off ("orbt" -> "orbit") and may
    even sound different but identical ("Horbid" -> "orbit").

    A joined run of words has to *sound* like the phrase as well. Spelling
    alone is far too loose here: "or not" is only two edits away from
    "orbit", and a television talking about anything at all woke the orb.
    "or bid" and "or a bit" still work, because they carry the consonants of
    the word.
    """
    for alias in WAKE_PHRASES:
        if tokens == 1:
            if 3 <= len(joined) <= 8 and _levenshtein(joined, alias) <= 1:
                return True
            if _sounds_like(joined, alias):
                return True
        else:
            if _sounds_like_joined(joined, alias):
                return True
    return False


def _match_at(words, index):
    """How many tokens the wake word covers at this position (0 = no match).

    A direct spelling is preferred over the clipped-word fallback, so
    "or a bit" wins over the clipped "or" that starts the same phrase.
    """
    for n in (1, 2, 3):
        if index + n > len(words):
            break
        for joined in _wake_candidates(words, index, n):
            if joined in WAKE_PHRASES:
                return n
            if _fuzzy_wake_hit(joined, n):
                return n
    # a clipped wake word only counts at the front of the utterance
    if (
        index < len(words)
        and _starts_utterance(words, index)
        and _is_clipped_word(words[index], WAKE_PHRASES)
    ):
        return 1
    # a bare "or" is the one fragment that is too common to trust, so it
    # only counts when it is all the transcriber heard
    if index < len(words) and _is_bare_clipped_word(words, index, WAKE_PHRASES):
        return 1
    return 0


def wake_detected(text):
    """Mirror of the phone's wake-word matcher, so the bridge can answer early.

    Consecutive tokens are joined before comparing, because whisper likes to
    render "Orbit" as "or a bit" - three tokens, not one.
    """
    cleaned = re.sub(r"[^a-z\s]", " ", (text or "").lower())
    words = [w for w in cleaned.split() if w]
    for i in range(len(words)):
        if _match_at(words, i) > 0:
            return True
    return False


# ------------------------------------------------------------------ Synthesize


def synthesize_mmx(text, voice=None):
    if not have("mmx"):
        raise RuntimeError("mmx CLI not installed")
    with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as handle:
        out_path = handle.name
    cmd = ["mmx", "speech", "synthesize", "--text", text, "--out", out_path, "--quiet"]
    chosen = (voice or MMX_VOICE).strip()
    if chosen:
        cmd += ["--voice", chosen]
    try:
        rc, out, err = run(cmd, timeout=300)
        if rc != 0 or not os.path.exists(out_path) or os.path.getsize(out_path) == 0:
            raise RuntimeError(f"mmx failed rc={rc}: {strip_ansi(err)[:200]}")
        return Path(out_path).read_bytes()
    finally:
        try:
            os.unlink(out_path)
        except OSError:
            pass


def synthesize_edge(text, voice=None):
    """Microsoft Edge TTS: free, no API key, very natural. Needs `pip install edge-tts`."""
    if not have("edge-tts"):
        raise RuntimeError("edge-tts not installed")
    with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as handle:
        out_path = handle.name
    chosen = (voice or os.environ.get("EDGE_VOICE", "en-US-AriaNeural")).strip()
    try:
        rc, out, err = run(
            ["edge-tts", "--voice", chosen, "--text", text, "--write-media", out_path],
            timeout=300,
        )
        if rc != 0 or not os.path.exists(out_path) or os.path.getsize(out_path) == 0:
            raise RuntimeError(f"edge-tts failed rc={rc}: {strip_ansi(err)[:200]}")
        return Path(out_path).read_bytes()
    finally:
        try:
            os.unlink(out_path)
        except OSError:
            pass


def synthesize_piper(text, voice=None):
    if not have("piper"):
        raise RuntimeError("piper not installed")
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as handle:
        out_path = handle.name
    cmd = ["piper"]
    model = (voice or os.environ.get("PIPER_MODEL", "")).strip()
    if model:
        cmd += ["--model", model]
    cmd += ["--output_file", out_path]
    try:
        rc, out, err = run(cmd, timeout=300, stdin_text=text)
        if rc != 0 or not os.path.exists(out_path) or os.path.getsize(out_path) == 0:
            raise RuntimeError(f"piper failed rc={rc}: {strip_ansi(err)[:200]}")
        return Path(out_path).read_bytes()
    finally:
        try:
            os.unlink(out_path)
        except OSError:
            pass


def synthesize(text, voice=None):
    try:
        audio = synthesize_mmx(text, voice)
        _hints["tts"] = "mmx"
        return audio
    except Exception as exc:  # noqa: BLE001
        log(f"mmx synthesis failed: {exc}")
    try:
        audio = synthesize_edge(text, voice)
        _hints["tts"] = "edge"
        return audio
    except Exception as exc:  # noqa: BLE001
        log(f"edge-tts synthesis failed: {exc}")
    try:
        audio = synthesize_piper(text, voice)
        _hints["tts"] = "piper"
        return audio
    except Exception as exc:  # noqa: BLE001
        log(f"piper synthesis failed: {exc}")
    raise RuntimeError("no text-to-speech backend available")


# ---------------------------------------------------------------------- Server


class Handler(BaseHTTPRequestHandler):
    server_version = "HermesBridge/1.0"

    def log_message(self, fmt, *args):  # quieter, structured logging
        log(f"{self.address_string()} {fmt % args}")

    def _authorized(self):
        if not TOKENS:
            return True
        return self.headers.get("X-Auth-Token", "").strip() in TOKENS

    def _send_json(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_bytes(self, data, content_type, status=200):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        return self.rfile.read(length) if length else b""

    def do_GET(self):
        if self.path.rstrip("/") in ("/health", ""):
            self._send_json({
                "ok": True,
                "bridge": BRIDGE_VERSION,
                "hermes": _hints["hermes"],
                "hermes_available": hermes_available(),
                "hermes_error": _last_error,
                "hermes_errors": list(_backend_errors[-6:]),
                "hermes_model": HERMES_CLI_MODEL,
                "hermes_models": model_report(),
                "hermes_settings": model_settings(),
                "hermes_config": agent_config(),
                "hermes_report": _cli_report,
                "hermes_tail": _cli_tail,
                "hermes_help": cli_help(),
                "journal": journal_status(),
                "account": account_status(),
                "stt": _hints["stt"],
                "tts": _hints["tts"],
                "token_required": bool(TOKEN),
            })
            return
        self._send_json({"error": "not found"}, 404)

    def do_POST(self):
        if not self._authorized():
            self._send_json({"error": "unauthorized"}, 401)
            return

        route = self.path.rstrip("/")
        body = self._read_body()

        try:
            if route == "/chat":
                payload = json.loads(body or b"{}")
                text = str(payload.get("text", "")).strip()
                session = str(payload.get("session", "")).strip()
                if not text:
                    self._send_json({"error": "text required"}, 400)
                    return
                reply = hermes_chat(text, session)
                self._send_json({"reply": reply})
                return

            if route == "/stt":
                if not body:
                    self._send_json({"error": "audio body required"}, 400)
                    return
                text = transcribe(body)
                self._send_json({"text": text})
                return

            if route == "/wake":
                if not body:
                    self._send_json({"error": "audio body required"}, 400)
                    return
                text = transcribe(body, prefer_local=True)
                woke = wake_detected(text)
                # log what the transcriber actually heard - without this the
                # wake word is impossible to debug
                log(f"wake heard={text!r} wake={woke}")
                self._send_json({"text": text, "wake": woke})
                return

            if route == "/tts":
                payload = json.loads(body or b"{}")
                text = str(payload.get("text", "")).strip()
                voice = str(payload.get("voice", "") or "")
                if not text:
                    self._send_json({"error": "text required"}, 400)
                    return
                audio = synthesize(text, voice)
                self._send_bytes(audio, "audio/mpeg")
                return
        except Exception as exc:  # noqa: BLE001
            log(f"{route} failed: {exc}")
            self._send_json({"error": str(exc)}, 502)
            return

        self._send_json({"error": "not found"}, 404)


def main():
    if "--whisper-worker" in sys.argv:
        sys.exit(whisper_worker_main())
    if not TOKEN:
        log("WARNING: BRIDGE_TOKEN is empty - anyone who can reach this port can use Hermes.")
    log(f"  Hermes target : {HERMES_BASE_URL} (model {HERMES_MODEL})")
    log(f"  MiniMax CLI   : {'yes' if have('mmx') else 'no'}")
    log(f"  edge-tts      : {'yes' if have('edge-tts') else 'no'}")
    log(f"  mcode-tools   : {'yes' if have('mcode-tools') else 'no'}")
    log(f"  whisper       : {'yes' if (have('whisper') or have('whisper-cli')) else 'no'}")
    try:
        import faster_whisper  # noqa: F401
        log(f"  faster-whisper: yes (model {WHISPER_MODEL}, stays resident)")
    except Exception:  # noqa: BLE001
        log("  faster-whisper: no (each clip reloads the model - slower)")

    def warm_up_whisper():
        # load the model in the background so the very first wake word is fast
        try:
            import faster_whisper  # noqa: F401
            _start_whisper_worker()
        except Exception:  # noqa: BLE001
            pass

    # The port is taken BEFORE the whisper worker is started.
    #
    # A bridge that cannot listen has no business loading a model. When a
    # second bridge was started while the first one was running, every
    # attempt loaded a fresh faster-whisper model before it found the port
    # taken - and the model that was actually answering the phone got less
    # and less of the machine. The wake word went from a second to five.
    try:
        server = ThreadingHTTPServer((HOST, PORT), Handler)
    except OSError as exc:
        log(f"cannot listen on {HOST}:{PORT}: {exc}")
        log("another bridge is already using this port - this one stops here")
        return 1
    server.daemon_threads = True
    log(f"Hermes bridge listening on http://{HOST}:{PORT}")

    threading.Thread(target=warm_up_whisper, daemon=True).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("shutting down")
        server.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
