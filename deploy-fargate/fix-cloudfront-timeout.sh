#!/bin/bash
# Fix CloudFront origin timeout: 30s -> 120s

DIST_ID="EYEAUA7F52S9D"

echo "Getting current config..."
aws cloudfront get-distribution-config --id $DIST_ID --output json > /tmp/cf.json
ETAG=$(aws cloudfront get-distribution-config --id $DIST_ID --query "ETag" --output text)

echo "Updating timeout to 120s..."
python3 -c "
import json
with open('/tmp/cf.json') as f:
    data = json.load(f)
config = data['DistributionConfig']
for origin in config['Origins']['Items']:
    origin['CustomOriginConfig']['OriginReadTimeout'] = 120
with open('/tmp/cf-update.json', 'w') as f:
    json.dump(config, f, indent=2)
"

aws cloudfront update-distribution --id $DIST_ID --if-match $ETAG --distribution-config file:///tmp/cf-update.json --query "Distribution.Status" --output text

echo ""
echo "Done! Timeout set to 120s. Wait ~2 min for propagation."
