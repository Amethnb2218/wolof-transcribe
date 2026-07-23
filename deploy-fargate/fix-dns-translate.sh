#!/bin/bash
# Diagnose and fix DNS/network issue for translation endpoint
set -e

REGION=us-east-1
VPC_ID=vpc-04d1e55f3387a9c2c
SUBNET1=subnet-0becd23a4e409e811
SUBNET2=subnet-05dfc0447fe541735
TASK_SG=sg-0af01817de2fd00ac

echo "=== DIAGNOSTIC RESEAU ECS ==="
echo ""

echo "[1] Route tables du subnet..."
RT_ID=$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$SUBNET1" --query "RouteTables[0].RouteTableId" --output text --region $REGION 2>/dev/null)
if [ "$RT_ID" = "None" ] || [ -z "$RT_ID" ]; then
  RT_ID=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" --query "RouteTables[0].RouteTableId" --output text --region $REGION)
  echo "  Subnet uses MAIN route table: $RT_ID"
else
  echo "  Subnet route table: $RT_ID"
fi

echo ""
echo "[2] Routes (cherche 0.0.0.0/0 -> igw)..."
aws ec2 describe-route-tables --route-table-ids $RT_ID --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0']" --output table --region $REGION

IGW=$(aws ec2 describe-route-tables --route-table-ids $RT_ID --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId | [0]" --output text --region $REGION)
echo "  Gateway for 0.0.0.0/0: $IGW"

if [[ "$IGW" == igw-* ]]; then
  echo "  OK - Route vers Internet Gateway existe"
else
  echo "  PROBLEME - Pas de route vers IGW!"
  echo "  Checking for NAT Gateway..."
  NAT=$(aws ec2 describe-route-tables --route-table-ids $RT_ID --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].NatGatewayId | [0]" --output text --region $REGION)
  echo "  NAT: $NAT"
fi

echo ""
echo "[3] Network ACLs..."
NACL_ID=$(aws ec2 describe-network-acls --filters "Name=association.subnet-id,Values=$SUBNET1" --query "NetworkAcls[0].NetworkAclId" --output text --region $REGION)
echo "  NACL: $NACL_ID"
echo "  Egress rules:"
aws ec2 describe-network-acls --network-acl-ids $NACL_ID --query "NetworkAcls[0].Entries[?Egress==\`true\`].[RuleNumber,RuleAction,Protocol,PortRange.From,PortRange.To,CidrBlock]" --output table --region $REGION

echo ""
echo "[4] Security Group egress (task)..."
aws ec2 describe-security-groups --group-ids $TASK_SG --query "SecurityGroups[0].IpPermissionsEgress" --output table --region $REGION

echo ""
echo "[5] Task network config actuelle..."
TASK_ARN=$(aws ecs list-tasks --cluster wolof-asr-cluster --service-name wolof-asr-service --query "taskArns[0]" --output text --region $REGION)
echo "  Task: $TASK_ARN"
if [ "$TASK_ARN" != "None" ] && [ -n "$TASK_ARN" ]; then
  aws ecs describe-tasks --cluster wolof-asr-cluster --tasks $TASK_ARN --query "tasks[0].attachments[0].details" --output table --region $REGION
  echo ""
  echo "  Network mode:"
  aws ecs describe-tasks --cluster wolof-asr-cluster --tasks $TASK_ARN --query "tasks[0].{subnet: attachments[0].details[?name=='subnetId'].value | [0], eni: attachments[0].details[?name=='networkInterfaceId'].value | [0], publicIp: attachments[0].details[?name=='publicIPv4Address'].value | [0]}" --output table --region $REGION
fi

echo ""
echo "[6] Test DNS depuis ce shell (reference)..."
nslookup api-inference.huggingface.co 2>/dev/null | head -5 || echo "  nslookup not available"

echo ""
echo "=== FIN DIAGNOSTIC ==="
echo ""
echo "Si publicIp est vide ou None -> le container n'a pas d'IP publique"
echo "Si pas de route igw -> subnet prive, besoin NAT Gateway"
