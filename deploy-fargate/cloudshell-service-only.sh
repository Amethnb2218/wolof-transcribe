#!/bin/bash
set -e
ACCOUNT=335596040822
REGION=us-east-1
REPO_URI=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/wolof-asr-fargate

echo "[3/7] ECS execution role..."
aws iam create-role --role-name wolof-asr-fargate-execution-role --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' 2>/dev/null || echo "  Role exists"
aws iam attach-role-policy --role-name wolof-asr-fargate-execution-role --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy 2>/dev/null || true

echo "[4/7] Log group..."
aws logs create-log-group --log-group-name /ecs/wolof-asr --region $REGION 2>/dev/null || echo "  Exists"

echo "[5/7] ECS Cluster..."
aws ecs create-cluster --cluster-name wolof-asr-cluster --capacity-providers FARGATE_SPOT FARGATE --default-capacity-provider-strategy '[{"capacityProvider":"FARGATE_SPOT","weight":1}]' --region $REGION > /dev/null 2>&1 || echo "  Cluster exists"

echo "[6/7] Task definition..."
cat > /tmp/task-def.json << EOF
{
  "family": "wolof-asr-task",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "1024",
  "memory": "5120",
  "executionRoleArn": "arn:aws:iam::${ACCOUNT}:role/wolof-asr-fargate-execution-role",
  "containerDefinitions": [
    {
      "name": "wolof-asr",
      "image": "${REPO_URI}:latest",
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
echo "  Task: 1 vCPU + 5GB RAM"

echo "[7/7] Creating service..."
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region $REGION)
SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[0:2].SubnetId' --output text --region $REGION)
SUB1=$(echo $SUBNETS | awk '{print $1}')
SUB2=$(echo $SUBNETS | awk '{print $2}')

SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=wolof-asr-fargate-sg" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text --region $REGION 2>/dev/null)
if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  SG_ID=$(aws ec2 create-security-group --group-name wolof-asr-fargate-sg --description "Wolof ASR Fargate" --vpc-id $VPC_ID --query 'GroupId' --output text --region $REGION)
  aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 8080 --cidr 0.0.0.0/0 --region $REGION
fi
echo "  SG: $SG_ID"

aws ecs create-service \
  --cluster wolof-asr-cluster \
  --service-name wolof-asr-service \
  --task-definition wolof-asr-task \
  --desired-count 1 \
  --capacity-provider-strategy '[{"capacityProvider":"FARGATE_SPOT","weight":1}]' \
  --network-configuration "{\"awsvpcConfiguration\":{\"subnets\":[\"$SUB1\",\"$SUB2\"],\"securityGroups\":[\"$SG_ID\"],\"assignPublicIp\":\"ENABLED\"}}" \
  --region $REGION > /dev/null 2>&1 || \
aws ecs update-service \
  --cluster wolof-asr-cluster \
  --service wolof-asr-service \
  --task-definition wolof-asr-task \
  --desired-count 1 \
  --region $REGION > /dev/null

echo "  Service deploying... waiting 60s..."
sleep 60

TASK_ARN=$(aws ecs list-tasks --cluster wolof-asr-cluster --service-name wolof-asr-service --query 'taskArns[0]' --output text --region $REGION)
for i in 1 2 3 4 5 6 7 8; do
  STATUS=$(aws ecs describe-tasks --cluster wolof-asr-cluster --tasks "$TASK_ARN" --query 'tasks[0].lastStatus' --output text --region $REGION)
  echo "  Status: $STATUS"
  [ "$STATUS" = "RUNNING" ] && break
  sleep 15
done

ENI_ID=$(aws ecs describe-tasks --cluster wolof-asr-cluster --tasks "$TASK_ARN" --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text --region $REGION)
PUBLIC_IP=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI_ID" --query 'NetworkInterfaces[0].Association.PublicIp' --output text --region $REGION)

echo ""
echo "=========================================="
echo "  FARGATE READY!"
echo "  URL: http://$PUBLIC_IP:8080"
echo "  beam_size=5, cpu_threads=4"
echo "  ~11$/mois (Fargate Spot)"
echo "=========================================="
