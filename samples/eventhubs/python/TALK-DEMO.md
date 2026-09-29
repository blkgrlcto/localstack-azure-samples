# Speaker runbook — "Azure Feels Slow Because Your Dev Loop Is Broken"

Target: **90-minute interactive session**. This sample (`samples/eventhubs`, the fraud
detection pipeline) is the flagship: three ingestion protocols into one Event Hub, a
serverless fraud detector, checkpointed recovery, an Avro cold path, a live dashboard, and
— the centerpiece — a genuine local inner dev loop that needs no `az deploy` at all.

**Only your laptop deploys anything.** LocalStack's Azure emulation isn't public yet, so
the room can't run `scripts/deploy.sh` themselves no matter how well they're prepped — that
rules out a bring-your-own-laptop workshop format for this sample specifically. The room
still gets real hands-on-keyboard time (well, hands-on-*phone* time): `scripts/talk/audience-bridge/`
is a small facilitation app that lets every phone in the room POST real payments into your
one running pipeline over HTTPS, using the exact SAS-token path `producer_http.py` already
uses. Nobody installs anything, nobody needs LocalStack access, and the alerts they trigger
are real — scored by the real, deployed Function App, visible on the real dashboard. See
`scripts/talk/audience-bridge/README.md` for how it works and how to run it.

| Abstract beat | Segment | What proves it |
|---|---|---|
| "a real event-driven application" | 1 | dashboard tour: partitions, consumer groups, schema registry, all real |
| "trigger workflows" | 2 | `producer_*.py` → Event Hubs trigger → alerts, live on the dashboard |
| interactive / hands-on | **3** | the room's phones drive real payments into the real pipeline |
| "iterate in seconds instead of minutes" | 4 | `func start` locally, edit `function_app.py`, Ctrl+C, restart — no deploy |
| "simulate failures" | 5 | `docker restart` the Function App's container mid-stream; checkpoint recovery |
| "test integrations safely" / breadth | 6 | `scripts/validate.sh` live: least-privilege SAS, app groups, geo-DR pairing |

`samples/eventhubs-eventgrid` is a good **bonus/backup topic** for Q&A about event-driven
vs. polling (Capture → `CaptureFileCreated` → Event Grid → a second hub, no polling loop
anywhere) — it isn't in the timed run because Capture's 60s minimum window and lack of a
dashboard don't suit live pacing.

## Timing budget (90 min)

| # | Segment | Content | Budget |
|---|---|---|---|
| 0 | Welcome & the problem | slides: the deploy-wait-debug-repeat cycle | 15 min |
| 1 | Orientation | architecture + dashboard tour | 5 min |
| 2 | Trigger the workflow | 3 protocols, presenter-led | 10 min |
| 3 | **The audience act** | phones drive the pipeline, team game | 20 min |
| 4 | **Iterate in seconds** | local dev loop, live code edit | 15 min |
| 5 | Simulate a failure | kill and recover | 10 min |
| 6 | Cold path + capability tour | `validate.sh` | 8 min |
| 7 | Recap, CTA, wrap-up | + cleanup | 7 min |

This is a runbook of commands you run one at a time, pausing to talk between them — not
one script that races through 90 minutes unattended. That's more important at this length,
not less: you're also facilitating a room, which needs slack the earlier 30-minute version
didn't.

## The one trap: don't let `az functionapp deploy` be your "fast" story

`scripts/run-pipeline.sh` (the repo's CI-grade demo) proves checkpoint recovery by
**redeploying** the function package to force a restart. A redeploy replaces the
container, so the host cold-starts and re-downloads its Functions extension bundle
before the next invocation — the script's own timeout for that step is 600 seconds.
Never run that step live; it would flatly contradict "seconds, not minutes" in front of
the room. Segment 5 below uses `docker restart` on the same container instead (same crash,
no re-download). Segment 4 sidesteps deployment entirely.

## Prerequisites beyond the sample's own README

- **Azure Functions Core Tools v4** (`func` on PATH) — for segment 4's local dev loop.
  `brew install azure/functions/azure-functions-core-tools@4`. On a machine that has
  never installed anything from this tap, Homebrew refuses it as untrusted the first
  time — run `brew trust azure/functions/azure-functions-core-tools` (it's the official
  Microsoft tap) and re-run the install.
- **Python 3.12 or 3.13 for the venv** (`src/producers/requirements.txt`), not whatever
  newer `python3` your machine defaults to. `confluent-kafka` and `fastavro` ship
  prebuilt wheels a version or two behind - on 3.14 both fail to build from source
  (a `Cython.Compiler.Errors.CompileError` on `fastavro`). `brew install python@3.12` and
  build the venv with `/opt/homebrew/bin/python3.12 -m venv .venv` if needed.
  **Every fresh terminal pane needs this venv activated before it can run anything under
  `scripts/talk/` or `scripts/validate.sh`** — `cd samples/eventhubs/python && source
  .venv/bin/activate`. Forgetting this is the single most likely way to stall live: the
  shell's own `python3` (no venv) can't import `azure-eventhub` at all, and without it
  every check in these scripts reads as a generic "unreadable"/"stalled" failure instead
  of the actual cause. The scripts under `scripts/talk/` catch this now and say so
  directly; `scripts/validate.sh` (part of the sample itself, not talk-specific tooling)
  does not, so if *it* stalls with something vague, activating the venv is still the
  first thing to check.
- **`cloudflared` (or `ngrok`) and the `qrcode` package** — for segment 3, to expose the
  audience bridge and put a scannable QR code on screen. Full detail in
  `scripts/talk/audience-bridge/README.md`.
- If you're on macOS, port 5000 is very often owned by AirPlay Receiver — run the bridge
  app with `PORT=5050` (see its README) rather than losing time to a confusing bind error.
- A second terminal pane/tab, for `func start` to run in foreground next to your main one.
  A third, for the audience bridge + tunnel, running for the whole session.
- The dashboard open in a browser tab, visible to the audience, before you start talking.
  A second display or window for `/scoreboard` (from the audience bridge) if you have one.
- `lstk login` done once beforehand. If you're already authenticated through `lstk` (an
  Enterprise/Pro plan shows in `~/.config/lstk/plan_label`), start the emulator with
  `lstk start -t azure` rather than exporting `LOCALSTACK_AUTH_TOKEN` - it uses the same
  stored credentials and the sample's README predates this flow.

## Before you leave for the venue

1. `bash scripts/deploy.sh` — well before the session, never live. First deploy pulls
   the Functions build image and can take several minutes.
2. Run the whole show once, start to finish, exactly as scripted below, on the actual
   laptop you'll present from. This is what warms the Function App (segment 2 won't stall
   on a cold start), seeds a real Capture archive (segment 6 has something to decode instead
   of waiting on a 60s window), and lets you feel the real timing so you know how much to
   talk over.
3. After the dry run, reset the file you'll edit live: `git checkout -- src/functions/function_app.py`.
4. Leave the emulator and the deployment running — don't `cleanup.sh` between the dry run
   and the session.
5. Start the audience bridge and its tunnel, and **scan the QR code with your own phone on
   cellular data** (not the venue wifi) to confirm it actually works from outside whatever
   network you're on. Submit a test payment through it and confirm it shows up on the
   dashboard. Do this the day before if you can — venue wifi on the day is not when you
   want to discover a firewall problem.

---

## Segment 0 — Welcome & the problem (15 min)

Slides. No commands. This is the "why" — the deploy-wait-debug-repeat cycle, what it
costs, why it becomes the default anyway. Land on: everything from here on runs on this
one laptop, offline, and the room is going to prove that themselves in a few minutes.

## Segment 1 — Orientation (5 min)

Open the dashboard (URL below) and narrate the architecture over it: partitions, the three
consumer groups (`fraud-detector`, `analytics`, `audit`), the Capture panel, the schema
registry panel. This is the "here's what's really running" beat — everything you and the
room touch for the rest of the session is visible on this one page.

```bash
cd samples/eventhubs/python
source scripts/.deployment-env
az webapp show --name "$WEB_APP_NAME" --resource-group "$RESOURCE_GROUP_NAME" \
  --query defaultHostName --output tsv --only-show-errors
```

## Segment 2 — Trigger the workflow across three protocols (10 min)

```bash
bash scripts/talk/ingest.sh
```

Narrate while it runs: POS terminals over AMQP (official SDK), a legacy settlement
gateway over Kafka (librdkafka, no Azure SDK at all), an ATM gateway over HTTPS (a
hand-rolled SAS token — the same path segment 3 is about to hand to the room). One log,
three protocols, ordered per account because producers key on `account_id`. Point at
partition counts ticking up, then the Alerts panel lighting up a few seconds later.

Re-runnable: fire it again anytime you want a second wave on screen — it only checks
growth past its own baseline, so a re-run is never a false failure.

## Segment 3 — The audience act (20 min)

Full setup and mechanics: `scripts/talk/audience-bridge/README.md`. In short: it's already
running from before you went on stage, alongside a `cloudflared` tunnel. Now put it in
front of the room.

```bash
qr "https://<your-tunnel-url>"
```

Project that (or the QR slide you screenshotted earlier) and walk the room through what
they're looking at: `/` is their form, it posts straight into the `payments` hub over the
same HTTPS path you just narrated in segment 2, and the Function App scoring it is the
one that's been running the whole time.

Run it as two beats:

1. **Solo (5 min)**: "send one payment over 5,000" — individual phones trip the amount
   rule, alerts land on the dashboard within a few seconds. Let a few people call out when
   they see their merchant's name land in the Alerts panel.
2. **Team burst (10 min)**: split the room into Team A / Team B (the form already has this
   toggle). "First team to get 6 people to hit send within the same minute trips the
   *velocity* rule instead — the card-testing pattern, not the amount one." Pull up
   `/scoreboard` on a second window/display for this part; it's the payoff shot, not the
   main dashboard.
3. **Debrief (5 min)**: whichever team won, ask the room what they think just happened
   server-side — this is a good spot to explain partition keys and per-account ordering
   without it feeling like a lecture, since they just watched it happen with their own
   taps.

## Segment 4 — Iterate in seconds: the actual dev loop (15 min)

This is the centerpiece. `scripts/deploy.sh` is how you *ship* the function; it is not
how you should *develop* it, because every redeploy replaces the container. The real
inner loop is Azure Functions Core Tools running the same code directly against the same
emulated Event Hubs — no container replacement, ever.

```bash
bash scripts/talk/local-dev-loop.sh
```

This writes `src/functions/local.settings.json` (gitignored) and prints the next step.
In your **second terminal pane**:

```bash
cd samples/eventhubs/python/src/functions
func start
```

Leave it running — it reads `payments` through the `analytics` consumer group (not
`fraud-detector`, so it never touches the deployed instance's checkpoints from segment 5)
and writes to the same `fraud-alerts` hub.

Now make the live edit. Open `src/functions/function_app.py` and:

1. Add a constant near the other thresholds:

   ```python
   SETTLEMENT_BATCH_LIMIT = float(os.environ.get("SETTLEMENT_BATCH_LIMIT", "150"))
   ```

2. Add a rule inside `evaluate()`, after the amount check:

   ```python
   channel = payment.get("channel", "")
   if channel == "settlement-batch" and amount >= SETTLEMENT_BATCH_LIMIT:
       reasons.append(
           f"settlement-batch payment {amount:.2f} >= manual-review limit {SETTLEMENT_BATCH_LIMIT:.2f}"
       )
   ```

Narrate while typing: "our legacy settlement gateway has no real-time authorization, so
anything unusually large coming through it should get flagged for manual review — that
didn't exist five seconds ago." With this much time in the room, it's worth asking first:
"what should we flag instead?" and adapting the rule to whatever they call out — the
mechanic (edit, `Ctrl+C`, `func start`, fire traffic) is the point, not this specific rule.
Then:

```
Ctrl+C          # in the func start pane
func start      # again - seconds, not minutes, no container replaced
```

Back in your main terminal, fire more Kafka traffic (Kafka payments use the
`settlement-batch` channel this new rule watches):

```bash
KAFKA_COUNT=8 AMQP_COUNT=0 HTTP_COUNT=0 bash scripts/talk/ingest.sh
```

Watch the `func start` pane log a new `FRAUD_ALERT ... settlement-batch payment`. That
alert is real, and it shows up on the dashboard too, in the Alerts panel, within the same
refresh cycle — your local instance and the deployed one both write to the same
`fraud-alerts` hub, and the dashboard reads the whole hub regardless of which instance
produced an entry. Point at it there for the payoff shot.

**This is genuinely live software, not a recording.** Payment amounts are randomized, so
if nothing trips in the first batch, say so and fire a few more — that's a feature of a
real demo, not a bug. (`KAFKA_COUNT` payments are ~63% likely each to clear $150 out of
their $5–$400 range, so eight of them very rarely all miss.)

When you're done, don't forget to reset before segment 5 changes anything you'd rather
keep clean for a follow-up run:

```bash
git checkout -- src/functions/function_app.py
```

## Segment 5 — Simulate a failure (10 min)

```bash
bash scripts/talk/simulate-failure.sh
```

Say what's about to happen *before* it happens: "I'm going to kill this process
mid-stream — no different from a spot-instance eviction or a bad rollout." Point at the
dashboard's Consumer Lag panel spiking, then draining back to zero once the host resumes.
The script publishes a burst *during* the outage and proves an alert for it lands after
recovery — resuming at the checkpoint, not replaying the whole backlog and not dropping
the outage-window payments either.

If the audience bridge is still getting occasional traffic, that's a bonus, not a
distraction: real audience-submitted payments piling up during the simulated outage and
then getting processed on recovery is a more honest demonstration than a scripted burst.

## Segment 6 — The cold path, and everything else (8 min)

```bash
bash scripts/talk/decode-capture.sh
```

Decodes whatever Capture archive already exists (from your pre-show warm-up) — Avro,
straight out of Blob Storage, no consumer code. Then, time permitting, run the full
capability audit live:

```bash
bash scripts/validate.sh
```

It's fast (pure CLI calls, no waits) and narrates itself: control plane, then data plane,
then bonus capabilities — least-privilege send-only/listen-only SAS rules, an application
group with a throttling policy, and a geo-disaster-recovery namespace pairing. You don't
need to explain every line; let the pass/fail output scroll and call out one or two that
land the "this isn't a toy" point.

## Segment 7 — Recap, CTA, wrap-up (7 min)

```bash
source scripts/.deployment-env
az webapp show --name "$WEB_APP_NAME" --resource-group "$RESOURCE_GROUP_NAME" \
  --query defaultHostName --output tsv --only-show-errors
```

Everything above ran offline, on this laptop, in ninety minutes including the room's own
phones triggering real alerts, a live code change, and a simulated crash — no cloud round
trip anywhere in the loop except the tunnel carrying phone taps in.

Azure emulation isn't public yet — if you want people to be able to try *this exact
session* themselves afterward, this is the spot for whatever the current sign-up/waitlist
call-to-action is. _(Fill in the actual link before you present — intentionally left as a
placeholder here rather than guessed at.)_

**Cleanup, once the room clears:**

```bash
# in the audience-bridge terminal: Ctrl+C, then Ctrl+C the cloudflared tunnel
bash scripts/cleanup.sh
lstk stop
```

---

## If something misbehaves live

- **No alert within the timeout (segment 2 or 4):** the Function App (or your local `func
  start`) went cold somehow. Don't debug live — acknowledge it, move to slides, and pick
  the demo back up at the end if there's time.
- **`docker restart` finds no container (segment 5):** the Function App isn't deployed or
  running. Same call: acknowledge, move on.
- **Nothing trips the new rule in segment 4:** fire `bash scripts/talk/ingest.sh` again —
  see the note in segment 4 above.
- **Audience bridge gets no traffic (segment 3):** check the tunnel is still up
  (`cloudflared` sessions can drop); re-print the QR code with `qr`. Worst case, run
  `scripts/talk/ingest.sh` yourself and say so — the room still sees the dashboard react.
- **Someone's phone submission gets a 429 ("slow down"):** that's the per-IP cooldown
  working as designed, not a bug — mention it as the "yes, this needed a little abuse
  protection" aside if anyone asks.
- **Wi-Fi/venue network is bad for the main pipeline:** doesn't matter, nothing in that
  path leaves the laptop. The audience bridge is the one thing that does depend on
  connectivity (the tunnel) — see the prerequisites above for testing it in advance.

## Rehearse the timing, not just the commands

Run the whole sequence at least twice on the real presenting laptop before the session. The
`ALERT_WAIT_SECONDS`, `RESTART_RECOVERY_WAIT_SECONDS`, and `CAPTURE_WAIT_SECONDS` env vars
(read by the scripts in `scripts/talk/`) default to generous, CI-style values; if your
hardware is consistently faster, lower them so a real stall still reads as a stall in
rehearsal instead of eating stage time.

For reference, one full dry run on Apple Silicon, warmed up (deploy already run, one
prior pipeline pass done), measured:

| Beat | Budgeted | Observed |
|---|---|---|
| Segment 2 ingest → first alert | 60s | ~12s |
| Segment 3 audience submission → dashboard alert | n/a | a few seconds |
| Segment 4 `func start`, cold | n/a | ready and processing within ~5s |
| Segment 4 `func start`, after the code edit | n/a | ~2s to "Job host started" |
| Segment 5 `docker restart` → recovered alert | 90s | ~12s |
| Segment 6 `validate.sh` (all 33 checks) | n/a | ~22s |

Real numbers will vary by machine, but they confirm the shape of the claim: none of this
needs minutes. If your rehearsal comes out much slower than this, that's worth knowing
before you're on stage, not during.
