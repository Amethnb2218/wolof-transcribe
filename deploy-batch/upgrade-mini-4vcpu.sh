#!/bin/bash
# Upgrade mini-server to 4 vCPU / 8 GB (2x faster transcription)
set -e

REGION=us-east-1
ACCOUNT=335596040822
CLUSTER=wolof-asr-cluster
SERVICE=wolof-mini-service

echo "=== UPGRADE MINI-SERVER (4 vCPU / 8 GB) ==="

echo "[1/3] New task definition..."
aws ecs register-task-definition \
  --cli-input-json "{
    \"family\": \"wolof-mini-task\",
    \"networkMode\": \"awsvpc\",
    \"requiresCompatibilities\": [\"FARGATE\"],
    \"cpu\": \"4096\",
    \"memory\": \"8192\",
    \"executionRoleArn\": \"arn:aws:iam::$ACCOUNT:role/ecsTaskExecutionRole\",
    \"containerDefinitions\": [{
      \"name\": \"wolof-asr\",
      \"image\": \"$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/wolof-asr-fargate:latest\",
      \"portMappings\": [{\"containerPort\": 8080, \"protocol\": \"tcp\"}],
      \"essential\": true,
      \"command\": [\"gunicorn\", \"--bind\", \"0.0.0.0:8080\", \"--timeout\", \"600\", \"--workers\", \"1\", \"app:app\"],
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
echo "  Done (4 vCPU / 8 GB, gunicorn timeout=600s)"

echo ""
echo "[2/3] Force new deployment..."
aws ecs update-service \
  --cluster $CLUSTER \
  --service $SERVICE \
  --task-definition wolof-mini-task \
  --force-new-deployment \
  --region $REGION > /dev/null
echo "  Redeploying (~2 min)..."

echo ""
echo "[3/3] Wait for healthy..."
sleep 120
TASK_ARN=$(aws ecs list-tasks --cluster $CLUSTER --service-name $SERVICE --region $REGION --query 'taskArns[0]' --output text)
STATUS=$(aws ecs describe-tasks --cluster $CLUSTER --tasks "$TASK_ARN" --region $REGION --query 'tasks[0].lastStatus' --output text)
echo "  Task: $STATUS"

if [ "$STATUS" == "RUNNING" ]; then
  ENI=$(aws ecs describe-tasks --cluster $CLUSTER --tasks "$TASK_ARN" --region $REGION --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text)
  IP=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI" --region $REGION --query 'NetworkInterfaces[0].Association.PublicIp' --output text)
  echo "  IP: $IP"

  # Update Lambda trigger with new IP
  echo ""
  echo "  Updating Lambda trigger with new IP..."
  CURRENT_ENV=$(aws lambda get-function-configuration --function-name wolof-batch-trigger --region $REGION --query 'Environment.Variables' --output json)
  NEW_ENV=$(echo "$CURRENT_ENV" | python3 -c "import sys,json; d=json.load(sys.stdin); d['MINI_SERVER']='http://$IP:8080'; print(json.dumps(d))")
  aws lambda update-function-configuration \
    --function-name wolof-batch-trigger \
    --environment "Variables=$NEW_ENV" \
    --region $REGION > /dev/null
  echo "  Lambda updated: MINI_SERVER=http://$IP:8080"

  # Test health
  sleep 60
  echo ""
  echo "  Testing health..."
  HEALTH=$(curl -s "http://$IP:8080/health" 2>/dev/null || echo "loading...")
  echo "  $HEALTH"
fi

echo ""
echo "=== DONE ==="
echo "  4 vCPU / 8 GB = ~90s for 1 min audio (beam_size=5, full quality)"
echo "  Cost: ~$75/month"
