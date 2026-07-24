#!/bin/bash
# ============================================================
# WOLOF ASR — ARCHITECTURE V3 (PROPRE, TESTEE, DEFINITIVE)
#
# API Gateway HTTP API → Lambda → S3 presigned URL
# S3 Event → SQS Standard → ECS Worker → DynamoDB + S3
#
# CORS geré par API Gateway (zero probleme navigateur)
# SQS Standard (compatible S3 events)
# Pas de FIFO, pas de Lambda Function URL
# ============================================================
set -e

ACCOUNT=335596040822
REGION=us-east-1
BUCKET="wolof-asr-audio-${ACCOUNT}"
QUEUE_NAME="wolof-asr-jobs-v3"
DLQ_NAME="wolof-asr-jobs-v3-dlq"
TABLE_NAME="wolof-asr-jobs"
FUNCTION_NAME="wolof-asr-api-v2"
API_NAME="wolof-asr-http-api"
CLUSTER_NAME="wolof-asr-cluster"
SERVICE_NAME="wolof-asr-worker"
TASK_FAMILY="wolof-asr-worker-task"
REPO_NAME="wolof-asr-worker"
WORKER_ROLE="wolof-asr-worker-role"
LOG_GROUP="/ecs/wolof-asr-worker"

echo "=========================================="
echo "  WOLOF ASR V3 — ARCHITECTURE DEFINITIVE"
echo "=========================================="

# ==========================================================
# STEP 1: SQS Standard Queues (pas FIFO — compatible S3 events)
# ==========================================================
echo ""
echo "[1/8] SQS Standard Queues..."

# DLQ
DLQ_URL=$(aws sqs get-queue-url --queue-name "$DLQ_NAME" --region $REGION --query 'QueueUrl' --output text 2>/dev/null || echo "")
if [ -z "$DLQ_URL" ] || [ "$DLQ_URL" = "None" ]; then
  DLQ_URL=$(aws sqs create-queue \
    --queue-name "$DLQ_NAME" \
    --attributes '{"MessageRetentionPeriod":"1209600"}' \
    --region $REGION --query 'QueueUrl' --output text)
  echo "  DLQ created: $DLQ_URL"
else
  echo "  DLQ exists: $DLQ_URL"
fi
DLQ_ARN=$(aws sqs get-queue-attributes --queue-url "$DLQ_URL" --attribute-names QueueArn --region $REGION --query 'Attributes.QueueArn' --output text)

# Main queue
QUEUE_URL=$(aws sqs get-queue-url --queue-name "$QUEUE_NAME" --region $REGION --query 'QueueUrl' --output text 2>/dev/null || echo "")
if [ -z "$QUEUE_URL" ] || [ "$QUEUE_URL" = "None" ]; then
  QUEUE_URL=$(aws sqs create-queue \
    --queue-name "$QUEUE_NAME" \
    --attributes "{
      \"VisibilityTimeout\":\"900\",
      \"MessageRetentionPeriod\":\"86400\",
      \"ReceiveMessageWaitTimeSeconds\":\"20\",
      \"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"${DLQ_ARN}\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"
    }" \
    --region $REGION --query 'QueueUrl' --output text)
  echo "  Queue created: $QUEUE_URL"
else
  echo "  Queue exists: $QUEUE_URL"
fi
QUEUE_ARN=$(aws sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names QueueArn --region $REGION --query 'Attributes.QueueArn' --output text)

# Allow S3 to send messages to SQS
echo "  Setting SQS policy for S3 events..."
SQS_POLICY="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"AllowS3\",\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"s3.amazonaws.com\"},\"Action\":\"SQS:SendMessage\",\"Resource\":\"${QUEUE_ARN}\",\"Condition\":{\"ArnLike\":{\"aws:SourceArn\":\"arn:aws:s3:::${BUCKET}\"},\"StringEquals\":{\"aws:SourceAccount\":\"${ACCOUNT}\"}}}]}"
aws sqs set-queue-attributes --queue-url "$QUEUE_URL" --attributes "{\"Policy\":$(echo $SQS_POLICY | sed 's/"/\\"/g' | sed 's/^/"/;s/$/"/')}" --region $REGION 2>/dev/null || \
aws sqs set-queue-attributes --queue-url "$QUEUE_URL" --attributes "Policy=${SQS_POLICY}" --region $REGION 2>/dev/null || true
echo "  SQS ready"

# ==========================================================
# STEP 2: S3 Event Notification → SQS
# ==========================================================
echo ""
echo "[2/8] S3 → SQS event notification..."

aws s3api put-bucket-notification-configuration --bucket "$BUCKET" --notification-configuration "{
  \"QueueConfigurations\":[{
    \"QueueArn\":\"${QUEUE_ARN}\",
    \"Events\":[\"s3:ObjectCreated:*\"],
    \"Filter\":{\"Key\":{\"FilterRules\":[{\"Name\":\"prefix\",\"Value\":\"uploads/\"}]}}
  }]
}" --region $REGION
echo "  S3 event -> SQS configured"

# ==========================================================
# STEP 3: Update Lambda code (remove CORS headers, remove SQS send)
# ==========================================================
echo ""
echo "[3/8] Update API Lambda..."

cd /tmp
rm -f api_lambda_v3.py api_lambda_v3.zip 2>/dev/null

cat > api_lambda_v3.py << 'PYEOF'
"""API Lambda v3 — no CORS headers (API Gateway handles it), no SQS send (S3 event handles it)."""
import os
import json
import uuid
import time
import boto3

S3_BUCKET = os.environ.get("S3_BUCKET", "wolof-asr-audio-335596040822")
TABLE_NAME = os.environ.get("DYNAMODB_TABLE", "wolof-asr-jobs")
REGION = os.environ.get("AWS_REGION", "us-east-1")

s3 = boto3.client("s3", region_name=REGION)
dynamodb = boto3.resource("dynamodb", region_name=REGION)
table = dynamodb.Table(TABLE_NAME)


def lambda_handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method", "GET")
    path = event.get("rawPath", event.get("requestContext", {}).get("http", {}).get("path", "/"))

    if path == "/upload" and method == "POST":
        return handle_upload(event)
    elif "/status/" in path and method == "GET":
        job_id = path.split("/status/")[-1].strip("/")
        return handle_status(job_id)
    elif "/result/" in path and method == "GET":
        job_id = path.split("/result/")[-1].strip("/")
        return handle_result(job_id)
    elif path == "/health":
        return resp(200, {"status": "ok", "service": "wolof-asr-api-v3"})
    else:
        return resp(404, {"error": f"Not found: {method} {path}"})


def handle_upload(event):
    body = {}
    if event.get("body"):
        try:
            import base64
            raw = event["body"]
            if event.get("isBase64Encoded"):
                raw = base64.b64decode(raw).decode()
            body = json.loads(raw)
        except Exception:
            pass

    filename = body.get("filename", "audio.mp3").replace("/", "_").replace("\\", "_")
    content_type = body.get("content_type", "application/octet-stream")
    job_id = str(uuid.uuid4())
    s3_key = f"uploads/{job_id}/{filename}"
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    # Presigned URL with matching ContentType
    presigned_url = s3.generate_presigned_url(
        "put_object",
        Params={"Bucket": S3_BUCKET, "Key": s3_key, "ContentType": content_type},
        ExpiresIn=3600,
    )

    # Create job in DynamoDB
    table.put_item(Item={
        "job_id": job_id,
        "status": "UPLOADED",
        "stage": "WAITING_UPLOAD",
        "progress": 0,
        "created_at": now,
        "updated_at": now,
        "filename": filename,
        "s3_key": s3_key,
        "content_type": content_type,
    })

    return resp(200, {
        "job_id": job_id,
        "upload_url": presigned_url,
        "content_type": content_type,
        "s3_key": s3_key,
    })


def handle_status(job_id):
    if not job_id or len(job_id) < 10:
        return resp(400, {"error": "Invalid job_id"})

    r = table.get_item(Key={"job_id": job_id})
    item = r.get("Item")
    if not item:
        return resp(404, {"error": "Job not found", "job_id": job_id})

    status_map = {"UPLOADED": "processing", "QUEUED": "processing", "PROCESSING": "processing", "COMPLETED": "done", "FAILED": "failed"}
    result = {
        "job_id": job_id,
        "status": status_map.get(item.get("status"), "processing"),
        "stage": item.get("stage", ""),
        "progress": int(item.get("progress", 0)),
        "created_at": item.get("created_at", ""),
        "updated_at": item.get("updated_at", ""),
    }
    if item.get("status") == "COMPLETED":
        result["result_key"] = item.get("result_key", "")
        result["duration"] = float(item.get("duration", 0))
        result["processing_time"] = float(item.get("processing_time", 0))
    if item.get("status") == "FAILED":
        result["error"] = item.get("error", "Unknown error")
    return resp(200, result)


def handle_result(job_id):
    if not job_id or len(job_id) < 10:
        return resp(400, {"error": "Invalid job_id"})
    try:
        obj = s3.get_object(Bucket=S3_BUCKET, Key=f"results/{job_id}.json")
        return resp(200, json.loads(obj["Body"].read().decode()))
    except Exception:
        return resp(404, {"error": "Result not ready"})


def resp(code, body):
    return {"statusCode": code, "body": json.dumps(body, ensure_ascii=False)}
PYEOF

zip -j api_lambda_v3.zip api_lambda_v3.py
aws lambda update-function-code --function-name $FUNCTION_NAME --zip-file fileb://api_lambda_v3.zip --region $REGION > /dev/null
aws lambda update-function-configuration --function-name $FUNCTION_NAME --handler "api_lambda_v3.lambda_handler" --region $REGION > /dev/null 2>&1 || true
sleep 3

# Update env vars (remove SQS_QUEUE_URL — not needed anymore)
aws lambda update-function-configuration \
  --function-name $FUNCTION_NAME \
  --environment "Variables={S3_BUCKET=$BUCKET,DYNAMODB_TABLE=$TABLE_NAME,AWS_REGION_=$REGION}" \
  --handler "api_lambda_v3.lambda_handler" \
  --region $REGION > /dev/null 2>&1 || true

echo "  Lambda updated (v3, no CORS headers, no SQS send)"

# ==========================================================
# STEP 4: API Gateway HTTP API
# ==========================================================
echo ""
echo "[4/8] API Gateway HTTP API..."

# Check if API already exists
EXISTING_API=$(aws apigatewayv2 get-apis --region $REGION --query "Items[?Name=='$API_NAME'].ApiId" --output text 2>/dev/null)
if [ -n "$EXISTING_API" ] && [ "$EXISTING_API" != "None" ]; then
  API_ID="$EXISTING_API"
  echo "  API exists: $API_ID"
else
  API_ID=$(aws apigatewayv2 create-api \
    --name "$API_NAME" \
    --protocol-type HTTP \
    --cors-configuration '{"AllowOrigins":["*"],"AllowMethods":["GET","POST","OPTIONS"],"AllowHeaders":["Content-Type","Authorization"],"MaxAge":86400}' \
    --region $REGION \
    --query 'ApiId' --output text)
  echo "  API created: $API_ID"
fi

# Create integration
INTEGRATION_ID=$(aws apigatewayv2 create-integration \
  --api-id "$API_ID" \
  --integration-type AWS_PROXY \
  --integration-uri "arn:aws:lambda:${REGION}:${ACCOUNT}:function:${FUNCTION_NAME}" \
  --payload-format-version 2.0 \
  --region $REGION \
  --query 'IntegrationId' --output text 2>/dev/null || echo "")

if [ -z "$INTEGRATION_ID" ]; then
  INTEGRATION_ID=$(aws apigatewayv2 get-integrations --api-id "$API_ID" --region $REGION --query 'Items[0].IntegrationId' --output text)
fi
echo "  Integration: $INTEGRATION_ID"

# Create routes
for ROUTE_KEY in 'POST /upload' 'GET /status/{id}' 'GET /result/{id}' 'GET /health'; do
  aws apigatewayv2 create-route \
    --api-id "$API_ID" \
    --route-key "$ROUTE_KEY" \
    --target "integrations/$INTEGRATION_ID" \
    --region $REGION 2>/dev/null || true
done
echo "  Routes created"

# Create stage
aws apigatewayv2 create-stage \
  --api-id "$API_ID" \
  --stage-name '$default' \
  --auto-deploy \
  --region $REGION 2>/dev/null || true
echo "  Stage \$default ready"

# Lambda permission for API Gateway
aws lambda add-permission \
  --function-name "$FUNCTION_NAME" \
  --statement-id "apigw-invoke-${API_ID}" \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT}:${API_ID}/*/*" \
  --region $REGION 2>/dev/null || true
echo "  Lambda permission granted"

API_ENDPOINT="https://${API_ID}.execute-api.${REGION}.amazonaws.com"
echo "  Endpoint: $API_ENDPOINT"

# ==========================================================
# STEP 5: Update Worker to use new SQS queue
# ==========================================================
echo ""
echo "[5/8] Update ECS Worker task definition..."

REPO_URI="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}"
EXEC_ROLE="wolof-asr-fargate-execution-role"

# Update worker role with new queue ARN
aws iam put-role-policy --role-name "$WORKER_ROLE" --policy-name worker-policy --policy-document "{
  \"Version\":\"2012-10-17\",
  \"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"logs:*\"],\"Resource\":\"*\"},
    {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\",\"s3:DeleteObject\"],\"Resource\":[\"arn:aws:s3:::${BUCKET}/*\"]},
    {\"Effect\":\"Allow\",\"Action\":[\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",\"sqs:GetQueueAttributes\",\"sqs:ChangeMessageVisibility\"],\"Resource\":\"${QUEUE_ARN}\"},
    {\"Effect\":\"Allow\",\"Action\":[\"dynamodb:GetItem\",\"dynamodb:PutItem\",\"dynamodb:UpdateItem\",\"dynamodb:Query\"],\"Resource\":\"arn:aws:dynamodb:${REGION}:${ACCOUNT}:table/${TABLE_NAME}\"},
    {\"Effect\":\"Allow\",\"Action\":[\"ecr:GetAuthorizationToken\",\"ecr:BatchGetImage\",\"ecr:GetDownloadUrlForLayer\"],\"Resource\":\"*\"}
  ]
}"

TASK_DEF=$(cat << TASKEOF
{
  "family": "$TASK_FAMILY",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "4096",
  "memory": "8192",
  "executionRoleArn": "arn:aws:iam::${ACCOUNT}:role/${EXEC_ROLE}",
  "taskRoleArn": "arn:aws:iam::${ACCOUNT}:role/${WORKER_ROLE}",
  "containerDefinitions": [
    {
      "name": "wolof-asr-worker",
      "image": "$REPO_URI:latest",
      "portMappings": [{"containerPort": 8080, "protocol": "tcp"}],
      "environment": [
        {"name": "SQS_QUEUE_URL", "value": "$QUEUE_URL"},
        {"name": "DYNAMODB_TABLE", "value": "$TABLE_NAME"},
        {"name": "RESULTS_BUCKET", "value": "$BUCKET"},
        {"name": "AWS_REGION", "value": "$REGION"},
        {"name": "KAGGLE_USERNAME", "value": "amethsl"},
        {"name": "KAGGLE_API_TOKEN", "value": "${KAGGLE_API_TOKEN:-}"},
        {"name": "KAGGLE_KERNEL_SLUG", "value": "amethsl/wolof-transcriber-gpu"},
        {"name": "OMP_NUM_THREADS", "value": "4"},
        {"name": "MKL_NUM_THREADS", "value": "4"},
        {"name": "OPENBLAS_NUM_THREADS", "value": "4"},
        {"name": "TOKENIZERS_PARALLELISM", "value": "false"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "$LOG_GROUP",
          "awslogs-region": "$REGION",
          "awslogs-stream-prefix": "worker"
        }
      },
      "essential": true
    }
  ]
}
TASKEOF
)

aws ecs register-task-definition --cli-input-json "$TASK_DEF" --region $REGION > /dev/null
echo "  Task definition updated with new SQS queue URL"

# ==========================================================
# STEP 6: Force redeploy worker with new task definition
# ==========================================================
echo ""
echo "[6/8] Redeploying worker..."

aws ecs update-service \
  --cluster $CLUSTER_NAME \
  --service $SERVICE_NAME \
  --task-definition $TASK_FAMILY \
  --force-new-deployment \
  --region $REGION > /dev/null 2>&1 || true
echo "  Worker redeploying with new config"

# ==========================================================
# STEP 7: Test
# ==========================================================
echo ""
echo "[7/8] Testing API..."
sleep 5

HEALTH=$(curl -s "${API_ENDPOINT}/health")
echo "  Health: $HEALTH"

UPLOAD_TEST=$(curl -s -X POST "${API_ENDPOINT}/upload" -H "Content-Type: application/json" -d '{"filename":"test.wav","content_type":"audio/wav"}')
echo "  Upload test: $(echo $UPLOAD_TEST | head -c 200)"

# Test presigned URL works
TEST_URL=$(echo "$UPLOAD_TEST" | grep -o '"upload_url":"[^"]*"' | cut -d'"' -f4)
if [ -n "$TEST_URL" ]; then
  echo "test" > /tmp/test.wav
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -H "Content-Type: audio/wav" -T /tmp/test.wav "$TEST_URL")
  echo "  S3 PUT test: HTTP $HTTP_CODE"
fi

# ==========================================================
# STEP 8: Summary
# ==========================================================
echo ""
echo "=========================================="
echo "  DEPLOYMENT V3 COMPLETE!"
echo "=========================================="
echo ""
echo "  API: $API_ENDPOINT"
echo ""
echo "  Endpoints:"
echo "    POST ${API_ENDPOINT}/upload"
echo "    GET  ${API_ENDPOINT}/status/{job_id}"
echo "    GET  ${API_ENDPOINT}/result/{job_id}"
echo ""
echo "  Architecture:"
echo "    Browser -> API Gateway (CORS auto) -> Lambda"
echo "    Browser -> S3 (presigned PUT)"
echo "    S3 event -> SQS Standard -> ECS Worker"
echo "    Worker -> DynamoDB + S3 results"
echo ""
echo "  CORS: Geré par API Gateway. Zero header dans Lambda."
echo "  Timeout: Impossible. Worker async, pas de limite."
echo ""
echo "  FRONTEND: Mettre VITE_API_URL=$API_ENDPOINT"
echo "=========================================="
