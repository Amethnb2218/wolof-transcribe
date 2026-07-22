#!/bin/bash
# Fix CORS on CloudFront distribution for wolof-transcriber

DIST_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?DomainName=='d21cxh8meizf3e.cloudfront.net'].Id | [0]" --output text)
echo "Distribution ID: $DIST_ID"

# Créer une Response Headers Policy avec CORS
POLICY_ID=$(aws cloudfront create-response-headers-policy --response-headers-policy-config '{
  "Name": "wolof-cors-policy",
  "Comment": "CORS for wolof-transcriber frontend",
  "CorsConfig": {
    "AccessControlAllowOrigins": {
      "Quantity": 1,
      "Items": ["*"]
    },
    "AccessControlAllowHeaders": {
      "Quantity": 3,
      "Items": ["Content-Type", "Authorization", "Origin"]
    },
    "AccessControlAllowMethods": {
      "Quantity": 3,
      "Items": ["GET", "POST", "OPTIONS"]
    },
    "AccessControlAllowCredentials": false,
    "AccessControlMaxAgeSec": 86400,
    "OriginOverride": true
  }
}' --query "ResponseHeadersPolicy.Id" --output text)

echo "Policy ID: $POLICY_ID"

# Récupérer la config actuelle
aws cloudfront get-distribution-config --id $DIST_ID --output json > /tmp/cf-current.json
ETAG=$(python3 -c "import json; data=json.load(open('/tmp/cf-current.json')); print(data['ETag'])")

# Extraire la config et ajouter la policy
python3 -c "
import json
with open('/tmp/cf-current.json') as f:
    data = json.load(f)
config = data['DistributionConfig']
config['DefaultCacheBehavior']['ResponseHeadersPolicyId'] = '$POLICY_ID'
with open('/tmp/cf-update.json', 'w') as f:
    json.dump(config, f, indent=2)
"

# Appliquer la mise à jour
aws cloudfront update-distribution --id $DIST_ID --if-match $ETAG --distribution-config file:///tmp/cf-update.json

echo ""
echo "CORS policy ajoutée ! Attends ~2-3 min pour propagation."
echo "Teste avec: curl -I -H 'Origin: https://wolof-transcribe.onrender.com' https://d21cxh8meizf3e.cloudfront.net/"
