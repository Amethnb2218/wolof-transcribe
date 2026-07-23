#!/bin/bash
# Check if new task has public IP
REGION=us-east-1
CLUSTER=wolof-asr-cluster
SERVICE=wolof-asr-service

echo "=== Verification deployment ==="
echo ""

echo "[1] Deployments en cours..."
aws ecs describe-services --cluster $CLUSTER --services $SERVICE \
  --query "services[0].deployments[*].{status:status,running:runningCount,desired:desiredCount,rollout:rolloutState}" \
  --output table --region $REGION

echo ""
echo "[2] Tasks actives..."
TASKS=$(aws ecs list-tasks --cluster $CLUSTER --service-name $SERVICE --query "taskArns" --output text --region $REGION)

for TASK in $TASKS; do
  echo ""
  echo "  Task: $(echo $TASK | awk -F'/' '{print $NF}')"
  aws ecs describe-tasks --cluster $CLUSTER --tasks $TASK \
    --query "tasks[0].{startedAt:startedAt, publicIp:attachments[0].details[?name=='publicIPv4Address'].value | [0], subnet:attachments[0].details[?name=='subnetId'].value | [0], lastStatus:lastStatus}" \
    --output table --region $REGION
done

echo ""
echo "[3] Test traduction..."
RESULT=$(curl -s -X POST https://transcribe.4ura.tech/api/translate \
  -H "Content-Type: application/json" \
  -d '{"text":"Jàmm nga am","src_lang":"wol_Latn","tgt_lang":"fra_Latn"}')
echo "  Resultat: $RESULT"

echo ""
echo "Si publicIp = None, le nouveau task n'est pas encore lance."
echo "Relancer ce script dans 1-2 min."
