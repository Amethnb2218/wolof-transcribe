#!/bin/bash
# Setup Kaggle GPU backend - ONE COMMAND
set -e

REGION=us-east-1
ACCOUNT=335596040822
S3_BUCKET="wolof-transcriber-audio"

# Credentials are read from environment or prompted
KAGGLE_USERNAME="${KAGGLE_USERNAME:-amethsl}"
KAGGLE_TOKEN="${KAGGLE_TOKEN:-}"
AWS_KEY_FOR_KAGGLE="${AWS_KEY_FOR_KAGGLE:-}"
AWS_SECRET_FOR_KAGGLE="${AWS_SECRET_FOR_KAGGLE:-}"

if [ -z "$KAGGLE_TOKEN" ]; then
  read -p "Kaggle API Token: " KAGGLE_TOKEN
fi
if [ -z "$AWS_KEY_FOR_KAGGLE" ]; then
  read -p "AWS Access Key (for Kaggle): " AWS_KEY_FOR_KAGGLE
fi
if [ -z "$AWS_SECRET_FOR_KAGGLE" ]; then
  read -p "AWS Secret Key (for Kaggle): " AWS_SECRET_FOR_KAGGLE
fi

echo "=== KAGGLE GPU SETUP ==="

# ============================================
echo ""
echo "[1/4] Update Lambda trigger (Kaggle mode)..."

cd /tmp
rm -rf kaggle-lambda
mkdir kaggle-lambda && cd kaggle-lambda

cat > index.py << 'PYEOF'
import json
import os
import base64
import urllib.request
import boto3

s3 = boto3.client("s3")

KAGGLE_USERNAME = os.environ["KAGGLE_USERNAME"]
KAGGLE_TOKEN = os.environ["KAGGLE_TOKEN"]
S3_BUCKET = os.environ["S3_BUCKET"]
AWS_KEY_FOR_KAGGLE = os.environ["AWS_KEY_FOR_KAGGLE"]
AWS_SECRET_FOR_KAGGLE = os.environ["AWS_SECRET_FOR_KAGGLE"]


def lambda_handler(event, context):
    for record in event.get("Records", []):
        key = record["s3"]["object"]["key"]
        if not key.startswith("uploads/"):
            continue

        parts = key.split("/")
        if len(parts) < 3:
            continue
        job_id = parts[1]

        print(f"New upload: {key}, job_id: {job_id}")

        s3.put_object(
            Bucket=S3_BUCKET,
            Key=f"jobs/{job_id}/status.json",
            Body=json.dumps({"status": "queued_kaggle", "job_id": job_id}),
        )

        trigger_kaggle(job_id, key)

    return {"statusCode": 200}


def trigger_kaggle(job_id, audio_key):
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

    headers = {
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
        f"https://www.kaggle.com/api/v1/kernels/push",
        data=payload,
        headers=headers,
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
        if hasattr(e, 'read'):
            print(f"Response: {e.read().decode()}")
        s3.put_object(
            Bucket=S3_BUCKET,
            Key=f"jobs/{job_id}/status.json",
            Body=json.dumps({"status": "failed", "error": str(e), "job_id": job_id}),
        )
        raise
PYEOF

zip -j kaggle-trigger.zip index.py

aws lambda update-function-code \
  --function-name wolof-batch-trigger \
  --zip-file fileb://kaggle-trigger.zip \
  --region $REGION > /dev/null

aws lambda update-function-configuration \
  --function-name wolof-batch-trigger \
  --environment "Variables={KAGGLE_USERNAME=$KAGGLE_USERNAME,KAGGLE_TOKEN=$KAGGLE_TOKEN,S3_BUCKET=$S3_BUCKET,AWS_KEY_FOR_KAGGLE=$AWS_KEY_FOR_KAGGLE,AWS_SECRET_FOR_KAGGLE=$AWS_SECRET_FOR_KAGGLE}" \
  --timeout 60 \
  --region $REGION > /dev/null

echo "  Lambda trigger updated (Kaggle GPU mode)"

# ============================================
echo ""
echo "[2/4] Test Kaggle API connection..."

RESULT=$(curl -s -X GET "https://www.kaggle.com/api/v1/kernels/list?user=amethsl" \
  -H "Authorization: Bearer $KAGGLE_TOKEN")
echo "  API response: $(echo $RESULT | head -c 200)"

# ============================================
echo ""
echo "[3/4] Quick test: push a GPU kernel..."

TEST_PAYLOAD=$(cat << 'EOF'
{
  "title": "wolof-gpu-test",
  "text": "import torch; print(f'CUDA: {torch.cuda.is_available()}, GPUs: {torch.cuda.device_count()}'); print('TEST OK')",
  "language": "python",
  "kernel_type": "script",
  "is_private": true,
  "enable_gpu": true,
  "enable_internet": true
}
EOF
)

TEST_RESULT=$(curl -s -X POST "https://www.kaggle.com/api/v1/kernels/push" \
  -H "Authorization: Bearer $KAGGLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$TEST_PAYLOAD")
echo "  Test push: $TEST_RESULT"

# ============================================
echo ""
echo "[4/4] Verify S3 trigger is connected..."

# Check if S3 notification exists
NOTIF=$(aws s3api get-bucket-notification-configuration --bucket $S3_BUCKET --region $REGION 2>/dev/null || echo "{}")
if echo "$NOTIF" | grep -q "wolof-batch-trigger"; then
  echo "  S3 trigger: OK (connected to Lambda)"
else
  echo "  Adding S3 trigger..."
  LAMBDA_ARN="arn:aws:lambda:$REGION:$ACCOUNT:function:wolof-batch-trigger"

  aws lambda add-permission \
    --function-name wolof-batch-trigger \
    --statement-id s3-trigger-kaggle \
    --action lambda:InvokeFunction \
    --principal s3.amazonaws.com \
    --source-arn "arn:aws:s3:::$S3_BUCKET" \
    --region $REGION 2>/dev/null || true

  aws s3api put-bucket-notification-configuration \
    --bucket $S3_BUCKET \
    --notification-configuration "{
      \"LambdaFunctionConfigurations\": [{
        \"LambdaFunctionArn\": \"$LAMBDA_ARN\",
        \"Events\": [\"s3:ObjectCreated:*\"],
        \"Filter\": {\"Key\": {\"FilterRules\": [{\"Name\": \"prefix\", \"Value\": \"uploads/\"}]}}
      }]
    }" \
    --region $REGION
  echo "  S3 trigger: ADDED"
fi

# ============================================
echo ""
echo "============================================"
echo "=== KAGGLE GPU SETUP COMPLETE ==="
echo "============================================"
echo ""
echo "Architecture:"
echo "  Frontend upload -> S3 -> Lambda -> Kaggle T4 x2 GPU"
echo "  Kaggle transcribes (Whisper) + translates (NLLB) -> Result in S3"
echo "  Frontend polls status -> displays result"
echo ""
echo "Performance:"
echo "  6h audio -> ~15 min (T4 GPU float16)"
echo "  1h audio -> ~3 min"
echo "  10 min   -> ~30 sec"
echo ""
echo "Cost: \$0/month (Kaggle free tier: 30h GPU/week)"
echo ""
echo "Test: upload any audio via the frontend or:"
echo "  aws s3 cp test.mp3 s3://$S3_BUCKET/uploads/test-$(date +%s)/audio.mp3"
