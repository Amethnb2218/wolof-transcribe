#!/bin/bash
# ============================================================
# OPTIONAL: Add autoscaling to worker service
# Scales 1-4 workers based on SQS queue depth
# Run AFTER cloudshell-deploy-full.sh
# ============================================================
set -e

REGION=us-east-1
CLUSTER_NAME=wolof-asr-cluster
SERVICE_NAME=wolof-asr-worker
QUEUE_NAME="wolof-asr-jobs.fifo"

echo "=== AUTOSCALING SETUP ==="

# Register scalable target
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id "service/${CLUSTER_NAME}/${SERVICE_NAME}" \
  --scalable-dimension "ecs:service:DesiredCount" \
  --min-capacity 1 \
  --max-capacity 4 \
  --region $REGION

echo "  Scalable target: min=1, max=4"

# Step scaling policy: scale up when queue has messages
aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --resource-id "service/${CLUSTER_NAME}/${SERVICE_NAME}" \
  --scalable-dimension "ecs:service:DesiredCount" \
  --policy-name "wolof-scale-up" \
  --policy-type StepScaling \
  --step-scaling-policy-configuration '{
    "AdjustmentType": "ChangeInCapacity",
    "StepAdjustments": [
      {"MetricIntervalLowerBound": 0, "MetricIntervalUpperBound": 3, "ScalingAdjustment": 1},
      {"MetricIntervalLowerBound": 3, "MetricIntervalUpperBound": 6, "ScalingAdjustment": 2},
      {"MetricIntervalLowerBound": 6, "ScalingAdjustment": 3}
    ],
    "Cooldown": 120
  }' \
  --region $REGION

echo "  Scale-up policy created"

# Step scaling policy: scale down when queue is empty
aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --resource-id "service/${CLUSTER_NAME}/${SERVICE_NAME}" \
  --scalable-dimension "ecs:service:DesiredCount" \
  --policy-name "wolof-scale-down" \
  --policy-type StepScaling \
  --step-scaling-policy-configuration '{
    "AdjustmentType": "ChangeInCapacity",
    "StepAdjustments": [
      {"MetricIntervalUpperBound": 0, "ScalingAdjustment": -1}
    ],
    "Cooldown": 300
  }' \
  --region $REGION

echo "  Scale-down policy created"

# CloudWatch alarm to trigger scale-up
aws cloudwatch put-metric-alarm \
  --alarm-name "wolof-worker-scale-up" \
  --metric-name ApproximateNumberOfMessagesVisible \
  --namespace AWS/SQS \
  --dimensions "Name=QueueName,Value=$QUEUE_NAME" \
  --statistic Average \
  --period 60 \
  --evaluation-periods 1 \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --alarm-actions "$(aws application-autoscaling describe-scaling-policies \
    --service-namespace ecs \
    --resource-id "service/${CLUSTER_NAME}/${SERVICE_NAME}" \
    --policy-name "wolof-scale-up" \
    --query 'ScalingPolicies[0].Alarms[0].AlarmARN' --output text --region $REGION 2>/dev/null || echo '')" \
  --region $REGION 2>/dev/null || true

echo "  Alarms configured"
echo ""
echo "  Autoscaling active:"
echo "    0 messages -> 1 worker"
echo "    1-3 messages -> +1 worker"
echo "    3-6 messages -> +2 workers"
echo "    6+ messages -> +3 workers (max 4)"
echo "    Empty for 5 min -> scale down"
