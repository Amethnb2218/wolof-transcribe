#!/bin/bash
# Deep diagnostic: why does ECS task have no public IP despite assignPublicIp=ENABLED?
set -e

REGION=us-east-1
CLUSTER=wolof-asr-cluster
SERVICE=wolof-asr-service

echo "=== DIAGNOSTIC APPROFONDI ==="
echo ""

# 1. Get current task info
TASK_ARN=$(aws ecs list-tasks --cluster $CLUSTER --service-name $SERVICE --query "taskArns[0]" --output text --region $REGION)
echo "[1] Task: $(echo $TASK_ARN | awk -F'/' '{print $NF}')"

# 2. Get ENI ID
ENI_ID=$(aws ecs describe-tasks --cluster $CLUSTER --tasks $TASK_ARN --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value | [0]" --output text --region $REGION)
echo "    ENI: $ENI_ID"

# 3. Check ENI directly from EC2 (authoritative source for public IP)
echo ""
echo "[2] ENI details from EC2 (authoritative)..."
aws ec2 describe-network-interfaces --network-interface-ids $ENI_ID \
  --query "NetworkInterfaces[0].{Status:Status,PrivateIp:PrivateIpAddress,PublicIp:Association.PublicIp,SubnetId:SubnetId,VpcId:VpcId}" \
  --output table --region $REGION 2>/dev/null || echo "  Could not describe ENI"

# 4. Platform version
echo ""
echo "[3] Platform version..."
aws ecs describe-tasks --cluster $CLUSTER --tasks $TASK_ARN \
  --query "tasks[0].platformVersion" --output text --region $REGION

# 5. Service network config verification
echo ""
echo "[4] Service assignPublicIp setting..."
aws ecs describe-services --cluster $CLUSTER --services $SERVICE \
  --query "services[0].networkConfiguration.awsvpcConfiguration.assignPublicIp" --output text --region $REGION

# 6. Task definition network mode
echo ""
echo "[5] Task definition..."
TD_ARN=$(aws ecs describe-tasks --cluster $CLUSTER --tasks $TASK_ARN --query "tasks[0].taskDefinitionArn" --output text --region $REGION)
echo "    TD: $TD_ARN"
aws ecs describe-task-definition --task-definition $TD_ARN \
  --query "taskDefinition.{networkMode:networkMode,cpu:cpu,memory:memory}" --output table --region $REGION

# 7. Check subnet MapPublicIpOnLaunch
SUBNET_ID=$(aws ecs describe-tasks --cluster $CLUSTER --tasks $TASK_ARN --query "tasks[0].attachments[0].details[?name=='subnetId'].value | [0]" --output text --region $REGION)
echo ""
echo "[6] Subnet $SUBNET_ID - MapPublicIpOnLaunch..."
aws ec2 describe-subnets --subnet-ids $SUBNET_ID \
  --query "Subnets[0].MapPublicIpOnLaunch" --output text --region $REGION

# 8. Try DNS from CloudShell
echo ""
echo "[7] DNS test from CloudShell..."
dig api-inference.huggingface.co +short 2>/dev/null || \
  host api-inference.huggingface.co 2>/dev/null || \
  python3 -c "import socket; print(socket.gethostbyname('api-inference.huggingface.co'))" 2>/dev/null || \
  echo "  Cannot resolve from CloudShell either!"

echo ""
echo "=========================================="
echo ""
echo "SI Public IP = None malgre assignPublicIp=ENABLED:"
echo "  -> On va forcer en activant MapPublicIpOnLaunch sur le subnet"
echo "  -> et redeployer"
echo ""
echo "Voulez-vous appliquer le fix? Lancez: fix-force-public-ip.sh"
echo "=========================================="
