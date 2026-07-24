#!/bin/bash
# ============================================================
# CLEANUP: Remove old Lambda-based architecture
# Run AFTER verifying new SQS architecture works
# ============================================================
set -e

REGION=us-east-1
CLUSTER_NAME=wolof-asr-cluster

echo "=== CLEANUP OLD ARCHITECTURE ==="
echo ""
echo "This will remove:"
echo "  - wolof-asr-service (old HTTP mini-server)"
echo "  - wolof-asr-orchestrator Lambda"
echo "  - wolof-asr-api Lambda (replaced by v2)"
echo ""
read -p "Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# Stop old ECS service
echo ""
echo "[1/3] Stopping old ECS service..."
aws ecs update-service --cluster $CLUSTER_NAME --service wolof-asr-service --desired-count 0 --region $REGION 2>/dev/null || true
aws ecs delete-service --cluster $CLUSTER_NAME --service wolof-asr-service --force --region $REGION 2>/dev/null || true
echo "  Old service removed"

# Remove old Lambda functions
echo ""
echo "[2/3] Removing old Lambda functions..."
aws lambda delete-function --function-name wolof-asr-orchestrator --region $REGION 2>/dev/null || true
aws lambda delete-function --function-name wolof-asr-api --region $REGION 2>/dev/null || true
echo "  Old Lambdas removed"

# Remove S3 trigger (old orchestrator)
echo ""
echo "[3/3] Removing old S3 notification..."
aws s3api put-bucket-notification-configuration \
  --bucket "wolof-asr-audio-335596040822" \
  --notification-configuration '{"LambdaFunctionConfigurations":[]}' \
  --region $REGION 2>/dev/null || true
echo "  S3 trigger removed"

echo ""
echo "=== CLEANUP COMPLETE ==="
echo ""
echo "Old resources removed. New architecture is now the only active one."
echo "The ALB and old ECR images remain (safe to delete manually later)."
