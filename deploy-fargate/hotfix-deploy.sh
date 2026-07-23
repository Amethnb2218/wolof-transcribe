#!/bin/bash
# Quick hotfix: rebuild image from existing ECR base + new app.py only
# No model download needed - takes ~1 min instead of 10
set -e

ACCOUNT=335596040822
REGION=us-east-1
REPO_URI=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/wolof-asr-fargate

echo "=== HOTFIX BUILD (app.py only, ~1 min) ==="

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
      - |
        cat > Dockerfile << 'DEOF'
        FROM 335596040822.dkr.ecr.us-east-1.amazonaws.com/wolof-asr-fargate:latest
        COPY app.py /app/app.py
        CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--timeout", "300", "--workers", "1", "app:app"]
        DEOF
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

BUILD_ID=$(aws codebuild start-build --project-name "wolof-fargate-build" --region $REGION --query 'build.id' --output text)
echo "  Build: $BUILD_ID"
echo "  Waiting (~1-2 min)..."

while true; do
  sleep 10
  STATUS=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].buildStatus' --output text)
  PHASE=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].currentPhase' --output text)
  echo "  [$PHASE] $STATUS"
  if [ "$STATUS" = "SUCCEEDED" ]; then
    echo "  Image updated!"
    break
  elif [ "$STATUS" != "IN_PROGRESS" ]; then
    echo "  BUILD FAILED!"
    exit 1
  fi
done

echo ""
echo "Now redeploying service..."
aws ecs update-service --cluster wolof-asr-cluster --service wolof-asr-service --force-new-deployment --region $REGION > /dev/null
echo "  Service redeploying (~2 min)..."
sleep 60

HEALTH=$(curl -s http://wolof-asr-alb-2025108882.us-east-1.elb.amazonaws.com/health 2>/dev/null || echo "waiting")
echo "  Health: $HEALTH"

echo ""
echo "=== HOTFIX DONE ==="
echo "Test: curl http://wolof-asr-alb-2025108882.us-east-1.elb.amazonaws.com/health"
