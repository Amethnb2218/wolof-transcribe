#!/bin/bash
# Build CPU image + update Lambda to use CPU job definition
set -e

REGION=us-east-1
ACCOUNT=335596040822

echo "=== [1] Update Lambda trigger to use CPU job definition ==="
aws lambda update-function-configuration \
  --function-name wolof-batch-trigger \
  --environment "Variables={JOB_QUEUE=wolof-transcription-queue,JOB_DEFINITION=wolof-transcribe-cpu,S3_BUCKET=wolof-transcriber-audio}" \
  --region $REGION > /dev/null
echo "  Done (wolof-transcribe-cpu)"

echo ""
echo "=== [2] Build CPU Docker Image ==="
aws codebuild update-project \
  --name "wolof-fargate-build" \
  --source '{
    "type": "GITHUB",
    "location": "https://github.com/Amethnb2218/wolof-transcribe.git",
    "buildspec": "deploy-batch/buildspec-cpu.yml",
    "gitCloneDepth": 1
  }' \
  --source-version "main" \
  --environment '{"type":"LINUX_CONTAINER","image":"aws/codebuild/standard:7.0","computeType":"BUILD_GENERAL1_LARGE","privilegedMode":true}' \
  --service-role "arn:aws:iam::335596040822:role/wolof-asr-codebuild-role" \
  --region $REGION > /dev/null

BUILD_ID=$(aws codebuild start-build --project-name "wolof-fargate-build" --region $REGION --query 'build.id' --output text)
echo "  Build: $BUILD_ID"
echo "  Waiting (~15 min)..."

while true; do
  sleep 30
  STATUS=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].buildStatus' --output text)
  PHASE=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].currentPhase' --output text)
  echo "  [$PHASE] $STATUS"
  if [ "$STATUS" = "SUCCEEDED" ]; then
    echo "  CPU image pushed!"
    break
  elif [ "$STATUS" != "IN_PROGRESS" ]; then
    echo "  BUILD FAILED - logs:"
    LOG_STREAM=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].logs.streamName' --output text)
    aws logs get-log-events --log-group-name "/aws/codebuild/wolof-fargate-build" --log-stream-name "$LOG_STREAM" --region $REGION --query 'events[-20:].message' --output text
    exit 1
  fi
done

echo ""
echo "=== DONE ==="
echo "  L'image CPU est prete."
echo "  Pour tester: aws s3 cp test.mp3 s3://wolof-transcriber-audio/uploads/test-001/audio.mp3"
echo "  Puis: aws s3 cp s3://wolof-transcriber-audio/jobs/test-001/status.json -"
