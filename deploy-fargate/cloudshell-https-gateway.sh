#!/bin/bash
set -e
REGION=us-east-1
FARGATE_URL="http://98.87.159.255:8080"

echo "[1/3] Creating API Gateway HTTP API..."
API_ID=$(aws apigatewayv2 create-api \
  --name wolof-asr-gateway \
  --protocol-type HTTP \
  --cors-configuration '{"AllowOrigins":["*"],"AllowMethods":["POST","GET","OPTIONS"],"AllowHeaders":["*"]}' \
  --query 'ApiId' --output text --region $REGION)
echo "  API: $API_ID"

echo "[2/3] Integration + Route..."
INTEG_ID=$(aws apigatewayv2 create-integration \
  --api-id $API_ID \
  --integration-type HTTP_PROXY \
  --integration-method ANY \
  --integration-uri $FARGATE_URL \
  --payload-format-version "1.0" \
  --query 'IntegrationId' --output text --region $REGION)

aws apigatewayv2 create-route \
  --api-id $API_ID \
  --route-key 'POST /' \
  --target "integrations/$INTEG_ID" \
  --region $REGION > /dev/null

aws apigatewayv2 create-route \
  --api-id $API_ID \
  --route-key 'GET /health' \
  --target "integrations/$INTEG_ID" \
  --region $REGION > /dev/null

echo "[3/3] Deploy stage..."
aws apigatewayv2 create-stage \
  --api-id $API_ID \
  --stage-name '$default' \
  --auto-deploy \
  --region $REGION > /dev/null

HTTPS_URL="https://$API_ID.execute-api.$REGION.amazonaws.com"

echo ""
echo "=========================================="
echo "  HTTPS GATEWAY READY!"
echo "  URL: $HTTPS_URL"
echo ""
echo "  Mets cette URL dans Render:"
echo "  VITE_API_URL = $HTTPS_URL"
echo "=========================================="
