#!/bin/bash

# =============================================================================
# Talk beat: "trigger the workflow" - publish across three protocols and wait
# for the fraud detector to react. See ../../TALK-DEMO.md, Act 1.
#
# Standalone and re-runnable: run it as many times as you like during the
# talk (e.g. if you want a second wave while narrating). Each run only
# asserts growth past its own baseline, so a re-run never looks like a
# failure just because the hub already has events in it.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="$(cd "$SCRIPTS_DIR/../src" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

AMQP_COUNT="${AMQP_COUNT:-12}"
KAFKA_COUNT="${KAFKA_COUNT:-6}"
HTTP_COUNT="${HTTP_COUNT:-4}"
# producer_amqp.py's --burst-account always adds a fixed 12-payment card-testing burst on
# top of --count - that size is hardcoded in the producer, not something this script (or
# any env var here) controls.
BURST_ACCOUNT="${BURST_ACCOUNT:-ACC-TALK-$RANDOM}"
ALERT_WAIT_SECONDS="${ALERT_WAIT_SECONDS:-60}"

if [[ ! -f "$SCRIPTS_DIR/.deployment-env" ]]; then
	echo "ERROR: scripts/.deployment-env not found. Run 'bash scripts/deploy.sh' first."
	exit 1
fi
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/.deployment-env"

# A fresh terminal (a new pane, a reboot since the last rehearsal) has no reason to have
# the project venv active, and PYTHON_BIN defaults to the shell's own python3 - which on
# a machine with a newer Python default, is very often one that never had azure-eventhub
# installed at all. Catching that here, loudly, beats every check below silently reading
# as "the alerts hub is unreadable" because the python calls that prove it are crashing.
if ! "$PYTHON_BIN" -c "import azure.eventhub" 2>/dev/null; then
	echo "ERROR: '$PYTHON_BIN' can't import azure-eventhub - is the project venv active?"
	echo "       cd samples/eventhubs/python && source .venv/bin/activate"
	exit 1
fi

fail() {
	echo "DEMO STALLED: $1"
	exit 1
}

count_total() {
	local total
	total=$(EVENTHUB_LISTEN_CONNECTION_STRING="$EVENTHUB_NAMESPACE_CONNECTION_STRING" \
		EVENT_HUB_NAME="$1" \
		"$PYTHON_BIN" "$SCRIPTS_DIR/roundtrip_check.py" --total 2>/dev/null | tail -1)
	[[ "$total" =~ ^[0-9]+$ ]] || return 1
	echo "$total"
}

wait_for_alerts() {
	local baseline="$1" timeout="$2" deadline current
	deadline=$((SECONDS + timeout))
	current="$baseline"
	while [ $SECONDS -lt $deadline ]; do
		current=$(count_total "$ALERT_HUB_NAME") || current="$baseline"
		if [[ "${current:-0}" -gt "${baseline:-0}" ]]; then
			echo "$current"
			return 0
		fi
		sleep 3
	done
	echo "${current:-0}"
	return 1
}

ALERTS_BASELINE=$(count_total "$ALERT_HUB_NAME") || fail "alerts hub '$ALERT_HUB_NAME' unreadable"
PAYMENTS_BEFORE=$(count_total "$EVENT_HUB_NAME") || fail "payments hub '$EVENT_HUB_NAME' unreadable"

cd "$SRC_DIR/producers" || fail "missing src/producers"
echo "--- AMQP (POS terminals, official SDK) ---"
EVENTHUB_SEND_CONNECTION_STRING="$EVENTHUB_SEND_CONNECTION_STRING" EVENT_HUB_NAME="$EVENT_HUB_NAME" \
	"$PYTHON_BIN" producer_amqp.py --count "$AMQP_COUNT" --burst-account "$BURST_ACCOUNT" ||
	fail "AMQP producer failed"
echo ""
echo "--- Kafka (legacy settlement gateway, librdkafka, no Azure SDK) ---"
EVENTHUB_SEND_CONNECTION_STRING="$EVENTHUB_NAMESPACE_CONNECTION_STRING" EVENT_HUB_NAME="$EVENT_HUB_NAME" \
	"$PYTHON_BIN" producer_kafka.py --count "$KAFKA_COUNT" || fail "Kafka producer failed"
echo ""
echo "--- HTTPS (ATM gateway, hand-built SAS token, no SDK at all) ---"
EVENTHUB_SEND_CONNECTION_STRING="$EVENTHUB_SEND_CONNECTION_STRING" EVENT_HUB_NAME="$EVENT_HUB_NAME" \
	"$PYTHON_BIN" producer_http.py --count "$HTTP_COUNT" || fail "HTTPS producer failed"

PAYMENTS_AFTER=$(count_total "$EVENT_HUB_NAME") || fail "payments hub unreadable after ingest"
echo ""
echo "Payments hub grew by $((PAYMENTS_AFTER - PAYMENTS_BEFORE)) events across 3 protocols."
echo "Waiting for the fraud detector to react (up to ${ALERT_WAIT_SECONDS}s)..."
wait_for_alerts "$ALERTS_BASELINE" "$ALERT_WAIT_SECONDS" >/dev/null ||
	fail "no alert within ${ALERT_WAIT_SECONDS}s - is the Function App warm?"
echo "Alert landed. -> point at the dashboard's Alerts panel now."
