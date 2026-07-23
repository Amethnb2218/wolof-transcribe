#!/bin/bash
# One-command deploy: reconfigure CodeBuild to use GitHub source, build, deploy to ECS
set -e

REGION=us-east-1
ACCOUNT=335596040822
CLUSTER=wolof-asr-cluster
SERVICE=wolof-asr-service

echo "=== [1] CONFIGURE CODEBUILD (GitHub source) ==="
aws codebuild update-project \
  --name "wolof-fargate-build" \
  --source '{
    "type": "GITHUB",
    "location": "https://github.com/Amethnb2218/wolof-transcribe.git",
    "buildspec": "deploy-fargate/buildspec.yml",
    "gitCloneDepth": 1
  }' \
  --source-version "main" \
  --environment '{"type":"LINUX_CONTAINER","image":"aws/codebuild/standard:7.0","computeType":"BUILD_GENERAL1_LARGE","privilegedMode":true}' \
  --service-role "arn:aws:iam::335596040822:role/wolof-asr-codebuild-role" \
  --region $REGION > /dev/null
echo "  Done (source: GitHub repo, buildspec: deploy-fargate/buildspec.yml)"

echo ""
echo "=== [2] START BUILD ==="
BUILD_ID=$(aws codebuild start-build --project-name "wolof-fargate-build" --region $REGION --query 'build.id' --output text)
echo "  Build: $BUILD_ID"
echo "  Waiting (~15 min for model downloads)..."

while true; do
  sleep 30
  STATUS=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].buildStatus' --output text)
  PHASE=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].currentPhase' --output text)
  echo "  [$PHASE] $STATUS"
  if [ "$STATUS" = "SUCCEEDED" ]; then
    echo "  Image pushed to ECR!"
    break
  elif [ "$STATUS" != "IN_PROGRESS" ]; then
    echo "  BUILD FAILED - logs:"
    LOG_STREAM=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].logs.streamName' --output text)
    aws logs get-log-events --log-group-name "/aws/codebuild/wolof-fargate-build" --log-stream-name "$LOG_STREAM" --region $REGION --query 'events[-30:].message' --output text
    exit 1
  fi
done

echo ""
echo "=== [3] UPDATE TASK DEFINITION ==="
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
echo "  Task: 4 vCPU / 16 GB"

echo ""
echo "=== [4] DEPLOY SERVICE ==="
aws ecs update-service \
  --cluster $CLUSTER \
  --service $SERVICE \
  --task-definition wolof-asr-task \
  --force-new-deployment \
  --region $REGION > /dev/null
echo "  Service redeploying..."

echo ""
echo "=== [5] HEALTH CHECK (~3 min) ==="
sleep 120
for i in $(seq 1 10); do
  HEALTH=$(curl -s https://transcribe.4ura.tech/health 2>/dev/null || echo "waiting...")
  echo "  [$((i*15))s] $HEALTH"
  if echo "$HEALTH" | grep -q "model_loaded"; then
    echo ""
    echo "=== [6] TEST TRADUCTION ==="
    curl -s -X POST https://transcribe.4ura.tech/api/translate \
      -H "Content-Type: application/json" \
      -d '{"text":"Jàmm nga am","src_lang":"wol_Latn","tgt_lang":"fra_Latn"}'
    echo ""
    echo ""
    echo "=== SUCCESS ==="
    echo "  URL: https://transcribe.4ura.tech"
    exit 0
  fi
  sleep 15
done

echo ""
echo "=== NOT READY YET - ECS logs: ==="
STREAM=$(aws logs describe-log-streams --log-group-name "/ecs/wolof-asr" --order-by LastEventTime --descending --limit 1 --region $REGION --query 'logStreams[0].logStreamName' --output text)
aws logs get-log-events --log-group-name "/ecs/wolof-asr" --log-stream-name "$STREAM" --limit 20 --region $REGION --query 'events[*].message' --output text
