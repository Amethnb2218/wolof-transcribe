#!/bin/bash
# Force deploy using FARGATE on-demand (not SPOT) to avoid capacity issues
# Also checks service events to understand why tasks fail to start
set -e

REGION=us-east-1
CLUSTER=wolof-asr-cluster
SERVICE=wolof-asr-service

echo "=== FORCE DEPLOY (ON-DEMAND) ==="

echo ""
echo "[1] Service events (why is new task not starting?)..."
aws ecs describe-services --cluster $CLUSTER --services $SERVICE --region $REGION \
  --query "services[0].events[:5].message" --output text

echo ""
echo "[2] Delete old service and recreate with FARGATE on-demand..."
aws ecs update-service --cluster $CLUSTER --service $SERVICE --desired-count 0 --region $REGION > /dev/null
echo "  Scaling to 0..."
sleep 15

aws ecs delete-service --cluster $CLUSTER --service $SERVICE --region $REGION > /dev/null 2>&1 || true
echo "  Old service deleted"
sleep 5

echo ""
echo "[3] Creating new service with FARGATE (not SPOT)..."
aws ecs create-service \
  --cluster $CLUSTER \
  --service-name $SERVICE \
  --task-definition wolof-asr-task \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-0becd23a4e409e811,subnet-05dfc0447fe541735],securityGroups=[sg-0af01817de2fd00ac],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=arn:aws:elasticloadbalancing:us-east-1:335596040822:targetgroup/wolof-asr-tg/$(aws elbv2 describe-target-groups --names wolof-asr-tg --region $REGION --query 'TargetGroups[0].TargetGroupArn' --output text | grep -oP '[^/]+$'),containerName=wolof-asr,containerPort=8080" \
  --region $REGION > /dev/null 2>&1

# Simpler approach if the above fails
if [ $? -ne 0 ]; then
  echo "  Retrying with simplified command..."
  TG_ARN=$(aws elbv2 describe-target-groups --names wolof-asr-tg --region $REGION --query 'TargetGroups[0].TargetGroupArn' --output text)
  aws ecs create-service \
    --cluster $CLUSTER \
    --service-name $SERVICE \
    --task-definition wolof-asr-task \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[subnet-0becd23a4e409e811,subnet-05dfc0447fe541735],securityGroups=[sg-0af01817de2fd00ac],assignPublicIp=ENABLED}" \
    --load-balancers "targetGroupArn=$TG_ARN,containerName=wolof-asr,containerPort=8080" \
    --region $REGION > /dev/null
fi
echo "  Service created with FARGATE on-demand + assignPublicIp=ENABLED"

echo ""
echo "[4] Waiting for task to start (~3 min)..."
for i in $(seq 1 24); do
  sleep 10
  TASKS=$(aws ecs list-tasks --cluster $CLUSTER --service-name $SERVICE --region $REGION --query 'taskArns[0]' --output text 2>/dev/null)
  if [ "$TASKS" != "None" ] && [ -n "$TASKS" ]; then
    STATUS=$(aws ecs describe-tasks --cluster $CLUSTER --tasks "$TASKS" --region $REGION --query "tasks[0].lastStatus" --output text)
    REASON=$(aws ecs describe-tasks --cluster $CLUSTER --tasks "$TASKS" --region $REGION --query "tasks[0].stoppedReason" --output text 2>/dev/null)
    echo "  [$((i*10))s] $STATUS (reason: $REASON)"
    if [ "$STATUS" = "RUNNING" ]; then
      echo "  Task is RUNNING!"
      break
    elif [ "$STATUS" = "STOPPED" ]; then
      echo "  TASK CRASHED! Reason: $REASON"
      echo "  Checking logs..."
      sleep 5
      STREAM=$(aws logs describe-log-streams --log-group-name "/ecs/wolof-asr" --order-by LastEventTime --descending --limit 1 --region $REGION --query 'logStreams[0].logStreamName' --output text)
      aws logs get-log-events --log-group-name "/ecs/wolof-asr" --log-stream-name "$STREAM" --limit 30 --region $REGION --query 'events[*].message' --output text
      exit 1
    fi
  else
    echo "  [$((i*10))s] No task yet..."
  fi
done

echo ""
echo "[5] Wait for ALB routing..."
sleep 30

echo ""
echo "[6] Tests..."
echo "  Health:"
curl -s https://transcribe.4ura.tech/health
echo ""

echo "  Traduction:"
curl -s -X POST https://transcribe.4ura.tech/api/translate \
  -H "Content-Type: application/json" \
  -d '{"text":"Jàmm nga am","src_lang":"wol_Latn","tgt_lang":"fra_Latn"}'
echo ""

echo ""
echo "[7] Latest logs..."
sleep 2
STREAM=$(aws logs describe-log-streams --log-group-name "/ecs/wolof-asr" --order-by LastEventTime --descending --limit 1 --region $REGION --query 'logStreams[0].logStreamName' --output text)
aws logs get-log-events --log-group-name "/ecs/wolof-asr" --log-stream-name "$STREAM" --limit 20 --region $REGION --query 'events[*].message' --output text

echo ""
echo "=== DONE ==="
