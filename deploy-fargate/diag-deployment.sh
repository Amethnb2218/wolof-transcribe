#!/bin/bash
# Diagnostic: check why new deployment isn't active
REGION=us-east-1
CLUSTER=wolof-asr-cluster
SERVICE=wolof-asr-service

echo "=== DEPLOYMENT DIAGNOSTIC ==="
echo ""

echo "[1] Service deployments..."
aws ecs describe-services --cluster $CLUSTER --services $SERVICE --region $REGION \
  --query "services[0].deployments[*].{status:status,desired:desiredCount,running:runningCount,taskDef:taskDefinition,rollout:rolloutState}" \
  --output table

echo ""
echo "[2] All tasks (running + stopped)..."
RUNNING=$(aws ecs list-tasks --cluster $CLUSTER --service-name $SERVICE --region $REGION --query 'taskArns' --output text)
STOPPED=$(aws ecs list-tasks --cluster $CLUSTER --service-name $SERVICE --desired-status STOPPED --region $REGION --query 'taskArns' --output text)

echo "  Running: $RUNNING"
echo "  Stopped: $STOPPED"

echo ""
echo "[3] Recent stopped tasks (crash?)..."
if [ -n "$STOPPED" ]; then
  aws ecs describe-tasks --cluster $CLUSTER --tasks $STOPPED --region $REGION \
    --query "tasks[*].{status:lastStatus,reason:stoppedReason,taskDef:taskDefinitionArn,startedAt:startedAt,stoppedAt:stoppedAt}" \
    --output table
fi

echo ""
echo "[4] Recent logs (last 20 lines)..."
aws logs get-log-events \
  --log-group-name "/ecs/wolof-asr" \
  --log-stream-name $(aws logs describe-log-streams --log-group-name "/ecs/wolof-asr" --order-by LastEventTime --descending --limit 1 --region $REGION --query 'logStreams[0].logStreamName' --output text) \
  --limit 20 --region $REGION \
  --query 'events[*].message' --output text

echo ""
echo "[5] Current task definition version..."
aws ecs describe-services --cluster $CLUSTER --services $SERVICE --region $REGION \
  --query "services[0].taskDefinition" --output text

echo ""
echo "=== END ==="
