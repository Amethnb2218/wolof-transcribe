"""API Lambda: presigned upload URL + job status + results."""
import json
import os
import uuid
import boto3

s3 = boto3.client("s3")

S3_BUCKET = os.environ.get("S3_BUCKET", "wolof-transcriber-audio")


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

        return {
            "statusCode": 200,
            "headers": headers,
            "body": json.dumps({
                "job_id": job_id,
                "upload_url": presigned,
                "audio_key": audio_key,
            }),
        }

    # GET /status/{job_id}
    if "/status/" in path:
        job_id = path.split("/status/")[-1].strip("/")
        try:
            obj = s3.get_object(Bucket=S3_BUCKET, Key=f"jobs/{job_id}/status.json")
            status_data = json.loads(obj["Body"].read())
            return {"statusCode": 200, "headers": headers, "body": json.dumps(status_data)}
        except s3.exceptions.NoSuchKey:
            return {"statusCode": 200, "headers": headers, "body": json.dumps({"status": "pending", "job_id": job_id})}

    # GET /result/{job_id}
    if "/result/" in path:
        job_id = path.split("/result/")[-1].strip("/")
        try:
            obj = s3.get_object(Bucket=S3_BUCKET, Key=f"results/{job_id}.json")
            result_data = obj["Body"].read().decode("utf-8")
            return {"statusCode": 200, "headers": headers, "body": result_data}
        except s3.exceptions.NoSuchKey:
            return {"statusCode": 404, "headers": headers, "body": json.dumps({"error": "Result not ready"})}

    # GET /health
    if "/health" in path:
        return {"statusCode": 200, "headers": headers, "body": json.dumps({"status": "ok", "mode": "batch"})}

    return {"statusCode": 404, "headers": headers, "body": json.dumps({"error": "Not found"})}
