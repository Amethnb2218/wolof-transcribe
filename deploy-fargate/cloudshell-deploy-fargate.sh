#!/bin/bash
# ============================================================
# FARGATE SPOT DEPLOYMENT — Wolof ASR
# Always-on, 1 vCPU + 5GB RAM, ~$11/mois (Spot)
# beam_size=5, cpu_threads=4, qualite max
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

echo "=========================================="
echo "  WOLOF ASR — FARGATE SPOT DEPLOYMENT"
echo "  1 vCPU + 5GB RAM + beam_size=5"
echo "=========================================="

# --- Step 1: ECR Repo ---
echo ""
echo "[1/7] ECR repo..."
aws ecr describe-repositories --repository-names $REPO_NAME --region $REGION 2>/dev/null || \
  aws ecr create-repository --repository-name $REPO_NAME --region $REGION
REPO_URI=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME
echo "  Repo: $REPO_URI"

# --- Step 2: Build image via CodeBuild ---
echo ""
echo "[2/7] Building Docker image via CodeBuild..."

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
echo "[3/7] ECS execution role..."

aws iam create-role --role-name $ROLE_NAME --assume-role-policy-document '{
  "Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]
}' 2>/dev/null || echo "  Role exists"

aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy 2>/dev/null || true
echo "  Role ready"

# --- Step 4: CloudWatch Log Group ---
echo ""
echo "[4/7] Log group..."
aws logs create-log-group --log-group-name $LOG_GROUP --region $REGION 2>/dev/null || echo "  Exists"

# --- Step 5: ECS Cluster ---
echo ""
echo "[5/7] ECS Cluster..."
aws ecs create-cluster --cluster-name $CLUSTER_NAME --capacity-providers FARGATE_SPOT FARGATE --default-capacity-provider-strategy '[{"capacityProvider":"FARGATE_SPOT","weight":1}]' --region $REGION 2>/dev/null || echo "  Cluster exists"
echo "  Cluster ready (FARGATE_SPOT default)"

# --- Step 6: Task Definition ---
echo ""
echo "[6/7] Task definition..."

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

# --- Step 7: Service with ALB ---
echo ""
echo "[7/7] Creating service..."

# Get default VPC and subnets
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region $REGION)
SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[*].SubnetId' --output text --region $REGION | tr '\t' ',')
SUBNET_LIST=$(echo $SUBNETS | tr ',' ' ')

# Create security group
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=wolof-asr-fargate-sg" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text --region $REGION 2>/dev/null)
if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  SG_ID=$(aws ec2 create-security-group --group-name wolof-asr-fargate-sg --description "Wolof ASR Fargate" --vpc-id $VPC_ID --query 'GroupId' --output text --region $REGION)
  aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port $PORT --cidr 0.0.0.0/0 --region $REGION
  echo "  SG created: $SG_ID"
else
  echo "  SG exists: $SG_ID"
fi

# Create service (no load balancer — direct IP access for now)
FIRST_SUBNET=$(echo $SUBNET_LIST | awk '{print $1}')
SECOND_SUBNET=$(echo $SUBNET_LIST | awk '{print $2}')

aws ecs create-service \
  --cluster $CLUSTER_NAME \
  --service-name $SERVICE_NAME \
  --task-definition $TASK_FAMILY \
  --desired-count 1 \
  --launch-type FARGATE \
  --capacity-provider-strategy '[{"capacityProvider":"FARGATE_SPOT","weight":1}]' \
  --network-configuration "{\"awsvpcConfiguration\":{\"subnets\":[\"$FIRST_SUBNET\",\"$SECOND_SUBNET\"],\"securityGroups\":[\"$SG_ID\"],\"assignPublicIp\":\"ENABLED\"}}" \
  --region $REGION 2>/dev/null || \
aws ecs update-service \
  --cluster $CLUSTER_NAME \
  --service $SERVICE_NAME \
  --task-definition $TASK_FAMILY \
  --desired-count 1 \
  --region $REGION

echo "  Service deploying..."
echo ""
echo "  Waiting for task to start (~2 min)..."
sleep 30

# Get public IP
TASK_ARN=$(aws ecs list-tasks --cluster $CLUSTER_NAME --service-name $SERVICE_NAME --query 'taskArns[0]' --output text --region $REGION)
echo "  Task: $TASK_ARN"

# Wait for running
for i in $(seq 1 12); do
  TASK_STATUS=$(aws ecs describe-tasks --cluster $CLUSTER_NAME --tasks "$TASK_ARN" --query 'tasks[0].lastStatus' --output text --region $REGION)
  echo "  Status: $TASK_STATUS"
  if [ "$TASK_STATUS" = "RUNNING" ]; then
    break
  fi
  sleep 15
done

# Get ENI and public IP
ENI_ID=$(aws ecs describe-tasks --cluster $CLUSTER_NAME --tasks "$TASK_ARN" --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text --region $REGION)
PUBLIC_IP=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI_ID" --query 'NetworkInterfaces[0].Association.PublicIp' --output text --region $REGION)

echo ""
echo "=========================================="
echo "  FARGATE DEPLOYMENT COMPLETE!"
echo "=========================================="
echo ""
echo "  URL: http://$PUBLIC_IP:$PORT"
echo "  Health: http://$PUBLIC_IP:$PORT/health"
echo ""
echo "  Config:"
echo "    CPU: 1 vCPU"
echo "    RAM: 5 GB"
echo "    beam_size: 5"
echo "    cpu_threads: 4"
echo "    Capacity: FARGATE_SPOT (~\$11/mois)"
echo ""
echo "  Remplace l'URL Lambda dans ton frontend par:"
echo "  http://$PUBLIC_IP:$PORT"
echo "=========================================="
