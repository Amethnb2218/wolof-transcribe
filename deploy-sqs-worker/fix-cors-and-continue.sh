#!/bin/bash
# Fix: create the Function URL that failed due to CORS validation error
# Then continue with steps 6-9
set -e

REGION=us-east-1
ACCOUNT=335596040822
API_LAMBDA_NAME="wolof-asr-api-v2"

echo "=== FIXING API Lambda Function URL ==="

# Delete old URL config if exists (so we can recreate)
aws lambda delete-function-url-config --function-name "$API_LAMBDA_NAME" --region $REGION 2>/dev/null || true

# Create with valid CORS (no OPTIONS — it's handled automatically by Lambda URL)
API_URL=$(aws lambda create-function-url-config \
  --function-name "$API_LAMBDA_NAME" \
  --auth-type NONE \
  --cors '{"AllowOrigins":["*"],"AllowMethods":["GET","POST"],"AllowHeaders":["*"]}' \
  --region $REGION --query 'FunctionUrl' --output text)

echo "  API URL: $API_URL"
echo ""
echo "Now continue with the rest of the deployment:"
echo "  bash deploy-sqs-worker/cloudshell-deploy-full.sh"
echo ""
echo "(The script will skip steps 1-5 since they already exist and continue from step 6)"
