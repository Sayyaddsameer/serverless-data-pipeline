#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# deploy_canary.sh
#
# Manages canary deployments for a Lambda function by updating aliases
# and configuring weighted traffic routing between PROD and CANARY versions.
#
# Usage:
#   ./deploy_canary.sh <function-name> [canary-weight]
#
# Arguments:
#   function-name   Name of the Lambda function to deploy.
#   canary-weight   Fraction of traffic for the canary (default: 0.1).
#                   Set to 0 to promote canary and route 100% to new version.
#
# Prerequisites:
#   - AWS CLI v2 installed and configured with appropriate permissions.
#   - The Lambda function must already have PROD, CANARY, and LIVE aliases.
# ---------------------------------------------------------------------------

set -euo pipefail

# ---- Input validation ------------------------------------------------------

if [[ $# -lt 1 ]]; then
    echo "Error: Missing required argument."
    echo "Usage: $0 <function-name> [canary-weight]"
    exit 1
fi

FUNCTION_NAME="$1"
CANARY_WEIGHT="${2:-0.1}"

# Validate weight is a number between 0 and 1.
if ! echo "$CANARY_WEIGHT" | grep -qE '^[0-1](\.[0-9]+)?$'; then
    echo "Error: canary-weight must be a number between 0.0 and 1.0."
    exit 1
fi

echo "Function:      $FUNCTION_NAME"
echo "Canary weight: $CANARY_WEIGHT"
echo ""

# ---- Fetch the latest published version ------------------------------------

LATEST_VERSION=$(aws lambda list-versions-by-function \
    --function-name "$FUNCTION_NAME" \
    --query 'Versions[-1].Version' \
    --output text)

if [[ "$LATEST_VERSION" == "\$LATEST" || -z "$LATEST_VERSION" ]]; then
    echo "Error: No published version found. Run 'aws lambda publish-version' first."
    exit 1
fi

echo "Latest published version: $LATEST_VERSION"

# ---- Resolve the current PROD version -------------------------------------

PROD_VERSION=$(aws lambda get-alias \
    --function-name "$FUNCTION_NAME" \
    --name PROD \
    --query 'FunctionVersion' \
    --output text)

echo "Current PROD version:     $PROD_VERSION"

# ---- Update the CANARY alias to the latest version ------------------------

echo ""
echo "Updating CANARY alias to version $LATEST_VERSION..."
aws lambda update-alias \
    --function-name "$FUNCTION_NAME" \
    --name CANARY \
    --function-version "$LATEST_VERSION" \
    --output json > /dev/null

echo "CANARY alias now points to version $LATEST_VERSION."

# ---- Configure traffic splitting on the LIVE alias -------------------------

if [[ "$CANARY_WEIGHT" == "0" || "$CANARY_WEIGHT" == "0.0" ]]; then
    # Promote: route all traffic to the new version (effectively makes it PROD).
    echo ""
    echo "Promoting canary: routing 100% traffic to version $LATEST_VERSION..."

    aws lambda update-alias \
        --function-name "$FUNCTION_NAME" \
        --name LIVE \
        --function-version "$LATEST_VERSION" \
        --routing-config 'AdditionalVersionWeights={}' \
        --output json > /dev/null

    # Update PROD alias to match.
    aws lambda update-alias \
        --function-name "$FUNCTION_NAME" \
        --name PROD \
        --function-version "$LATEST_VERSION" \
        --output json > /dev/null

    echo "PROD alias updated to version $LATEST_VERSION."
    echo "LIVE alias routing: 100% -> version $LATEST_VERSION"
else
    # Split traffic between the current PROD version and the canary.
    PROD_WEIGHT=$(echo "1.0 - $CANARY_WEIGHT" | bc)

    echo ""
    echo "Configuring weighted routing on LIVE alias..."
    echo "  PROD   (version $PROD_VERSION): ${PROD_WEIGHT}"
    echo "  CANARY (version $LATEST_VERSION): ${CANARY_WEIGHT}"

    aws lambda update-alias \
        --function-name "$FUNCTION_NAME" \
        --name LIVE \
        --function-version "$PROD_VERSION" \
        --routing-config "AdditionalVersionWeights={$LATEST_VERSION=$CANARY_WEIGHT}" \
        --output json > /dev/null

    echo "LIVE alias updated with weighted routing."
fi

echo ""
echo "Canary deployment complete."

# ---- Print current state for verification ----------------------------------

echo ""
echo "Current alias state:"
for ALIAS_NAME in PROD CANARY LIVE; do
    ALIAS_INFO=$(aws lambda get-alias \
        --function-name "$FUNCTION_NAME" \
        --name "$ALIAS_NAME" \
        --output json)
    VERSION=$(echo "$ALIAS_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['FunctionVersion'])")
    ROUTING=$(echo "$ALIAS_INFO" | python3 -c "import sys,json; rc=json.load(sys.stdin).get('RoutingConfig',{}); print(rc.get('AdditionalVersionWeights',{}) if rc else '{}')")
    echo "  $ALIAS_NAME -> version $VERSION (routing: $ROUTING)"
done
