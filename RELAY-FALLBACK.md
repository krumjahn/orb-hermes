# Zero-sudo fallback - run the dialer on the Beelink

Use this **only if you cannot run the sudo firewall command**. It works because
the Beelink's firewall blocks every *inbound* connection (a scan of ports
1-10000 found nothing open), but outbound connections are fine.

The Beelink dials **out** to the Mac and holds a byte pipe open. The Mac
splices that pipe onto a local port, and the phone talks to the Mac. The
bridge never has to accept an inbound connection.

```
phone --http--> Mac:8891 --raw bytes--> Beelink:8787
Beelink --http POST (chunked)--> Mac:8890
```

Nothing on the phone changes except the server URL.

> **The cost of this route:** the phone talks to the *Mac*, so the Mac has to be
> awake and the relay has to be running. If the Mac sleeps, the orb goes deaf
> even though Hermes is fine on the Beelink. Opening the firewall instead makes
> the phone talk to the Beelink directly and drops the Mac out of the loop.

---

## On the Mac (I have already done this - it is running)

```bash
python3 relay_mac.py YOUR_BRIDGE_TOKEN 8890 8891
```

It listens on `0.0.0.0:8890` (the Beelink dials in here) and `0.0.0.0:8891`
(the phone connects here). The phone's server URL becomes:

```
http://192.168.1.10:8891
```

---

## On the server

Fetch the dialer and run it:

```bash
mkdir -p ~/orb-setup/beelink && cd ~/orb-setup/beelink
curl -fsSL -o relay_dialer.py http://192.168.1.10:8899/relay_dialer.py
python3 relay_dialer.py 192.168.1.10 8890 YOUR_BRIDGE_TOKEN 8787
```

It should print:

```
[dialer] splicing 127.0.0.1:8787 through 192.168.1.10:8890
[dialer] connected to 192.168.1.10:8890
```

Leave it running in its own terminal or under `tmux`/`screen`. It reconnects
on its own if the link drops.

### Two bugs this path hides

Both of them only show up with the real model behind the relay, and both are
now fixed and covered by `tools/test-relay.py`:

- **The dialer's 15 second timeout.** `socket.create_connection(..., timeout=15)`
  sets the timeout on the whole socket, so the *read* of the answer was cut off
  after 15 seconds too. A 27B model needs 10-16 seconds to answer, so a chat
  that ran a little long was truncated and the relay answered the phone with
  its own `502 Bad Gateway` - the phone then showed `Hermes unreachable`. The
  dialer now connects with a 15 second timeout but waits `BRIDGE_TIMEOUT`
  (200 s) for the answer.
- **The stale disconnect.** The relay keeps one socket, and a reconnecting
  dialer replaces it. When the *old* dialer finally went away, its handler
  still cleared the channel - so the relay was left holding a dead socket
  while the live dialer waited forever for a request that never came. The
  relay now only detaches if the socket it is dropping is still the live one.

Run the test yourself after changing either file:

```bash
python3 tools/test-relay.py
# ALL RELAY TESTS PASS
```

### Make it survive a reboot (no sudo needed for the service itself)

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
systemctl --user --no-pager status orb-relay-dialer.service | head -10
```

Note: this only keeps the *dialer* alive. The bridge itself already runs as
`orb-hermes.service` on the Beelink.

---

## Verify, from the Beelink

```bash
# the bridge must still be alive
curl -s http://127.0.0.1:8787/health

# the relay on the Mac must answer
curl -s -o /dev/null -w 'relay:%{http_code}\n' --max-time 8 http://192.168.1.10:8891/health

# and the real model must answer through the pipe
curl -s --max-time 60 -X POST http://192.168.1.10:8891/chat \
  -H 'X-Auth-Token: YOUR_BRIDGE_TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{"text":"Reply with exactly: RELAY_OK"}'
```

Expect `RELAY_OK` (or a short reply from `qwen3.8-27b-hermes:latest`).

---

## Report back

1. The dialer's output (both lines)
2. The `relay:` status code
3. The `/chat` reply
4. Whether the systemd unit started cleanly
