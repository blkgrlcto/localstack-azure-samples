# Stage cheat sheet

Pure commands, in order. Full context/rationale/troubleshooting: `TALK-DEMO.md`.
Run everything from `samples/eventhubs/python` unless a step says otherwise.

**Panes**: Main · Func (for `func start`) · Bridge (audience-bridge app) · Tunnel (cloudflared)

---

## Pre-show (before doors open)

```bash
lstk start -t azure
lstk az start-interception
bash scripts/deploy.sh
```
→ if the Function App step 500s: just run `bash scripts/deploy.sh` again (safe, idempotent).

```bash
source .venv/bin/activate
bash scripts/talk/ingest.sh
```
→ "Alert landed." If it says "no alert" instead: Function App is cold, wait ~1 min, run it again.

**Bridge pane:**
```bash
source scripts/.deployment-env
source .venv/bin/activate
cd scripts/talk/audience-bridge
PORT=5050 python3 app.py
```
**Tunnel pane:**
```bash
cloudflared tunnel --url http://localhost:5050
```
→ copy the `https://....trycloudflare.com` URL it prints. Test it from your phone on cellular.

**If it's been >10 min since the last `ingest.sh`, re-run it** — the Function App scales to zero when idle and cold-starts again.

---

## Segment 0 — Welcome (15 min)
Slides only. No commands.

## Segment 1 — Orientation (5 min)
```bash
source scripts/.deployment-env
az webapp show --name "$WEB_APP_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query defaultHostName --output tsv --only-show-errors
```
→ open the printed URL. Narrate the panels.

## Segment 2 — Trigger the workflow (10 min)
```bash
source .venv/bin/activate
bash scripts/talk/ingest.sh
```
→ "Alert landed." Point at dashboard.

## Segment 3 — Audience act (20 min)
```bash
qr "https://<tunnel-url>"
```
→ project it. Phones submit at `/`, scoreboard at `/scoreboard`.

## Segment 4 — Iterate in seconds (15 min)
**Main pane:**
```bash
bash scripts/talk/local-dev-loop.sh
```
**Func pane:**
```bash
cd src/functions
func start
```
→ "Job host started."

**Edit `src/functions/function_app.py`:**
```python
# near the other thresholds
SETTLEMENT_BATCH_LIMIT = float(os.environ.get("SETTLEMENT_BATCH_LIMIT", "150"))
```
```python
# inside evaluate(), after the amount check
channel = payment.get("channel", "")
if channel == "settlement-batch" and amount >= SETTLEMENT_BATCH_LIMIT:
    reasons.append(
        f"settlement-batch payment {amount:.2f} >= "
        f"manual-review limit {SETTLEMENT_BATCH_LIMIT:.2f}")
```

**Func pane:** `Ctrl+C`, then:
```bash
func start
```
→ "Job host started" again (seconds).

**Main pane:**
```bash
KAFKA_COUNT=8 AMQP_COUNT=0 HTTP_COUNT=0 bash scripts/talk/ingest.sh
```
→ new alert, reason = "settlement-batch payment...". Point at dashboard.

**After this segment:**
```bash
git checkout -- src/functions/function_app.py
```

## Segment 5 — Simulate a failure (10 min)
```bash
bash scripts/talk/simulate-failure.sh
```
→ "Recovered: N new alert(s)". Point at Consumer Lag panel.

## Segment 6 — Cold path + capability tour (8 min)
```bash
bash scripts/talk/decode-capture.sh
bash scripts/validate.sh
```
→ decoded records printed / "33 passed, 0 failed".

## Segment 7 — Recap + wrap (7 min)
```bash
source scripts/.deployment-env
az webapp show --name "$WEB_APP_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query defaultHostName --output tsv --only-show-errors
```

**After the room clears:**
```bash
# Ctrl+C the Bridge and Tunnel panes first
bash scripts/cleanup.sh
lstk stop
```

---

## If something breaks mid-segment

| Symptom | Fix |
|---|---|
| `ModuleNotFoundError: No module named 'azure'` | `source .venv/bin/activate` (from `samples/eventhubs/python`) |
| `Port 5050 is in use` | `lsof -i :5050`, then `kill <PID>` |
| `.venv/bin/activate: permission denied` | You forgot `source` in front of it |
| `Worker runtime cannot be 'None'` | Run `scripts/talk/local-dev-loop.sh` before `func start`, not after |
| `EVENTHUB_SEND_CONNECTION_STRING is not set` | `source scripts/.deployment-env` from `samples/eventhubs/python`, **before** `cd`-ing anywhere else |
| "no alert" / DEMO STALLED | Function App went cold (idle timeout) — wait ~1 min, re-run `ingest.sh` |
| Anything else | Say so, move to slides, come back to it later. Don't debug live. |
