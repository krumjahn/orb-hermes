# Run this **on the server** (192.168.1.20)

The last install stopped at the speech self-test because of a **PyAV
version problem**, and the old bridge process is still running with the
broken code. This pass fixes both.

**What went wrong.** faster-whisper hands a file path to PyAV, and PyAV 15+
dropped the `metadata_errors` argument that faster-whisper still passes:

```
TypeError: open() got an unexpected keyword argument 'metadata_errors'
```

The installer tried to prevent that by pinning `av>=11,<15`, but there is no
PyAV 14 wheel for Python 3.14, so that install failed instead and PyAV 19.0.2
stayed in place.

**The real fix.** The bridge only ever receives plain 16 kHz PCM WAV from the
phone, so it now reads the samples itself (`load_audio`) and hands
faster-whisper a numpy array. faster-whisper only calls PyAV for compressed
formats, so **PyAV is never used at all** - any PyAV version works, including
19.0.2. The version pin is gone.

The files are served from the Mac at `http://192.168.1.10:8899/`.

> **Use the same token as before** (`YOUR_BRIDGE_TOKEN`) — the
> phone already has it stored. Do not generate a new one.

---

## 1. Stop the old bridge

The old process is still holding port 8787. Stop it before installing.

```bash
systemctl --user stop orb-hermes.service 2>/dev/null || true
pkill -f 'hermes_bridge.py' 2>/dev/null || true
sleep 2
ss -ltnp 2>/dev/null | grep 8787 || echo "port 8787 is free"
```

If it was started by hand rather than by systemd, `pkill` handles it. If the
port is still taken, tell me which process holds it.

---

## 2. Fetch the new files

There are now **four** files, and one of them is new:

```bash
mkdir -p ~/orb-setup/beelink && cd ~/orb-setup/beelink
for f in hermes_bridge.py selftest-stt.py setup-beelink.sh install.sh; do
  curl -fsSL -o "$f" "http://192.168.1.10:8899/$f" || echo "FAILED: $f"
done
chmod +x install.sh setup-beelink.sh selftest-stt.py
ls -la
```

---

## 3. Re-run the installer

```bash
bash ~/orb-setup/beelink/install.sh \
  --token YOUR_BRIDGE_TOKEN \
  --transport none \
  --wake orbit \
  --port 8787 \
  --ollama-model qwen3.8-27b-hermes:latest
```

Re-running it is safe and expected. Three things changed since the last run:

- **No PyAV pin.** faster-whisper is installed on its own, so whatever PyAV
  pip picks (19.0.2 on this machine) is fine.
- **The self-test now transcribes real speech.** It uses edge-tts to say
  "One two three", converts it to WAV, and reads it back through the *same*
  wav reader the wake word uses. It must print:

  ```
  wav reader: 32624 samples, peak 0.6637
  transcribed: '1-2-3'
  speech-to-text self-test OK
  ```

  If it says `speech-to-text self-test failed`, paste the whole error - do
  not move on.
- **The wake matcher is a little more forgiving**: it now also accepts `or bid`
  and `or bids`, which is how whisper sometimes renders "Orbit" when the "t" is
  swallowed. `for a bit` is still correctly rejected. The phone runs the same
  rules, so the two cannot disagree.

---

## 4. Prove the speech stack

```bash
systemctl --user status orb-hermes.service --no-pager | head -15
journalctl --user -u orb-hermes.service -n 40 --no-pager
```

The startup banner should contain:

```
faster-whisper: yes (model base, stays resident)
whisper worker up (model base)
```

Now time a wake request with real speech. Make the WAV first:

```bash
~/orb-hermes/venv/bin/python - <<'PY'
import edge_tts, asyncio, wave, av, numpy as np, os
async def go():
    await edge_tts.Communicate("Orbit, what time is it", "en-US-AriaNeural").save("/tmp/orbit.mp3")
asyncio.run(go())
c = av.open("/tmp/orbit.mp3"); s = c.streams.audio[0]
r = av.audio.resampler.AudioResampler(format="s16", layout="mono", rate=16000)
w = wave.open("/tmp/orbit.wav", "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
for f in c.decode(s):
    for rf in r.resample(f):
        w.writeframes(rf.to_ndarray().tobytes())
w.close(); c.close()
print("/tmp/orbit.wav written")
PY

time curl -s -X POST http://127.0.0.1:8787/wake \
  -H 'X-Auth-Token: YOUR_BRIDGE_TOKEN' \
  --data-binary @/tmp/orbit.wav
```

Expect:

```
{"text": "Orbit, what time is it?", "wake": true}
```

and it should take **well under a second** (the model stays resident). If it
answers slowly, the worker did not start - check the banner in step 4.

Also check text-to-speech:

```bash
curl -s -X POST http://127.0.0.1:8787/tts \
  -H 'X-Auth-Token: YOUR_BRIDGE_TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{"text":"Hello from the Beelink."}' \
  -o /tmp/tts.mp3 -w 'tts:%{http_code} bytes:%{size_download}\n'
```

Expect `tts:200` with a few tens of kilobytes.

Finally the health endpoint:

```bash
curl -s http://127.0.0.1:8787/health
```

---

## 5. Open the firewall

One command, one password, only you can type it:

```bash
sudo ufw allow from 192.168.1.0/22 to any port 8787 proto tcp
sudo ufw status | grep 8787
```

If `ufw` is not the firewall in use, find the real one first:

```bash
command -v ufw firewall-cmd nft iptables
sudo ufw status verbose 2>/dev/null | head -5
sudo firewall-cmd --state 2>/dev/null
sudo nft list ruleset 2>/dev/null | head -20
sudo iptables -S INPUT 2>/dev/null | head -20
```

and then open the port with whichever applies:

```bash
sudo firewall-cmd --permanent --add-port=8787/tcp && sudo firewall-cmd --reload
sudo nft add rule inet filter input tcp dport 8787 accept
sudo iptables -I INPUT -p tcp --dport 8787 -j ACCEPT
```

Also make the bridge survive a reboot:

```bash
sudo loginctl enable-linger $USER
```

Verify LAN reachability from the Beelink itself:

```bash
curl -s --max-time 8 http://192.168.1.20:8787/health
```

---

## 6. If the firewall cannot be opened - use the relay instead

A port scan of 1-10000 found **nothing** open on the Beelink, so there may be
no rule to add. The relay works without any inbound access: the Beelink dials
*out* to the Mac and holds a byte pipe open, and the Mac splices the phone
onto it. The Mac side is already running.

```bash
cd ~/orb-setup/beelink
curl -fsSL -o relay_dialer.py http://192.168.1.10:8899/relay_dialer.py
python3 relay_dialer.py 192.168.1.10 8890 YOUR_BRIDGE_TOKEN 8787
```

It should print:

```
[dialer] splicing 127.0.0.1:8787 through 192.168.1.10:8890
[dialer] connected to 192.168.1.10:8890
```

Leave it running. To keep it alive across reboots:

```bash
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/orb-relay-dialer.service <<'EOF'
[Unit]
Description=Orb Hermes relay dialer (Beelink -> Mac)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=%h/orb-setup/beelink
ExecStart=/usr/bin/env python3 %h/orb-setup/beelink/relay_dialer.py 192.168.1.10 8890 YOUR_BRIDGE_TOKEN 8787
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now orb-relay-dialer.service
```

With the relay, the phone's server URL is `http://192.168.1.10:8891`
instead of `http://192.168.1.20:8787`.

---

## 7. Update the relay dialer (if you are using the relay)

The relay is working, but the dialer that runs **here** has a 15 second
timeout on the bridge. A 27B model on this machine needs 10-16 seconds to
answer, so a chat that takes a little longer gets cut off and the relay
answers the phone with its own `502 Bad Gateway`. The phone then shows
`Hermes unreachable`.

Fetch the fixed dialer and restart it:

```bash
cd ~/orb-setup/beelink
curl -fsSL -o relay_dialer.py http://192.168.1.10:8899/relay_dialer.py
systemctl --user restart orb-relay-dialer.service 2>/dev/null || true
sleep 3
systemctl --user --no-pager status orb-relay-dialer.service | head -10
```

The new dialer waits 200 seconds for the bridge, so a slow answer gets
through. Check the line that says `BRIDGE_TIMEOUT`:

```bash
grep -n "BRIDGE_TIMEOUT" ~/orb-setup/beelink/relay_dialer.py
```

It should print `BRIDGE_TIMEOUT = 200.0`.

If the dialer is not running under systemd but you started it by hand, stop
that one first (`pkill -f relay_dialer.py`) and start the new one:

```bash
python3 ~/orb-setup/beelink/relay_dialer.py 192.168.1.10 8890 YOUR_BRIDGE_TOKEN 8787
```

---

## Report back

1. The installer's `speech-to-text self-test` lines, including the transcript
2. The PyAV version that ended up installed (`~/orb-hermes/venv/bin/python -m pip show av | head -2`)
3. The startup banner lines for faster-whisper and the worker
4. The `/wake` response **and how long it took**
5. The `/tts` status code and byte count
6. The final `/health` JSON
7. Whether the firewall rule went in, and which command did it - or that you
   are using the relay instead, plus the dialer's output
8. The `BRIDGE_TIMEOUT` line from the updated dialer, and the time a
   `/chat` takes through the relay (`curl -w '%{time_total}s'`)
