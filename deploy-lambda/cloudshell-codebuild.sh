#!/bin/bash
# ============================================================
# Solution definitive: CodeBuild build sur AWS (64GB disque)
# PAS de limite CloudShell
# ============================================================
set -e

ACCOUNT=335596040822
REGION=us-east-1
PROJECT_NAME=wolof-asr-build
ROLE_NAME=wolof-asr-codebuild-role
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"
POLICY_ARN="arn:aws:iam::${ACCOUNT}:policy/wolof-asr-codebuild-policy"
REPO_URI=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/wolof-asr

echo "=========================================="
echo "  WOLOF-ASR — CodeBuild Deployment"
echo "=========================================="

# --- Step 1: IAM Role ---
echo ""
echo "[1/4] IAM role..."

aws iam create-role --role-name $ROLE_NAME --assume-role-policy-document '{
  "Version":"2012-10-17",
  "Statement":[{"Effect":"Allow","Principal":{"Service":"codebuild.amazonaws.com"},"Action":"sts:AssumeRole"}]
}' 2>/dev/null || echo "  Role exists"

aws iam put-role-policy --role-name $ROLE_NAME --policy-name codebuild-inline --policy-document '{
  "Version":"2012-10-17",
  "Statement":[
    {"Effect":"Allow","Action":["logs:*"],"Resource":"*"},
    {"Effect":"Allow","Action":["ecr:*"],"Resource":"*"},
    {"Effect":"Allow","Action":["lambda:UpdateFunctionCode"],"Resource":"*"}
  ]
}' 2>/dev/null || true

echo "  Role ready"
sleep 8

# --- Step 2: Create/Update CodeBuild Project ---
echo ""
echo "[2/4] CodeBuild project..."

# Write buildspec to a temp file
cat > /tmp/buildspec.yml << 'BUILDSPECEOF'
version: 0.2
phases:
  pre_build:
    commands:
      - echo Logging in to ECR...
      - aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 335596040822.dkr.ecr.us-east-1.amazonaws.com
      - docker pull 335596040822.dkr.ecr.us-east-1.amazonaws.com/wolof-asr:latest
  build:
    commands:
      - echo Updating handler...
      - curl -sL -o /tmp/handler.py https://raw.githubusercontent.com/Amethnb2218/wolof-transcribe/main/deploy-lambda/handler.py
      - docker create --name temp 335596040822.dkr.ecr.us-east-1.amazonaws.com/wolof-asr:latest
      - docker cp /tmp/handler.py temp:/var/task/handler.py
      - docker commit temp wolof-asr:updated
      - docker rm temp
  post_build:
    commands:
      - docker tag wolof-asr:updated 335596040822.dkr.ecr.us-east-1.amazonaws.com/wolof-asr:latest
      - docker push 335596040822.dkr.ecr.us-east-1.amazonaws.com/wolof-asr:latest
      - aws lambda update-function-code --function-name wolof-asr --image-uri 335596040822.dkr.ecr.us-east-1.amazonaws.com/wolof-asr:latest --region us-east-1
      - echo DONE
BUILDSPECEOF

BUILDSPEC=$(cat /tmp/buildspec.yml)

# Create or update project
aws codebuild create-project \
  --name "$PROJECT_NAME" \
  --source "{\"type\":\"NO_SOURCE\",\"buildspec\":$(echo "$BUILDSPEC" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}" \
  --artifacts '{"type":"NO_ARTIFACTS"}' \
  --environment '{"type":"LINUX_CONTAINER","image":"aws/codebuild/standard:7.0","computeType":"BUILD_GENERAL1_MEDIUM","privilegedMode":true}' \
  --service-role "$ROLE_ARN" \
  --region $REGION 2>/dev/null && echo "  Project created" || \
aws codebuild update-project \
  --name "$PROJECT_NAME" \
  --source "{\"type\":\"NO_SOURCE\",\"buildspec\":$(echo "$BUILDSPEC" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}" \
  --environment '{"type":"LINUX_CONTAINER","image":"aws/codebuild/standard:7.0","computeType":"BUILD_GENERAL1_MEDIUM","privilegedMode":true}' \
  --service-role "$ROLE_ARN" \
  --region $REGION && echo "  Project updated"

# --- Step 3: Start Build ---
echo ""
echo "[3/4] Starting build..."

BUILD_ID=$(aws codebuild start-build --project-name "$PROJECT_NAME" --region $REGION --query 'build.id' --output text)
echo "  Build ID: $BUILD_ID"
echo "  Waiting (~3-5 min)..."

# --- Step 4: Wait ---
while true; do
  sleep 15
  STATUS=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].buildStatus' --output text)
  PHASE=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].currentPhase' --output text)
  echo "  [$PHASE] $STATUS"

  if [ "$STATUS" = "SUCCEEDED" ]; then
    echo ""
    echo "=========================================="
    echo "  DONE! Lambda updated with lazy import"
    echo "  Plus de init timeout!"
    echo "=========================================="
    break
  elif [ "$STATUS" != "IN_PROGRESS" ]; then
    echo ""
    echo "  FAILED! Voir les logs:"
    echo "  aws codebuild batch-get-builds --ids $BUILD_ID --region $REGION --query 'builds[0].phases'"
    exit 1
  fi
done
