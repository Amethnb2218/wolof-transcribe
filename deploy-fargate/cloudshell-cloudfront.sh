#!/bin/bash
set -e
REGION=us-east-1
ORIGIN_DOMAIN="transcribe.4ura.tech"

echo "=========================================="
echo "  CLOUDFRONT HTTPS → FARGATE"
echo "  Origin: $ORIGIN_DOMAIN:8080"
echo "  Timeout: 120s | HTTPS gratuit"
echo "=========================================="

echo ""
echo "[1/1] Creation distribution CloudFront..."

cat > /tmp/cf-config.json << EOF
{
  "CallerReference": "wolof-asr-$(date +%s)",
  "Comment": "Wolof ASR HTTPS proxy",
  "Enabled": true,
  "DefaultCacheBehavior": {
    "TargetOriginId": "fargate-wolof",
    "ViewerProtocolPolicy": "allow-all",
    "AllowedMethods": {
      "Quantity": 7,
      "Items": ["GET","HEAD","OPTIONS","PUT","PATCH","POST","DELETE"],
      "CachedMethods": {"Quantity": 2, "Items": ["GET","HEAD"]}
    },
    "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
    "OriginRequestPolicyId": "216adef6-5c7f-47e4-b989-5492eafa07d3",
    "Compress": true
  },
  "Origins": {
    "Quantity": 1,
    "Items": [{
      "Id": "fargate-wolof",
      "DomainName": "$ORIGIN_DOMAIN",
      "CustomOriginConfig": {
        "HTTPPort": 8080,
        "HTTPSPort": 443,
        "OriginProtocolPolicy": "http-only",
        "OriginReadTimeout": 120,
        "OriginKeepaliveTimeout": 60,
        "OriginSslProtocols": {"Quantity": 1, "Items": ["TLSv1.2"]}
      }
    }]
  }
}
EOF

RESULT=$(aws cloudfront create-distribution --distribution-config file:///tmp/cf-config.json --output json)
DOMAIN=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['Distribution']['DomainName'])")
DIST_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['Distribution']['Id'])")

echo ""
echo "=========================================="
echo "  CLOUDFRONT DEPLOYE!"
echo ""
echo "  URL HTTPS: https://$DOMAIN"
echo "  Distribution ID: $DIST_ID"
echo "  Timeout: 120 secondes"
echo ""
echo "  Mets dans Render:"
echo "  VITE_API_URL = https://$DOMAIN"
echo ""
echo "  Note: deploiement ~5 min pour etre actif"
echo "=========================================="
