"""
API Lambda — Wolof ASR S3 Pipeline
Provides presigned upload URLs and job status polling.

Endpoints:
  POST /upload        -> Returns presigned S3 URL + job_id
  GET  /status/{id}   -> Returns job status + result if done
  OPTIONS /*          -> CORS preflight
"""
import os
import json
import uuid
import boto3

S3_BUCKET = os.environ.get("S3_BUCKET", "wolof-asr-audio-335596040822")
UPLOAD_EXPIRY = 3600  # 1 hour presigned URL validity

s3 = boto3.client("s3")

HEADERS = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
}


def lambda_handler(event, context):
    """Route requests based on path and method."""
    # Handle Function URL or API Gateway event formats
    request_context = event.get("requestContext", {})
    http_info = request_context.get("http", {})

    method = http_info.get("method", event.get("httpMethod", "GET"))
    path = http_info.get("path", event.get("rawPath", event.get("path", "/")))

    print(f"Request: {method} {path}")

    # CORS preflight
    if method == "OPTIONS":
        return response(200, {"message": "OK"})

    # Route
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
    # Parse body for optional filename/content_type
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

    # Sanitize filename
    filename = filename.replace("/", "_").replace("\\", "_")

    # Generate unique job ID
    job_id = str(uuid.uuid4())

    # S3 key for upload
    s3_key = f"uploads/{job_id}/{filename}"

    # Generate presigned PUT URL
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
        "instructions": {
            "upload": f"PUT the audio file to upload_url with Content-Type: {content_type}",
            "poll": f"GET /status/{job_id} to check progress",
        },
    })


def handle_status(job_id):
    """Get job status and result if done."""
    if not job_id or len(job_id) < 10:
        return response(400, {"error": "Invalid job_id"})

    # Read status file
    status_key = f"jobs/{job_id}/status.json"
    try:
        obj = s3.get_object(Bucket=S3_BUCKET, Key=status_key)
        status_data = json.loads(obj["Body"].read().decode("utf-8"))
    except s3.exceptions.NoSuchKey:
        return response(404, {"error": "Job not found", "job_id": job_id})
    except Exception as e:
        return response(500, {"error": f"Failed to read status: {e}"})

    # If done, include result URL (presigned GET)
    if status_data.get("status") == "done":
        result_key = status_data.get("result_key", f"results/{job_id}.json")
        result_url = s3.generate_presigned_url(
            "get_object",
            Params={"Bucket": S3_BUCKET, "Key": result_key},
            ExpiresIn=3600,
        )
        status_data["result_url"] = result_url

        # Optionally include the result inline if small enough
        try:
            result_obj = s3.get_object(Bucket=S3_BUCKET, Key=result_key)
            result_body = result_obj["Body"].read().decode("utf-8")
            if len(result_body) < 5 * 1024 * 1024:  # < 5MB inline
                status_data["result"] = json.loads(result_body)
        except Exception:
            pass  # Result URL is still available

    return response(200, status_data)


def response(status_code, body):
    """Build Lambda response."""
    return {
        "statusCode": status_code,
        "headers": HEADERS,
        "body": json.dumps(body, ensure_ascii=False),
    }
