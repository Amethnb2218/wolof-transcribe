#!/bin/bash
# Finish provisioned concurrency setup (step 2/3 that failed earlier)
set -e

REGION=us-east-1
ACCOUNT=335596040822
S3_BUCKET="wolof-transcriber-audio"

echo "=== FINISH PROVISIONED CONCURRENCY ==="

echo "[1] Wait for Lambda to be ready..."
aws lambda wait function-updated --function-name wolof-batch-trigger --region $REGION 2>/dev/null || true

echo "[2] Provisioned Concurrency on trigger Lambda..."
aws lambda put-provisioned-concurrency-config \
  --function-name wolof-batch-trigger \
  --qualifier 1 \
  --provisioned-concurrent-executions 1 \
  --region $REGION > /dev/null
echo "  Done (version 1, 1 instance warm)"

echo "[3] Create alias 'live'..."
aws lambda create-alias \
  --function-name wolof-batch-trigger \
  --name live \
  --function-version 1 \
  --region $REGION 2>/dev/null || \
aws lambda update-alias \
  --function-name wolof-batch-trigger \
  --name live \
  --function-version 1 \
  --region $REGION > /dev/null
echo "  Alias 'live' -> version 1"

echo "[4] Update S3 trigger to use alias..."
ALIAS_ARN="arn:aws:lambda:$REGION:$ACCOUNT:function:wolof-batch-trigger:live"

aws lambda add-permission \
  --function-name wolof-batch-trigger \
  --qualifier live \
  --statement-id s3-trigger-alias \
  --action lambda:InvokeFunction \
  --principal s3.amazonaws.com \
  --source-arn "arn:aws:s3:::$S3_BUCKET" \
  --region $REGION 2>/dev/null || true

aws s3api put-bucket-notification-configuration \
  --bucket $S3_BUCKET \
  --notification-configuration "{
    \"LambdaFunctionConfigurations\": [{
      \"LambdaFunctionArn\": \"$ALIAS_ARN\",
      \"Events\": [\"s3:ObjectCreated:*\"],
      \"Filter\": {\"Key\": {\"FilterRules\": [{\"Name\": \"prefix\", \"Value\": \"uploads/\"}]}}
    }]
  }" \
  --region $REGION
echo "  S3 trigger -> alias (provisioned concurrency active)"

echo ""
echo "=== DONE ==="
echo "  No more cold starts on trigger Lambda"
echo "  Cost: ~\$6/month"
