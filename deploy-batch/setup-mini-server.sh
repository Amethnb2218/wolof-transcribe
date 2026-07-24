#!/bin/bash
# Mini-serveur Fargate (1 vCPU / 2 GB) pour transcription instantanée des audios courts
# Coût: ~$30/mois | Réponse: ~5 sec pour audio < 10 min
set -e

REGION=us-east-1
ACCOUNT=335596040822
CLUSTER=wolof-asr-cluster
SERVICE=wolof-mini-service

echo "=== MINI-SERVER SETUP (1 vCPU / 2 GB) ==="

# [1] Create cluster if needed
echo ""
echo "[1/5] Cluster ECS..."
aws ecs create-cluster --cluster-name $CLUSTER --region $REGION > /dev/null 2>&1 || true
echo "  $CLUSTER OK"

# [2] Register task definition (mini)
echo ""
echo "[2/5] Task definition (1 vCPU / 2 GB)..."
aws ecs register-task-definition \
  --cli-input-json "{
    \"family\": \"wolof-mini-task\",
    \"networkMode\": \"awsvpc\",
    \"requiresCompatibilities\": [\"FARGATE\"],
    \"cpu\": \"1024\",
    \"memory\": \"3072\",
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
echo "  wolof-mini-task (1 vCPU / 3 GB)"

# [3] Log group
echo ""
echo "[3/5] Log group..."
aws logs create-log-group --log-group-name /aws/ecs/wolof-mini --region $REGION 2>/dev/null || true
echo "  /aws/ecs/wolof-mini"

# [4] Get networking
echo ""
echo "[4/5] Networking..."
VPC=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --region $REGION --query 'Vpcs[0].VpcId' --output text)
SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" --region $REGION --query 'Subnets[*].SubnetId' --output text | tr '\t' ',')
SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" "Name=group-name,Values=default" --region $REGION --query 'SecurityGroups[0].GroupId' --output text)

# Open port 8080 in security group
aws ec2 authorize-security-group-ingress --group-id $SG --protocol tcp --port 8080 --cidr 0.0.0.0/0 --region $REGION 2>/dev/null || true
echo "  VPC: $VPC, SG: $SG"

# [5] Create service
echo ""
echo "[5/5] Create service..."
aws ecs delete-service --cluster $CLUSTER --service $SERVICE --force --region $REGION > /dev/null 2>&1 || true
sleep 10

aws ecs create-service \
  --cluster $CLUSTER \
  --service-name $SERVICE \
  --task-definition wolof-mini-task \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[${SUBNETS}],securityGroups=[$SG],assignPublicIp=ENABLED}" \
  --region $REGION > /dev/null
echo "  Service created!"

# Wait for task to start
echo ""
echo "  Waiting for task to start (~2 min)..."
for i in $(seq 1 12); do
  TASK_ARN=$(aws ecs list-tasks --cluster $CLUSTER --service-name $SERVICE --region $REGION --query 'taskArns[0]' --output text 2>/dev/null)
  if [ "$TASK_ARN" != "None" ] && [ -n "$TASK_ARN" ]; then
    STATUS=$(aws ecs describe-tasks --cluster $CLUSTER --tasks "$TASK_ARN" --region $REGION --query 'tasks[0].lastStatus' --output text)
    echo "    [${i}0s] $STATUS"
    if [ "$STATUS" == "RUNNING" ]; then
      # Get public IP
      ENI=$(aws ecs describe-tasks --cluster $CLUSTER --tasks "$TASK_ARN" --region $REGION --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text)
      PUBLIC_IP=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI" --region $REGION --query 'NetworkInterfaces[0].Association.PublicIp' --output text)
      echo ""
      echo "  PUBLIC IP: $PUBLIC_IP"
      echo "  Health: http://$PUBLIC_IP:8080/health"
      break
    fi
  else
    echo "    [${i}0s] waiting..."
  fi
  sleep 10
done

echo ""
echo "============================================"
echo "=== MINI-SERVER READY ==="
echo "============================================"
echo ""
echo "  URL: http://$PUBLIC_IP:8080"
echo "  Cost: ~\$33/month (1 vCPU / 3 GB Fargate)"
echo "  Response: ~5 sec for short audio"
echo ""
echo "  Update frontend VITE_MINI_SERVER_URL to: http://$PUBLIC_IP:8080"
echo ""
echo "  Routing:"
echo "    Audio < 10 min -> Mini-server (instantane)"
echo "    Audio > 10 min -> Kaggle GPU (6h+ support)"
