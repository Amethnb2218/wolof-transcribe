#!/bin/bash
# Rebuild image with NLLB translation model included (no internet needed at runtime)
# Takes ~15 min (downloads NLLB model during build)
set -e

ACCOUNT=335596040822
REGION=us-east-1
REPO_URI=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/wolof-asr-fargate
CLUSTER=wolof-asr-cluster
SERVICE=wolof-asr-service

echo "=== REBUILD WITH NLLB (translation model included) ==="
echo "  This takes ~15 min (downloads NLLB 600M model)"
echo ""

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
      - curl -sL -o Dockerfile.hotfix https://raw.githubusercontent.com/Amethnb2218/wolof-transcribe/main/deploy-fargate/Dockerfile.hotfix
      - docker build --platform linux/amd64 -f Dockerfile.hotfix -t wolof-asr-fargate .
  post_build:
    commands:
      - docker tag wolof-asr-fargate:latest 335596040822.dkr.ecr.us-east-1.amazonaws.com/wolof-asr-fargate:latest
      - docker push 335596040822.dkr.ecr.us-east-1.amazonaws.com/wolof-asr-fargate:latest
      - echo DONE
BSEOF
)

ENCODED_SPEC=$(echo "$BUILDSPEC" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

aws codebuild update-project \
  --name "wolof-fargate-build" \
  --source "{\"type\":\"NO_SOURCE\",\"buildspec\":$ENCODED_SPEC}" \
  --environment '{"type":"LINUX_CONTAINER","image":"aws/codebuild/standard:7.0","computeType":"BUILD_GENERAL1_LARGE","privilegedMode":true}' \
  --service-role "arn:aws:iam::335596040822:role/wolof-asr-codebuild-role" \
  --region $REGION > /dev/null && echo "  Project updated"

BUILD_ID=$(aws codebuild start-build --project-name "wolof-fargate-build" --region $REGION --query 'build.id' --output text)
echo "  Build: $BUILD_ID"
echo "  Waiting (~15 min for NLLB download + PyTorch install)..."

while true; do
  sleep 30
  STATUS=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].buildStatus' --output text)
  PHASE=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].currentPhase' --output text)
  echo "  [$PHASE] $STATUS"
  if [ "$STATUS" = "SUCCEEDED" ]; then
    echo "  Image built with NLLB!"
    break
  elif [ "$STATUS" != "IN_PROGRESS" ]; then
    echo "  BUILD FAILED!"
    echo "  Check logs: aws codebuild batch-get-builds --ids $BUILD_ID"
    exit 1
  fi
done

echo ""
echo "[2] Updating task definition (2 vCPU / 6 GB for Whisper + NLLB)..."
TASK_DEF=$(cat << 'TDEOF'
{
  "family": "wolof-asr-task",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "2048",
  "memory": "8192",
  "executionRoleArn": "arn:aws:iam::335596040822:role/ecsTaskExecutionRole",
  "containerDefinitions": [
    {
      "name": "wolof-asr",
      "image": "335596040822.dkr.ecr.us-east-1.amazonaws.com/wolof-asr-fargate:latest",
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
TDEOF
)

echo "$TASK_DEF" > /tmp/task-def.json
aws ecs register-task-definition --cli-input-json file:///tmp/task-def.json --region $REGION > /dev/null
echo "  Task definition updated (2 vCPU / 6 GB)"

echo ""
echo "[3] Redeploying service..."
aws ecs update-service \
  --cluster $CLUSTER \
  --service $SERVICE \
  --task-definition wolof-asr-task \
  --force-new-deployment \
  --region $REGION > /dev/null
echo "  Service redeploying (~3 min)..."

sleep 90

echo ""
echo "[4] Health check..."
for i in $(seq 1 6); do
  HEALTH=$(curl -s https://transcribe.4ura.tech/health 2>/dev/null || echo "waiting")
  echo "  [$((i*15))s] $HEALTH"
  if echo "$HEALTH" | grep -q "model_loaded"; then
    break
  fi
  sleep 15
done

echo ""
echo "[5] Test traduction..."
TRANSLATE=$(curl -s -X POST https://transcribe.4ura.tech/api/translate \
  -H "Content-Type: application/json" \
  -d '{"text":"Jàmm nga am","src_lang":"wol_Latn","tgt_lang":"fra_Latn"}' 2>/dev/null)
echo "  Resultat: $TRANSLATE"

echo ""
echo "=== DONE ==="
echo "  Transcription + Traduction en local (pas besoin d'internet)"
echo "  URL: https://transcribe.4ura.tech"
