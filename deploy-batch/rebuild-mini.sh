#!/bin/bash
# Rebuild mini-server image with beam_size=1 (3x faster) and redeploy
set -e

REGION=us-east-1
ACCOUNT=335596040822

echo "=== REBUILD MINI-SERVER (faster) ==="

echo "[1/3] Build new image via CodeBuild..."
aws codebuild update-project \
  --name "wolof-fargate-build" \
  --source '{
    "type": "GITHUB",
    "location": "https://github.com/Amethnb2218/wolof-transcribe.git",
    "buildspec": "deploy-batch/buildspec-cpu.yml",
    "gitCloneDepth": 1
  }' \
  --source-version "main" \
  --region $REGION > /dev/null

BUILD_ID=$(aws codebuild start-build --project-name "wolof-fargate-build" --region $REGION --query 'build.id' --output text)
echo "  Build: $BUILD_ID"
echo "  Waiting (~10 min)..."

while true; do
  sleep 30
  STATUS=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].buildStatus' --output text)
  PHASE=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].currentPhase' --output text)
  echo "  [$PHASE] $STATUS"
  if [ "$STATUS" == "SUCCEEDED" ]; then
    echo "  Image pushed!"
    break
  elif [ "$STATUS" != "IN_PROGRESS" ]; then
    echo "  FAILED"
    exit 1
  fi
done

echo ""
echo "[2/3] Force new deployment of mini-server..."
aws ecs update-service \
  --cluster wolof-asr-cluster \
  --service wolof-mini-service \
  --force-new-deployment \
  --region $REGION > /dev/null
echo "  Redeploying (~2 min)..."

echo ""
echo "[3/3] Wait for healthy..."
sleep 90
for i in $(seq 1 10); do
  IP=$(bash deploy-batch/get-mini-ip.sh 2>/dev/null | grep "PUBLIC IP" | awk '{print $NF}')
  if [ -n "$IP" ]; then
    HEALTH=$(curl -s "http://$IP:8080/health" 2>/dev/null || echo "waiting")
    echo "  [$((i*10))s] $HEALTH"
    if echo "$HEALTH" | grep -q "model_loaded"; then
      echo ""
      echo "=== DONE ==="
      echo "  Mini-server rebuilt with beam_size=1 (3x faster)"
      echo "  New IP: $IP"
      echo ""
      echo "  IMPORTANT: Update MINI_SERVER in Lambda trigger:"
      echo "  aws lambda update-function-configuration --function-name wolof-batch-trigger --environment \"Variables={\$(aws lambda get-function-configuration --function-name wolof-batch-trigger --region us-east-1 --query 'Environment.Variables' --output json | python3 -c 'import sys,json; d=json.load(sys.stdin); d[\"MINI_SERVER\"]=\"http://$IP:8080\"; print(\",\".join(f\"{k}={v}\" for k,v in d.items()))')}\" --region us-east-1"
      exit 0
    fi
  fi
  sleep 10
done
echo "  Still starting... check manually in a few minutes"
