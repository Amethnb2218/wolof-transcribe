#!/bin/bash
# Setup: Kaggle GPU backend for Wolof Transcriber
# Run on CloudShell AFTER setup-batch.sh
set -e

REGION=us-east-1
ACCOUNT=335596040822
S3_BUCKET="wolof-transcriber-audio"

echo "=== KAGGLE GPU SETUP ==="
echo ""
echo "Pre-requisites (do these first on kaggle.com):"
echo "  1. Go to kaggle.com/settings -> API -> Create New Token"
echo "     This downloads kaggle.json with your username + key"
echo "  2. Go to kaggle.com/settings -> Secrets -> Add secrets:"
echo "     - AWS_ACCESS_KEY_ID"
echo "     - AWS_SECRET_ACCESS_KEY"
echo "  3. Upload the kernel script as a Kaggle Dataset"
echo ""
read -p "Enter your Kaggle username: " KAGGLE_USERNAME
read -p "Enter your Kaggle API key: " KAGGLE_KEY

if [ -z "$KAGGLE_USERNAME" ] || [ -z "$KAGGLE_KEY" ]; then
  echo "ERROR: Kaggle username and key required!"
  exit 1
fi

KERNEL_SLUG="${KAGGLE_USERNAME}/wolof-transcriber-gpu"
echo ""
echo "  Username: $KAGGLE_USERNAME"
echo "  Kernel: $KERNEL_SLUG"

# ============================================
echo ""
echo "[1/5] Create IAM user for Kaggle S3 access..."

aws iam create-user --user-name kaggle-wolof-s3 --region $REGION 2>/dev/null || true
aws iam put-user-policy --user-name kaggle-wolof-s3 --policy-name s3-access --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Action\": [\"s3:GetObject\", \"s3:PutObject\", \"s3:ListBucket\"],
    \"Resource\": [\"arn:aws:s3:::$S3_BUCKET\", \"arn:aws:s3:::$S3_BUCKET/*\"]
  }]
}"

# Check if keys already exist
EXISTING_KEYS=$(aws iam list-access-keys --user-name kaggle-wolof-s3 --query 'AccessKeyMetadata[0].AccessKeyId' --output text 2>/dev/null || echo "None")
if [ "$EXISTING_KEYS" == "None" ] || [ -z "$EXISTING_KEYS" ]; then
  KEYS=$(aws iam create-access-key --user-name kaggle-wolof-s3 --output json)
  KAGGLE_AWS_KEY=$(echo "$KEYS" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKey']['AccessKeyId'])")
  KAGGLE_AWS_SECRET=$(echo "$KEYS" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKey']['SecretAccessKey'])")
  echo "  IAM user created. SAVE THESE (shown once):"
  echo "    AWS_ACCESS_KEY_ID: $KAGGLE_AWS_KEY"
  echo "    AWS_SECRET_ACCESS_KEY: $KAGGLE_AWS_SECRET"
  echo ""
  echo "  >>> Add these as Kaggle Secrets NOW (kaggle.com/settings -> Secrets) <<<"
  echo ""
  read -p "  Press Enter when done..."
else
  echo "  IAM user exists (keys already created)"
  KAGGLE_AWS_KEY="(already exists)"
fi

# ============================================
echo ""
echo "[2/5] Upload kernel script as Kaggle Dataset..."

cd /tmp
rm -rf wolof-kaggle-dataset
mkdir -p wolof-kaggle-dataset
cd wolof-kaggle-dataset

# Create dataset metadata
cat > dataset-metadata.json << EOF
{
  "title": "wolof-transcriber-script",
  "id": "${KAGGLE_USERNAME}/wolof-transcriber-script",
  "licenses": [{"name": "CC0-1.0"}]
}
EOF

# Copy kernel script
cp ~/wolof-transcribe/deploy-kaggle/kaggle-kernel.py .

# Upload dataset via API
echo "  Uploading kernel script to Kaggle Datasets..."
curl -s -X POST "https://www.kaggle.com/api/v1/datasets/create/new" \
  -u "${KAGGLE_USERNAME}:${KAGGLE_KEY}" \
  -F "body=@dataset-metadata.json;type=application/json" \
  -F "files=@kaggle-kernel.py" > /dev/null 2>&1 || \
curl -s -X POST "https://www.kaggle.com/api/v1/datasets/${KAGGLE_USERNAME}/wolof-transcriber-script/new-version" \
  -u "${KAGGLE_USERNAME}:${KAGGLE_KEY}" \
  -F "body={\"versionNotes\":\"update\"};type=application/json" \
  -F "files=@kaggle-kernel.py" > /dev/null 2>&1 || true
echo "  Done (or upload manually: kaggle.com -> Datasets -> New Dataset)"

# ============================================
echo ""
echo "[3/5] Update Lambda trigger to use Kaggle..."

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

KAGGLE_USERNAME = os.environ.get("KAGGLE_USERNAME", "")
KAGGLE_KEY = os.environ.get("KAGGLE_KEY", "")
S3_BUCKET = os.environ.get("S3_BUCKET", "wolof-transcriber-audio")
KERNEL_SLUG = os.environ.get("KERNEL_SLUG", "")


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
    auth = base64.b64encode(f"{KAGGLE_USERNAME}:{KAGGLE_KEY}".encode()).decode()

    script = f'''import os
os.environ["JOB_ID"] = "{job_id}"
os.environ["AUDIO_KEY"] = "{audio_key}"
os.environ["S3_BUCKET"] = "{S3_BUCKET}"

import subprocess, sys
subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", "faster-whisper", "transformers", "sentencepiece", "boto3"])

import json, time, torch, boto3
from faster_whisper import WhisperModel
from transformers import AutoTokenizer, AutoModelForSeq2SeqLM
from kaggle_secrets import UserSecretsClient

secrets = UserSecretsClient()
s3 = boto3.client("s3",
    aws_access_key_id=secrets.get_secret("AWS_ACCESS_KEY_ID"),
    aws_secret_access_key=secrets.get_secret("AWS_SECRET_ACCESS_KEY"),
    region_name="us-east-1")

def update_status(status, **extra):
    s3.put_object(Bucket="{S3_BUCKET}", Key=f"jobs/{job_id}/status.json",
        Body=json.dumps({{"status": status, "job_id": "{job_id}", **extra}}))
    print(f"[STATUS] {{status}}", flush=True)

update_status("downloading")
local_audio = "/tmp/audio." + "{audio_key}".rsplit(".", 1)[-1]
s3.download_file("{S3_BUCKET}", "{audio_key}", local_audio)

update_status("transcribing")
start = time.time()
model = WhisperModel("momosl/whisper-wolof-v2-ct2", device="cuda", compute_type="float16")
segs, info = model.transcribe(local_audio, beam_size=5, language="wo", vad_filter=True)
segments = [{{"start": round(s.start,2), "end": round(s.end,2), "text": s.text.strip()}} for s in segs]
text = " ".join(s["text"] for s in segments)
txn_time = time.time() - start

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

total_time = time.time() - start
result = {{"text": text, "translation": " ".join(s.get("translation","") for s in segments),
    "segments": segments, "duration": info.duration, "processing_time": total_time,
    "device": "gpu-t4-kaggle", "speed_factor": round(info.duration/txn_time, 1), "job_id": "{job_id}"}}
s3.put_object(Bucket="{S3_BUCKET}", Key=f"results/{job_id}.json",
    Body=json.dumps(result, ensure_ascii=False), ContentType="application/json")
update_status("done", processing_time=total_time, speed_factor=result["speed_factor"])
print(f"DONE: {{info.duration:.0f}}s audio in {{total_time:.0f}}s ({{result[\\'speed_factor\\']}}x)")
'''

    payload = json.dumps({
        "id": KERNEL_SLUG,
        "newTitle": f"wolof-job-{job_id[:8]}",
        "text": script,
        "language": "python",
        "kernelType": "script",
        "isPrivate": True,
        "enableGpu": True,
        "enableInternet": True,
    }).encode()

    req = urllib.request.Request(
        "https://www.kaggle.com/api/v1/kernels/push",
        data=payload,
        headers={"Authorization": f"Basic {auth}", "Content-Type": "application/json"},
        method="POST",
    )

    resp = urllib.request.urlopen(req, timeout=30)
    result = json.loads(resp.read().decode())
    print(f"Kaggle kernel pushed: {result}")
    return result
PYEOF

zip -j kaggle-trigger.zip index.py

# Update existing trigger Lambda
aws lambda update-function-code \
  --function-name wolof-batch-trigger \
  --zip-file fileb://kaggle-trigger.zip \
  --region $REGION > /dev/null

aws lambda update-function-configuration \
  --function-name wolof-batch-trigger \
  --environment "Variables={KAGGLE_USERNAME=$KAGGLE_USERNAME,KAGGLE_KEY=$KAGGLE_KEY,S3_BUCKET=$S3_BUCKET,KERNEL_SLUG=$KERNEL_SLUG}" \
  --timeout 60 \
  --region $REGION > /dev/null

echo "  Lambda trigger updated (Kaggle mode)"

# ============================================
echo ""
echo "[4/5] Test: push a test kernel..."

# Quick test push
TEST_SCRIPT='print("Kaggle GPU test OK"); import torch; print(f"CUDA: {torch.cuda.is_available()}, GPUs: {torch.cuda.device_count()}")'
TEST_PAYLOAD=$(python3 -c "
import json, base64
auth = base64.b64encode('${KAGGLE_USERNAME}:${KAGGLE_KEY}'.encode()).decode()
print(json.dumps({
    'id': '${KERNEL_SLUG}',
    'newTitle': 'wolof-test-gpu',
    'text': '''$TEST_SCRIPT''',
    'language': 'python',
    'kernelType': 'script',
    'isPrivate': True,
    'enableGpu': True,
    'enableInternet': True,
}))
")

RESULT=$(curl -s -X POST "https://www.kaggle.com/api/v1/kernels/push" \
  -u "${KAGGLE_USERNAME}:${KAGGLE_KEY}" \
  -H "Content-Type: application/json" \
  -d "$TEST_PAYLOAD")
echo "  Push result: $RESULT"

# ============================================
echo ""
echo "[5/5] Summary..."
echo ""
echo "============================================"
echo "=== KAGGLE GPU SETUP COMPLETE ==="
echo "============================================"
echo ""
echo "Architecture:"
echo "  Frontend -> API Lambda -> S3 upload -> Trigger Lambda -> Kaggle T4 GPU"
echo "  Kaggle transcribes + translates -> Result in S3 -> Frontend polls"
echo ""
echo "Performance:"
echo "  6h audio -> ~15 min (T4 GPU)"
echo "  1h audio -> ~3 min (T4 GPU)"
echo "  30h GPU/week free (Kaggle quota)"
echo ""
echo "Costs: \$0/month (100% free)"
echo ""
echo "IMPORTANT - Manual steps on kaggle.com:"
echo "  1. Add secrets (Settings -> Secrets):"
echo "     - AWS_ACCESS_KEY_ID"
echo "     - AWS_SECRET_ACCESS_KEY"
echo "  2. Make sure 'Phone verified' for GPU access"
echo "  3. Accept GPU quota (Settings -> Accelerator Quota)"
echo ""
echo "Test from frontend: upload any audio file"
echo "Test from CLI: aws s3 cp test.mp3 s3://$S3_BUCKET/uploads/test-123/audio.mp3"
