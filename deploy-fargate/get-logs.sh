#!/bin/bash
# Get last CodeBuild logs
REGION=us-east-1
BUILD_ID=$(aws codebuild list-builds-for-project --project-name "wolof-fargate-build" --region $REGION --query 'ids[0]' --output text)
echo "Last build: $BUILD_ID"
LOG_STREAM=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].logs.streamName' --output text)
echo "Stream: $LOG_STREAM"
echo ""
echo "=== LAST 40 LOG LINES ==="
aws logs get-log-events --log-group-name "/aws/codebuild/wolof-fargate-build" --log-stream-name "$LOG_STREAM" --region $REGION --query 'events[-40:].message' --output text
