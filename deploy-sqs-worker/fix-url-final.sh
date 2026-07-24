#!/bin/bash
# FIX DEFINITIF: Depuis octobre 2025, AWS exige 2 permissions pour les Lambda Function URLs
REGION=us-east-1
FUNC=wolof-asr-api-v2

echo "=== FIX LAMBDA URL (2 permissions requises depuis oct 2025) ==="

echo "[1] Ajout permission lambda:InvokeFunction..."
aws lambda add-permission \
  --function-name $FUNC \
  --statement-id FunctionURLInvokeAccess \
  --action lambda:InvokeFunction \
  --principal "*" \
  --region $REGION 2>/dev/null || echo "  (deja existe ou erreur)"

echo "[2] Verification policy complete..."
aws lambda get-policy --function-name $FUNC --region $REGION --query 'Policy' --output text | python3 -m json.tool

echo ""
echo "[3] Test..."
sleep 3
URL=$(aws lambda get-function-url-config --function-name $FUNC --region $REGION --query 'FunctionUrl' --output text)
echo "URL: $URL"
RESULT=$(curl -s "${URL}health")
echo "Response: $RESULT"
echo ""
if echo "$RESULT" | grep -q "ok"; then
  echo "SUCCESS! L'API fonctionne."
  echo ""
  echo "Mets cette URL dans le frontend: $URL"
else
  echo "Toujours bloque. Verifions si c'est un SCP..."
  curl -s -v "${URL}health" 2>&1 | grep -i "x-amzn"
fi
