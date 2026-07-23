#!/bin/bash
# Diagnose failed build + rebuild
set -e

REGION=us-east-1
BUILD_ID="wolof-fargate-build:b2c8211e-262c-46e8-bf9a-eac504c7cf90"

echo "=== [1] FETCHING BUILD LOGS ==="
LOG_GROUP=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].logs.groupName' --output text)
LOG_STREAM=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].logs.streamName' --output text)
echo "  Log group: $LOG_GROUP"
echo "  Log stream: $LOG_STREAM"
echo ""
echo "--- LAST 50 LINES ---"
aws logs get-log-events --log-group-name "$LOG_GROUP" --log-stream-name "$LOG_STREAM" --region $REGION --query 'events[-50:].message' --output text
echo "--- END LOGS ---"
echo ""

echo "=== [2] REBUILDING WITH FIXED BUILDSPEC ==="

BUILDSPEC=$(cat << 'BSEOF'
version: 0.2
env:
  variables:
    DOCKER_BUILDKIT: "1"
phases:
  pre_build:
    commands:
      - aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 335596040822.dkr.ecr.us-east-1.amazonaws.com
  build:
    commands:
      - mkdir -p /tmp/fargate
      - cd /tmp/fargate
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

aws codebuild update-project \
  --name "wolof-fargate-build" \
  --source "{\"type\":\"NO_SOURCE\",\"buildspec\":$ENCODED_SPEC}" \
  --environment '{"type":"LINUX_CONTAINER","image":"aws/codebuild/standard:7.0","computeType":"BUILD_GENERAL1_LARGE","privilegedMode":true}' \
  --service-role "arn:aws:iam::335596040822:role/wolof-asr-codebuild-role" \
  --region $REGION > /dev/null && echo "  Project updated"

NEW_BUILD_ID=$(aws codebuild start-build --project-name "wolof-fargate-build" --region $REGION --query 'build.id' --output text)
echo "  New build: $NEW_BUILD_ID"
echo "  Waiting (~15 min)..."

while true; do
  sleep 30
  STATUS=$(aws codebuild batch-get-builds --ids "$NEW_BUILD_ID" --region $REGION --query 'builds[0].buildStatus' --output text)
  PHASE=$(aws codebuild batch-get-builds --ids "$NEW_BUILD_ID" --region $REGION --query 'builds[0].currentPhase' --output text)
  echo "  [$PHASE] $STATUS"
  if [ "$STATUS" = "SUCCEEDED" ]; then
    echo "  Image pushed!"
    break
  elif [ "$STATUS" != "IN_PROGRESS" ]; then
    echo "  FAILED AGAIN - getting logs..."
    NEW_STREAM=$(aws codebuild batch-get-builds --ids "$NEW_BUILD_ID" --region $REGION --query 'builds[0].logs.streamName' --output text)
    aws logs get-log-events --log-group-name "$LOG_GROUP" --log-stream-name "$NEW_STREAM" --region $REGION --query 'events[-40:].message' --output text
    exit 1
  fi
done

echo ""
echo "=== [3] DEPLOYING ==="
CLUSTER=wolof-asr-cluster
SERVICE=wolof-asr-service

aws ecs register-task-definition --cli-input-json '{
  "family": "wolof-asr-task",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "4096",
  "memory": "16384",
  "executionRoleArn": "arn:aws:iam::335596040822:role/ecsTaskExecutionRole",
  "containerDefinitions": [{
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
  }]
}' --region $REGION > /dev/null
echo "  Task definition updated (4 vCPU / 16 GB)"

aws ecs update-service \
  --cluster $CLUSTER \
  --service $SERVICE \
  --task-definition wolof-asr-task \
  --force-new-deployment \
  --region $REGION > /dev/null
echo "  Service redeploying..."

echo ""
echo "=== [4] WAITING FOR HEALTHY (~3 min) ==="
sleep 90
for i in $(seq 1 8); do
  HEALTH=$(curl -s https://transcribe.4ura.tech/health 2>/dev/null || echo "waiting...")
  echo "  [$((i*15))s] $HEALTH"
  if echo "$HEALTH" | grep -q "model_loaded"; then
    echo ""
    echo "=== [5] TEST TRADUCTION ==="
    curl -s -X POST https://transcribe.4ura.tech/api/translate \
      -H "Content-Type: application/json" \
      -d '{"text":"Jàmm nga am","src_lang":"wol_Latn","tgt_lang":"fra_Latn"}'
    echo ""
    echo ""
    echo "=== SUCCESS ==="
    exit 0
  fi
  sleep 15
done

echo ""
echo "=== Service pas encore ready - check logs: ==="
STREAM=$(aws logs describe-log-streams --log-group-name "/ecs/wolof-asr" --order-by LastEventTime --descending --limit 1 --region $REGION --query 'logStreams[0].logStreamName' --output text)
aws logs get-log-events --log-group-name "/ecs/wolof-asr" --log-stream-name "$STREAM" --limit 20 --region $REGION --query 'events[*].message' --output text
