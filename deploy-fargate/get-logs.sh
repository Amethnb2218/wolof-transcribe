#!/bin/bash
# Get last CodeBuild logs - full output
REGION=us-east-1
BUILD_ID=$(aws codebuild list-builds-for-project --project-name "wolof-fargate-build" --region $REGION --query 'ids[0]' --output text)
echo "Last build: $BUILD_ID"
STATUS=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].buildStatus' --output text)
echo "Status: $STATUS"
LOG_STREAM=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].logs.streamName' --output text)
echo "Stream: $LOG_STREAM"
echo ""

# Get all events with pagination (forward from start, get last token, then last events)
echo "=== DOCKER BUILD ERROR (searching for ERROR/error/failed) ==="
aws logs get-log-events --log-group-name "/aws/codebuild/wolof-fargate-build" --log-stream-name "$LOG_STREAM" --region $REGION --no-start-from-head --limit 100 --query 'events[].message' --output text | grep -i -E "error|failed|errno|killed|oom|no space"
echo ""
echo "=== LAST 80 LINES ==="
aws logs get-log-events --log-group-name "/aws/codebuild/wolof-fargate-build" --log-stream-name "$LOG_STREAM" --region $REGION --no-start-from-head --limit 80 --query 'events[].message' --output text
