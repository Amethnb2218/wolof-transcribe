#!/bin/bash
# Get mini-server logs
REGION=us-east-1
STREAM=$(aws logs describe-log-streams --log-group-name /aws/ecs/wolof-mini --order-by LastEventTime --descending --limit 1 --region $REGION --query 'logStreams[0].logStreamName' --output text)
echo "Stream: $STREAM"
echo ""
echo "=== LAST 20 LOG LINES ==="
aws logs get-log-events --log-group-name /aws/ecs/wolof-mini --log-stream-name "$STREAM" --region $REGION --query 'events[-20:].message' --output text
