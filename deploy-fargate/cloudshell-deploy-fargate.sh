#!/bin/bash
# ============================================================
# FARGATE SPOT + ALB DEPLOYMENT — Wolof ASR
# Always-on, 1 vCPU + 5GB RAM, ~$29/mois (Spot + ALB)
# beam_size=5, cpu_threads=4, qualite max
# ALB = URL stable, health checks, no DNS updates needed
# ============================================================
set -e

ACCOUNT=335596040822
REGION=us-east-1
CLUSTER_NAME=wolof-asr-cluster
SERVICE_NAME=wolof-asr-service
TASK_FAMILY=wolof-asr-task
REPO_NAME=wolof-asr-fargate
ROLE_NAME=wolof-asr-fargate-execution-role
LOG_GROUP=/ecs/wolof-asr
CONTAINER_NAME=wolof-asr
PORT=8080
ALB_NAME=wolof-asr-alb
TG_NAME=wolof-asr-tg

echo "=========================================="
echo "  WOLOF ASR — FARGATE SPOT + ALB"
echo "  1 vCPU + 5GB RAM + beam_size=5"
echo "=========================================="

# --- Step 1: ECR Repo ---
echo ""
echo "[1/8] ECR repo..."
aws ecr describe-repositories --repository-names $REPO_NAME --region $REGION 2>/dev/null || \
  aws ecr create-repository --repository-name $REPO_NAME --region $REGION
REPO_URI=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME
echo "  Repo: $REPO_URI"

# --- Step 2: Build image via CodeBuild ---
echo ""
echo "[2/8] Building Docker image via CodeBuild..."

BUILDSPEC=$(cat << 'BSEOF'
version: 0.2
phases:
  pre_build:
    commands:
      - aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 335596040822.dkr.ecr.us-east-1.amazonaws.com
  build:
    commands:
      - mkdir -p /tmp/fargate && cd /tmp/fargate
      - curl -sL -o app.py https://raw.githubusercontent.com/Amethnb2218/wolof-transcribe/main/deploy-fargate/app.py
      - curl -sL -o Dockerfile https://raw.githubusercontent.com/Amethnb2218/wolof-transcribe/main/deploy-fargate/Dockerfile
      - curl -sL -o patch_config.py https://raw.githubusercontent.com/Amethnb2218/wolof-transcribe/main/deploy-fargate/patch_config.py
      - docker build --platform linux/amd64 -t wolof-asr-fargate .
  post_build:
    commands:
      - docker tag wolof-asr-fargate:latest 335596040822.dkr.ecr.us-east-1.amazonaws.com/wolof-asr-fargate:latest
      - docker push 335596040822.dkr.ecr.us-east-1.amazonaws.com/wolof-asr-fargate:latest
      - echo DONE
BSEOF
)

ENCODED_SPEC=$(echo "$BUILDSPEC" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

aws codebuild create-project \
  --name "wolof-fargate-build" \
  --source "{\"type\":\"NO_SOURCE\",\"buildspec\":$ENCODED_SPEC}" \
  --artifacts '{"type":"NO_ARTIFACTS"}' \
  --environment '{"type":"LINUX_CONTAINER","image":"aws/codebuild/standard:7.0","computeType":"BUILD_GENERAL1_LARGE","privilegedMode":true}' \
  --service-role "arn:aws:iam::${ACCOUNT}:role/wolof-asr-codebuild-role" \
  --region $REGION 2>/dev/null && echo "  Project created" || \
aws codebuild update-project \
  --name "wolof-fargate-build" \
  --source "{\"type\":\"NO_SOURCE\",\"buildspec\":$ENCODED_SPEC}" \
  --environment '{"type":"LINUX_CONTAINER","image":"aws/codebuild/standard:7.0","computeType":"BUILD_GENERAL1_LARGE","privilegedMode":true}' \
  --service-role "arn:aws:iam::${ACCOUNT}:role/wolof-asr-codebuild-role" \
  --region $REGION && echo "  Project updated"

BUILD_ID=$(aws codebuild start-build --project-name "wolof-fargate-build" --region $REGION --query 'build.id' --output text)
echo "  Build: $BUILD_ID"
echo "  Waiting (~10 min for model download)..."

while true; do
  sleep 20
  STATUS=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].buildStatus' --output text)
  PHASE=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].currentPhase' --output text)
  echo "  [$PHASE] $STATUS"
  if [ "$STATUS" = "SUCCEEDED" ]; then
    echo "  Image ready!"
    break
  elif [ "$STATUS" != "IN_PROGRESS" ]; then
    echo "  BUILD FAILED!"
    exit 1
  fi
done

# --- Step 3: ECS Execution Role ---
echo ""
echo "[3/8] ECS execution role..."

aws iam create-role --role-name $ROLE_NAME --assume-role-policy-document '{
  "Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]
}' 2>/dev/null || echo "  Role exists"

aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy 2>/dev/null || true
echo "  Role ready"

# --- Step 4: CloudWatch Log Group ---
echo ""
echo "[4/8] Log group..."
aws logs create-log-group --log-group-name $LOG_GROUP --region $REGION 2>/dev/null || echo "  Exists"

# --- Step 5: ECS Cluster ---
echo ""
echo "[5/8] ECS Cluster..."
aws ecs create-cluster --cluster-name $CLUSTER_NAME --capacity-providers FARGATE_SPOT FARGATE --default-capacity-provider-strategy '[{"capacityProvider":"FARGATE_SPOT","weight":1}]' --region $REGION 2>/dev/null || echo "  Cluster exists"
echo "  Cluster ready (FARGATE_SPOT default)"

# --- Step 6: ALB + Target Group ---
echo ""
echo "[6/8] ALB + Target Group..."

VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region $REGION)
SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[*].SubnetId' --output text --region $REGION | tr '\t' ',')
SUBNET_LIST=$(echo $SUBNETS | tr ',' ' ')
FIRST_SUBNET=$(echo $SUBNET_LIST | awk '{print $1}')
SECOND_SUBNET=$(echo $SUBNET_LIST | awk '{print $2}')

# Security group for ALB (allow 80 and 443 from anywhere)
ALB_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=wolof-asr-alb-sg" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text --region $REGION 2>/dev/null)
if [ "$ALB_SG_ID" = "None" ] || [ -z "$ALB_SG_ID" ]; then
  ALB_SG_ID=$(aws ec2 create-security-group --group-name wolof-asr-alb-sg --description "Wolof ASR ALB" --vpc-id $VPC_ID --query 'GroupId' --output text --region $REGION)
  aws ec2 authorize-security-group-ingress --group-id $ALB_SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $REGION
  echo "  ALB SG created: $ALB_SG_ID"
else
  echo "  ALB SG exists: $ALB_SG_ID"
fi

# Security group for ECS tasks (allow traffic from ALB only)
TASK_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=wolof-asr-task-sg" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text --region $REGION 2>/dev/null)
if [ "$TASK_SG_ID" = "None" ] || [ -z "$TASK_SG_ID" ]; then
  TASK_SG_ID=$(aws ec2 create-security-group --group-name wolof-asr-task-sg --description "Wolof ASR Tasks" --vpc-id $VPC_ID --query 'GroupId' --output text --region $REGION)
  aws ec2 authorize-security-group-ingress --group-id $TASK_SG_ID --protocol tcp --port $PORT --source-group $ALB_SG_ID --region $REGION
  echo "  Task SG created: $TASK_SG_ID"
else
  echo "  Task SG exists: $TASK_SG_ID"
fi

# Create ALB
ALB_ARN=$(aws elbv2 describe-load-balancers --names $ALB_NAME --query 'LoadBalancers[0].LoadBalancerArn' --output text --region $REGION 2>/dev/null)
if [ "$ALB_ARN" = "None" ] || [ -z "$ALB_ARN" ]; then
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name $ALB_NAME \
    --subnets $FIRST_SUBNET $SECOND_SUBNET \
    --security-groups $ALB_SG_ID \
    --scheme internet-facing \
    --type application \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text --region $REGION)
  echo "  ALB created: $ALB_ARN"
else
  echo "  ALB exists: $ALB_ARN"
fi

ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --query 'LoadBalancers[0].DNSName' --output text --region $REGION)
echo "  ALB DNS: $ALB_DNS"

# Create Target Group
TG_ARN=$(aws elbv2 describe-target-groups --names $TG_NAME --query 'TargetGroups[0].TargetGroupArn' --output text --region $REGION 2>/dev/null)
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
  echo "  Target Group created"
else
  echo "  Target Group exists"
fi

# Create Listener (HTTP:80 -> Target Group)
LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN --query 'Listeners[0].ListenerArn' --output text --region $REGION 2>/dev/null)
if [ "$LISTENER_ARN" = "None" ] || [ -z "$LISTENER_ARN" ]; then
  aws elbv2 create-listener \
    --load-balancer-arn $ALB_ARN \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn=$TG_ARN \
    --region $REGION > /dev/null
  echo "  Listener created (HTTP:80)"
else
  echo "  Listener exists"
fi

# --- Step 7: Task Definition ---
echo ""
echo "[7/8] Task definition..."

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
echo "  Task: 1 vCPU + 5GB RAM"

# --- Step 8: ECS Service with ALB ---
echo ""
echo "[8/8] ECS Service (with ALB)..."

# Delete old service without ALB if it exists
aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --desired-count 0 --region $REGION 2>/dev/null || true
aws ecs delete-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --force --region $REGION 2>/dev/null || true
sleep 5

aws ecs create-service \
  --cluster $CLUSTER_NAME \
  --service-name $SERVICE_NAME \
  --task-definition $TASK_FAMILY \
  --desired-count 1 \
  --capacity-provider-strategy '[{"capacityProvider":"FARGATE_SPOT","weight":1}]' \
  --network-configuration "{\"awsvpcConfiguration\":{\"subnets\":[\"$FIRST_SUBNET\",\"$SECOND_SUBNET\"],\"securityGroups\":[\"$TASK_SG_ID\"],\"assignPublicIp\":\"ENABLED\"}}" \
  --load-balancers "[{\"targetGroupArn\":\"$TG_ARN\",\"containerName\":\"$CONTAINER_NAME\",\"containerPort\":$PORT}]" \
  --region $REGION

echo "  Service created with ALB!"
echo ""
echo "  Waiting for task to be healthy (~3 min)..."
sleep 60

for i in $(seq 1 10); do
  HEALTHY=$(aws elbv2 describe-target-health --target-group-arn $TG_ARN --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text --region $REGION 2>/dev/null)
  echo "  Health: $HEALTHY"
  if [ "$HEALTHY" = "healthy" ]; then
    break
  fi
  sleep 15
done

echo ""
echo "=========================================="
echo "  DEPLOYMENT COMPLETE!"
echo "=========================================="
echo ""
echo "  ALB URL: http://$ALB_DNS"
echo "  Health:  http://$ALB_DNS/health"
echo ""
echo "  Pour CloudFront, change l'origin vers:"
echo "  $ALB_DNS (HTTP, port 80)"
echo ""
echo "  Config:"
echo "    CPU: 1 vCPU"
echo "    RAM: 5 GB"
echo "    beam_size: 5"
echo "    cpu_threads: 4"
echo "    Capacity: FARGATE_SPOT"
echo "    Cost: ~\$29/mois (Spot + ALB)"
echo ""
echo "  L'ALB a une URL STABLE — plus besoin de"
echo "  mettre a jour le DNS apres chaque deploy!"
echo "=========================================="
