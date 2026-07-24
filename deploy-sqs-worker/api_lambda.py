"""
API Lambda — Wolof ASR (SQS Architecture)
Ultra-lightweight: creates jobs, returns status. No ML, no waiting.

Endpoints:
  POST /upload     -> presigned URL + job_id + sends SQS message
  GET  /status/{id} -> reads DynamoDB status
  GET  /result/{id} -> returns result from S3
  GET  /health      -> OK
"""
import os
import json
import uuid
import time
import boto3

S3_BUCKET = os.environ.get("S3_BUCKET", "wolof-asr-audio-335596040822")
QUEUE_URL = os.environ["SQS_QUEUE_URL"]
TABLE_NAME = os.environ.get("DYNAMODB_TABLE", "wolof-asr-jobs")
REGION = os.environ.get("AWS_REGION", "us-east-1")

s3 = boto3.client("s3", region_name=REGION)
sqs = boto3.client("sqs", region_name=REGION)
dynamodb = boto3.resource("dynamodb", region_name=REGION)
table = dynamodb.Table(TABLE_NAME)

HEADERS = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
}


def lambda_handler(event, context):
    request_context = event.get("requestContext", {})
    http_info = request_context.get("http", {})
    method = http_info.get("method", event.get("httpMethod", "GET"))
    path = http_info.get("path", event.get("rawPath", event.get("path", "/")))

    if method == "OPTIONS":
        return response(200, {"message": "OK"})

    if path == "/upload" and method == "POST":
        return handle_upload(event)
    elif path.startswith("/status/") and method == "GET":
        job_id = path.split("/status/")[-1].strip("/")
        return handle_status(job_id)
    elif path.startswith("/result/") and method == "GET":
        job_id = path.split("/result/")[-1].strip("/")
        return handle_result(job_id)
    elif path == "/health" and method == "GET":
        return response(200, {"status": "ok", "service": "wolof-asr-api-v2"})
    else:
        return response(404, {"error": f"Not found: {method} {path}"})


def handle_upload(event):
    body = {}
    if event.get("body"):
        try:
            import base64
            raw_body = event["body"]
            if event.get("isBase64Encoded"):
                raw_body = base64.b64decode(raw_body).decode("utf-8")
            body = json.loads(raw_body)
        except Exception:
            pass

    filename = body.get("filename", "audio.mp3")
    content_type = body.get("content_type", "audio/mpeg")
    source_language = body.get("source_language", "wol")
    target_language = body.get("target_language", "fra")

    filename = filename.replace("/", "_").replace("\\", "_")
    job_id = str(uuid.uuid4())
    s3_key = f"uploads/{job_id}/{filename}"
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    # Create presigned upload URL
    presigned_url = s3.generate_presigned_url(
        "put_object",
        Params={"Bucket": S3_BUCKET, "Key": s3_key, "ContentType": content_type},
        ExpiresIn=3600,
    )

    # Create job in DynamoDB
    table.put_item(Item={
        "job_id": job_id,
        "status": "UPLOADED",
        "stage": "WAITING",
        "progress": 0,
        "created_at": now,
        "updated_at": now,
        "filename": filename,
        "s3_key": s3_key,
        "source_language": source_language,
        "target_language": target_language,
    })

    # Send SQS message
    sqs.send_message(
        QueueUrl=QUEUE_URL,
        MessageBody=json.dumps({
            "job_id": job_id,
            "input_bucket": S3_BUCKET,
            "input_key": s3_key,
            "source_language": source_language,
            "target_language": target_language,
            "pipeline_version": "whisper-nllb-v2",
        }),
        MessageGroupId="asr-jobs",
        MessageDeduplicationId=job_id,
    )

    # Update status to QUEUED
    table.update_item(
        Key={"job_id": job_id},
        UpdateExpression="SET #s = :s, updated_at = :t",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":s": "QUEUED", ":t": now},
    )

    return response(200, {
        "job_id": job_id,
        "upload_url": presigned_url,
        "s3_key": s3_key,
        "status": "QUEUED",
        "instructions": {
            "upload": f"PUT audio to upload_url with Content-Type: {content_type}",
            "poll": f"GET /status/{job_id} every 3s",
        },
    })


def handle_status(job_id):
    if not job_id or len(job_id) < 10:
        return response(400, {"error": "Invalid job_id"})

    resp = table.get_item(Key={"job_id": job_id})
    item = resp.get("Item")

    if not item:
        # Fallback: check S3 status.json for backward compat
        try:
            obj = s3.get_object(Bucket=S3_BUCKET, Key=f"jobs/{job_id}/status.json")
            status_data = json.loads(obj["Body"].read().decode("utf-8"))
            return response(200, status_data)
        except Exception:
            return response(404, {"error": "Job not found", "job_id": job_id})

    # Map DynamoDB status to frontend-compatible format
    status_map = {
        "UPLOADED": "processing",
        "QUEUED": "processing",
        "PROCESSING": "processing",
        "COMPLETED": "done",
        "FAILED": "failed",
    }

    result = {
        "job_id": job_id,
        "status": status_map.get(item.get("status"), item.get("status", "unknown")),
        "stage": item.get("stage", ""),
        "progress": int(item.get("progress", 0)),
        "created_at": item.get("created_at", ""),
        "updated_at": item.get("updated_at", ""),
    }

    if item.get("status") == "COMPLETED":
        result["result_key"] = item.get("result_key", "")
        result["duration"] = float(item.get("duration", 0))
        result["processing_time"] = float(item.get("processing_time", 0))
        result["completed_at"] = item.get("completed_at", "")

    if item.get("status") == "FAILED":
        result["error"] = item.get("error", "Unknown error")

    return response(200, result)


def handle_result(job_id):
    if not job_id or len(job_id) < 10:
        return response(400, {"error": "Invalid job_id"})

    result_key = f"results/{job_id}.json"
    try:
        obj = s3.get_object(Bucket=S3_BUCKET, Key=result_key)
        result_body = obj["Body"].read().decode("utf-8")
        return response(200, json.loads(result_body))
    except s3.exceptions.NoSuchKey:
        return response(404, {"error": "Result not ready", "job_id": job_id})
    except Exception as e:
        return response(500, {"error": str(e)})


def response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": HEADERS,
        "body": json.dumps(body, ensure_ascii=False),
    }
