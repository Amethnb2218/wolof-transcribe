"""Lambda: S3 upload triggers AWS Batch transcription job."""
import json
import os
import boto3
import uuid

batch = boto3.client("batch")
s3 = boto3.client("s3")

JOB_QUEUE = os.environ.get("JOB_QUEUE", "wolof-transcription-queue")
JOB_DEFINITION = os.environ.get("JOB_DEFINITION", "wolof-transcribe-gpu")
S3_BUCKET = os.environ.get("S3_BUCKET", "wolof-transcriber-audio")


def lambda_handler(event, context):
    record = event["Records"][0]
    bucket = record["s3"]["bucket"]["name"]
    key = record["s3"]["object"]["key"]

    parts = key.split("/")
    if len(parts) >= 3:
        job_id = parts[1]
    else:
        job_id = str(uuid.uuid4())

    result_key = f"results/{job_id}.json"

    s3.put_object(
        Bucket=bucket,
        Key=f"jobs/{job_id}/status.json",
        Body=json.dumps({"status": "submitted", "audio_key": key, "job_id": job_id}),
        ContentType="application/json",
    )

    response = batch.submit_job(
        jobName=f"wolof-{job_id[:8]}",
        jobQueue=JOB_QUEUE,
        jobDefinition=JOB_DEFINITION,
        containerOverrides={
            "environment": [
                {"name": "AUDIO_KEY", "value": key},
                {"name": "RESULT_KEY", "value": result_key},
                {"name": "JOB_ID", "value": job_id},
                {"name": "S3_BUCKET", "value": bucket},
            ]
        },
    )

    s3.put_object(
        Bucket=bucket,
        Key=f"jobs/{job_id}/status.json",
        Body=json.dumps({
            "status": "submitted",
            "batch_job_id": response["jobId"],
            "audio_key": key,
            "job_id": job_id,
            "result_key": result_key,
        }),
        ContentType="application/json",
    )

    return {"statusCode": 200, "body": json.dumps({"job_id": job_id, "batch_job_id": response["jobId"]})}
