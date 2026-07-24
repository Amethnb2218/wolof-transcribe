#!/bin/bash
# DEFINITIVE FIX for 403 Forbidden on Lambda Function URL
# Root cause: resource-based policy not granting lambda:InvokeFunctionUrl
#
# A Lambda Function URL with AuthType=NONE returns 403 ONLY when:
#   - The resource-based policy does NOT grant lambda:InvokeFunctionUrl to "*"
#   - OR the policy targets a different qualifier than what the Function URL uses
#
# This script: diagnoses, fixes the policy, and also fixes the S3_BUCKET env var
# issue from fix-api-proxy.sh (which used $S3_BUCKET without defining it).
set -e

REGION=us-east-1
FUNCTION_NAME=wolof-batch-api
S3_BUCKET=wolof-transcriber-audio
MINI_IP="52.91.36.73"

echo "=== DEFINITIVE 403 FIX ==="
echo ""

# [1] DIAGNOSE: Check current resource-based policy
echo "[1/5] Checking current resource-based policy..."
POLICY=$(aws lambda get-policy --function-name $FUNCTION_NAME --region $REGION 2>/dev/null || echo "NONE")
if [ "$POLICY" = "NONE" ]; then
  echo "  NO POLICY EXISTS - this is the cause of 403!"
else
  echo "  Current policy:"
  echo "$POLICY" | python3 -c "import sys,json; p=json.loads(json.loads(sys.stdin.read())['Policy']); print(json.dumps(p,indent=2))" 2>/dev/null || echo "$POLICY"
fi

# [2] DIAGNOSE: Check Function URL config
echo ""
echo "[2/5] Checking Function URL config..."
URL_CONFIG=$(aws lambda get-function-url-config --function-name $FUNCTION_NAME --region $REGION 2>/dev/null || echo "NONE")
if [ "$URL_CONFIG" = "NONE" ]; then
  echo "  NO FUNCTION URL EXISTS - recreating..."
  aws lambda create-function-url-config \
    --function-name $FUNCTION_NAME \
    --auth-type NONE \
    --cors '{"AllowOrigins":["*"],"AllowMethods":["*"],"AllowHeaders":["*"],"ExposeHeaders":["*"],"MaxAge":86400}' \
    --region $REGION
else
  echo "  Function URL exists:"
  echo "$URL_CONFIG" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(f'  URL: {d[\"FunctionUrl\"]}'); print(f'  AuthType: {d[\"AuthType\"]}'); print(f'  CORS: {d.get(\"Cors\",{})}')" 2>/dev/null || echo "$URL_CONFIG"

  # Ensure AuthType is NONE (not AWS_IAM)
  AUTH_TYPE=$(echo "$URL_CONFIG" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['AuthType'])" 2>/dev/null)
  if [ "$AUTH_TYPE" != "NONE" ]; then
    echo "  AUTH TYPE IS $AUTH_TYPE - CHANGING TO NONE..."
    aws lambda update-function-url-config \
      --function-name $FUNCTION_NAME \
      --auth-type NONE \
      --cors '{"AllowOrigins":["*"],"AllowMethods":["*"],"AllowHeaders":["*"],"ExposeHeaders":["*"],"MaxAge":86400}' \
      --region $REGION
  fi
fi

# [3] FIX: Remove old permission (ignore error if not exists) then re-add
echo ""
echo "[3/5] Fixing resource-based policy (remove + re-add)..."
aws lambda remove-permission \
  --function-name $FUNCTION_NAME \
  --statement-id public-access \
  --region $REGION 2>/dev/null || true

aws lambda add-permission \
  --function-name $FUNCTION_NAME \
  --statement-id public-access \
  --action lambda:InvokeFunctionUrl \
  --principal "*" \
  --function-url-auth-type NONE \
  --region $REGION

echo "  Permission added: lambda:InvokeFunctionUrl for Principal *"

# [4] FIX: Ensure S3_BUCKET env var is correctly set
# fix-api-proxy.sh used $S3_BUCKET without defining it, so it may be empty
echo ""
echo "[4/5] Fixing Lambda environment variables..."
echo "  Setting S3_BUCKET=$S3_BUCKET, MINI_SERVER=http://$MINI_IP:8080"

aws lambda update-function-configuration \
  --function-name $FUNCTION_NAME \
  --environment "Variables={S3_BUCKET=$S3_BUCKET,MINI_SERVER=http://$MINI_IP:8080}" \
  --timeout 300 \
  --memory-size 256 \
  --region $REGION > /dev/null

aws lambda wait function-updated --function-name $FUNCTION_NAME --region $REGION
echo "  Done"

# [5] VERIFY: Test the endpoint
echo ""
echo "[5/5] Verifying fix..."
API_URL=$(aws lambda get-function-url-config --function-name $FUNCTION_NAME --region $REGION --query 'FunctionUrl' --output text)
echo "  API URL: $API_URL"
echo ""
echo "  Testing POST /upload..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_URL}upload" \
  -H "Content-Type: application/json" \
  -d '{"filename":"test.webm"}')
HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)
echo "  HTTP $HTTP_CODE"
echo "  Body: $BODY"

if [ "$HTTP_CODE" = "200" ]; then
  echo ""
  echo "============================================"
  echo "  SUCCESS - 403 is fixed!"
  echo "============================================"
else
  echo ""
  echo "  Still failing. Checking policy one more time..."
  aws lambda get-policy --function-name $FUNCTION_NAME --region $REGION
  echo ""
  echo "  If still 403, check:"
  echo "  1. Is there an AWS WAF WebACL attached? (aws wafv2 list-web-acls)"
  echo "  2. Is there an SCP in AWS Organizations blocking it?"
  echo "  3. Run: aws lambda get-function --function-name $FUNCTION_NAME to check state"
fi

echo ""
echo "=== DONE ==="
echo ""
echo "  Frontend URL: https://wolof-transcribe.onrender.com"
echo "  Lambda URL:   ${API_URL}"
echo "  Endpoints:    POST /upload, POST /transcribe-s3, GET /status/{id}, GET /result/{id}"
