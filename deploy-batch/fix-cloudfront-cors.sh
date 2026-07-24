#!/bin/bash
# Fix CORS on CloudFront for mini-server
set -e

REGION=us-east-1
DIST_ID="EO0YNR4AVPFKG"

echo "=== FIX CLOUDFRONT CORS ==="

# Use AWS managed CORS-with-preflight response headers policy
# ID: 60669652-455b-4ae9-85a4-c4c02393f86c (Managed-CORS-With-Preflight)
CORS_POLICY="60669652-455b-4ae9-85a4-c4c02393f86c"

# Get current config
echo "[1/3] Getting current config..."
aws cloudfront get-distribution-config --id $DIST_ID --region $REGION > /tmp/cf-config.json
ETAG=$(cat /tmp/cf-config.json | python3 -c "import sys,json; print(json.load(sys.stdin)['ETag'])")

# Update config to add CORS headers policy + forward Origin header
echo "[2/3] Updating distribution..."
python3 << 'PYEOF'
import json

with open("/tmp/cf-config.json") as f:
    data = json.load(f)

config = data["DistributionConfig"]
behavior = config["DefaultCacheBehavior"]

# Add CORS response headers policy
behavior["ResponseHeadersPolicyId"] = "60669652-455b-4ae9-85a4-c4c02393f86c"

# Use CachingDisabled policy (no caching for API)
behavior["CachePolicyId"] = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"

# Use AllViewerExceptHostHeader origin request policy
behavior["OriginRequestPolicyId"] = "b689b0a8-53d0-40ab-baf2-68738e2966ac"

with open("/tmp/cf-update.json", "w") as f:
    json.dump(config, f)
PYEOF

aws cloudfront update-distribution --id $DIST_ID --if-match "$ETAG" \
  --distribution-config file:///tmp/cf-update.json \
  --region $REGION > /dev/null

echo "[3/3] Done! CloudFront updating (~2 min)..."
echo ""
echo "  CORS headers will be added automatically."
echo "  Test: curl -H 'Origin: https://wolof-transcribe.onrender.com' https://d3d6l9iin3tqdq.cloudfront.net/health"
