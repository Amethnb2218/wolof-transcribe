#!/bin/bash
# Setup ALB + ECS Service ONLY (image already built)
set -e

ACCOUNT=335596040822
REGION=us-east-1
CLUSTER_NAME=wolof-asr-cluster
SERVICE_NAME=wolof-asr-service
TASK_FAMILY=wolof-asr-task
REPO_URI=335596040822.dkr.ecr.us-east-1.amazonaws.com/wolof-asr-fargate
ROLE_NAME=wolof-asr-fargate-execution-role
LOG_GROUP=/ecs/wolof-asr
CONTAINER_NAME=wolof-asr
PORT=8080
ALB_NAME=wolof-asr-alb
TG_NAME=wolof-asr-tg

echo "=== ALB + ECS Setup ==="

# Network
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region $REGION)
SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[*].SubnetId' --output text --region $REGION | tr '\t' ' ')
FIRST_SUBNET=$(echo $SUBNETS | awk '{print $1}')
SECOND_SUBNET=$(echo $SUBNETS | awk '{print $2}')
echo "VPC: $VPC_ID"
echo "Subnets: $FIRST_SUBNET $SECOND_SUBNET"

# SGs
ALB_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=wolof-asr-alb-sg" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text --region $REGION 2>/dev/null)
TASK_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=wolof-asr-task-sg" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text --region $REGION 2>/dev/null)
echo "ALB SG: $ALB_SG_ID"
echo "Task SG: $TASK_SG_ID"

# Create ALB
echo ""
echo "[1] Creating ALB..."
ALB_ARN=$(aws elbv2 describe-load-balancers --names $ALB_NAME --query 'LoadBalancers[0].LoadBalancerArn' --output text --region $REGION 2>/dev/null || echo "None")
if [ "$ALB_ARN" = "None" ] || [ -z "$ALB_ARN" ]; then
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name $ALB_NAME \
    --subnets $FIRST_SUBNET $SECOND_SUBNET \
    --security-groups $ALB_SG_ID \
    --scheme internet-facing \
    --type application \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text --region $REGION)
  echo "  Created: $ALB_ARN"
else
  echo "  Exists: $ALB_ARN"
fi

ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --query 'LoadBalancers[0].DNSName' --output text --region $REGION)
echo "  DNS: $ALB_DNS"

# Create Target Group
echo ""
echo "[2] Target Group..."
TG_ARN=$(aws elbv2 describe-target-groups --names $TG_NAME --query 'TargetGroups[0].TargetGroupArn' --output text --region $REGION 2>/dev/null || echo "None")
if [ "$TG_ARN" = "None" ] || [ -z "$TG_ARN" ]; then
  TG_ARN=$(aws elbv2 create-target-group \
    --name $TG_NAME \
    --protocol HTTP \
    --port $PORT \
    --vpc-id $VPC_ID \
    --target-type ip \
    --health-check-path "/health" \
    --health-check-interval-seconds 30 \
    --health-check-timeout-seconds 10 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --query 'TargetGroups[0].TargetGroupArn' --output text --region $REGION)
  echo "  Created"
else
  echo "  Exists"
fi

# Listener
echo ""
echo "[3] Listener..."
LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN --query 'Listeners[0].ListenerArn' --output text --region $REGION 2>/dev/null || echo "None")
if [ "$LISTENER_ARN" = "None" ] || [ -z "$LISTENER_ARN" ]; then
  aws elbv2 create-listener \
    --load-balancer-arn $ALB_ARN \
    --protocol HTTP --port 80 \
    --default-actions Type=forward,TargetGroupArn=$TG_ARN \
    --region $REGION > /dev/null
  echo "  Created"
else
  echo "  Exists"
fi

# Task Definition
echo ""
echo "[4] Task Definition..."
TASK_DEF=$(cat << TASKEOF
{
  "family": "$TASK_FAMILY",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "1024",
  "memory": "5120",
  "executionRoleArn": "arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}",
  "containerDefinitions": [
    {
      "name": "$CONTAINER_NAME",
      "image": "$REPO_URI:latest",
      "portMappings": [{"containerPort": $PORT, "protocol": "tcp"}],
      "environment": [
        {"name": "HF_API_TOKEN", "value": "${HF_API_TOKEN:-}"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "$LOG_GROUP",
          "awslogs-region": "$REGION",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "essential": true
    }
  ]
}
TASKEOF
)
aws ecs register-task-definition --cli-input-json "$TASK_DEF" --region $REGION > /dev/null
echo "  Registered"

# Delete old service and create new one with ALB
echo ""
echo "[5] ECS Service with ALB..."
aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --desired-count 0 --region $REGION > /dev/null 2>&1 || true
aws ecs delete-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --force --region $REGION > /dev/null 2>&1 || true
echo "  Old service removed, waiting 10s..."
sleep 10

aws ecs create-service \
  --cluster $CLUSTER_NAME \
  --service-name $SERVICE_NAME \
  --task-definition $TASK_FAMILY \
  --desired-count 1 \
  --capacity-provider-strategy '[{"capacityProvider":"FARGATE_SPOT","weight":1}]' \
  --network-configuration "{\"awsvpcConfiguration\":{\"subnets\":[\"$FIRST_SUBNET\",\"$SECOND_SUBNET\"],\"securityGroups\":[\"$TASK_SG_ID\"],\"assignPublicIp\":\"ENABLED\"}}" \
  --load-balancers "[{\"targetGroupArn\":\"$TG_ARN\",\"containerName\":\"$CONTAINER_NAME\",\"containerPort\":$PORT}]" \
  --region $REGION > /dev/null

echo "  Service created!"
echo ""
echo "  Waiting for healthy target (~2-3 min)..."
sleep 60

for i in $(seq 1 10); do
  HEALTH=$(aws elbv2 describe-target-health --target-group-arn $TG_ARN --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text --region $REGION 2>/dev/null || echo "unknown")
  echo "  Health: $HEALTH"
  if [ "$HEALTH" = "healthy" ]; then
    break
  fi
  sleep 15
done

echo ""
echo "=========================================="
echo "  DONE!"
echo "=========================================="
echo ""
echo "  ALB URL: http://$ALB_DNS"
echo "  Test: curl http://$ALB_DNS/health"
echo ""
echo "  Pour CloudFront, mets l'origin a:"
echo "  $ALB_DNS (HTTP, port 80)"
echo "=========================================="
