#!/bin/bash
echo "=== RECREATE LAMBDA FUNCTION URL ==="
REGION=us-east-1
FUNC=wolof-asr-api-v2

echo "[1] Delete old URL..."
aws lambda delete-function-url-config --function-name $FUNC --region $REGION 2>/dev/null

echo "[2] Remove old permissions..."
aws lambda remove-permission --function-name $FUNC --statement-id FunctionURLAllowPublicAccess --region $REGION 2>/dev/null
aws lambda remove-permission --function-name $FUNC --statement-id public-url --region $REGION 2>/dev/null
aws lambda remove-permission --function-name $FUNC --statement-id public-url-access --region $REGION 2>/dev/null

echo "[3] Wait 5s..."
sleep 5

echo "[4] Add public permission FIRST..."
aws lambda add-permission \
  --function-name $FUNC \
  --statement-id FunctionURLAllowPublicAccess \
  --action lambda:InvokeFunctionUrl \
  --principal "*" \
  --function-url-auth-type NONE \
  --region $REGION

echo "[5] Create new URL..."
aws lambda create-function-url-config \
  --function-name $FUNC \
  --auth-type NONE \
  --cors '{"AllowOrigins":["*"],"AllowMethods":["GET","POST"],"AllowHeaders":["*"]}' \
  --region $REGION

echo ""
echo "[6] Wait 10s for propagation..."
sleep 10

echo "[7] Test..."
NEW_URL=$(aws lambda get-function-url-config --function-name $FUNC --region $REGION --query 'FunctionUrl' --output text)
echo "New URL: $NEW_URL"
curl -s "${NEW_URL}health"
echo ""
echo ""
echo "If URL changed, update frontend VITE_API_URL to: $NEW_URL"
