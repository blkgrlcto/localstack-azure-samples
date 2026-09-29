#!/bin/bash

# =============================================================================
# Talk beat: "iterate in seconds" - the actual inner dev loop, no deploy at all.
# See ../../TALK-DEMO.md, Act 2.
#
# `scripts/deploy.sh` publishes the function to a Function App resource on the
# emulator, which is how you ship it - but it is not how you should *develop*
# it: every `az functionapp deploy` replaces the container, so the host cold
# starts and re-downloads its extension bundle before the next invocation.
#
# The actual local loop is Azure Functions Core Tools: `func start` runs the
# same function_app.py directly against the same emulated Event Hubs and
# Storage, on your machine, with no container replacement at all. Edit the
# code, Ctrl+C, `func start` again - seconds, not minutes.
#
# This script only generates local.settings.json (Functions Core Tools reads
# its config from this file, the same way it reads app settings in Azure) and
# tells you the next command. It deliberately does not run `func start` itself:
# that has to run in the foreground, in its own terminal, so you can Ctrl+C it
# live.
#
# It points FRAUD_CONSUMER_GROUP at the *analytics* consumer group rather than
# fraud-detector - deploy.sh already creates it (see README architecture
# diagram: "groups: fraud-detector, analytics, audit") and nothing else reads
# it. That keeps this local instance from fighting the deployed Function App
# over partition ownership and checkpoints; the two run side by side, and Beat
# 3's failure simulation is undisturbed by whatever you do here.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FUNCTIONS_DIR="$(cd "$SCRIPTS_DIR/../src/functions" && pwd)"

if [[ ! -f "$SCRIPTS_DIR/.deployment-env" ]]; then
	echo "ERROR: scripts/.deployment-env not found. Run 'bash scripts/deploy.sh' first."
	exit 1
fi
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/.deployment-env"

if ! command -v func >/dev/null 2>&1; then
	echo "ERROR: Azure Functions Core Tools ('func') is not on PATH."
	echo "       brew install azure/functions/azure-functions-core-tools@4"
	exit 1
fi

LOCAL_SETTINGS="$FUNCTIONS_DIR/local.settings.json"
cat >"$LOCAL_SETTINGS" <<EOF
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "$STORAGE_CONNECTION_STRING",
    "FUNCTIONS_WORKER_RUNTIME": "python",
    "EVENTHUB_LISTEN_CONNECTION": "$EVENTHUB_LISTEN_CONNECTION_STRING",
    "EVENTHUB_SEND_CONNECTION": "$EVENTHUB_ALERT_SEND_CONNECTION_STRING",
    "EVENT_HUB_NAME": "$EVENT_HUB_NAME",
    "ALERT_HUB_NAME": "$ALERT_HUB_NAME",
    "FRAUD_CONSUMER_GROUP": "analytics",
    "FRAUD_AMOUNT_THRESHOLD": "5000",
    "FRAUD_VELOCITY_COUNT": "5",
    "FRAUD_VELOCITY_WINDOW_SECONDS": "60"
  }
}
EOF

echo "Wrote $LOCAL_SETTINGS (gitignored - holds live connection strings)."
echo ""
echo "Next, in a SEPARATE terminal pane:"
echo ""
echo "  cd samples/eventhubs/python/src/functions"
echo "  func start"
echo ""
echo "Leave it running. It's reading the same 'payments' hub the deployed"
echo "Function App reads, through the 'analytics' consumer group instead of"
echo "'fraud-detector', and writing alerts to the same 'fraud-alerts' hub."
echo ""
echo "Fire scripts/talk/ingest.sh (or reuse payments already in the hub - this"
echo "instance reads from its own consumer group's position) to prove it's"
echo "live, then make the code edit from TALK-DEMO.md Act 2 in function_app.py,"
echo "Ctrl+C, and 'func start' again."
