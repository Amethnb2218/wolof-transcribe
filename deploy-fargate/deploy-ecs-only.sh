#!/bin/bash
# Deploy ECS service only (skip CodeBuild - image already in ECR)

CLUSTER="wolof-asr-cluster"
SERVICE="wolof-asr-service"
TASK_FAMILY="wolof-asr-task"
CONTAINER_NAME="wolof-asr"
REPO_URI="335596040822.dkr.ecr.us-east-1.amazonaws.com/wolof-asr-fargate"
PORT=8080
REGION="us-east-1"

echo "[3/7] ECS Cluster..."
aws ecs create-cluster --cluster-name $CLUSTER \
  --capacity-providers FARGATE_SPOT FARGATE \
  --default-capacity-provider-strategy capacityProvider=FARGATE_SPOT,weight=1 2>/dev/null || echo "  Cluster exists"

echo "[4/7] Task Definition..."
aws ecs register-task-definition --family $TASK_FAMILY \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu "1024" --memory "5120" \
  --execution-role-arn arn:aws:iam::335596040822:role/ecsTaskExecutionRole \
  --container-definitions '[{
    "name": "'"$CONTAINER_NAME"'",
    "image": "'"$REPO_URI"':latest",
    "portMappings": [{"containerPort": '"$PORT"', "protocol": "tcp"}],
    "environment": [
      {"name": "HF_API_TOKEN", "value": "'"${HF_API_TOKEN:-}"'"}
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/wolof-asr",
        "awslogs-region": "'"$REGION"'",
        "awslogs-stream-prefix": "ecs",
        "awslogs-create-group": "true"
      }
    }
  }]'

echo "[5/7] Network config..."
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text)
SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[*].SubnetId" --output text | tr '\t' ',')
SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=default" --query "SecurityGroups[0].GroupId" --output text)

echo "  VPC: $VPC_ID"
echo "  Subnets: $SUBNETS"
echo "  SG: $SG"

echo "[6/7] Open port 8080..."
aws ec2 authorize-security-group-ingress --group-id $SG --protocol tcp --port $PORT --cidr 0.0.0.0/0 2>/dev/null || echo "  Rule exists"

echo "[7/7] Create/Update ECS service..."
aws ecs update-service --cluster $CLUSTER --service $SERVICE --task-definition $TASK_FAMILY --force-new-deployment 2>/dev/null && echo "  Service updated" || \
aws ecs create-service --cluster $CLUSTER --service-name $SERVICE \
  --task-definition $TASK_FAMILY \
  --desired-count 1 \
  --capacity-provider-strategy capacityProvider=FARGATE_SPOT,weight=1 \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SG],assignPublicIp=ENABLED}" && echo "  Service created"

echo ""
echo "Done! Task will start in ~2 min."
