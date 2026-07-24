#!/bin/bash
# Test: upload un audio et lance la transcription
# Usage: bash submit-job.sh <fichier-audio>
# Exemple: bash submit-job.sh ~/test-wolof.mp3
set -e

REGION=us-east-1
S3_BUCKET="wolof-transcriber-audio"
AUDIO_FILE=${1:-""}

if [ -z "$AUDIO_FILE" ]; then
  echo "Usage: bash submit-job.sh <fichier-audio>"
  echo "  Ex: bash submit-job.sh ~/mon-audio.mp3"
  exit 1
fi

JOB_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')
AUDIO_KEY="uploads/$JOB_ID/audio$(echo $AUDIO_FILE | grep -oE '\.[^.]+$')"

echo "=== WOLOF TRANSCRIPTION ==="
echo "  Job ID: $JOB_ID"
echo "  File: $AUDIO_FILE"
echo ""

echo "[1] Upload audio to S3..."
aws s3 cp "$AUDIO_FILE" "s3://$S3_BUCKET/$AUDIO_KEY" --region $REGION
echo "  Uploaded: s3://$S3_BUCKET/$AUDIO_KEY"
echo ""

echo "[2] Job submitted (Lambda trigger automatique)"
echo "  La transcription va démarrer automatiquement"
echo ""

echo "[3] Pour suivre le status:"
echo "  aws s3 cp s3://$S3_BUCKET/jobs/$JOB_ID/status.json - | python3 -m json.tool"
echo ""
echo "[4] Pour récupérer le résultat une fois terminé:"
echo "  aws s3 cp s3://$S3_BUCKET/results/$JOB_ID.json - | python3 -m json.tool"
echo ""

echo "Waiting for job to start..."
sleep 10
STATUS=$(aws s3 cp "s3://$S3_BUCKET/jobs/$JOB_ID/status.json" - 2>/dev/null || echo '{"status":"pending"}')
echo "  Status: $STATUS"
