#!/bin/bash

# =============================================================================
# Real-time payment fraud detection on Azure Event Hubs - LIGHTNING version
#
# This is a ~3 minute smoke test / rehearsal / fallback, not the talk itself.
# The actual 30-minute live demo is a runbook you drive by hand, one command
# at a time, pausing to narrate between them - see ../TALK-DEMO.md. That is
# deliberate: a live 30-minute demo needs you controlling the pacing, not a
# single script racing through it unattended while you talk over fixed sleeps.
#
# Use this script to:
#   - warm up the environment before you leave for the venue (it's also what
#     seeds a real Capture archive and gets the Function App off a cold start,
#     both of which the full runbook depends on);
#   - smoke-test that deploy.sh actually produced a working pipeline;
#   - fall back to, verbatim, if you only have a few minutes on stage instead
#     of the full 30 (e.g. a lightning-talk slot, or Q&A time).
#
# It runs the three reusable beats from scripts/talk/ back to back with no
# pauses. Each one is also independently runnable and reused directly by the
# 30-minute runbook - see scripts/talk/*.sh.
#
# Run scripts/deploy.sh first. Everything is local to the emulator.
# =============================================================================

CURRENT_DIR="$(cd "$(dirname "$0")" && pwd)"
TALK_DIR="$CURRENT_DIR/talk"

if [[ ! -f "$CURRENT_DIR/.deployment-env" ]]; then
	echo "ERROR: scripts/.deployment-env not found. Run 'bash scripts/deploy.sh' first."
	exit 1
fi
# shellcheck disable=SC1091
source "$CURRENT_DIR/.deployment-env"

step() {
	echo ""
	echo "============================================================"
	echo "$1"
	echo "============================================================"
}

# -----------------------------------------------------------------------------
step "Where the audience should be looking"
# -----------------------------------------------------------------------------
WEB_APP_URL=$(az webapp show --name "$WEB_APP_NAME" --resource-group "$RESOURCE_GROUP_NAME" \
	--query defaultHostName --output tsv --only-show-errors 2>/dev/null)
[[ -n "$WEB_APP_URL" ]] && echo "Dashboard: https://${WEB_APP_URL}"

# -----------------------------------------------------------------------------
step "Beat 1/3 - Trigger the workflow: one stream, three protocols"
# -----------------------------------------------------------------------------
bash "$TALK_DIR/ingest.sh" || exit 1

# -----------------------------------------------------------------------------
step "Beat 2/3 - Simulate a failure: kill the processor mid-stream"
# -----------------------------------------------------------------------------
bash "$TALK_DIR/simulate-failure.sh" || exit 1

# -----------------------------------------------------------------------------
step "Beat 3/3 - The cold path: Blob Storage has the whole story too"
# -----------------------------------------------------------------------------
bash "$TALK_DIR/decode-capture.sh" "$@"

# -----------------------------------------------------------------------------
step "Recap"
# -----------------------------------------------------------------------------
[[ -n "$WEB_APP_URL" ]] && echo "Dashboard: https://${WEB_APP_URL}"
echo ""
echo "For the full 30-minute version (local dev loop + live code edit +"
echo "capability tour), drive ../TALK-DEMO.md by hand instead of this script."
