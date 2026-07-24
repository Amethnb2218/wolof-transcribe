#!/bin/bash
# Add proxy endpoint to the API Lambda so frontend can reach mini-server via HTTPS
set -e

REGION=us-east-1
MINI_IP="52.91.36.73"

echo "=== ADD PROXY TO API LAMBDA ==="

cd /tmp
rm -rf api-proxy
mkdir api-proxy && cd api-proxy

cat > index.py << 'PYEOF'
import json
import os
import uuid
import base64
import urllib.request
import boto3

s3 = boto3.client("s3")
S3_BUCKET = os.environ.get("S3_BUCKET", "wolof-transcriber-audio")
MINI_SERVER = os.environ.get("MINI_SERVER", "http://52.91.36.73:8080")


def lambda_handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method", "GET")
    path = event.get("rawPath", "/")
    headers = {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers": "*",
    }

    if method == "OPTIONS":
        return {"statusCode": 200, "headers": headers, "body": ""}

    # POST /transcribe — proxy to mini-server
    if method == "POST" and "/transcribe" in path:
        body = event.get("body", "")
        is_base64 = event.get("isBase64Encoded", False)
        if is_base64:
            audio_bytes = base64.b64decode(body)
        else:
            audio_bytes = body.encode() if isinstance(body, str) else body

        content_type = event.get("headers", {}).get("content-type", "audio/mpeg")

        req = urllib.request.Request(
            MINI_SERVER + "/",
            data=audio_bytes,
            headers={"Content-Type": content_type},
            method="POST",
        )
        try:
            resp = urllib.request.urlopen(req, timeout=290)
            result = resp.read().decode()
            return {"statusCode": 200, "headers": headers, "body": result}
        except Exception as e:
            return {"statusCode": 502, "headers": headers, "body": json.dumps({"error": str(e)})}

    # POST /upload — generate presigned URL
    if method == "POST" and "/upload" in path:
        body = json.loads(event.get("body", "{}"))
        filename = body.get("filename", "audio.mp3")
        ext = filename.rsplit(".", 1)[-1] if "." in filename else "mp3"
        job_id = str(uuid.uuid4())
        audio_key = f"uploads/{job_id}/audio.{ext}"
        presigned = s3.generate_presigned_url(
            "put_object",
            Params={"Bucket": S3_BUCKET, "Key": audio_key, "ContentType": "audio/*"},
            ExpiresIn=3600,
        )
        return {"statusCode": 200, "headers": headers, "body": json.dumps({"job_id": job_id, "upload_url": presigned, "audio_key": audio_key})}

    # GET /status/{job_id}
    if "/status/" in path:
        job_id = path.split("/status/")[-1].strip("/")
        try:
            obj = s3.get_object(Bucket=S3_BUCKET, Key=f"jobs/{job_id}/status.json")
            return {"statusCode": 200, "headers": headers, "body": obj["Body"].read().decode()}
        except:
            return {"statusCode": 200, "headers": headers, "body": json.dumps({"status": "pending", "job_id": job_id})}

    # GET /result/{job_id}
    if "/result/" in path:
        job_id = path.split("/result/")[-1].strip("/")
        try:
            obj = s3.get_object(Bucket=S3_BUCKET, Key=f"results/{job_id}.json")
            return {"statusCode": 200, "headers": headers, "body": obj["Body"].read().decode()}
        except:
            return {"statusCode": 404, "headers": headers, "body": json.dumps({"error": "Not ready"})}

    # GET /health
    if "/health" in path:
        return {"statusCode": 200, "headers": headers, "body": json.dumps({"status": "ok", "mode": "mini+kaggle"})}

    return {"statusCode": 404, "headers": headers, "body": json.dumps({"error": "Not found"})}
PYEOF

zip -j api-proxy.zip index.py

echo "[1/2] Updating API Lambda code..."
aws lambda update-function-code \
  --function-name wolof-batch-api \
  --zip-file fileb://api-proxy.zip \
  --region $REGION > /dev/null

echo "  Waiting for update..."
aws lambda wait function-updated --function-name wolof-batch-api --region $REGION

echo "[2/2] Updating config..."
aws lambda update-function-configuration \
  --function-name wolof-batch-api \
  --environment "Variables={S3_BUCKET=$S3_BUCKET,MINI_SERVER=http://$MINI_IP:8080}" \
  --timeout 300 \
  --memory-size 256 \
  --region $REGION > /dev/null

echo ""
echo "=== DONE ==="
echo ""
API_URL=$(aws lambda get-function-url-config --function-name wolof-batch-api --region $REGION --query 'FunctionUrl' --output text)
echo "  API URL: $API_URL"
echo "  Test: curl -X POST ${API_URL}transcribe -H 'Content-Type: audio/mpeg' --data-binary @test.mp3"
echo ""
echo "  Frontend uses this same API URL for both:"
echo "    - POST /transcribe (short audio, instant)"
echo "    - POST /upload + GET /status + GET /result (long audio, Kaggle)"
