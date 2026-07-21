#!/bin/bash
# ============================================================
# CLOUDSHELL SETUP — Wolof ASR S3 + Parallel Lambda Pipeline
#
# Architecture:
#   1. Frontend uploads audio to S3 via presigned URL (API Lambda)
#   2. S3 trigger fires Orchestrator Lambda
#   3. Orchestrator splits audio into 5-min chunks (ffmpeg)
#   4. Each chunk sent to wolof-asr Lambda in parallel
#   5. Results assembled, saved to S3
#   6. Frontend polls status via API Lambda
#
# Prerequisites:
#   - Run in AWS CloudShell (us-east-1)
#   - wolof-asr Lambda already deployed
#   - ECR repo wolof-asr already exists
#
# Account: 335596040822
# Region: us-east-1
# ============================================================

set -e

ACCOUNT=335596040822
REGION=us-east-1
BUCKET="wolof-asr-audio-${ACCOUNT}"
ORCHESTRATOR_NAME="wolof-asr-orchestrator"
API_NAME="wolof-asr-api"
ASR_FUNCTION="wolof-asr"
ROLE_NAME="wolof-asr-s3-pipeline-role"
POLICY_NAME="wolof-asr-s3-pipeline-policy"

echo "=========================================="
echo "  WOLOF ASR — S3 + PARALLEL PIPELINE"
echo "=========================================="
echo ""
echo "Account:      $ACCOUNT"
echo "Region:       $REGION"
echo "Bucket:       $BUCKET"
echo "Orchestrator: $ORCHESTRATOR_NAME"
echo "API:          $API_NAME"
echo ""

# ============================================================
# STEP 1: Create S3 Bucket
# ============================================================
echo "--- [1/7] Creating S3 bucket ---"

if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    echo "Bucket $BUCKET already exists."
else
    aws s3api create-bucket \
        --bucket "$BUCKET" \
        --region "$REGION"
    echo "Bucket $BUCKET created."
fi

# CORS for presigned URL uploads from browser
aws s3api put-bucket-cors --bucket "$BUCKET" --cors-configuration '{
  "CORSRules": [
    {
      "AllowedHeaders": ["*"],
      "AllowedMethods": ["PUT", "GET", "HEAD"],
      "AllowedOrigins": ["*"],
      "ExposeHeaders": ["ETag"],
      "MaxAgeSeconds": 3600
    }
  ]
}'
echo "CORS configured on bucket."

# Lifecycle rule: auto-delete uploads after 7 days, results after 30 days
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration '{
  "Rules": [
    {
      "ID": "cleanup-uploads",
      "Status": "Enabled",
      "Filter": {"Prefix": "uploads/"},
      "Expiration": {"Days": 7}
    },
    {
      "ID": "cleanup-results",
      "Status": "Enabled",
      "Filter": {"Prefix": "results/"},
      "Expiration": {"Days": 30}
    },
    {
      "ID": "cleanup-jobs",
      "Status": "Enabled",
      "Filter": {"Prefix": "jobs/"},
      "Expiration": {"Days": 30}
    }
  ]
}'
echo "Lifecycle rules configured (uploads: 7d, results: 30d)."

# ============================================================
# STEP 2: Create IAM Role & Policy
# ============================================================
echo ""
echo "--- [2/7] Creating IAM role & policy ---"

# Trust policy for Lambda
TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "lambda.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}'

# Create role (ignore if exists)
if aws iam get-role --role-name "$ROLE_NAME" 2>/dev/null; then
    echo "Role $ROLE_NAME already exists."
else
    aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document "$TRUST_POLICY" \
        --description "Wolof ASR S3 pipeline Lambda execution role"
    echo "Role $ROLE_NAME created."
fi

ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"

# Custom policy
POLICY_DOC=$(cat <<POLICYJSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:${REGION}:${ACCOUNT}:*"
    },
    {
      "Sid": "S3Access",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${BUCKET}",
        "arn:aws:s3:::${BUCKET}/*"
      ]
    },
    {
      "Sid": "InvokeASR",
      "Effect": "Allow",
      "Action": [
        "lambda:InvokeFunction"
      ],
      "Resource": "arn:aws:lambda:${REGION}:${ACCOUNT}:function:${ASR_FUNCTION}"
    }
  ]
}
POLICYJSON
)

# Create or update policy
POLICY_ARN="arn:aws:iam::${ACCOUNT}:policy/${POLICY_NAME}"
if aws iam get-policy --policy-arn "$POLICY_ARN" 2>/dev/null; then
    echo "Policy exists, creating new version..."
    # Delete oldest version if at limit (max 5)
    VERSIONS=$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text)
    for v in $VERSIONS; do
        aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$v" 2>/dev/null || true
    done
    aws iam create-policy-version \
        --policy-arn "$POLICY_ARN" \
        --policy-document "$POLICY_DOC" \
        --set-as-default
else
    aws iam create-policy \
        --policy-name "$POLICY_NAME" \
        --policy-document "$POLICY_DOC"
fi

# Attach policy to role
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN"
echo "Policy attached to role."

# Wait for IAM propagation
echo "Waiting 10s for IAM propagation..."
sleep 10

# ============================================================
# STEP 3: Create Orchestrator Lambda (Docker-based with ffmpeg)
# ============================================================
echo ""
echo "--- [3/7] Building Orchestrator Lambda Docker image ---"

cd /tmp
rm -rf wolof-orchestrator 2>/dev/null
mkdir -p wolof-orchestrator && cd wolof-orchestrator

# orchestrator.py
cat > orchestrator.py << 'ORCHESTRATOR_CODE'
"""
Orchestrator Lambda — Wolof ASR S3 Pipeline
Triggered by S3 upload event. Downloads audio, splits into 5-min chunks,
invokes wolof-asr Lambda in parallel, assembles results, saves to S3.
"""
import os
import json
import uuid
import time
import base64
import subprocess
import boto3
from concurrent.futures import ThreadPoolExecutor, as_completed

S3_BUCKET = os.environ.get("S3_BUCKET", "wolof-asr-audio-335596040822")
ASR_FUNCTION_NAME = os.environ.get("ASR_FUNCTION_NAME", "wolof-asr")
CHUNK_DURATION_SEC = 300  # 5 minutes per chunk
MAX_PARALLEL = 20  # Max parallel Lambda invocations

s3 = boto3.client("s3")
lambda_client = boto3.client("lambda")


def lambda_handler(event, context):
    """Handle S3 event trigger."""
    print(f"Event received: {json.dumps(event)[:500]}")

    # Extract S3 key from event
    record = event["Records"][0]
    bucket = record["s3"]["bucket"]["name"]
    key = record["s3"]["object"]["key"]

    # Extract job_id from key: uploads/{job_id}/{filename}
    parts = key.split("/")
    if len(parts) < 3 or parts[0] != "uploads":
        print(f"Ignoring key: {key}")
        return {"statusCode": 200, "body": "Ignored"}

    job_id = parts[1]
    filename = "/".join(parts[2:])
    print(f"Processing job_id={job_id}, file={filename}")

    # Write initial status
    write_status(job_id, {
        "status": "processing",
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "filename": filename,
        "chunks_done": 0,
        "chunks_total": 0,
    })

    try:
        # Download audio from S3
        local_input = f"/tmp/{job_id}_input"
        print(f"Downloading s3://{bucket}/{key} to {local_input}")
        s3.download_file(bucket, key, local_input)
        file_size = os.path.getsize(local_input)
        print(f"Downloaded {file_size / (1024*1024):.1f} MB")

        # Get audio duration
        duration = get_audio_duration(local_input)
        print(f"Audio duration: {duration:.1f}s ({duration/60:.1f} min)")

        # Split into chunks
        chunk_dir = f"/tmp/{job_id}_chunks"
        os.makedirs(chunk_dir, exist_ok=True)
        chunk_files = split_audio(local_input, chunk_dir, CHUNK_DURATION_SEC)
        print(f"Split into {len(chunk_files)} chunks")

        # Update status with total chunks
        write_status(job_id, {
            "status": "processing",
            "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "filename": filename,
            "duration": round(duration, 1),
            "chunks_done": 0,
            "chunks_total": len(chunk_files),
        })

        # Transcribe chunks in parallel
        results = transcribe_chunks_parallel(chunk_files, job_id)

        # Assemble final result
        final_result = assemble_results(results, duration, filename)

        # Save result to S3
        result_key = f"results/{job_id}.json"
        s3.put_object(
            Bucket=S3_BUCKET,
            Key=result_key,
            Body=json.dumps(final_result, ensure_ascii=False),
            ContentType="application/json",
        )

        # Update final status
        write_status(job_id, {
            "status": "done",
            "completed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "filename": filename,
            "duration": round(duration, 1),
            "chunks_total": len(chunk_files),
            "chunks_done": len(chunk_files),
            "result_key": result_key,
        })

        print(f"Job {job_id} completed successfully")
        return {"statusCode": 200, "body": json.dumps({"job_id": job_id, "status": "done"})}

    except Exception as e:
        print(f"Error processing job {job_id}: {e}")
        write_status(job_id, {
            "status": "error",
            "error": str(e),
            "filename": filename,
        })
        raise

    finally:
        # Cleanup /tmp
        cleanup_tmp(job_id)


def write_status(job_id, status_data):
    """Write job status to S3."""
    s3.put_object(
        Bucket=S3_BUCKET,
        Key=f"jobs/{job_id}/status.json",
        Body=json.dumps(status_data, ensure_ascii=False),
        ContentType="application/json",
    )


def get_audio_duration(filepath):
    """Get audio duration using ffprobe."""
    cmd = [
        "ffprobe", "-v", "quiet",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        filepath,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        raise RuntimeError(f"ffprobe failed: {result.stderr}")
    return float(result.stdout.strip())


def split_audio(input_path, output_dir, segment_duration):
    """Split audio into chunks using ffmpeg segment muxer."""
    output_pattern = os.path.join(output_dir, "chunk_%04d.mp3")

    cmd = [
        "ffmpeg", "-y",
        "-i", input_path,
        "-f", "segment",
        "-segment_time", str(segment_duration),
        "-c:a", "libmp3lame",
        "-ac", "1",
        "-ar", "16000",
        "-b:a", "64k",
        "-reset_timestamps", "1",
        output_pattern,
    ]

    result = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    if result.returncode != 0:
        raise RuntimeError(f"ffmpeg split failed: {result.stderr[:500]}")

    # Collect chunk files in order
    chunks = sorted([
        os.path.join(output_dir, f)
        for f in os.listdir(output_dir)
        if f.startswith("chunk_") and f.endswith(".mp3")
    ])

    if not chunks:
        raise RuntimeError("ffmpeg produced no chunks")

    return chunks


def transcribe_single_chunk(chunk_path, chunk_index, total_chunks, job_id):
    """Invoke wolof-asr Lambda for a single chunk."""
    print(f"  Transcribing chunk {chunk_index + 1}/{total_chunks}")

    with open(chunk_path, "rb") as f:
        audio_bytes = f.read()

    chunk_size_mb = len(audio_bytes) / (1024 * 1024)
    print(f"  Chunk {chunk_index + 1} size: {chunk_size_mb:.2f} MB")

    payload = {
        "body": base64.b64encode(audio_bytes).decode("utf-8"),
        "isBase64Encoded": True,
        "requestContext": {"http": {"method": "POST"}},
    }

    response = lambda_client.invoke(
        FunctionName=ASR_FUNCTION_NAME,
        InvocationType="RequestResponse",
        Payload=json.dumps(payload).encode("utf-8"),
    )

    response_payload = json.loads(response["Payload"].read())

    if response.get("FunctionError"):
        raise RuntimeError(
            f"Chunk {chunk_index + 1} Lambda error: {response_payload}"
        )

    if isinstance(response_payload.get("body"), str):
        result = json.loads(response_payload["body"])
    else:
        result = response_payload

    if response_payload.get("statusCode", 200) != 200:
        error_msg = result.get("error", "Unknown error")
        raise RuntimeError(f"Chunk {chunk_index + 1} transcription error: {error_msg}")

    return {
        "index": chunk_index,
        "text": result.get("text", ""),
        "segments": result.get("segments", []),
        "duration": result.get("duration", 0),
    }


def transcribe_chunks_parallel(chunk_files, job_id):
    """Transcribe all chunks in parallel using ThreadPoolExecutor."""
    total = len(chunk_files)
    results = [None] * total

    with ThreadPoolExecutor(max_workers=min(MAX_PARALLEL, total)) as executor:
        futures = {
            executor.submit(
                transcribe_single_chunk, chunk_path, i, total, job_id
            ): i
            for i, chunk_path in enumerate(chunk_files)
        }

        completed = 0
        for future in as_completed(futures):
            chunk_idx = futures[future]
            try:
                result = future.result()
                results[result["index"]] = result
                completed += 1
                print(f"  Completed {completed}/{total} chunks")
            except Exception as e:
                print(f"  ERROR on chunk {chunk_idx + 1}: {e}")
                results[chunk_idx] = {
                    "index": chunk_idx,
                    "text": f"[Erreur chunk {chunk_idx + 1}]",
                    "segments": [],
                    "duration": CHUNK_DURATION_SEC,
                    "error": str(e),
                }

    return results


def assemble_results(results, total_duration, filename):
    """Assemble chunk results into final transcription."""
    all_segments = []
    all_text_parts = []
    cumulative_offset = 0.0
    errors = []

    for chunk_result in results:
        if chunk_result is None:
            cumulative_offset += CHUNK_DURATION_SEC
            continue

        chunk_duration = chunk_result.get("duration", CHUNK_DURATION_SEC)

        for seg in chunk_result.get("segments", []):
            all_segments.append({
                "start": round(seg["start"] + cumulative_offset, 2),
                "end": round(seg["end"] + cumulative_offset, 2),
                "text": seg["text"],
            })

        all_text_parts.append(chunk_result.get("text", ""))

        if chunk_result.get("error"):
            errors.append({
                "chunk": chunk_result["index"] + 1,
                "error": chunk_result["error"],
            })

        cumulative_offset += chunk_duration

    full_text = " ".join(part for part in all_text_parts if part)

    result = {
        "text": full_text.strip(),
        "segments": all_segments,
        "language": "wo",
        "duration": round(total_duration, 1),
        "filename": filename,
        "chunks_processed": len(results),
    }

    if errors:
        result["errors"] = errors

    return result


def cleanup_tmp(job_id):
    """Clean up temporary files."""
    import shutil
    for path in [f"/tmp/{job_id}_input", f"/tmp/{job_id}_chunks"]:
        try:
            if os.path.isfile(path):
                os.unlink(path)
            elif os.path.isdir(path):
                shutil.rmtree(path)
        except Exception:
            pass
ORCHESTRATOR_CODE

# Dockerfile for orchestrator (includes ffmpeg)
cat > Dockerfile << 'DOCKERFILE'
FROM public.ecr.aws/lambda/python:3.11

# Install ffmpeg (static build)
RUN yum install -y tar xz && \
    curl -sL https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz | \
    tar xJ --strip-components=1 -C /usr/local/bin/ --wildcards '*/ffmpeg' '*/ffprobe' && \
    chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe && \
    ffmpeg -version && \
    yum clean all

# boto3 is pre-installed in Lambda runtime, but we pin for consistency
RUN pip install --no-cache-dir boto3

COPY orchestrator.py ${LAMBDA_TASK_ROOT}/

CMD ["orchestrator.lambda_handler"]
DOCKERFILE

echo "Building orchestrator Docker image..."
docker build --platform linux/amd64 -t wolof-orchestrator .

# Push to ECR
echo "Creating ECR repo for orchestrator..."
aws ecr describe-repositories --repository-names wolof-orchestrator --region $REGION 2>/dev/null || \
    aws ecr create-repository --repository-name wolof-orchestrator --region $REGION

ORCH_REPO="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/wolof-orchestrator"
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
docker tag wolof-orchestrator:latest "$ORCH_REPO:latest"
docker push "$ORCH_REPO:latest"
echo "Orchestrator image pushed to ECR."

# ============================================================
# STEP 4: Create API Lambda (lightweight, no Docker needed)
# ============================================================
echo ""
echo "--- [4/7] Creating API Lambda ---"

cd /tmp
rm -rf wolof-api 2>/dev/null
mkdir -p wolof-api && cd wolof-api

cat > api_handler.py << 'API_CODE'
"""
API Lambda — Wolof ASR S3 Pipeline
Provides presigned upload URLs and job status polling.
"""
import os
import json
import uuid
import boto3

S3_BUCKET = os.environ.get("S3_BUCKET", "wolof-asr-audio-335596040822")
UPLOAD_EXPIRY = 3600

s3 = boto3.client("s3")

HEADERS = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
}


def lambda_handler(event, context):
    """Route requests based on path and method."""
    request_context = event.get("requestContext", {})
    http_info = request_context.get("http", {})

    method = http_info.get("method", event.get("httpMethod", "GET"))
    path = http_info.get("path", event.get("rawPath", event.get("path", "/")))

    print(f"Request: {method} {path}")

    if method == "OPTIONS":
        return response(200, {"message": "OK"})

    if path == "/upload" and method == "POST":
        return handle_upload(event)
    elif path.startswith("/status/") and method == "GET":
        job_id = path.split("/status/")[-1].strip("/")
        return handle_status(job_id)
    elif path == "/health" and method == "GET":
        return response(200, {"status": "ok", "service": "wolof-asr-api"})
    else:
        return response(404, {"error": f"Not found: {method} {path}"})


def handle_upload(event):
    """Generate presigned upload URL and job_id."""
    body = {}
    if event.get("body"):
        try:
            raw_body = event["body"]
            if event.get("isBase64Encoded"):
                import base64
                raw_body = base64.b64decode(raw_body).decode("utf-8")
            body = json.loads(raw_body)
        except (json.JSONDecodeError, Exception):
            pass

    filename = body.get("filename", "audio.mp3")
    content_type = body.get("content_type", "audio/mpeg")

    filename = filename.replace("/", "_").replace("\\", "_")
    job_id = str(uuid.uuid4())
    s3_key = f"uploads/{job_id}/{filename}"

    presigned_url = s3.generate_presigned_url(
        "put_object",
        Params={
            "Bucket": S3_BUCKET,
            "Key": s3_key,
            "ContentType": content_type,
        },
        ExpiresIn=UPLOAD_EXPIRY,
    )

    return response(200, {
        "job_id": job_id,
        "upload_url": presigned_url,
        "s3_key": s3_key,
        "expires_in": UPLOAD_EXPIRY,
    })


def handle_status(job_id):
    """Get job status and result if done."""
    if not job_id or len(job_id) < 10:
        return response(400, {"error": "Invalid job_id"})

    status_key = f"jobs/{job_id}/status.json"
    try:
        obj = s3.get_object(Bucket=S3_BUCKET, Key=status_key)
        status_data = json.loads(obj["Body"].read().decode("utf-8"))
    except s3.exceptions.NoSuchKey:
        return response(404, {"error": "Job not found", "job_id": job_id})
    except Exception as e:
        return response(500, {"error": f"Failed to read status: {e}"})

    if status_data.get("status") == "done":
        result_key = status_data.get("result_key", f"results/{job_id}.json")
        result_url = s3.generate_presigned_url(
            "get_object",
            Params={"Bucket": S3_BUCKET, "Key": result_key},
            ExpiresIn=3600,
        )
        status_data["result_url"] = result_url

        try:
            result_obj = s3.get_object(Bucket=S3_BUCKET, Key=result_key)
            result_body = result_obj["Body"].read().decode("utf-8")
            if len(result_body) < 5 * 1024 * 1024:
                status_data["result"] = json.loads(result_body)
        except Exception:
            pass

    return response(200, status_data)


def response(status_code, body):
    """Build Lambda response."""
    return {
        "statusCode": status_code,
        "headers": HEADERS,
        "body": json.dumps(body, ensure_ascii=False),
    }
API_CODE

# Package as zip (no Docker needed, boto3 is in Lambda runtime)
zip -j api_handler.zip api_handler.py
echo "API Lambda package created."

# ============================================================
# STEP 5: Deploy Lambda Functions
# ============================================================
echo ""
echo "--- [5/7] Deploying Lambda functions ---"

# --- Deploy Orchestrator Lambda ---
if aws lambda get-function --function-name "$ORCHESTRATOR_NAME" --region $REGION 2>/dev/null; then
    echo "Updating orchestrator Lambda..."
    aws lambda update-function-code \
        --function-name "$ORCHESTRATOR_NAME" \
        --image-uri "$ORCH_REPO:latest" \
        --region $REGION

    # Wait for update
    aws lambda wait function-updated --function-name "$ORCHESTRATOR_NAME" --region $REGION

    aws lambda update-function-configuration \
        --function-name "$ORCHESTRATOR_NAME" \
        --timeout 900 \
        --memory-size 3008 \
        --ephemeral-storage '{"Size": 10240}' \
        --environment "Variables={S3_BUCKET=$BUCKET,ASR_FUNCTION_NAME=$ASR_FUNCTION}" \
        --region $REGION
else
    echo "Creating orchestrator Lambda..."
    aws lambda create-function \
        --function-name "$ORCHESTRATOR_NAME" \
        --package-type Image \
        --code "ImageUri=$ORCH_REPO:latest" \
        --role "$ROLE_ARN" \
        --timeout 900 \
        --memory-size 3008 \
        --ephemeral-storage '{"Size": 10240}' \
        --environment "Variables={S3_BUCKET=$BUCKET,ASR_FUNCTION_NAME=$ASR_FUNCTION}" \
        --region $REGION
fi

echo "Orchestrator Lambda deployed."
echo "  - Timeout: 15 min (max)"
echo "  - Memory: 3 GB"
echo "  - Ephemeral storage: 10 GB (for large audio files)"

# --- Deploy API Lambda ---
if aws lambda get-function --function-name "$API_NAME" --region $REGION 2>/dev/null; then
    echo "Updating API Lambda..."
    aws lambda update-function-code \
        --function-name "$API_NAME" \
        --zip-file fileb:///tmp/wolof-api/api_handler.zip \
        --region $REGION

    aws lambda wait function-updated --function-name "$API_NAME" --region $REGION

    aws lambda update-function-configuration \
        --function-name "$API_NAME" \
        --timeout 30 \
        --memory-size 256 \
        --handler "api_handler.lambda_handler" \
        --environment "Variables={S3_BUCKET=$BUCKET}" \
        --region $REGION
else
    echo "Creating API Lambda..."
    aws lambda create-function \
        --function-name "$API_NAME" \
        --runtime python3.11 \
        --handler "api_handler.lambda_handler" \
        --zip-file fileb:///tmp/wolof-api/api_handler.zip \
        --role "$ROLE_ARN" \
        --timeout 30 \
        --memory-size 256 \
        --environment "Variables={S3_BUCKET=$BUCKET}" \
        --region $REGION
fi

echo "API Lambda deployed."

# Wait for functions to be active
echo "Waiting for functions to become active..."
aws lambda wait function-active-v2 --function-name "$ORCHESTRATOR_NAME" --region $REGION 2>/dev/null || true
aws lambda wait function-active-v2 --function-name "$API_NAME" --region $REGION 2>/dev/null || true

# ============================================================
# STEP 6: Setup S3 Trigger for Orchestrator
# ============================================================
echo ""
echo "--- [6/7] Setting up S3 trigger ---"

# Grant S3 permission to invoke the orchestrator
aws lambda add-permission \
    --function-name "$ORCHESTRATOR_NAME" \
    --statement-id "s3-trigger-uploads" \
    --action "lambda:InvokeFunction" \
    --principal "s3.amazonaws.com" \
    --source-arn "arn:aws:s3:::${BUCKET}" \
    --source-account "$ACCOUNT" \
    --region $REGION 2>/dev/null || echo "(Permission already exists)"

# Configure S3 event notification
ORCH_ARN=$(aws lambda get-function --function-name "$ORCHESTRATOR_NAME" --region $REGION --query 'Configuration.FunctionArn' --output text)

aws s3api put-bucket-notification-configuration \
    --bucket "$BUCKET" \
    --notification-configuration "{
  \"LambdaFunctionConfigurations\": [
    {
      \"Id\": \"TriggerOrchestrator\",
      \"LambdaFunctionArn\": \"$ORCH_ARN\",
      \"Events\": [\"s3:ObjectCreated:*\"],
      \"Filter\": {
        \"Key\": {
          \"FilterRules\": [
            {\"Name\": \"prefix\", \"Value\": \"uploads/\"}
          ]
        }
      }
    }
  ]
}"

echo "S3 trigger configured: uploads/* -> $ORCHESTRATOR_NAME"

# ============================================================
# STEP 7: Create Function URL for API Lambda
# ============================================================
echo ""
echo "--- [7/7] Creating API Function URL ---"

# Check if Function URL already exists
API_URL=$(aws lambda get-function-url-config --function-name "$API_NAME" --region $REGION --query 'FunctionUrl' --output text 2>/dev/null || echo "")

if [ -z "$API_URL" ] || [ "$API_URL" = "None" ]; then
    # Add permission for public access
    aws lambda add-permission \
        --function-name "$API_NAME" \
        --statement-id "public-url-access" \
        --action "lambda:InvokeFunctionUrl" \
        --principal "*" \
        --function-url-auth-type NONE \
        --region $REGION 2>/dev/null || true

    # Create Function URL
    API_URL=$(aws lambda create-function-url-config \
        --function-name "$API_NAME" \
        --auth-type NONE \
        --cors '{
            "AllowOrigins": ["*"],
            "AllowMethods": ["GET", "POST", "OPTIONS"],
            "AllowHeaders": ["Content-Type", "Authorization"],
            "MaxAge": 3600
        }' \
        --region $REGION \
        --query 'FunctionUrl' --output text)
fi

echo ""
echo "=========================================="
echo "  DEPLOYMENT COMPLETE!"
echo "=========================================="
echo ""
echo "  S3 Bucket:         $BUCKET"
echo "  Orchestrator:      $ORCHESTRATOR_NAME (triggered by S3)"
echo "  API Lambda:        $API_NAME"
echo "  API URL:           $API_URL"
echo ""
echo "  --- ENDPOINTS ---"
echo "  POST ${API_URL}upload"
echo "       Body: {\"filename\": \"audio.mp3\", \"content_type\": \"audio/mpeg\"}"
echo "       Returns: {job_id, upload_url}"
echo ""
echo "  GET  ${API_URL}status/{job_id}"
echo "       Returns: {status, result}"
echo ""
echo "  --- FLOW ---"
echo "  1. POST /upload -> get presigned URL + job_id"
echo "  2. PUT audio file to presigned URL"
echo "  3. Poll GET /status/{job_id} every 5-10 seconds"
echo "  4. When status=done, result contains full transcription"
echo ""
echo "  --- COSTS (estimated) ---"
echo "  - S3: ~\$0.023/GB stored + \$0.005/1000 requests"
echo "  - Orchestrator: ~\$0.05 per 5h audio (3GB RAM, 15min)"
echo "  - ASR Lambda: existing cost (per chunk invocation)"
echo "  - Total for 5h audio: ~\$0.30-0.50"
echo "=========================================="
