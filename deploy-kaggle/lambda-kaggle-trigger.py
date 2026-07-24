"""Lambda: Triggers Kaggle kernel for transcription when audio is uploaded to S3."""
import json
import os
import subprocess
import tempfile
import boto3
import urllib.request

KAGGLE_USERNAME = os.environ.get("KAGGLE_USERNAME", "")
KAGGLE_KEY = os.environ.get("KAGGLE_KEY", "")
S3_BUCKET = os.environ.get("S3_BUCKET", "wolof-transcriber-audio")
KERNEL_SLUG = os.environ.get("KERNEL_SLUG", "")  # username/wolof-transcriber-gpu

s3 = boto3.client("s3")


def lambda_handler(event, context):
    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = record["s3"]["object"]["key"]

        if not key.startswith("uploads/"):
            continue

        # Extract job_id from key: uploads/{job_id}/audio.ext
        parts = key.split("/")
        if len(parts) < 3:
            continue
        job_id = parts[1]

        print(f"New upload: {key}, job_id: {job_id}")

        # Update status to queued
        s3.put_object(
            Bucket=bucket,
            Key=f"jobs/{job_id}/status.json",
            Body=json.dumps({"status": "queued", "job_id": job_id}),
        )

        # Push kernel with environment variables via Kaggle API
        trigger_kaggle_kernel(job_id, key)

    return {"statusCode": 200}


def trigger_kaggle_kernel(job_id, audio_key):
    """Trigger Kaggle kernel execution via REST API."""
    import base64

    auth = base64.b64encode(f"{KAGGLE_USERNAME}:{KAGGLE_KEY}".encode()).decode()

    payload = json.dumps({
        "id": KERNEL_SLUG,
        "newTitle": f"wolof-job-{job_id[:8]}",
        "text": generate_kernel_script(job_id, audio_key),
        "language": "python",
        "kernelType": "script",
        "isPrivate": True,
        "enableGpu": True,
        "enableInternet": True,
    }).encode()

    req = urllib.request.Request(
        "https://www.kaggle.com/api/v1/kernels/push",
        data=payload,
        headers={
            "Authorization": f"Basic {auth}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        resp = urllib.request.urlopen(req, timeout=30)
        result = json.loads(resp.read().decode())
        print(f"Kaggle kernel pushed: {result}")
        return result
    except Exception as e:
        print(f"Error pushing kernel: {e}")
        s3.put_object(
            Bucket=S3_BUCKET,
            Key=f"jobs/{job_id}/status.json",
            Body=json.dumps({"status": "failed", "error": str(e), "job_id": job_id}),
        )
        raise


def generate_kernel_script(job_id, audio_key):
    """Generate the kernel script with job-specific env vars injected."""
    return f'''import os
os.environ["JOB_ID"] = "{job_id}"
os.environ["AUDIO_KEY"] = "{audio_key}"
os.environ["S3_BUCKET"] = "{S3_BUCKET}"

# The rest is pulled from Kaggle Secrets (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)
exec(open("/kaggle/input/wolof-transcriber-script/kaggle-kernel.py").read())
'''
