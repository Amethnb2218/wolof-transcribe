#!/bin/bash
REGION=us-east-1
API_URL="https://6vc5h24e6d7pxjqyznfg4xwgzq0hjwww.lambda-url.us-east-1.on.aws"

echo "=== TEST S3 UPLOAD ==="
echo ""
echo "[1] Get presigned URL from API..."
RESPONSE=$(curl -s -X POST "${API_URL}/upload" -H "Content-Type: application/json" -d '{"filename":"test.wav"}')
echo "  API response: $RESPONSE"
echo ""

UPLOAD_URL=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('upload_url',''))" 2>/dev/null)
JOB_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('job_id',''))" 2>/dev/null)

if [ -z "$UPLOAD_URL" ]; then
  echo "  ERROR: No upload_url in response"
  exit 1
fi

echo "  Job ID: $JOB_ID"
echo "  Upload URL: ${UPLOAD_URL:0:80}..."
echo ""

echo "[2] PUT test file to S3..."
echo "hello audio test" > /tmp/test-audio.wav
HTTP_CODE=$(curl -s -o /tmp/s3-response.txt -w "%{http_code}" -X PUT -T /tmp/test-audio.wav "$UPLOAD_URL")
echo "  HTTP code: $HTTP_CODE"
echo "  S3 response: $(cat /tmp/s3-response.txt)"
echo ""

if [ "$HTTP_CODE" = "200" ]; then
  echo "SUCCESS! S3 upload works."
  echo ""
  echo "[3] Check job status..."
  sleep 2
  curl -s "${API_URL}/status/${JOB_ID}" | python3 -m json.tool
else
  echo "FAILED. Checking S3 error details..."
  cat /tmp/s3-response.txt
fi
