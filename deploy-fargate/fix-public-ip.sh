#!/bin/bash
# Fix: ECS task has no public IP -> can't reach internet -> translation DNS fails
# Solution: Update service with assignPublicIp=ENABLED
set -e

REGION=us-east-1
CLUSTER=wolof-asr-cluster
SERVICE=wolof-asr-service
SUBNET1=subnet-0becd23a4e409e811
SUBNET2=subnet-05dfc0447fe541735
TASK_SG=sg-0af01817de2fd00ac

echo "=== FIX: Activer IP publique sur ECS task ==="
echo ""

echo "[1] Mise a jour du service avec assignPublicIp=ENABLED..."
aws ecs update-service \
  --cluster $CLUSTER \
  --service $SERVICE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET1,$SUBNET2],securityGroups=[$TASK_SG],assignPublicIp=ENABLED}" \
  --force-new-deployment \
  --region $REGION \
  --query "service.networkConfiguration" --output table

echo ""
echo "[2] Attente du nouveau deploiement (~2-3 min)..."
echo "    Le nouveau container aura une IP publique et pourra atteindre HuggingFace."
echo ""

for i in $(seq 1 18); do
  sleep 10
  RUNNING=$(aws ecs describe-services --cluster $CLUSTER --services $SERVICE --query "services[0].runningCount" --output text --region $REGION)
  DESIRED=$(aws ecs describe-services --cluster $CLUSTER --services $SERVICE --query "services[0].desiredCount" --output text --region $REGION)
  echo "  [$((i*10))s] Running: $RUNNING / Desired: $DESIRED"
  if [ "$RUNNING" = "$DESIRED" ] && [ "$RUNNING" != "0" ]; then
    sleep 15
    break
  fi
done

echo ""
echo "[3] Verification IP publique..."
TASK_ARN=$(aws ecs list-tasks --cluster $CLUSTER --service-name $SERVICE --query "taskArns[0]" --output text --region $REGION)
PUBLIC_IP=$(aws ecs describe-tasks --cluster $CLUSTER --tasks $TASK_ARN --query "tasks[0].attachments[0].details[?name=='publicIPv4Address'].value | [0]" --output text --region $REGION)
echo "  Public IP: $PUBLIC_IP"

if [ "$PUBLIC_IP" != "None" ] && [ -n "$PUBLIC_IP" ]; then
  echo "  OK! Le container a une IP publique."
else
  echo "  ATTENTION: toujours pas d'IP publique. Attendre encore 1 min..."
  sleep 60
  TASK_ARN=$(aws ecs list-tasks --cluster $CLUSTER --service-name $SERVICE --query "taskArns[0]" --output text --region $REGION)
  PUBLIC_IP=$(aws ecs describe-tasks --cluster $CLUSTER --tasks $TASK_ARN --query "tasks[0].attachments[0].details[?name=='publicIPv4Address'].value | [0]" --output text --region $REGION)
  echo "  Public IP: $PUBLIC_IP"
fi

echo ""
echo "[4] Test health..."
curl -s https://transcribe.4ura.tech/health || echo "  (ALB pas encore pret, attendre 1 min)"

echo ""
echo "=== DONE ==="
echo "La traduction devrait fonctionner maintenant."
echo "Test: sur le site, transcris un audio puis clique Traduire."
