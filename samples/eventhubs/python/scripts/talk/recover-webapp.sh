#!/bin/bash

# =============================================================================
# Recovery for a known deploy.sh race: step [10/12] (the Function App code
# deploy) times out with "500 ... Functions runtime not responding" the first
# time the container has to download its extension bundle from cold. The
# container is NOT broken when this happens - it keeps downloading in the
# background after the CLI gives up waiting on it.
#
# The wrong fix is re-running `bash scripts/deploy.sh` again: it always calls
# `az functionapp deploy` unconditionally, which REPLACES the container and
# resets the download to zero. Do that enough times and it never finishes.
#
# This script instead: waits for the *existing* container to actually finish,
# then completes only the steps deploy.sh never reached (Web App creation,
# dashboard deploy, scripts/.deployment-env) - without touching the Function
# App again.
#
# Use this only after `bash scripts/deploy.sh` has failed at step [10/12] or
# later. If it failed earlier than that (resource group, storage, Event Hubs
# namespace, etc. never got created), run deploy.sh again from scratch instead.
# =============================================================================

CURRENT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$(cd "$CURRENT_DIR/../src" && pwd)"
cd "$CURRENT_DIR" || exit 1

RESOURCE_GROUP_NAME='local-eventhubs-rg'
EVENTHUB_NAMESPACE_NAME='local-ehns-payments'
EVENT_HUB_NAME='payments'
ALERT_HUB_NAME='fraud-alerts'
FRAUD_CONSUMER_GROUP='fraud-detector'
SCHEMA_GROUP_NAME='payments-schemas'
STORAGE_ACCOUNT_NAME='localehstoragepaym'
CAPTURE_CONTAINER_NAME='payments-archive'
KEY_VAULT_NAME='localehkvpaym'
FUNCTION_APP_NAME='local-eh-fraud-func'
WEB_APP_NAME='local-eh-dashboard'
APP_SERVICE_PLAN_NAME='local-eh-plan'
APP_SERVICE_PLAN_SKU='S1'
WEB_APP_RUNTIME='PYTHON:3.12'
WEB_APP_ZIP='dashboard.zip'
LOCATION='westeurope'
SEND_RULE_NAME='payments-send'
LISTEN_RULE_NAME='payments-listen'
ALERT_SEND_RULE_NAME='alerts-send'
DASHBOARD_LISTEN_RULE_NAME='dashboard-listen'

WAIT_TIMEOUT_SECONDS="${RECOVER_WAIT_TIMEOUT_SECONDS:-900}"

fail() {
	echo "ERROR: $1"
	exit 1
}

if ! az group show --name "$RESOURCE_GROUP_NAME" --only-show-errors &>/dev/null; then
	fail "resource group '$RESOURCE_GROUP_NAME' doesn't exist - run 'bash scripts/deploy.sh' from scratch instead, this script only picks up after step [10/12]."
fi
if ! az functionapp show --name "$FUNCTION_APP_NAME" --resource-group "$RESOURCE_GROUP_NAME" --only-show-errors &>/dev/null; then
	fail "function app '$FUNCTION_APP_NAME' doesn't exist yet - run 'bash scripts/deploy.sh' from scratch instead."
fi

echo "Waiting for the Function App container to finish its cold start (up to ${WAIT_TIMEOUT_SECONDS}s)..."
DEADLINE=$((SECONDS + WAIT_TIMEOUT_SECONDS))
FUNC_CONTAINER=""
while [ $SECONDS -lt $DEADLINE ]; do
	FUNC_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "^ls-.*${FUNCTION_APP_NAME}" | head -1)
	if [[ -n "$FUNC_CONTAINER" ]] && docker logs "$FUNC_CONTAINER" 2>&1 | grep -qE "Job host started|Host lock lease acquired"; then
		echo "Ready: $FUNC_CONTAINER"
		break
	fi
	sleep 10
	echo "  ...still waiting ($((DEADLINE - SECONDS))s left)"
done
if [[ -z "$FUNC_CONTAINER" ]] || ! docker logs "$FUNC_CONTAINER" 2>&1 | grep -qE "Job host started|Host lock lease acquired"; then
	fail "the Function App never finished starting within ${WAIT_TIMEOUT_SECONDS}s. Check 'docker logs \$(docker ps --format \"{{.Names}}\" | grep fraud-func)' directly."
fi

echo ""
echo "Re-deriving connection strings..."
STORAGE_KEY=$(az storage account keys list --account-name "$STORAGE_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query "[0].value" --output tsv --only-show-errors)
STORAGE_BLOB_ENDPOINT=$(az storage account show --name "$STORAGE_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query primaryEndpoints.blob --output tsv --only-show-errors)
STORAGE_QUEUE_ENDPOINT=$(az storage account show --name "$STORAGE_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query primaryEndpoints.queue --output tsv --only-show-errors)
STORAGE_TABLE_ENDPOINT=$(az storage account show --name "$STORAGE_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query primaryEndpoints.table --output tsv --only-show-errors)
STORAGE_CONNECTION_STRING="DefaultEndpointsProtocol=https;AccountName=${STORAGE_ACCOUNT_NAME};AccountKey=${STORAGE_KEY};BlobEndpoint=${STORAGE_BLOB_ENDPOINT};QueueEndpoint=${STORAGE_QUEUE_ENDPOINT};TableEndpoint=${STORAGE_TABLE_ENDPOINT}"

EVENTHUB_SEND_CONNECTION_STRING=$(az eventhubs eventhub authorization-rule keys list --name "$SEND_RULE_NAME" --eventhub-name "$EVENT_HUB_NAME" --namespace-name "$EVENTHUB_NAMESPACE_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query primaryConnectionString --output tsv --only-show-errors)
EVENTHUB_LISTEN_CONNECTION_STRING=$(az eventhubs eventhub authorization-rule keys list --name "$LISTEN_RULE_NAME" --eventhub-name "$EVENT_HUB_NAME" --namespace-name "$EVENTHUB_NAMESPACE_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query primaryConnectionString --output tsv --only-show-errors)
EVENTHUB_ALERT_SEND_CONNECTION_STRING=$(az eventhubs eventhub authorization-rule keys list --name "$ALERT_SEND_RULE_NAME" --eventhub-name "$ALERT_HUB_NAME" --namespace-name "$EVENTHUB_NAMESPACE_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query primaryConnectionString --output tsv --only-show-errors)
EVENTHUB_NAMESPACE_CONNECTION_STRING=$(az eventhubs namespace authorization-rule keys list --name RootManageSharedAccessKey --namespace-name "$EVENTHUB_NAMESPACE_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query primaryConnectionString --output tsv --only-show-errors)
DASHBOARD_LISTEN_CONNECTION_STRING=$(az eventhubs namespace authorization-rule keys list --name "$DASHBOARD_LISTEN_RULE_NAME" --namespace-name "$EVENTHUB_NAMESPACE_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query primaryConnectionString --output tsv --only-show-errors)

if [[ -z "$STORAGE_CONNECTION_STRING" || -z "$EVENTHUB_SEND_CONNECTION_STRING" || -z "$EVENTHUB_LISTEN_CONNECTION_STRING" || -z "$EVENTHUB_ALERT_SEND_CONNECTION_STRING" || -z "$EVENTHUB_NAMESPACE_CONNECTION_STRING" || -z "$DASHBOARD_LISTEN_CONNECTION_STRING" ]]; then
	fail "one or more connection strings came back empty"
fi
echo "OK."

echo ""
echo "=== Web App (operations dashboard) ==="
if ! az appservice plan show --name "$APP_SERVICE_PLAN_NAME" --resource-group "$RESOURCE_GROUP_NAME" --only-show-errors &>/dev/null; then
	az appservice plan create --name "$APP_SERVICE_PLAN_NAME" --resource-group "$RESOURCE_GROUP_NAME" --location "$LOCATION" --sku "$APP_SERVICE_PLAN_SKU" --is-linux --only-show-errors 1>/dev/null || fail "could not create the app service plan"
fi

if ! az webapp show --name "$WEB_APP_NAME" --resource-group "$RESOURCE_GROUP_NAME" --only-show-errors &>/dev/null; then
	az webapp create --name "$WEB_APP_NAME" --resource-group "$RESOURCE_GROUP_NAME" --plan "$APP_SERVICE_PLAN_NAME" --runtime "$WEB_APP_RUNTIME" --only-show-errors 1>/dev/null || fail "could not create the web app"
fi

az webapp config appsettings set --name "$WEB_APP_NAME" --resource-group "$RESOURCE_GROUP_NAME" --settings \
	"EVENTHUB_LISTEN_CONNECTION_STRING=$DASHBOARD_LISTEN_CONNECTION_STRING" \
	"STORAGE_CONNECTION_STRING=$STORAGE_CONNECTION_STRING" \
	"EVENT_HUB_NAME=$EVENT_HUB_NAME" \
	"ALERT_HUB_NAME=$ALERT_HUB_NAME" \
	"FRAUD_CONSUMER_GROUP=$FRAUD_CONSUMER_GROUP" \
	"CAPTURE_CONTAINER_NAME=$CAPTURE_CONTAINER_NAME" \
	"SCHEMA_GROUP_NAME=$SCHEMA_GROUP_NAME" \
	"SCM_DO_BUILD_DURING_DEPLOYMENT=true" \
	--only-show-errors 1>/dev/null || fail "could not set web app settings"

az webapp config set --name "$WEB_APP_NAME" --resource-group "$RESOURCE_GROUP_NAME" --startup-file "gunicorn --config gunicorn.conf.py app:app" --only-show-errors 1>/dev/null || fail "could not set the dashboard startup command"

cd "$SRC_DIR/dashboard" || fail "missing src/dashboard"
rm -f "$CURRENT_DIR/$WEB_APP_ZIP"
zip -r "$CURRENT_DIR/$WEB_APP_ZIP" app.py gunicorn.conf.py requirements.txt templates static 1>/dev/null
cd "$CURRENT_DIR" || exit 1

echo "Deploying the dashboard package..."
az webapp deploy --resource-group "$RESOURCE_GROUP_NAME" --name "$WEB_APP_NAME" --src-path "$WEB_APP_ZIP" --type zip 1>/dev/null || fail "could not deploy the web app"
rm -f "$WEB_APP_ZIP"

WEB_APP_URL=$(az webapp show --name "$WEB_APP_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query defaultHostName --output tsv --only-show-errors 2>/dev/null)

cat > .deployment-env <<EOF
export RESOURCE_GROUP_NAME='$RESOURCE_GROUP_NAME'
export EVENTHUB_NAMESPACE_NAME='$EVENTHUB_NAMESPACE_NAME'
export EVENT_HUB_NAME='$EVENT_HUB_NAME'
export ALERT_HUB_NAME='$ALERT_HUB_NAME'
export FRAUD_CONSUMER_GROUP='$FRAUD_CONSUMER_GROUP'
export SCHEMA_GROUP_NAME='$SCHEMA_GROUP_NAME'
export STORAGE_ACCOUNT_NAME='$STORAGE_ACCOUNT_NAME'
export CAPTURE_CONTAINER_NAME='$CAPTURE_CONTAINER_NAME'
export KEY_VAULT_NAME='$KEY_VAULT_NAME'
export FUNCTION_APP_NAME='$FUNCTION_APP_NAME'
export WEB_APP_NAME='$WEB_APP_NAME'
export EVENTHUB_SEND_CONNECTION_STRING='$EVENTHUB_SEND_CONNECTION_STRING'
export EVENTHUB_LISTEN_CONNECTION_STRING='$EVENTHUB_LISTEN_CONNECTION_STRING'
export EVENTHUB_ALERT_SEND_CONNECTION_STRING='$EVENTHUB_ALERT_SEND_CONNECTION_STRING'
export EVENTHUB_NAMESPACE_CONNECTION_STRING='$EVENTHUB_NAMESPACE_CONNECTION_STRING'
export STORAGE_CONNECTION_STRING='$STORAGE_CONNECTION_STRING'
EOF

echo ""
echo "Dashboard: https://${WEB_APP_URL}"
echo "Wrote fresh scripts/.deployment-env"
