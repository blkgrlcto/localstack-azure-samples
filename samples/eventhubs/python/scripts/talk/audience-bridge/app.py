"""Audience bridge: phones -> the live fraud detection pipeline.

Azure emulation isn't public yet, so the room can't run `deploy.sh` themselves - but they
can still be the ones actually triggering the pipeline. This is a small Flask app, meant to
run on the PRESENTER's laptop next to an already-deployed samples/eventhubs stack. It serves
a one-field mobile form; every submission is signed and POSTed over the exact same HTTPS
path `producer_http.py` uses (a hand-built Event Hubs SAS token, no SDK) into the *same*
running `payments` hub. From there it's indistinguishable from any other payment: the real,
deployed Function App scores it, and a real alert can land on the real dashboard - the
audience is not simulating the pipeline, they're driving it.

Nothing about samples/eventhubs itself changes. This only reuses its existing HTTP
ingestion path, imported directly from src/producers.

Run this on the presenter's laptop, in a shell that has already sourced
scripts/.deployment-env (same requirement as every producer script):

    source scripts/.deployment-env
    cd scripts/talk/audience-bridge
    pip install -r requirements.txt
    python app.py

Then expose it to the room - see ../../../TALK-DEMO.md, "The audience act" - and put the
tunnel URL (or a QR code of it) on screen.
"""

import os
import random
import sys
import threading
import time
from collections import defaultdict

import requests
from flask import Flask, jsonify, render_template, request

# Reuse the exact producers the sample already ships, rather than re-implementing SAS
# signing or the payment schema here.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "..", "src", "producers"))
from common import (  # noqa: E402
    COUNTRIES,
    MERCHANTS,
    connection_string,
    encode_payment,
    event_hub_name,
    require_env,
    sas_credentials,
)
from producer_http import build_sas_token  # noqa: E402

app = Flask(__name__)

FRAUD_AMOUNT_THRESHOLD = float(os.environ.get("FRAUD_AMOUNT_THRESHOLD", "5000"))
VELOCITY_COUNT = int(os.environ.get("FRAUD_VELOCITY_COUNT", "5"))
CHANNEL = "audience-phone"

TEAMS = {
    "A": "ACC-TEAM-A",
    "B": "ACC-TEAM-B",
}

# A gentle per-IP cooldown: enough to stop one phone from scripting a flood, loose enough
# that a person mashing "send" by hand for the team-burst game never feels throttled.
SUBMIT_COOLDOWN_SECONDS = 1.5
_last_submit_by_ip: dict[str, float] = {}
_lock = threading.Lock()

# In-memory scoreboard for /scoreboard. Ephemeral by design - this is a talk prop, not a
# system of record, and it resets every time the app restarts.
_stats = {team: {"submitted": 0, "flagged": 0} for team in TEAMS}
_recent: list[dict] = []
MAX_RECENT = 12


def _connection_details():
    conn_str = connection_string()
    hub = event_hub_name()
    host, key_name, key = sas_credentials(conn_str)
    resource_uri = f"https://{host}/{hub}"
    endpoint = f"{resource_uri}/messages?api-version=2014-01"
    return resource_uri, endpoint, key_name, key


@app.route("/")
def form():
    return render_template(
        "form.html",
        teams=list(TEAMS.keys()),
        threshold=FRAUD_AMOUNT_THRESHOLD,
        velocity_count=VELOCITY_COUNT,
    )


@app.route("/scoreboard")
def scoreboard():
    return render_template("scoreboard.html")


@app.route("/api/scoreboard")
def api_scoreboard():
    return jsonify({"stats": _stats, "recent": _recent})


@app.route("/submit", methods=["POST"])
def submit():
    ip = request.headers.get("X-Forwarded-For", request.remote_addr or "unknown").split(",")[0].strip()
    now = time.monotonic()
    with _lock:
        last = _last_submit_by_ip.get(ip, 0)
        if now - last < SUBMIT_COOLDOWN_SECONDS:
            return jsonify({"ok": False, "message": "Slow down a second - one at a time!"}), 429
        _last_submit_by_ip[ip] = now

    team = request.form.get("team", "")
    if team not in TEAMS:
        return jsonify({"ok": False, "message": "Pick a team."}), 400

    try:
        amount = float(request.form.get("amount", ""))
    except ValueError:
        return jsonify({"ok": False, "message": "That doesn't look like an amount."}), 400
    if not (0 < amount <= 20000):
        return jsonify({"ok": False, "message": "Keep it between 1 and 20,000."}), 400

    merchant = request.form.get("merchant", "")
    if merchant not in MERCHANTS:
        merchant = random.choice(MERCHANTS)

    payment = {
        "transaction_id": f"audience-{int(now * 1000)}-{random.randint(1000, 9999)}",
        "account_id": TEAMS[team],
        "merchant": merchant,
        "country": random.choice(COUNTRIES),
        "amount": round(amount, 2),
        "currency": "EUR",
        "channel": CHANNEL,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }

    try:
        resource_uri, endpoint, key_name, key = _connection_details()
        token = build_sas_token(resource_uri, key_name, key)
        response = requests.post(
            endpoint,
            data=encode_payment(payment),
            headers={
                "Authorization": token,
                "Content-Type": "application/atom+xml;type=entry;charset=utf-8",
                "source": "audience-bridge",
                "protocol": "http",
                "BrokerProperties": '{"PartitionKey": "%s"}' % payment["account_id"],
            },
            timeout=10,
            verify="localhost.localstack.cloud" not in endpoint,
        )
        response.raise_for_status()
    except Exception as exc:  # noqa: BLE001 - this is a talk prop; surface any failure plainly
        return jsonify({"ok": False, "message": f"Couldn't reach the pipeline: {exc}"}), 502

    flagged = amount >= FRAUD_AMOUNT_THRESHOLD
    with _lock:
        _stats[team]["submitted"] += 1
        if flagged:
            _stats[team]["flagged"] += 1
        _recent.insert(0, {"team": team, "merchant": merchant, "amount": payment["amount"], "flagged": flagged})
        del _recent[MAX_RECENT:]

    message = (
        "Sent! That one's over the threshold - watch the dashboard \U0001f440"
        if flagged
        else "Sent! Under the radar this time - try a bigger one, or team up for a burst."
    )
    return jsonify({"ok": True, "message": message, "flagged": flagged})


if __name__ == "__main__":
    # Fails loudly and immediately if scripts/.deployment-env hasn't been sourced, rather
    # than accepting submissions it can't actually deliver anywhere.
    require_env("EVENTHUB_SEND_CONNECTION_STRING")
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "5000")))
