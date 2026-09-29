#!/bin/bash

# =============================================================================
# Talk beat: "the cold path" - decode the newest Event Hubs Capture archive
# straight out of Blob Storage. See ../../TALK-DEMO.md, Act 4.
#
# Decodes whatever archive already exists by default, so it never blocks the
# talk. Pass --wait to poll for a fresh window instead (Capture's minimum
# interval is 60s - no script makes that faster, so only do this if you have
# time and want to narrate the wait).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
WAIT_SECONDS="${CAPTURE_WAIT_SECONDS:-70}"

if [[ ! -f "$SCRIPTS_DIR/.deployment-env" ]]; then
	echo "ERROR: scripts/.deployment-env not found. Run 'bash scripts/deploy.sh' first."
	exit 1
fi
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/.deployment-env"

# See ingest.sh for why this check exists: a fresh terminal has no reason to have the
# project venv active, and read_capture.py needs both of these to decode anything.
if ! "$PYTHON_BIN" -c "import azure.storage.blob, fastavro" 2>/dev/null; then
	echo "ERROR: '$PYTHON_BIN' can't import azure-storage-blob/fastavro - is the project venv active?"
	echo "       cd samples/eventhubs/python && source .venv/bin/activate"
	exit 1
fi

if [[ "$1" == "--wait" ]]; then
	echo "Waiting up to ${WAIT_SECONDS}s for a fresh Capture window to flush..."
	DEADLINE=$((SECONDS + WAIT_SECONDS))
	BLOB_COUNT=0
	while [ $SECONDS -lt $DEADLINE ]; do
		BLOB_COUNT=$(az storage blob list \
			--container-name "$CAPTURE_CONTAINER_NAME" \
			--connection-string "$STORAGE_CONNECTION_STRING" \
			--query "length(@)" --output tsv --only-show-errors 2>/dev/null || echo 0)
		[[ "${BLOB_COUNT:-0}" -gt 0 ]] && break
		sleep 5
	done
fi

DECODED=$(STORAGE_CONNECTION_STRING="$STORAGE_CONNECTION_STRING" \
	CAPTURE_CONTAINER_NAME="$CAPTURE_CONTAINER_NAME" \
	"$PYTHON_BIN" "$SCRIPTS_DIR/read_capture.py" 2>&1)
if [[ $? -eq 0 ]]; then
	echo "$DECODED" | sed 's/^/  /'
else
	echo "No archive decoded yet - Capture flushes on a 60s window."
	echo "Point at the dashboard's Capture panel instead, or re-run with --wait."
fi
