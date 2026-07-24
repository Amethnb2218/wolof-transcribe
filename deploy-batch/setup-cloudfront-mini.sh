#!/bin/bash
# Put CloudFront in front of mini-server for HTTPS
set -e

REGION=us-east-1
ORIGIN_IP="44.198.161.205"
ORIGIN_PORT="8080"

echo "=== CLOUDFRONT HTTPS SETUP ==="

# Create CloudFront distribution
echo ""
echo "[1/2] Creating CloudFront distribution..."

DIST_ID=$(aws cloudfront create-distribution \
  --distribution-config "{
    \"CallerReference\": \"wolof-mini-$(date +%s)\",
    \"Comment\": \"Wolof mini-server HTTPS\",
    \"Enabled\": true,
    \"DefaultCacheBehavior\": {
      \"TargetOriginId\": \"wolof-mini\",
      \"ViewerProtocolPolicy\": \"redirect-to-https\",
      \"AllowedMethods\": {\"Quantity\": 7, \"Items\": [\"GET\",\"HEAD\",\"OPTIONS\",\"PUT\",\"POST\",\"PATCH\",\"DELETE\"], \"CachedMethods\": {\"Quantity\": 2, \"Items\": [\"GET\",\"HEAD\"]}},
      \"CachePolicyId\": \"4135ea2d-6df8-44a3-9df3-4b5a84be39ad\",
      \"OriginRequestPolicyId\": \"216adef6-5c7f-47e4-b989-5492eafa07d3\",
      \"Compress\": true,
      \"ForwardedValues\": {\"QueryString\": true, \"Cookies\": {\"Forward\": \"none\"}, \"Headers\": {\"Quantity\": 3, \"Items\": [\"Content-Type\",\"Accept\",\"Origin\"]}},
      \"MinTTL\": 0,
      \"DefaultTTL\": 0,
      \"MaxTTL\": 0
    },
    \"Origins\": {
      \"Quantity\": 1,
      \"Items\": [{
        \"Id\": \"wolof-mini\",
        \"DomainName\": \"$ORIGIN_IP\",
        \"CustomOriginConfig\": {
          \"HTTPPort\": $ORIGIN_PORT,
          \"HTTPSPort\": 443,
          \"OriginProtocolPolicy\": \"http-only\",
          \"OriginSslProtocols\": {\"Quantity\": 1, \"Items\": [\"TLSv1.2\"]}
        }
      }]
    },
    \"PriceClass\": \"PriceClass_100\"
  }" \
  --region $REGION \
  --query 'Distribution.[Id,DomainName]' --output text)

DIST_ID_ONLY=$(echo "$DIST_ID" | awk '{print $1}')
DOMAIN=$(echo "$DIST_ID" | awk '{print $2}')

echo "  Distribution ID: $DIST_ID_ONLY"
echo "  Domain: $DOMAIN"
echo ""
echo "============================================"
echo "=== DONE ==="
echo "============================================"
echo ""
echo "  HTTPS URL: https://$DOMAIN"
echo ""
echo "  Set VITE_MINI_SERVER_URL on Render to:"
echo "  https://$DOMAIN"
echo ""
echo "  Note: CloudFront takes 5-10 min to deploy globally."
echo "  Test: curl https://$DOMAIN/health"
