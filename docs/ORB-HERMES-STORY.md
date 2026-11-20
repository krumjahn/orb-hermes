# The Orb — how a phone on my desk ended up talking to my own Hermes agent

*A working document for a video. Everything below is what actually happened, with the
evidence that was captured at the time.*

---

## 0. The one-paragraph version

I wanted a glass orb sitting on my desk that wakes to my voice and answers with my own
Hermes agent — the one with my memory, my notes and the ability to search the web.
The orb's *look* came from an open-source liquid-glass shader; everything else — the
app, the relay, the agent bridge, the deploy tooling — I built.

It took six bugs to get there, and the last one was the reason the orb spent a whole
week sounding like a chatbot with no internet: **the app was never talking to my agent
at all.** It was silently falling back to a plain model server. The fix was one word
of argument order in a shell command, and the thing that finally showed me the truth
was the failing program's own help text.

---

## 1. What it is

| Piece | What it does | Where it runs |
|---|---|---|
| **The orb app** (Kotlin, Android) | Liquid-glass shader, mic capture, wake word, STT upload, TTS playback | Galaxy J4+ (`SM_J415GN`, LineageOS 18.1 / Android 12), adb `DEVICE_SERIAL` |
| **The relay** (`relay_mac.py`) | Bridges the phone to the Beelink over plain LAN | Mac (`192.168.1.10`), ports 8890 (tunnel) / 8891 (phone) |
| **The dialer** (`relay_dialer.py`) | Dials *out* from the Beelink because it can't be dialled *in* | Beelink (`192.168.1.20`) |
| **The bridge** (`hermes_bridge.py`) | HTTP API in front of the agent: `/wake` `/stt` `/chat` `/tts` `/health` | Beelink, port 8787 |
| **The agent** | Hermes — 35 tools, web search, memory, my notes | Beelink (same box as Ollama) |
| **Ollama** | The 27B model the agent calls | Beelink, port 11434 |
| **Whisper** | Speech-to-text, resident worker | Beelink |
| **Stage server** | Serves the bridge and scripts to the Beelink over HTTP | Mac, port 8899 |
| **UGREEN NAS** (`192.168.1.40`) | Meeting recordings + notes | Same LAN |

The visual is a liquid-glass orb (the shader concept from
[github.com/LerSent001/orb](https://github.com/LerSent001/orb)) — a breathing, refracting
sphere whose bands follow the microphone envelope. It dims when nobody talks to it.

---

## 2. The constraints that shaped every decision

These are the facts that made the obvious solutions wrong, and they're the reason the
architecture looks the way it does:

1. **The Beelink is firewalled.** No inbound SSH, no inbound anything. The only way to
   change it is a script somebody runs *on* it. This is why every change ships as
   `curl -fsSL http://192.168.1.10:8899/SCRIPT.sh | bash`.
2. **The phone has no speech recogniser.** This ROM has no `android.speech.RecognitionService`,
   so all STT happens on the Beelink.
3. **The phone must be awake and in the foreground.** Android feeds a background
   capture nothing but zeros — forever. The orb goes silent if you lock the screen.
4. **Plain home LAN, no cloud.** Tailscale off, NordVPN on the Mac.
5. **One relay tunnel, one request at a time.** The Beelink's dialer answers in order,
   so a request and its reply are one indivisible step. A 90-second agent answer blocks
   the tunnel for 90 seconds.
6. **Secrets never travel in plain text and never appear in output.** NAS password is
   typed on the Beelink terminal; API keys and Telegram tokens are masked as `<set>`.

---

## 3. The debugging journey — six bugs

### Bug 1 — "The app doesn't respond"

**Symptom:** after a while the orb stopped hearing the wake word. Logcat showed
`chunk dropped, backlog=9`, over and over.

**Root cause:** the app had a single upload thread doing a socket **write** with no
write timeout. When the bridge or the relay was restarted underneath it, the write
blocked forever — and one blocked thread meant no clip was ever uploaded again. The
orb wasn't broken; it was deaf.

**Fix:** `UploadGuard.kt` — a two-thread pool with a hard deadline. A worker that
misses it is abandoned and replaced, and the in-flight count drops exactly once no
matter how the upload ends (success, failure, or give-up).

> **Lesson:** *a single-threaded pipeline is one hung socket away from total silence.
> Every I/O path needs its own deadline and its own replacement.*

---

### Bug 2 — the two-bridge crash loop

**Symptom:** the wake word took 5 seconds instead of 1. The phone's upload queue
overflowed and clips were dropped.

**Root cause:** the bridge was started twice — once by its systemd unit and once by
hand. They fought over port 8787. The loser's start-up still **loaded a full Whisper
model** before discovering the port was taken, starving the bridge that was actually
working.

**Fix:** the bridge now **takes the port before it loads any model**, so a failed
start can never eat the working one's resources. The update script stops the service
*and* the old process before starting exactly one owner. The unit got
`StartLimitIntervalSec=120`, `StartLimitBurst=3`, `RestartSec=15`.

> **Lesson:** *acquire the scarce resource before the expensive one. And a service
> should have exactly one owner — if two things can start it, they will.*

---

### Bug 3 — the corrupted `config.yaml`

**Symptom:** the Telegram gateway stopped working. Hermes' error was
`mapping values are not allowed here, line 2, column 10`.

**Root cause:** my own update script. Its regex matched the **empty `model:` key line**
and wrote the model onto it, leaving a plain value on line 1 and a nested block on
line 2 — which is not valid YAML. Hermes then ran with no model at all.

**Fix:** the writer now puts the model into `model.default` when `model:` is a block,
checks the file still parses, checks the model is where Hermes looks for it, and puts
the old file back if either check fails. A separate `BEELINK-HERMES-RESTORE.sh`
restores the pristine backup.

> **Lesson:** *a script that edits a config must prove the result is still valid
> before it leaves it in place — and must be able to undo itself.*

---

### Bug 4 — the version drift (the one that bit *me*)

**Symptom:** after I rebuilt the bridge, every install script refused the download:
`the downloaded bridge is not version 2026-11-19c - refusing to install it`.

**Root cause:** each script hard-coded the expected version, and I'd bumped the bridge
without bumping the scripts. Keith ran the clean script and it "worked" — it installed
the build that happened to be staged at that moment, which was *not* the one I'd just
fixed.

**Fix:** the staged bridge and the scripts' expectations are now checked by a test
(`tools/test-bridge-version-sync.sh`) that fails the moment they disagree. The install
scripts also verify that the download **parses as Python**, not just that it contains
a version string.

> **Lesson:** *version constants drift. Make the test suite notice, not the user.*

---

### Bug 5 — the cut-off ("how are the Toronto rap? Doctors.")

**Symptom:** I asked the orb *"how are the Toronto Raptors doing this season?"* and it
heard:

```
10:44:15  "how are the Toronto we're after is doing."
10:46:33  "how are the Toronto rap? Doctors."
10:48:16  "how are the Toronto- Raptors Raptors"
```

**Root cause:** the recorder cuts the audio into clips at fixed byte offsets. Each clip
was transcribed **separately**, so every cut landed in the middle of a word. The relay
log shows exactly what the phone sent:

```
49,918 bytes  POST /wake    ← 1.56 s   (0.35 s lead-in + 1.2 s of speech)
96,317 bytes  POST /stt     ← 3.00 s   (the continuation)
    314 bytes  POST /stt     ← 8 ms     ← "Doctors." was invented from this
```

Three clips, three transcripts. The first ended on "rap", the second was eight
milliseconds of near-silence (Whisper hallucinated "Doctors."), and in the third
attempt the cut landed *between* the two halves of the word — so "Raptors" came out
twice.

**Fix:** the app now keeps the whole utterance as **audio** and transcribes it **once**
at the end. The cuts stop mattering, because the transcriber hears one continuous
sentence. New `Utterance.kt` + 17 offline checks, including this exact case.

> **Lesson:** *don't transcribe a stream in pieces and stitch the words. Stitch the
> audio first, transcribe once.*

---

### Bug 6 — the real one: **the orb was never talking to my agent**

**Symptom:** "the app is kinda useless without the ability to search the internet.
How come my Hermes on Telegram can search but the app cannot?"

**The evidence.** The bridge's health endpoint finally showed me its own output:

```
🤖 AI Agent with Tool Calling
🤖 AI Agent initialized with model:          ← EMPTY
🛠️ Final tool selection (35 tools): annotate_preview, browser_exec, memory, execute_code…
⚠️ Attempt 1/3, not retryable failed: HTTP 400: model is required
```

The agent *did* start and *did* load all 35 tools — including the browser tool. But the
model was blank, the provider rejected the request, and the bridge quietly fell back to
Ollama.

**Ollama is not the agent.** It's a model server: it answers from the prompt alone. No
tools, no web, no memory. That's why the orb said *"I don't have live standings or
recent game results"* — it was guessing politely. My Telegram Hermes works because the
gateway reads the settings file properly and hands the agent a real model.

**The root cause, in one line.** The bridge called:

```
hermes chat --query "…" --model base
```

The CLI is `hermes [options] <command> [args]`. The options belong **in front of** the
command. Put the model after the subcommand and argparse throws the whole thing away:

```
usage: hermes [-h] [--version] [-z PROMPT] … [-m MODEL] [--provider PROVIDER] … <command> ...
hermes: error: unrecognized arguments: [The user's own notes follow…]
```

Two separate faults, stacked:

1. **Wrong option order** → argparse rejected the command → the agent ran *without a
   model* → `HTTP 400: model is required`.
2. **The wrong model** → the value being passed was `base`. That's the **size** of a
   Whisper model (`base`, `tiny`, `small`, `medium`, `large`), scraped out of the STT
   section of the settings file by my own update script.

And the nastiest part: **every script on the Beelink had the same wrong command** —
including the ones whose job was to check whether the agent worked. So the diagnostic
that was supposed to catch this was broken in exactly the same way.

**The fix (bridge 19f).**

```
hermes --model qwen3.8-27b-hermes chat --query "<question>"
```

- The model comes from, in order: the sessions my agent itself left behind (the exact
  names it used, which are known to work) → the settings file (`model.default`) → the
  model server's own list (preferring the model with `hermes` in its name). A speech
  model is **never** accepted.
- A model the provider rejects is not retried in another form; the whole attempt has a
  300-second budget so the orb can't hang.
- The bridge now captures the CLI's own `--help` into `/health`, so the interface is
  *read*, not guessed.
- The install scripts use the right order too, so their self-checks work.

**The proof.** The question, through the relay — the phone's exact path:

> **Raptors are struggling a bit this season (as of Nov 18):**
> **Record:** 5-9 — 4th in the Atlantic, 9th in the East
> **Form:** on a 5-game losing streak (2-8 in their last 10)
> **Recent:** NYK 108-112 OT (Nov 15), NYK 102-111 (Nov 17), PHI 112-123 (Nov 12), BOS 93-98 (Nov 11) · Last win Nov 6 vs Milwaukee 121-107
> **Players:** Scottie Barnes, RJ Barrett (31 vs PHI), Poeltl, Quickley
> **Next:** Nov 18 vs Washington · Nov 20 @ Detroit

Real box scores and a live schedule. **96 seconds** end to end (it loads 35 tools
first). Before the fix, the same question got a guess.

> **Lesson:** *a fallback that hides a failure is worse than a crash. When the
> system "works but is dumber", the fallback is the bug.*
>
> *And: the failing program's own help text was the answer. I had been reading
> summaries of the error; the tool was printing exactly what it wanted, and I
> wasn't looking.*

---

## 4. The learnings, collected

1. **A silent fallback is a bug wearing a disguise.** The orb never said "I failed." It
   said something plausible. Every fallback must be visible — in the health endpoint,
   in the log, in the UI.
2. **Read the error, not your summary of it.** Twice I reasoned about the CLI from a
   paraphrased message and was wrong. The raw `usage:` line settled it in one read.
3. **Cut audio at word boundaries, not byte boundaries.** If you have to cut, cut on
   silence — or don't cut at all.
4. **One owner per service.** Two owners means they fight, and the loser still costs
   you the expensive resource.
5. **Acquire the scarce resource before the expensive one.** Take the port, *then* load
   the model.
6. **Every I/O path needs a deadline**, and a worker that misses it needs to be
   replaceable.
7. **Version constants drift.** Put the check in the test suite.
8. **Diagnostics that share a bug with the thing they diagnose are worse than nothing.**
   Every script here used the same broken command as the bridge.
9. **Instrument the wire.** Byte counts told me the clip boundaries; timestamps told me
   who was blocking. "It doesn't work" is a symptom; a 314-byte request is a diagnosis.
10. **Verify with the real voice.** The Mac's speakers bleed into the phone's mic and
    produce garbage. Only my own voice is a valid test.
11. **Never guess a remote machine's state.** Ask it. `/health` became the window into
    a box I couldn't SSH into.

---

## 5. The runbook

Everything the Beelink needs is one `curl` away. The Mac stages the files on port 8899.

```bash
# Install the current bridge, start exactly one of them, and prove the agent
# answers a question that needs the web:
curl -fsSL http://192.168.1.10:8899/BEELINK-AGENT-VERIFY.sh | bash

# Read-only diagnosis of the agent and the settings file:
curl -fsSL http://192.168.1.10:8899/BEELINK-HERMES-DIAG.sh | bash

# Restore the pristine config.yaml and restart only the gateway:
curl -fsSL http://192.168.1.10:8899/BEELINK-HERMES-RESTORE.sh | bash

# Install the meeting-notes daemon (prompts for the NAS password):
curl -fsSL http://192.168.1.10:8899/BEELINK-NOTES-DAEMON.sh | bash

# One bridge, one owner (use when the service is flapping):
curl -fsSL http://192.168.1.10:8899/BEELINK-BRIDGE-CLEAN.sh | bash
```

On the Mac:

```bash
# The bridge's own view of the world (works without SSH):
curl -s -m 60 http://127.0.0.1:8891/health -H "X-Auth-Token: $TOKEN"

# Ask the orb's backend directly:
curl -s -m 400 -X POST http://127.0.0.1:8891/chat \
  -H "X-Auth-Token: $TOKEN" -H "Content-Type: application/json" \
  -d '{"text":"How are the Toronto Raptors doing this season?","session":"check"}'

# Build and install the app on the phone:
cd orb-hermes && gradle assembleRelease && adb install -r app/build/outputs/apk/release/app-release.apk

# Every offline test, no device required:
bash tools/test-app-logic.sh            # Kotlin: 110 checks
python3 tools/test-bridge-backend.py    # bridge: 67 checks
python3 tools/test-bridge-http.py       # 8
python3 tools/test-bridge-wake.py       # 30
python3 tools/test-relay.py             # relay + stale-reply checks
bash tools/test-beelink-script.sh       # and the other six script sandboxes
```

---

## 6. The file map

**Phone app** — `OrbHermes/app/src/main/java/com/keith/orbhermes/`

| File | Job |
|---|---|
| `OrbCore.kt` | The brain: phases, uploads, the utterance lifecycle, replies |
| `VoiceStreamer.kt` | Continuous mic capture, energy VAD, clip windows |
| `ClipWindow.kt` | Finds the onset of speech, builds lead-in + speech clips |
| `Utterance.kt` | **New.** Keeps an utterance as audio so it can be transcribed in one go |
| `WakeWord.kt` | Fuzzy "Orbit" matching, and stripping the echo off the front |
| `VoiceClient.kt` | HTTP client for `/wake` `/stt` `/chat` `/tts` |
| `UploadGuard.kt` | Deadlines and replaceable workers for the uploads |
| `AnswerCleaner.kt` | Takes only the answer out of the agent's tool log |
| `WavCodec.kt` | Minimal RIFF/WAVE read/write |
| `BandSmoother.kt` | Attack/decay smoothing for the glass |
| `OrbView.kt` / `OrbShader.kt` / `OrbPresets.kt` | The liquid-glass renderer |

**Beelink** — `OrbHermes/beelink/`

| File | Job |
|---|---|
| `hermes_bridge.py` | The HTTP API in front of the agent (currently `2026-11-19f`) |
| `relay_dialer.py` | Dials out of the Beelink to the Mac |
| `relay_mac.py` | The Mac's relay |
| `setup-beelink.sh` / `install.sh` | First-time install |

**Scripts that go to the Beelink** — the `BEELINK-*.sh` files in this repo

`BEELINK-AGENT-VERIFY.sh` (install + prove), `BEELINK-BRIDGE-CLEAN.sh` (one owner),
`BEELINK-BRIDGE-UPDATE.sh` (install + verify), `BEELINK-HERMES-DIAG.sh` (read-only),
`BEELINK-HERMES-RESTORE.sh` (config rescue), `BEELINK-NOTES-DAEMON.sh` (meeting notes),
`sync-stage.sh` (publish to the stage server), plus one sandbox test per script.

---

## 7. Measurements worth quoting

| Thing | Number |
|---|---|
| Wake check + speech-to-text round trip | ~1.0 s (2.5–4.8 s while the double-bridge crash loop was live) |
| Speech-to-text round trip | ~1.0 s |
| Whole-utterance transcription | 0.5 s for 4.6 s of audio |
| Whisper model load (once) | ~24 s |
| Agent answer, warm | 10–48 s |
| Agent answer, cold | up to ~232 s |
| Agent answer, measured end to end through the relay | **96 s** |
| Clip sizes on the wire | 49,918 / 96,317 / 314 bytes |
| Phone `/chat` timeout | 420 s |
| Relay tunnel | one request at a time |

---

## 8. Still open

- **The notes daemon.** The scripts deployed (10:03 and again later), but I can't
  confirm from the Mac that the Beelink daemon is running or that recordings are
  landing on the NAS.
- **The agent is slow.** 96 s to answer is a long time to stare at a glass ball.
  The fix is to trim the toolset to the handful the orb actually needs
  (`-t TOOLSETS` is right there in the CLI's usage).
- **The Beelink firewall.** Opening it would let the phone talk straight to the
  bridge and drop the relay out of the path.
- **Conversation memory.** The CLI supports `--resume SESSION_ID`; wiring the orb's
  session id through the bridge would let it remember the conversation.
- **The phone sleeps.** The orb needs the screen awake, or the capture is fed zeros
  forever.

---

## 9. A shape for the video

*(Suggestions for the editor — not gospel.)*

**Cold open (0:00–0:15).** The orb on the desk. Ask it a question about the Toronto
Raptors. It answers, wrongly, with a shrug: *"I don't have live standings or recent
game results."* The promise of the video: *it was never even asking.*

**The setup (0:15–2:00).** What the thing is, the three boxes, the liquid-glass shader,
the wake word, and the one constraint that shapes everything: *the box with the agent
in it can't be reached — you have to walk over to it.*

**The hunt (2:00–8:00).** Four escalating bugs, each with its evidence on screen:
the deaf uploads, the two bridges fighting, the corrupted YAML, and the cut-off
("Toronto rap? Doctors." — with the 314-byte request that invented a word).

**The twist (8:00–12:00).** The question: why can Telegram search and the orb can't?
Follow the trail into the bridge's own log — the agent banner, the 35 tools, the blank
model, `HTTP 400: model is required` — and then the `usage:` line that gives the whole
thing away. The realisation that the fallback was the bug: it never failed, it just
answered dumber.

**The fix (12:00–14:00).** One argument in the wrong place. `hermes --model NAME chat
--query "…"`.

**The payoff (14:00–15:00).** The same question, answered properly, with live box
scores and a schedule — and the whole thing running on a five-year-old Galaxy J4+.

**The takeaways (15:00–16:00).** Silent fallbacks, reading errors properly, one owner
per service, deadlines on every I/O path, and the reminder that the most useful
artifact in the whole project was the failing command's own help text.

**B-roll / stings to pull:**
- The orb breathing in standby, dimmed to 0.22.
- The relay log scrolling: byte counts, then a `/chat` line with the question.
- The health endpoint showing `backend: ollama` → `backend: cli` side by side.
- Terminal captures of `usage: hermes …` scrolling past.
- The Beelink's stage-server access log as the "who did what, and when" shot.

---

## 10. Appendix — raw evidence

```text
# the cut-off, three attempts (relay log)
10:44:15  "how are the Toronto we're after is doing."
10:46:33  "how are the Toronto rap? Doctors."
10:48:16  "how are the Toronto- Raptors Raptors"

# after the fix, one attempt
11:54:38  "how are the Toronto Raptors doing this season?"

# the clip boundaries, from the relay log
49918 bytes POST /wake      ← 1.56 s
96318 bytes POST /stt       ← 3.00 s
  314 bytes POST /stt       ← 8 ms   ← "Doctors."

# the agent's own report (bridge /health)
🤖 AI Agent with Tool Calling
🤖 AI Agent initialized with model:
🛠️ Final tool selection (35 tools): annotate_preview, browser_exec, memory, execute_code…
⚠️ Attempt 1/3, not retryable failed: HTTP 400: model is required

# the parser, giving the answer away
usage: hermes [-h] [--version] [-z PROMPT] [--usage-file PATH] [--cpu-profile PATH]
[-m MODEL] [--provider PROVIDER] [--reasoning LEVEL] [-t TOOLSETS] [--resume SESSION] … <command> ...
hermes: error: unrecognized arguments: [The user's own notes follow…]

# after the fix (bridge /health)
bridge : 2026-11-19f | backend: cli
model  : qwen3.8-27b-hermes ( config.model.default )
command: hermes --model qwen3.8-27b-hermes chat --query {}
```

---

*Written 2026-11-19, Hong Kong. Sources: the relay log, the Beelink stage-server access
log, the phone's logcat, and the bridge's `/health` endpoint.*
