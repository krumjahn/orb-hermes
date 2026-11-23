Orb Hermes v1.1.1 — the orb actually listens

Three bugs, all found by watching a real phone on a real desk. Together they
are why the orb seemed to be broken: it woke on the television, it cut your
question off in the middle, and it then took minutes to answer.

**1. The wake word fired on ordinary speech.**

The rule that decides "was that the wake word" was too loose. "or not" is
only two edits away from "orbit", so any sentence ending in "or not" woke the
orb. Worse, a bare "or" was accepted as the wake word at the front of an
utterance — and "or" starts an enormous number of ordinary sentences. A
dictionary of 197,000 words produced 196,344 false pairs that way.

The matcher now insists that a joined run of words *sounds* like the word,
consonants and all: "or bid" and "or a bit" still work, "or not", "or
maybe" and "or the" no longer do. A clipped "orb" still works. A bare "or"
now only counts when it is all the transcriber heard, so "Orbit" on its own
still wakes the orb but "or not at all" does not.

The bridge and the Mac relay now run the same rules, so a bridge that has
not been updated yet cannot wake the orb on the telly either.

**2. Your question was cut off in the middle.**

This phone's microphone is quiet. A voice reaches about 0.02 and a room
reaches about 0.01, so the bar that decides "is that speech" sat *above*
the voice whenever the room got slightly louder — and a dip between two
words was read as the end of the sentence. "what's on my calendar" arrived
as "what's on my-".

The bar now follows the person who is speaking: it is half of their own
level while they talk, so a voice that gets quieter between words is still
speech. The room can no longer raise the bar above the voice.

**3. A third of the question was thrown away.**

While the orb was deciding whether the wake word had been heard, the next
clip was already on its way to the bridge. When the answer came back the orb
was awake, and that clip — recorded *after* the wake word — was dropped
because it had been sent as a wake check. The clips are now numbered, and a
clip that was recorded after the wake word goes into the question even if
its answer arrives late.

Also in this release: the follow-up window, saying "stop" to cut the reply
off, and answers spoken in pieces — all from v1.1.0.

Upgrading is in place: the same signing key, so your settings stay.

    adb install -r orb-hermes-v1.1.1.apk

The bridge on the Beelink wants the same fix:

    curl -fsSL http://192.168.68.57:8899/BEELINK-BRIDGE-UPDATE.sh | bash
