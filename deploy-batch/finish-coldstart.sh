#!/bin/bash
# Use EventBridge ping instead of Provisioned Concurrency (account limit too low)
set -e

REGION=us-east-1
ACCOUNT=335596040822

echo "=== WARMUP (EventBridge ping every 5 min) ==="

echo "[1] Create warmup rule for trigger Lambda..."
aws events put-rule \
  --name wolof-trigger-warmup \
  --schedule-expression "rate(5 minutes)" \
  --state ENABLED \
  --region $REGION > /dev/null

aws lambda add-permission \
  --function-name wolof-batch-trigger \
  --statement-id eventbridge-warmup \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "arn:aws:events:$REGION:$ACCOUNT:rule/wolof-trigger-warmup" \
  --region $REGION 2>/dev/null || true

aws events put-targets \
  --rule wolof-trigger-warmup \
  --targets "Id=warmup,Arn=arn:aws:lambda:$REGION:$ACCOUNT:function:wolof-batch-trigger,Input=\"{\\\"source\\\":\\\"aws.events\\\"}\"" \
  --region $REGION > /dev/null

echo "  Done (ping every 5 min, no cold start)"

echo ""
echo "[2] Create warmup rule for API Lambda..."
aws events put-rule \
  --name wolof-api-warmup \
  --schedule-expression "rate(5 minutes)" \
  --state ENABLED \
  --region $REGION > /dev/null

aws lambda add-permission \
  --function-name wolof-batch-api \
  --statement-id eventbridge-warmup \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "arn:aws:events:$REGION:$ACCOUNT:rule/wolof-api-warmup" \
  --region $REGION 2>/dev/null || true

aws events put-targets \
  --rule wolof-api-warmup \
  --targets "Id=warmup,Arn=arn:aws:lambda:$REGION:$ACCOUNT:function:wolof-batch-api,Input=\"{\\\"source\\\":\\\"aws.events\\\"}\"" \
  --region $REGION > /dev/null

echo "  Done (ping every 5 min)"

echo ""
echo "=== DONE ==="
echo "  Both Lambdas stay warm (free, no extra cost)"
echo "  Cold start eliminated"
