#!/usr/bin/env python3
"""
test-bridge-backend.py - the orb must talk to the Hermes agent, not to Ollama.

Ollama on the Beelink is only a model server: it answers from the prompt
alone, with no memory and no tools, so the orb would know nothing about the
machine. The Hermes agent is the one with the memory and the tools, so the
bridge has to reach for it first.

This checks the order the bridge tries its backends in.
"""
import importlib.util
import json
import os
import tempfile
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRIDGE = os.path.join(ROOT, "beelink", "hermes_bridge.py")

FAILURES = 0


def check(label, ok, detail=""):
    global FAILURES
    print(f"  {'PASS' if ok else 'FAIL'}  {label}" + (f"  {detail}" if detail else ""))
    if not ok:
        FAILURES += 1


def load(prefer=None):
    """Load the bridge with HERMES_PREFER set to the given value."""
    if prefer is not None:
        os.environ["HERMES_PREFER"] = prefer
    else:
        os.environ.pop("HERMES_PREFER", None)
    spec = importlib.util.spec_from_file_location("bridge_under_test", BRIDGE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def order(module, api_up=True):
    """Which backends the bridge tries, and in what order."""
    calls = []
    module.hermes_api_reachable = lambda: api_up
    module.hermes_api_chat = lambda text, session: calls.append("api") or "ok"
    module.hermes_cli_chat = lambda text, session: calls.append("cli") or "ok"
    module.ollama_chat = lambda text, session: calls.append("ollama") or "ok"
    module.hermes_chat("hello", "session")
    return calls


class FakeResponse:
    """The little bit of a HTTP response the model server check needs."""

    def __init__(self, body):
        self.body = body

    def read(self):
        return self.body

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


def main():
    print("BRIDGE BACKEND ORDER")

    # the default: the agent first
    module = load(prefer=None)
    check("the default prefers the Hermes agent", module.HERMES_PREFER == "auto",
          f"HERMES_PREFER={module.HERMES_PREFER!r}")
    check("the agent is tried before Ollama", order(module) == ["api"],
          f"order={order(module)}")

    # the agent's API server is down, the CLI is there
    module = load(prefer="auto")
    check("the CLI is tried when the API server is down",
          order(module, api_up=False) == ["cli"], f"order={order(module, api_up=False)}")

    # a plain Ollama host can still ask for Ollama only
    module = load(prefer="ollama")
    check("'ollama' keeps Ollama first", order(module) == ["ollama"],
          f"order={order(module)}")

    # and when the agent fails, Ollama still answers - the orb never goes mute
    module = load(prefer="auto")
    def broken(text, session):
        raise RuntimeError("no agent here")
    module.hermes_api_reachable = lambda: True
    module.hermes_api_chat = broken
    module.hermes_cli_chat = broken
    module.ollama_chat = lambda text, session: "ollama answer"
    check("Ollama answers when the agent fails",
          module.hermes_chat("hello", "session") == "ollama answer")

    # the CLI wraps the answer in a label, a rule and a session footer
    module = load(prefer="auto")
    sample = (
        "Query: \n\nReply with exactly: HELLO\n\n"
        "────────────────────────────────────────\n"
        "☤ Hermes\n"
        "HELLO\n"
        "────────────────────────────────────────\n\n"
        "Resume this session with:\n"
        "  hermes --resume local-e60f2a236f35887f840964ea819c984fc8d034ab2dd4d00caa3c9194b8cdeae7\n\n"
        "Session:        local-e60f2a236f35887f840964ea819c984fc8d034ab2dd4d00caa3c9194b8cdeae7\n"
        "Duration:       10s\n"
        "Messages:       2 (1 user, 0 tool calls)\n"
    )
    got = module.clean_cli_output(sample)
    check("the CLI answer is taken out of the chrome", got == "HELLO", repr(got))

    multi = (
        "Query: \n\ntell me two things\n\n"
        "────────────────────────────────────────\n"
        "☤ Hermes\n"
        "First paragraph.\n\n"
        "Second paragraph.\n"
        "────────────────────────────────────────\n"
        "Session:        local-abc\n"
    )
    got = module.clean_cli_output(multi)
    check("a multi paragraph answer survives",
          got == "First paragraph.\n\nSecond paragraph.", repr(got))

    # The agent can fail while the CLI still exits with 0 - it did exactly
    # that when the CLI had no model: "HTTP 400: model is required". That
    # report must never become the answer the orb reads out.
    failed = (
        "\U0001f916 AI Agent with Tool Calling\n"
        "==================================================\n"
        "\U0001f916 AI Agent initialized with model: \n"
        "\U0001f511 Using API key: no-key-required\n"
        "\U0001f9e0 Disabled toolset 'onboarding': setup_beat\n"
        "\U0001f4ca Context limit: 256,000 tokens (compress at 75% = 192,000)\n\n"
        "\U0001f4dd User Query: [current local time: Tuesday, 2026-11-17 15:00:00 GMT+08:00]\n\n"
        "Reply with exactly one short sentence: what is a liquid glass orb?\n\n"
        "==================================================\n"
        "\U0001f4ac Starting conversation: '...'\n\n"
        "\U0001f504 Making API call #1/10...\n"
        "   \U0001f4ca Request size: 2 messages, ~4,017 tokens\n"
        "\u26a0\ufe0f Attempt 1/3, not retryable failed: HTTP 400: model is required\n"
        "\u274c OpenRouter rejected the request and retrying won't help: HTTP 400: model is required\n"
        "\n"
        "\U0001f4cb CONVERSATION SUMMARY\n"
        "==================================================\n"
        "\u2705 Completed: False\n"
        "\U0001f4de API Calls: 1\n"
        "\U0001f4ac Messages: 1\n\n"
        "\U0001f3af FINAL RESPONSE:\n"
        "------------------------------\n"
        "OpenRouter rejected this request as malformed, so the model didn't answer.\n"
        "\n"
        "Provider said: HTTP 400: model is required\n"
        "\n"
        "\U0001f3c1 Agent execution completed!\n"
    )
    # The bridge's own settings must not reach the CLI. They describe the
    # agent's API server - which is not running - so the CLI inherited a
    # dead endpoint, found no model, and answered "model is required". The
    # orb then fell back to Ollama, which has no tools and cannot search.
    module = load(prefer="auto")
    os.environ["HERMES_BASE_URL"] = "http://127.0.0.1:8642/v1"
    os.environ["HERMES_MODEL"] = "hermes-agent"
    os.environ["HERMES_API_KEY"] = "bridge-token"
    os.environ["OLLAMA_MODEL"] = "qwen3.8-27b-hermes:latest"
    env = module.cli_env()
    check("the CLI does not inherit the bridge's base url",
          "HERMES_BASE_URL" not in env)
    check("the CLI does not inherit the bridge's model",
          "HERMES_MODEL" not in env)
    check("the CLI does not inherit the bridge's api key",
          "HERMES_API_KEY" not in env)
    check("the CLI does not inherit the Ollama settings",
          "OLLAMA_MODEL" not in env)
    check("the CLI keeps the path and the home folder",
          "PATH" in env and "HOME" in env)

    # An answer that starts with an emoji is still an answer. Throwing it
    # away left the bridge with nothing to say, and it fell back to Ollama.
    module = load(prefer="auto")
    emoji_answer = (
        "Query: \n\nhow are the raptors doing\n\n"
        "\U0001f916 AI Agent with Tool Calling\n"
        "==================================================\n"
        "\U0001f4ac Starting conversation: '...'\n\n"
        "==================================================\n"
        "\U0001f3af FINAL RESPONSE:\n"
        "------------------------------\n"
        "\U0001f4c1 The Raptors are 12-4 this season.\n"
    )
    got = module.clean_cli_output(emoji_answer)
    check("an answer that starts with an emoji survives",
          "Raptors are 12-4" in got, repr(got[:120]))

    # A newer build labels the answer its own way
    module = load(prefer="auto")
    own_label = (
        "Query: \n\nhello\n\n"
        "\U0001f916 AI Agent with Tool Calling\n"
        "\U0001f4ac Starting conversation\n"
        "------------------------------\n"
        "\U0001f916 Hermes\n"
        "Hello there.\n"
        "------------------------------\n"
        "Session: local-abc\n"
    )
    got = module.clean_cli_output(own_label)
    check("a label the bridge has never seen is still found",
          got == "Hello there.", repr(got[:120]))

    # No label at all: the answer is the last block before the footer
    module = load(prefer="auto")
    no_label = (
        "\U0001f916 AI Agent with Tool Calling\n"
        "\U0001f4ac Starting conversation\n"
        "------------------------------\n"
        "The Raptors won last night.\n"
        "------------------------------\n"
        "Session: local-abc\n"
    )
    got = module.clean_cli_output(no_label)
    check("an unlabelled answer is still found",
          "Raptors won last night" in got, repr(got[:120]))

    check("a failed agent is spotted", module.cli_output_failed(failed) != "",
          repr(module.cli_output_failed(failed)))
    check("a failed report is never read out", module.clean_cli_output(failed) == "",
          repr(module.clean_cli_output(failed)[:120]))

    # the CLI path has to treat that as a failure, not as an answer
    module.run = lambda cmd, timeout=120, stdin_text=None, env=None: (0, failed, "")
    module.have = lambda binary: True
    try:
        module.hermes_cli_chat("hello", "session")
        raised = False
    except RuntimeError:
        raised = True
    check("a failed agent raises, so the orb falls back to Ollama", raised)

    # and the health endpoint says which build is running
    source = open(BRIDGE, encoding="utf-8").read()
    check("the bridge reports its version", '"bridge": BRIDGE_VERSION' in source
          and bool(module.BRIDGE_VERSION))
    check("the bridge reports the last error", '"hermes_error": _last_error' in source)
    check("the health says which model the agent uses",
          '"hermes_models": model_report()' in source)

    # The CLI has two shapes. The verbose agent mode needs a model of its own
    # and reports "model is required" while still exiting with 0; the quiet
    # mode answers with the same agent. The bridge has to fall through to the
    # quiet one instead of reading the failure report out loud.
    module = load(prefer="auto")
    module.have = lambda binary: True
    quiet = (
        "Query: \n\nhello\n\n"
        "────────────────────────\n"
        "☤ Hermes\n"
        "The answer.\n"
        "────────────────────────\n\n"
        "Resume this session with:\n  hermes --resume local-abc\n"
    )
    calls = []

    def fake_run(cmd, timeout=120, stdin_text=None, env=None):
        calls.append(cmd)
        if "--query" in cmd:
            return 0, failed, ""
        return 0, quiet, ""

    module.run = fake_run
    got = module.hermes_cli_chat("hello", "session")
    check("the quiet mode answers when the agent mode has no model",
          got == "The answer.", repr(got))
    check("the agent mode was tried first", bool(calls) and "--query" in calls[0],
          repr(calls[:1]))

    # and the broken mode is left alone afterwards, so the next question does
    # not have to wait for it to fail again
    calls.clear()
    module.hermes_cli_chat("hello again", "session")
    check("the broken mode is skipped after it failed",
          all("--query" not in cmd or "--model" in cmd for cmd in calls),
          repr(calls))

    # The CLI has no "chat" subcommand. "hermes chat --query ..." prints its
    # own usage and exits, so the agent never ran and the bridge fell back to
    # Ollama - a model server with no tools and no web search. The prompt goes
    # in with "--query" (or "-z") and the model with "--model".
    module = load(prefer="auto")
    os.environ["HERMES_CLI_MODEL"] = "base"
    fake_home = tempfile.mkdtemp()
    os.makedirs(os.path.join(fake_home, ".hermes"), exist_ok=True)
    with open(os.path.join(fake_home, ".hermes", "config.yaml"), "w") as handle:
        handle.write(
            "model:\n"
            "  default: qwen3.8-27b-hermes\n"
            "  provider: custom\n"
            "  base_url: http://localhost:11434/v1\n"
            "stt:\n"
            "  model: base\n"
            "tts:\n"
            "  model: whisper-1\n"
        )
    real_expanduser = module.os.path.expanduser
    module.os.path.expanduser = lambda path: fake_home if path == "~" else real_expanduser(path)
    try:
        found = module.config_model_default()
        candidates = module.cli_candidates()
    finally:
        module.os.path.expanduser = real_expanduser
    check("the agent's model comes from model.default",
          found == "qwen3.8-27b-hermes", repr(found))
    check("the model is in front of the command",
          candidates[0][0] == "hermes" and candidates[0][1] == "--model"
          and "chat" in candidates[0], repr(candidates[0]))
    check("the prompt goes with --query",
          "--query" in candidates[0], repr(candidates[0]))
    check("no command is left without a model",
          all("--model" in candidate for candidate in candidates),
          repr(candidates[:2]))
    check("the CLI is told the agent's model, not the speech one",
          "--model" in candidates[0]
          and candidates[0][candidates[0].index("--model") + 1] == "qwen3.8-27b-hermes",
          repr(candidates[0]))
    check("the speech model is never used as the agent's model",
          all("--base" not in " ".join(c) and "whisper-1" not in " ".join(c)
              for c in candidates), repr(candidates[:1]))

    # The tagged model is tried as well. Ollama serves "name:latest", and a
    # name without a tag is not always the model that is really there.
    module = load(prefer="auto")
    os.environ["HERMES_CLI_MODEL"] = "base"
    os.environ["OLLAMA_MODEL"] = "qwen3.8-27b-hermes:latest"
    fake_home = tempfile.mkdtemp()
    os.makedirs(os.path.join(fake_home, ".hermes"), exist_ok=True)
    with open(os.path.join(fake_home, ".hermes", "config.yaml"), "w") as handle:
        handle.write("model:\n  default: qwen3.8-27b-hermes\n")
    real_expanduser = module.os.path.expanduser
    module.os.path.expanduser = lambda path: fake_home if path == "~" else real_expanduser(path)
    try:
        candidates = module.cli_candidates()
    finally:
        module.os.path.expanduser = real_expanduser
    check("the tagged model is tried as well",
          any("--model" in c and c[c.index("--model") + 1] == "qwen3.8-27b-hermes:latest"
              for c in candidates),
          repr(candidates[:2]))
    os.environ.pop("OLLAMA_MODEL", None)

    # The model the agent has actually used is in its session files. That name
    # is known to work, so it comes before everything else.
    module = load(prefer="auto")
    fake_home = tempfile.mkdtemp()
    sessions = os.path.join(fake_home, ".hermes", "sessions")
    os.makedirs(sessions, exist_ok=True)
    with open(os.path.join(sessions, "local-abc.json"), "w") as handle:
        handle.write('{"model": "qwen3.8-27b-hermes:latest", "messages": []}')
    real_expanduser = module.os.path.expanduser
    module.os.path.expanduser = lambda path: fake_home if path == "~" else real_expanduser(path)
    try:
        found = module.session_models()
    finally:
        module.os.path.expanduser = real_expanduser
    check("the model the agent used is found in its sessions",
          found == ["qwen3.8-27b-hermes:latest"], repr(found))

    # The model server is asked what it has, and the agent's own model comes
    # first.
    module = load(prefer="auto")
    module.urllib.request.urlopen = lambda *args, **kwargs: FakeResponse(
        json.dumps({"models": [{"name": "llama3:8b"}, {"name": "qwen3.8-27b-hermes:latest"}]}).encode()
    )
    names = module.ollama_models()
    check("the model the agent has is asked for first",
          bool(names) and names[0] == "qwen3.8-27b-hermes:latest", repr(names))

    # When the settings file does not name a model, the pinned value is used
    # - but only when it is not a speech model. A speech model is always a
    # mistake, so the bridge falls back to the model that is really running.
    os.environ["HERMES_CLI_MODEL"] = "base"
    os.environ["OLLAMA_MODEL"] = "qwen3.8-27b-hermes:latest"
    module = load(prefer="auto")
    fake_home = tempfile.mkdtemp()
    os.makedirs(os.path.join(fake_home, ".hermes"), exist_ok=True)
    with open(os.path.join(fake_home, ".hermes", "config.yaml"), "w") as handle:
        handle.write("model:\n  provider: custom\n  base_url: http://localhost:11434/v1\n")
    real_expanduser = module.os.path.expanduser
    module.os.path.expanduser = lambda path: fake_home if path == "~" else real_expanduser(path)
    try:
        model, source_name = module.agent_model()
        report = module.model_report()
    finally:
        module.os.path.expanduser = real_expanduser
    check("a speech model is recognised as a speech model",
          module.is_speech_model("base") and module.is_speech_model("whisper-1")
          and not module.is_speech_model("qwen3.8-27b-hermes"))
    check("the pinned speech model is not the agent's model",
          model == "qwen3.8-27b-hermes:latest" and source_name == "OLLAMA_MODEL",
          f"{model!r} from {source_name!r}")
    check("the report says where the model came from",
          report["source"] == "OLLAMA_MODEL" and report["pinned"] == "base",
          repr(report))
    os.environ.pop("OLLAMA_MODEL", None)

    # A model the provider does not know is a broken model: it is left alone
    # for a while instead of failing on every question.
    module = load(prefer="auto")
    check("an unknown model is spotted as a failure",
          module.cli_output_failed("model not found: qwen") != "")
    check("an unknown model counts as a broken model",
          "model not found" in module.CLI_MODEL_FAILURES)

    # The CLI must really be started without the bridge's own settings. This
    # is the difference between the agent and plain Ollama: with the dead
    # API server address in its environment the CLI found no model and the
    # orb lost every tool the agent has.
    module = load(prefer="auto")
    os.environ["HERMES_BASE_URL"] = "http://127.0.0.1:8642/v1"
    os.environ["HERMES_MODEL"] = "hermes-agent"
    seen_env = []

    def fake_run2(cmd, timeout=120, stdin_text=None, env=None):
        seen_env.append(env)
        return 0, quiet, ""

    module.run = fake_run2
    module.hermes_cli_chat("hello", "session")
    check("the CLI is started with the bridge's settings taken out",
          bool(seen_env) and seen_env[0] is not None
          and "HERMES_BASE_URL" not in seen_env[0]
          and "HERMES_MODEL" not in seen_env[0],
          repr(sorted((seen_env[0] or {}).keys())[:6]))
    os.environ.pop("HERMES_BASE_URL", None)
    os.environ.pop("HERMES_MODEL", None)

    # the journal lives on this machine, so the bridge reads it and puts it
    # in front of the model - the orb can then answer questions about it
    module = load(prefer="auto")
    with tempfile.TemporaryDirectory() as folder:
        with open(os.path.join(folder, "2026-11-17.md"), "w", encoding="utf-8") as fh:
            fh.write("Today I shipped the orb.\n")
        with open(os.path.join(folder, "2026-11-16.md"), "w", encoding="utf-8") as fh:
            fh.write("Yesterday I fixed the bridge.\n")
        os.utime(os.path.join(folder, "2026-11-17.md"), (2000, 2000))
        module.JOURNAL_DIR = folder
        entries = module.journal_entries(5)
        check("the journal entries are found", len(entries) == 2, str(len(entries)))
        check("the newest entry comes first",
              bool(entries) and os.path.basename(entries[0][0]) == "2026-11-16.md",
              entries and os.path.basename(entries[0][0]))
        context = module.journal_context("what is in my last journal entry?")
        check("the journal goes with the question",
              "Yesterday I fixed the bridge." in context, repr(context[:120]))
        check("a question about the journal brings more of it",
              len(context) > len(module.journal_context("what time is it?")))
        status = module.journal_status()
        check("the health endpoint counts the entries", status["entries"] == 2,
              str(status))

    # An imported entry with no writing in it must not hide the real ones.
    # The imported files were written more recently, so by date alone they
    # would sit in front of the entries that actually have content.
    module = load(prefer="auto")
    with tempfile.TemporaryDirectory() as folder:
        stub = os.path.join(folder, "2026-01-23.md")
        real = os.path.join(folder, "2025-12-19.md")
        with open(stub, "w", encoding="utf-8") as fh:
            fh.write("# 2026-01-23 (Friday)\n\n"
                     "Imported from a nanobot workspace on Nov 8, 2026.\n"
                     "Date entry would be populated with actual content from file.\n")
        with open(real, "w", encoding="utf-8") as fh:
            fh.write("# 2025-12-19 (Friday)\n\nI went to the market and bought fish.\n")
        # the empty one is the newer of the two
        os.utime(stub, (4000, 4000))
        os.utime(real, (1000, 1000))
        module.JOURNAL_DIR = folder
        entries = module.journal_entries(5)
        names = [os.path.basename(p) for p, _, _ in entries]
        check("an imported entry with no writing is left out",
              names == ["2025-12-19.md"], str(names))
        check("the real entry is still there",
              "market" in module.journal_context("what did I do?"),
              repr(module.journal_context("what did I do?")[:160]))
        check("a long entry that mentions the notice is kept",
              not module.is_placeholder("x" * 700 + " imported from a nanobot workspace"))
        check("a short entry that mentions the notice is a placeholder",
              module.is_placeholder("imported from a nanobot workspace"))
        status = module.journal_status()
        check("the health endpoint says one entry was skipped",
              status["entries"] == 1 and status["skipped"] == 1, str(status))

    # Nothing about Keith's account is written into the bridge: the paths are
    # found from the account that runs it. If a path is ever hardcoded again,
    # the bridge would read the wrong account's notes - or none at all.
    source = open(BRIDGE, encoding="utf-8").read()
    check("the bridge has no hardcoded home path",
          "/home/" not in source and "youruser" not in source)
    check("the bridge finds its home instead",
          "os.path.expanduser" in source)

    module = load(prefer="auto")
    real_home = os.environ.get("HOME")
    with tempfile.TemporaryDirectory() as home:
        profile = os.path.join(home, ".hermes", "profiles", "memory")
        os.makedirs(os.path.join(profile, "journal"))
        os.makedirs(os.path.join(home, ".nanobot", "workspace", "journal"))
        with open(os.path.join(profile, "MEMORY.md"), "w", encoding="utf-8") as fh:
            fh.write("Keith keeps the orb on a Galaxy J4.\n")
        with open(os.path.join(profile, "USER.md"), "w", encoding="utf-8") as fh:
            fh.write("Keith's son Hunter plays tennis.\n")
        with open(os.path.join(profile, "SOUL.md"), "w", encoding="utf-8") as fh:
            fh.write("Warm, brief answers.\n")
        with open(os.path.join(profile, "FAMILY_SPORTS.md"), "w",
                  encoding="utf-8") as fh:
            fh.write("Hunter plays tennis on Saturday mornings.\n")
        with open(os.path.join(profile, "CHRISTMAS_SHOPPING.md"), "w",
                  encoding="utf-8") as fh:
            fh.write("A present for Dad.\n")
        with open(os.path.join(profile, "journal", "2026-11-17.md"), "w",
                  encoding="utf-8") as fh:
            fh.write("Today I shipped the profile notes.\n")
        with open(os.path.join(home, ".nanobot", "workspace", "journal",
                               "2026-01-23.md"), "w", encoding="utf-8") as fh:
            fh.write("The real entry from the old workspace.\n")

        os.environ["HOME"] = home
        try:
            check("the profile is found in the running account's home",
                  module.profile_dirs() == [profile], str(module.profile_dirs()))
            check("the profile's journal folder is found",
                  os.path.join(profile, "journal") in module.journal_dirs(),
                  str(module.journal_dirs()))
            check("the legacy journal folder is found too",
                  os.path.join(home, ".nanobot", "workspace", "journal")
                  in module.journal_dirs(), str(module.journal_dirs()))
            names = [os.path.basename(p) for p in module.context_files()]
            check("the profile's notes are found",
                  "MEMORY.md" in names and "USER.md" in names and "SOUL.md" in names,
                  str(names))
            check("who the user is comes first",
                  names[:2] == ["MEMORY.md", "USER.md"], str(names[:2]))
            notes = module.profile_context()
            check("the notes go into the prompt",
                  "Galaxy J4" in notes and "Hunter" in notes, repr(notes[:120]))
            check("the notes are labelled as the user's own",
                  "notes" in notes.lower(), repr(notes[:80]))
            check("the notes stay inside the budget",
                  len(module.profile_context("tennis")) <= module.CONTEXT_MAX_CHARS + 200,
                  str(len(module.profile_context("tennis"))))

            # a question about the tennis brings the sports note along
            sports = module.profile_context("when does Hunter play tennis?")
            check("the note the question is about comes along",
                  "tennis" in sports.lower(), repr(sports[-300:]))
            check("the note it is about comes before the other one",
                  sports.find("FAMILY_SPORTS") < sports.find("CHRISTMAS_SHOPPING"),
                  repr((sports.find("FAMILY_SPORTS"), sports.find("CHRISTMAS_SHOPPING"))))

            # the notes have to reach the model, not just be found
            sent = {}
            module.hermes_api_reachable = lambda: False
            module.have = lambda binary: False

            def capture(text, session):
                sent["text"] = text
                return "ok"

            module.ollama_chat = capture
            module.hermes_chat("who am I?", "session")
            check("the notes reach the model with the question",
                  "Galaxy J4" in sent.get("text", ""), repr(sent.get("text", "")[:160]))
            check("the question is still the last thing in the prompt",
                  sent.get("text", "").endswith("who am I?"),
                  repr(sent.get("text", "")[-40:]))
            check("the real date goes with the question",
                  "Today is" in sent.get("text", "")
                  and time.strftime("%Y-%m-%d") in sent.get("text", ""),
                  repr(sent.get("text", "")[-120:]))

            account = module.account_status()
            check("the health endpoint names the account",
                  account["home"] == home and account["profiles"] == [profile],
                  str(account)[:200])
            check("the health endpoint lists the notes it found",
                  len(account["context_files"]) == 5, str(account["context_files"]))
        finally:
            if real_home is None:
                os.environ.pop("HOME", None)
            else:
                os.environ["HOME"] = real_home

    print()
    if FAILURES:
        print(f"BRIDGE BACKEND ORDER: {FAILURES} FAILURE(S)")
        return 1
    print("ALL BRIDGE BACKEND TESTS PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
