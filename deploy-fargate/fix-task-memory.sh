#!/bin/bash
# Fix: task:10 won't start - increase memory to 8 GB and force redeploy
set -e

REGION=us-east-1
CLUSTER=wolof-asr-cluster
SERVICE=wolof-asr-service

echo "=== FIX TASK MEMORY (4 vCPU / 16 GB) ==="

echo "[1] Register new task definition with 16 GB..."
cat > /tmp/task-def.json << 'EOF'
{
  "family": "wolof-asr-task",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "4096",
  "memory": "16384",
  "executionRoleArn": "arn:aws:iam::335596040822:role/ecsTaskExecutionRole",
  "containerDefinitions": [
    {
      "name": "wolof-asr",
      "image": "335596040822.dkr.ecr.us-east-1.amazonaws.com/wolof-asr-fargate:latest",
      "portMappings": [{"containerPort": 8080, "protocol": "tcp"}],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/wolof-asr",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "essential": true
    }
  ]
}
EOF

aws ecs register-task-definition --cli-input-json file:///tmp/task-def.json --region $REGION > /dev/null
echo "  Done (4 vCPU / 16 GB)"

echo ""
echo "[2] Force new deployment..."
aws ecs update-service \
  --cluster $CLUSTER \
  --service $SERVICE \
  --task-definition wolof-asr-task \
  --force-new-deployment \
  --region $REGION > /dev/null
echo "  Service redeploying..."

echo ""
echo "[3] Waiting for new task (~3 min)..."
for i in $(seq 1 18); do
  sleep 10
  TASKS=$(aws ecs list-tasks --cluster $CLUSTER --service-name $SERVICE --region $REGION --query 'taskArns' --output text)
  if [ -n "$TASKS" ]; then
    TASK_ARN=$(echo "$TASKS" | awk '{print $NF}')
    STATUS=$(aws ecs describe-tasks --cluster $CLUSTER --tasks "$TASK_ARN" --region $REGION --query "tasks[0].lastStatus" --output text)
    HEALTH=$(aws ecs describe-tasks --cluster $CLUSTER --tasks "$TASK_ARN" --region $REGION --query "tasks[0].healthStatus" --output text)
    echo "  [$((i*10))s] Status: $STATUS | Health: $HEALTH"
    if [ "$STATUS" = "RUNNING" ] && [ "$HEALTH" = "HEALTHY" ]; then
      break
    fi
  else
    echo "  [$((i*10))s] No tasks yet..."
  fi
done

echo ""
echo "[4] Test health..."
sleep 5
curl -s https://transcribe.4ura.tech/health
echo ""

echo ""
echo "[5] Test traduction..."
RESULT=$(curl -s -X POST https://transcribe.4ura.tech/api/translate \
  -H "Content-Type: application/json" \
  -d '{"text":"Jàmm nga am","src_lang":"wol_Latn","tgt_lang":"fra_Latn"}')
echo "  $RESULT"

echo ""
echo "[6] Logs du nouveau container..."
sleep 2
STREAM=$(aws logs describe-log-streams --log-group-name "/ecs/wolof-asr" --order-by LastEventTime --descending --limit 1 --region $REGION --query 'logStreams[0].logStreamName' --output text)
aws logs get-log-events --log-group-name "/ecs/wolof-asr" --log-stream-name "$STREAM" --limit 15 --region $REGION --query 'events[*].message' --output text

echo ""
echo "=== DONE ==="
