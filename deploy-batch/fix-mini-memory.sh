#!/bin/bash
# Fix: increase mini-server memory (OOM with 3 GB)
set -e

REGION=us-east-1
ACCOUNT=335596040822
CLUSTER=wolof-asr-cluster
SERVICE=wolof-mini-service

echo "=== FIX MINI-SERVER MEMORY (2 vCPU / 5 GB) ==="

echo ""
echo "[1/3] New task definition..."
aws ecs register-task-definition \
  --cli-input-json "{
    \"family\": \"wolof-mini-task\",
    \"networkMode\": \"awsvpc\",
    \"requiresCompatibilities\": [\"FARGATE\"],
    \"cpu\": \"2048\",
    \"memory\": \"5120\",
    \"executionRoleArn\": \"arn:aws:iam::$ACCOUNT:role/ecsTaskExecutionRole\",
    \"containerDefinitions\": [{
      \"name\": \"wolof-asr\",
      \"image\": \"$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/wolof-asr-fargate:latest\",
      \"portMappings\": [{\"containerPort\": 8080, \"protocol\": \"tcp\"}],
      \"essential\": true,
      \"command\": [\"gunicorn\", \"--bind\", \"0.0.0.0:8080\", \"--timeout\", \"300\", \"--workers\", \"1\", \"app:app\"],
      \"logConfiguration\": {
        \"logDriver\": \"awslogs\",
        \"options\": {
          \"awslogs-group\": \"/aws/ecs/wolof-mini\",
          \"awslogs-region\": \"$REGION\",
          \"awslogs-stream-prefix\": \"mini\"
        }
      }
    }]
  }" \
  --region $REGION > /dev/null
echo "  Done (2 vCPU / 5 GB)"

echo ""
echo "[2/3] Force new deployment..."
aws ecs update-service --cluster $CLUSTER --service $SERVICE \
  --task-definition wolof-mini-task --force-new-deployment \
  --region $REGION > /dev/null
echo "  Redeploying..."

echo ""
echo "[3/3] Waiting for healthy task (~3 min)..."
sleep 60
for i in $(seq 1 12); do
  HEALTH=$(curl -s http://44.198.161.205:8080/health 2>/dev/null || echo "waiting...")
  echo "  [$((i*10+60))s] $HEALTH"
  if echo "$HEALTH" | grep -q "model_loaded"; then
    echo ""
    echo "=== MINI-SERVER OK ==="
    echo "  Cost: ~$42/month (2 vCPU / 5 GB)"
    # Get new IP (may change)
    bash deploy-batch/get-mini-ip.sh
    exit 0
  fi
  sleep 10
done

echo ""
echo "  Still starting... check IP:"
bash deploy-batch/get-mini-ip.sh
