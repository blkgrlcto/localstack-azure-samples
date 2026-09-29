#!/bin/bash

# =============================================================================
# Talk beat: "simulate a failure" - kill the deployed Function App's container
# mid-stream and prove it resumes from its checkpoint. See ../../TALK-DEMO.md,
# Act 3.
#
# Uses `docker restart` on the function's own container, not a redeploy. Same
# process death, same in-memory state loss, same "does it resume?" question -
# but the container's filesystem (and whatever it already downloaded) survives,
# so recovery is tens of seconds, not the ten minutes a redeploy would cost.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="$(cd "$SCRIPTS_DIR/../src" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

RESTART_COUNT="${RESTART_COUNT:-10}"
BURST_ACCOUNT="${BURST_ACCOUNT:-ACC-TALK-$RANDOM}"
RESTART_RECOVERY_WAIT_SECONDS="${RESTART_RECOVERY_WAIT_SECONDS:-90}"

if [[ ! -f "$SCRIPTS_DIR/.deployment-env" ]]; then
	echo "ERROR: scripts/.deployment-env not found. Run 'bash scripts/deploy.sh' first."
	exit 1
fi
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/.deployment-env"

# See ingest.sh for why this check exists: a fresh terminal has no reason to have the
# project venv active, and a missing azure-eventhub here would otherwise surface as a
# confusing "alerts hub unreadable" instead of the actual cause.
if ! "$PYTHON_BIN" -c "import azure.eventhub" 2>/dev/null; then
	echo "ERROR: '$PYTHON_BIN' can't import azure-eventhub - is the project venv active?"
	echo "       cd samples/eventhubs/python && source .venv/bin/activate"
	exit 1
fi

function_container() {
	docker ps --format "{{.Names}}" | grep -E "^ls-.*${FUNCTION_APP_NAME}" | head -1
}

function_logs() {
	command -v docker >/dev/null 2>&1 || return 1
	local container
	container=$(function_container)
	[[ -n "$container" ]] && docker logs "$container" 2>&1
}

fail() {
	echo "DEMO STALLED: $1"
	local logs
	logs=$(function_logs)
	[[ -n "$logs" ]] && echo "$logs" | tail -30 | sed 's/^/  /'
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

CONTAINER=$(function_container)
[[ -n "$CONTAINER" ]] || fail "no running container matches the Function App '$FUNCTION_APP_NAME'"
ALERTS_BEFORE=$(count_total "$ALERT_HUB_NAME") || fail "alerts hub unreadable"

echo "Killing the processor: docker restart $CONTAINER"
echo "(narrate: same failure mode as a spot-instance eviction or a bad rollout)"
docker restart "$CONTAINER" >/dev/null || fail "docker restart failed"

echo "Publishing $RESTART_COUNT more payments while it's down..."
cd "$SRC_DIR/producers" || fail "missing src/producers"
EVENTHUB_SEND_CONNECTION_STRING="$EVENTHUB_SEND_CONNECTION_STRING" EVENT_HUB_NAME="$EVENT_HUB_NAME" \
	"$PYTHON_BIN" producer_amqp.py --count "$RESTART_COUNT" --burst-account "$BURST_ACCOUNT" ||
	fail "producer failed during the outage window"

echo "Watching the dashboard's Consumer Lag panel climb, then recover on its own"
echo "(up to ${RESTART_RECOVERY_WAIT_SECONDS}s)..."
ALERTS_AFTER=$(wait_for_alerts "$ALERTS_BEFORE" "$RESTART_RECOVERY_WAIT_SECONDS") ||
	fail "processor did not resume within ${RESTART_RECOVERY_WAIT_SECONDS}s of the restart"
echo ""
echo "Recovered: $((ALERTS_AFTER - ALERTS_BEFORE)) new alert(s) from payments published"
echo "while the processor was down. Nothing published before the kill was reprocessed -"
echo "that's the checkpoint, not luck."
