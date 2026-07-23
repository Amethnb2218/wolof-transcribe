#!/bin/bash
# Force public IP: enable MapPublicIpOnLaunch on subnets + redeploy
set -e

REGION=us-east-1
CLUSTER=wolof-asr-cluster
SERVICE=wolof-asr-service
SUBNET1=subnet-0becd23a4e409e811
SUBNET2=subnet-05dfc0447fe541735
TASK_SG=sg-0af01817de2fd00ac

echo "=== FIX: Forcer IP publique ==="
echo ""

echo "[1] Activer MapPublicIpOnLaunch sur les subnets..."
aws ec2 modify-subnet-attribute --subnet-id $SUBNET1 --map-public-ip-on-launch --region $REGION
echo "  $SUBNET1 -> MapPublicIpOnLaunch=true"
aws ec2 modify-subnet-attribute --subnet-id $SUBNET2 --map-public-ip-on-launch --region $REGION
echo "  $SUBNET2 -> MapPublicIpOnLaunch=true"

echo ""
echo "[2] Force redeployment..."
aws ecs update-service \
  --cluster $CLUSTER \
  --service $SERVICE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET1,$SUBNET2],securityGroups=[$TASK_SG],assignPublicIp=ENABLED}" \
  --force-new-deployment \
  --region $REGION > /dev/null
echo "  Service en cours de redeploiement..."

echo ""
echo "[3] Attente (3 min)..."
for i in $(seq 1 18); do
  sleep 10
  TASKS=$(aws ecs list-tasks --cluster $CLUSTER --service-name $SERVICE --query "taskArns" --output text --region $REGION)
  TASK_COUNT=$(echo "$TASKS" | wc -w)

  if [ "$TASK_COUNT" -ge 1 ]; then
    LATEST_TASK=$(echo "$TASKS" | awk '{print $NF}')
    PUBLIC_IP=$(aws ecs describe-tasks --cluster $CLUSTER --tasks $LATEST_TASK \
      --query "tasks[0].attachments[0].details[?name=='publicIPv4Address'].value | [0]" --output text --region $REGION 2>/dev/null)
    STATUS=$(aws ecs describe-tasks --cluster $CLUSTER --tasks $LATEST_TASK \
      --query "tasks[0].lastStatus" --output text --region $REGION 2>/dev/null)
    echo "  [$((i*10))s] Status: $STATUS | PublicIP: $PUBLIC_IP | Tasks: $TASK_COUNT"

    if [ "$STATUS" = "RUNNING" ] && [ "$PUBLIC_IP" != "None" ] && [ -n "$PUBLIC_IP" ]; then
      echo ""
      echo "  IP PUBLIQUE OBTENUE: $PUBLIC_IP"
      break
    fi
  else
    echo "  [$((i*10))s] Waiting for task..."
  fi
done

echo ""
echo "[4] Test traduction..."
sleep 5
RESULT=$(curl -s -X POST https://transcribe.4ura.tech/api/translate \
  -H "Content-Type: application/json" \
  -d '{"text":"Jàmm nga am","src_lang":"wol_Latn","tgt_lang":"fra_Latn"}' --max-time 30)
echo "  Resultat: $RESULT"

echo ""
if echo "$RESULT" | grep -q "translation_text"; then
  echo "=== TRADUCTION OK! ==="
else
  echo "=== Traduction pas encore prete ==="
  echo "  Si le modele HuggingFace dort, ca peut prendre 20-30s au premier appel."
  echo "  Reteste dans 1 min: curl -X POST https://transcribe.4ura.tech/api/translate -H 'Content-Type: application/json' -d '{\"text\":\"Jàmm nga am\",\"src_lang\":\"wol_Latn\",\"tgt_lang\":\"fra_Latn\"}'"
fi
