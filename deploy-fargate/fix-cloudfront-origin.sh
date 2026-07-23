#!/bin/bash
# Update CloudFront origin to point to ALB
DIST_ID="EYEAUA7F52S9D"
ALB_DNS="wolof-asr-alb-2025108882.us-east-1.elb.amazonaws.com"

echo "Updating CloudFront origin to ALB..."
ETAG=$(aws cloudfront get-distribution-config --id $DIST_ID --query "ETag" --output text)
aws cloudfront get-distribution-config --id $DIST_ID --output json > /tmp/cf.json

python3 -c "
import json
with open('/tmp/cf.json') as f:
    data = json.load(f)
config = data['DistributionConfig']
for origin in config['Origins']['Items']:
    origin['DomainName'] = '$ALB_DNS'
    origin['CustomOriginConfig']['HTTPPort'] = 80
    origin['CustomOriginConfig']['HTTPSPort'] = 443
    origin['CustomOriginConfig']['OriginProtocolPolicy'] = 'http-only'
    origin['CustomOriginConfig']['OriginReadTimeout'] = 120
with open('/tmp/cf-update.json', 'w') as f:
    json.dump(config, f, indent=2)
"

aws cloudfront update-distribution --id $DIST_ID --if-match $ETAG --distribution-config file:///tmp/cf-update.json --query "Distribution.Status" --output text

echo ""
echo "Done! CloudFront -> ALB ($ALB_DNS)"
echo "Wait ~2 min for propagation, then test:"
echo "curl -s https://d21cxh8meizf3e.cloudfront.net/health"
