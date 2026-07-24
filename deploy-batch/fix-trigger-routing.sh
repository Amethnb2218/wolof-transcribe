#!/bin/bash
# DEFINITIVE FIX: Lambda trigger routes short audio to mini-server, long to Kaggle
set -e

REGION=us-east-1
ACCOUNT=335596040822
S3_BUCKET="wolof-transcriber-audio"
MINI_IP="52.91.36.73"
KAGGLE_USERNAME="amethsl"
KAGGLE_TOKEN="${KAGGLE_TOKEN:-}"
AWS_KEY_FOR_KAGGLE="${AWS_KEY_FOR_KAGGLE:-AKIAU4IYVGJ3M3SFVVNK}"
AWS_SECRET_FOR_KAGGLE="${AWS_SECRET_FOR_KAGGLE:-}"

if [ -z "$KAGGLE_TOKEN" ]; then
  read -p "Kaggle Token: " KAGGLE_TOKEN
fi
if [ -z "$AWS_SECRET_FOR_KAGGLE" ]; then
  read -p "AWS Secret Key (for Kaggle): " AWS_SECRET_FOR_KAGGLE
fi

echo "=== FIX TRIGGER ROUTING ==="

cd /tmp
rm -rf trigger-fix
mkdir trigger-fix && cd trigger-fix

cat > index.py << 'PYEOF'
import json
import os
import urllib.request
import boto3
import tempfile

s3 = boto3.client("s3")

KAGGLE_USERNAME = os.environ.get("KAGGLE_USERNAME", "")
KAGGLE_TOKEN = os.environ.get("KAGGLE_TOKEN", "")
S3_BUCKET = os.environ.get("S3_BUCKET", "wolof-transcriber-audio")
AWS_KEY_FOR_KAGGLE = os.environ.get("AWS_KEY_FOR_KAGGLE", "")
AWS_SECRET_FOR_KAGGLE = os.environ.get("AWS_SECRET_FOR_KAGGLE", "")
MINI_SERVER = os.environ.get("MINI_SERVER", "http://52.91.36.73:8080")

SHORT_THRESHOLD = 50 * 1024 * 1024  # 50 MB


def lambda_handler(event, context):
    for record in event.get("Records", []):
        key = record["s3"]["object"]["key"]
        size = record["s3"]["object"].get("size", 0)
        if not key.startswith("uploads/"):
            continue

        parts = key.split("/")
        if len(parts) < 3:
            continue
        job_id = parts[1]

        print(f"New upload: {key}, size: {size}, job_id: {job_id}")

        if size < SHORT_THRESHOLD:
            print(f"SHORT audio ({size} bytes) -> mini-server")
            transcribe_via_mini(job_id, key)
        else:
            print(f"LONG audio ({size} bytes) -> Kaggle GPU")
            s3.put_object(
                Bucket=S3_BUCKET,
                Key=f"jobs/{job_id}/status.json",
                Body=json.dumps({"status": "queued_kaggle", "job_id": job_id}),
            )
            trigger_kaggle(job_id, key)

    return {"statusCode": 200}


def transcribe_via_mini(job_id, audio_key):
    """Send audio to mini-server and write result to S3."""
    try:
        s3.put_object(
            Bucket=S3_BUCKET,
            Key=f"jobs/{job_id}/status.json",
            Body=json.dumps({"status": "transcribing", "job_id": job_id}),
        )

        # Download from S3
        tmp_path = f"/tmp/{job_id}.audio"
        s3.download_file(S3_BUCKET, audio_key, tmp_path)

        with open(tmp_path, "rb") as f:
            audio_bytes = f.read()
        os.unlink(tmp_path)

        print(f"Downloaded {len(audio_bytes)} bytes, sending to mini-server...")

        # Send to mini-server
        req = urllib.request.Request(
            MINI_SERVER + "/",
            data=audio_bytes,
            headers={"Content-Type": "audio/mpeg"},
            method="POST",
        )
        resp = urllib.request.urlopen(req, timeout=290)
        result = json.loads(resp.read().decode())

        print(f"Mini-server response: {len(result.get('text', ''))} chars, {len(result.get('segments', []))} segments")

        # Write result to S3
        result["job_id"] = job_id
        result["device"] = "cpu-mini"
        s3.put_object(
            Bucket=S3_BUCKET,
            Key=f"results/{job_id}.json",
            Body=json.dumps(result, ensure_ascii=False),
            ContentType="application/json",
        )
        s3.put_object(
            Bucket=S3_BUCKET,
            Key=f"jobs/{job_id}/status.json",
            Body=json.dumps({"status": "done", "job_id": job_id, "device": "cpu-mini"}),
        )
        print(f"DONE via mini-server")

    except Exception as e:
        print(f"Mini-server failed: {e}")
        s3.put_object(
            Bucket=S3_BUCKET,
            Key=f"jobs/{job_id}/status.json",
            Body=json.dumps({"status": "failed", "error": str(e), "job_id": job_id}),
        )


def trigger_kaggle(job_id, audio_key):
    """Push a Kaggle kernel for long audio transcription."""
    script = f'''import os, subprocess, sys
os.environ["JOB_ID"] = "{job_id}"
os.environ["AUDIO_KEY"] = "{audio_key}"
os.environ["S3_BUCKET"] = "{S3_BUCKET}"
os.environ["AWS_ACCESS_KEY_ID"] = "{AWS_KEY_FOR_KAGGLE}"
os.environ["AWS_SECRET_ACCESS_KEY"] = "{AWS_SECRET_FOR_KAGGLE}"
os.environ["AWS_REGION"] = "us-east-1"

subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", "faster-whisper", "transformers", "sentencepiece", "boto3"])

import json, time, torch, boto3
from faster_whisper import WhisperModel
from transformers import AutoTokenizer, AutoModelForSeq2SeqLM

s3 = boto3.client("s3", aws_access_key_id="{AWS_KEY_FOR_KAGGLE}", aws_secret_access_key="{AWS_SECRET_FOR_KAGGLE}", region_name="us-east-1")

def update_status(status, **extra):
    s3.put_object(Bucket="{S3_BUCKET}", Key=f"jobs/{job_id}/status.json",
        Body=json.dumps({{"status": status, "job_id": "{job_id}", **extra}}))
    print(f"[STATUS] {{status}}", flush=True)

update_status("downloading")
ext = "{audio_key}".rsplit(".", 1)[-1] if "." in "{audio_key}" else "mp3"
local_audio = f"/tmp/audio.{{ext}}"
s3.download_file("{S3_BUCKET}", "{audio_key}", local_audio)
print(f"Downloaded: {{os.path.getsize(local_audio)/1024/1024:.1f}} MB", flush=True)

update_status("transcribing")
start = time.time()
model = WhisperModel("momosl/whisper-wolof-v2-ct2", device="cuda", compute_type="float16")
segs, info = model.transcribe(local_audio, beam_size=5, language="wo", vad_filter=True, vad_parameters=dict(min_silence_duration_ms=500))
segments = []
for s in segs:
    segments.append({{"start": round(s.start, 2), "end": round(s.end, 2), "text": s.text.strip()}})
text = " ".join(s["text"] for s in segments)
txn_time = time.time() - start
print(f"Transcribed: {{len(segments)}} segments, {{info.duration:.0f}}s audio in {{txn_time:.0f}}s ({{info.duration/txn_time:.1f}}x)", flush=True)

update_status("translating")
tok = AutoTokenizer.from_pretrained("facebook/nllb-200-distilled-600M")
nllb = AutoModelForSeq2SeqLM.from_pretrained("facebook/nllb-200-distilled-600M").to("cuda")
tok.src_lang = "wol_Latn"
tgt_id = tok.convert_tokens_to_ids("fra_Latn")
for i in range(0, len(segments), 8):
    batch = segments[i:i+8]
    inp = tok([s["text"] for s in batch], return_tensors="pt", padding=True, truncation=True, max_length=512).to("cuda")
    with torch.no_grad():
        gen = nllb.generate(**inp, forced_bos_token_id=tgt_id, max_new_tokens=256)
    trans = tok.batch_decode(gen, skip_special_tokens=True)
    for s, t in zip(batch, trans):
        s["translation"] = t
print(f"Translated: {{len(segments)}} segments", flush=True)

total_time = time.time() - start
result = {{"text": text, "translation": " ".join(s.get("translation","") for s in segments),
    "segments": segments, "duration": info.duration, "processing_time": total_time,
    "device": "gpu-t4-kaggle", "speed_factor": round(info.duration/txn_time, 1), "job_id": "{job_id}"}}
s3.put_object(Bucket="{S3_BUCKET}", Key=f"results/{job_id}.json",
    Body=json.dumps(result, ensure_ascii=False), ContentType="application/json")
update_status("done", processing_time=total_time, speed_factor=result["speed_factor"])
print(f"DONE: {{info.duration:.0f}}s audio in {{total_time:.0f}}s ({{result[\\'speed_factor\\']}}x realtime)")
'''

    headers_dict = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {KAGGLE_TOKEN}",
    }

    payload = json.dumps({
        "title": f"wolof-job-{job_id[:8]}",
        "text": script,
        "language": "python",
        "kernel_type": "script",
        "is_private": True,
        "enable_gpu": True,
        "enable_internet": True,
    }).encode()

    req = urllib.request.Request(
        "https://www.kaggle.com/api/v1/kernels/push",
        data=payload,
        headers=headers_dict,
        method="POST",
    )

    try:
        resp = urllib.request.urlopen(req, timeout=30)
        result = json.loads(resp.read().decode())
        print(f"Kaggle kernel pushed: {result}")
        s3.put_object(
            Bucket=S3_BUCKET,
            Key=f"jobs/{job_id}/status.json",
            Body=json.dumps({"status": "running_kaggle", "job_id": job_id, "kernel": result}),
        )
        return result
    except Exception as e:
        print(f"Error pushing kernel: {e}")
        s3.put_object(
            Bucket=S3_BUCKET,
            Key=f"jobs/{job_id}/status.json",
            Body=json.dumps({"status": "failed", "error": str(e), "job_id": job_id}),
        )
        raise
PYEOF

zip -j trigger-fix.zip index.py

echo "[1/3] Updating trigger Lambda code..."
aws lambda update-function-code \
  --function-name wolof-batch-trigger \
  --zip-file fileb://trigger-fix.zip \
  --region $REGION > /dev/null

echo "  Waiting..."
aws lambda wait function-updated --function-name wolof-batch-trigger --region $REGION

echo "[2/3] Updating trigger Lambda config..."
aws lambda update-function-configuration \
  --function-name wolof-batch-trigger \
  --environment "Variables={KAGGLE_USERNAME=$KAGGLE_USERNAME,KAGGLE_TOKEN=$KAGGLE_TOKEN,S3_BUCKET=$S3_BUCKET,AWS_KEY_FOR_KAGGLE=$AWS_KEY_FOR_KAGGLE,AWS_SECRET_FOR_KAGGLE=$AWS_SECRET_FOR_KAGGLE,MINI_SERVER=http://$MINI_IP:8080}" \
  --timeout 300 \
  --memory-size 256 \
  --region $REGION > /dev/null

echo "  Done"

echo ""
echo "[3/3] Also updating API Lambda (API Gateway URL)..."
# Make sure wolof-batch-api has the correct API Gateway URL
API_URL="https://d8x2g8k8bh.execute-api.us-east-1.amazonaws.com/"
echo "  API: $API_URL"

echo ""
echo "=== ROUTING FIXED ==="
echo ""
echo "  Audio < 50 MB -> mini-server (http://$MINI_IP:8080) -> result in S3 (~5s)"
echo "  Audio > 50 MB -> Kaggle T4 GPU -> result in S3 (~10 min)"
echo ""
echo "  Frontend polls GET /status/{id} then GET /result/{id}"
echo "  Both routes write result to s3://\$S3_BUCKET/results/{id}.json"
echo ""
echo "  Test: upload a short audio from the site"
