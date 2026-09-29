# Audience bridge

A one-page mobile form that lets a room full of phones drive the *actual* fraud detection
pipeline, without anyone installing anything or needing access to LocalStack's (not yet
public) Azure emulation. Every submission is signed and POSTed over the exact same HTTPS
path `../ingest.sh` / `src/producers/producer_http.py` already use, into the same running
`payments` hub. The Function App that scores it is the real, deployed one - the audience
isn't watching a simulation, they're driving the real thing.

Nothing in `samples/eventhubs` itself changes for this. It's a standalone Flask app that
imports `src/producers/common.py` and `producer_http.py` rather than reimplementing SAS
signing or the payment schema.

## Run it

Needs an already-deployed stack (`bash scripts/deploy.sh` from the sample root).

```bash
source scripts/.deployment-env      # from the sample root
cd scripts/talk/audience-bridge
pip install -r requirements.txt
PORT=5050 python3 app.py
```

`PORT=5050` isn't optional cosmetics on macOS: 5000 is very often owned by AirPlay
Receiver (System Settings -> General -> AirDrop & Handoff), and Flask's own error message
for that ("Address already in use") doesn't say so - if port 5000 refuses to bind, that's
almost always it.

Two routes:

- `/` - the phone form.
- `/scoreboard` - a big-screen view (Team A vs Team B, live), meant for a second window or
  a secondary display, separate from the main dashboard.

## Expose it to the room

The room's phones need to reach this from wherever they are, which rules out the laptop's
bare LAN IP more often than you'd expect: plenty of conference and corporate wifi enables
**client isolation**, which silently blocks device-to-device traffic on the same network
even though everyone shows as connected. Don't find this out live. Use a tunnel instead -
it works regardless of client isolation, because phones reach it over the open internet:

```bash
brew install cloudflared
cloudflared tunnel --url http://localhost:5050
```

This prints an `https://<random>.trycloudflare.com` URL with no account or setup needed.
`ngrok http 5050` is the equivalent if you already use ngrok. Test the printed URL from
your own phone (on cellular, not the venue wifi) before you rely on it.

## Put it on screen

```bash
pip install qrcode
qr "https://<your-tunnel-url>"
```

`qr` (installed by the `qrcode` package) prints a scannable ASCII QR code straight to the
terminal - no image file, no slide-authoring, and it's regenerated in seconds if the tunnel
URL changes. Project that terminal, or screenshot it into a slide right before you go on if
your deck needs a static image.

## The two game mechanics

Both are visible on the main dashboard's Alerts panel (tagged `channel: audience-phone`)
and on `/scoreboard`:

1. **Solo trip**: one submission over the fraud amount threshold (5,000 by default) trips
   the amount rule instantly.
2. **Team burst**: more than 5 submissions from the *same team* within 60 seconds trips the
   velocity rule, regardless of amount - this is the card-testing pattern, and it's why the
   form assigns every submission to one of two shared team accounts (`ACC-TEAM-A` /
   `ACC-TEAM-B`) instead of one account per phone. Get the room to coordinate a synchronized
   "everyone hit send now" for team B and it reliably trips within a few seconds.

Both were validated end-to-end against a live deployment before this was written: real
HTTP submissions, real alerts, real dashboard.

## Why the form has no free text

Every field is a bounded number or a fixed dropdown, on purpose. This form's output can end
up projected on a screen in front of a room - an open text field is an open invitation for
someone to put something inappropriate on your screen, live. There is a light per-IP
cooldown (1.5s) for the same reason on the abuse side: harmless for someone tapping send by
hand, enough to stop a single phone from scripting a flood.

## After the session

The Flask dev server's in-memory scoreboard resets on restart, and nothing here writes to
disk. `Ctrl+C` stops it; nothing to clean up beyond that (the pipeline itself is torn down
the normal way, with `scripts/cleanup.sh`, from the sample root).
