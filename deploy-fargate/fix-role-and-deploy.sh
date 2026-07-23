#!/bin/bash
# Fix: ECS cannot assume ecsTaskExecutionRole + recreate service
set -e

REGION=us-east-1
CLUSTER=wolof-asr-cluster
SERVICE=wolof-asr-service

echo "=== FIX ROLE + DEPLOY ==="

echo ""
echo "[1] Fix trust policy on ecsTaskExecutionRole..."
aws iam update-assume-role-policy --role-name ecsTaskExecutionRole --policy-document '{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ecs-tasks.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'
echo "  Trust policy fixed"

echo ""
echo "[2] Get target group ARN..."
TG_ARN=$(aws elbv2 describe-target-groups --names wolof-asr-tg --region $REGION --query 'TargetGroups[0].TargetGroupArn' --output text)
echo "  TG: $TG_ARN"

echo ""
echo "[3] Delete old service if exists..."
aws ecs delete-service --cluster $CLUSTER --service $SERVICE --force --region $REGION > /dev/null 2>&1 || true
echo "  Done"
sleep 10

echo ""
echo "[4] Create service (FARGATE on-demand, 4 vCPU / 16 GB, public IP)..."
aws ecs create-service \
  --cluster $CLUSTER \
  --service-name $SERVICE \
  --task-definition wolof-asr-task \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-0becd23a4e409e811,subnet-05dfc0447fe541735],securityGroups=[sg-0af01817de2fd00ac],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=$TG_ARN,containerName=wolof-asr,containerPort=8080" \
  --region $REGION > /dev/null
echo "  Service created!"

echo ""
echo "[5] Waiting for task (~3 min)..."
for i in $(seq 1 24); do
  sleep 10
  TASK=$(aws ecs list-tasks --cluster $CLUSTER --service-name $SERVICE --region $REGION --query 'taskArns[0]' --output text 2>/dev/null)
  if [ "$TASK" != "None" ] && [ -n "$TASK" ]; then
    STATUS=$(aws ecs describe-tasks --cluster $CLUSTER --tasks "$TASK" --region $REGION --query "tasks[0].lastStatus" --output text)
    echo "  [$((i*10))s] $STATUS"
    if [ "$STATUS" = "RUNNING" ]; then
      echo "  Task RUNNING!"
      break
    elif [ "$STATUS" = "STOPPED" ]; then
      REASON=$(aws ecs describe-tasks --cluster $CLUSTER --tasks "$TASK" --region $REGION --query "tasks[0].stoppedReason" --output text)
      echo "  CRASHED: $REASON"
      break
    fi
  else
    echo "  [$((i*10))s] waiting..."
  fi
done

echo ""
echo "[6] Health check (wait 60s for model load)..."
sleep 60
curl -s https://transcribe.4ura.tech/health
echo ""

echo ""
echo "[7] Test traduction..."
curl -s -X POST https://transcribe.4ura.tech/api/translate \
  -H "Content-Type: application/json" \
  -d '{"text":"Jàmm nga am","src_lang":"wol_Latn","tgt_lang":"fra_Latn"}'
echo ""

echo ""
echo "[8] Logs..."
STREAM=$(aws logs describe-log-streams --log-group-name "/ecs/wolof-asr" --order-by LastEventTime --descending --limit 1 --region $REGION --query 'logStreams[0].logStreamName' --output text)
aws logs get-log-events --log-group-name "/ecs/wolof-asr" --log-stream-name "$STREAM" --limit 15 --region $REGION --query 'events[*].message' --output text

echo ""
echo "=== DONE ==="
