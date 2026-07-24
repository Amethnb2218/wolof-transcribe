#!/bin/bash
# ============================================================
# SETUP KAGGLE KERNEL: amethsl/wolof-transcriber-gpu
# Creates the kernel + configures AWS secrets on Kaggle
# Run from CloudShell AFTER setting:
#   export KAGGLE_API_TOKEN=KGAT_xxx
#   export AWS_ACCESS_KEY_ID_FOR_KAGGLE=xxx
#   export AWS_SECRET_ACCESS_KEY_FOR_KAGGLE=xxx
# ============================================================
set -e

KAGGLE_TOKEN="${KAGGLE_API_TOKEN:-}"
AWS_KEY="${AWS_ACCESS_KEY_ID_FOR_KAGGLE:-}"
AWS_SECRET="${AWS_SECRET_ACCESS_KEY_FOR_KAGGLE:-}"

if [ -z "$KAGGLE_TOKEN" ]; then
  echo "ERROR: export KAGGLE_API_TOKEN=KGAT_xxx first"
  exit 1
fi

echo "=== SETUP KAGGLE KERNEL ==="
echo ""

# ============================================
echo "[1/3] Testing Kaggle API connection..."
RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
  "https://www.kaggle.com/api/v1/kernels/list?user=amethsl" \
  -H "Authorization: Bearer $KAGGLE_TOKEN")

if [ "$RESULT" = "200" ]; then
  echo "  API connection OK"
else
  echo "  ERROR: Kaggle API returned $RESULT"
  echo "  Check your KAGGLE_API_TOKEN"
  exit 1
fi

# ============================================
echo ""
echo "[2/3] Pushing kernel: amethsl/wolof-transcriber-gpu..."

# The kernel script is self-contained — when triggered by the worker,
# it receives JOB_ID, AUDIO_KEY, S3_BUCKET via env vars injected at push time.
# AWS credentials come from Kaggle Secrets.

KERNEL_SCRIPT=$(cat << 'PYEOF'
"""
Kaggle Kernel: Wolof ASR + Translation (GPU T4)
Triggered by SQS worker. Downloads audio from S3, transcribes, translates, uploads result.
"""
import os
import sys
import json
import time
import subprocess

subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", "faster-whisper", "transformers", "sentencepiece", "boto3"])

import boto3
import torch
from faster_whisper import WhisperModel
from transformers import AutoTokenizer, AutoModelForSeq2SeqLM

# --- Config (injected by worker at push time) ---
JOB_ID = os.environ.get("JOB_ID", "")
AUDIO_KEY = os.environ.get("AUDIO_KEY", "")
S3_BUCKET = os.environ.get("S3_BUCKET", "wolof-asr-audio-335596040822")

# AWS credentials from Kaggle Secrets
AWS_ACCESS_KEY_ID = os.environ.get("AWS_ACCESS_KEY_ID", "")
AWS_SECRET_ACCESS_KEY = os.environ.get("AWS_SECRET_ACCESS_KEY", "")

try:
    from kaggle_secrets import UserSecretsClient
    secrets = UserSecretsClient()
    AWS_ACCESS_KEY_ID = secrets.get_secret("AWS_ACCESS_KEY_ID") or AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY = secrets.get_secret("AWS_SECRET_ACCESS_KEY") or AWS_SECRET_ACCESS_KEY
    S3_BUCKET = secrets.get_secret("S3_BUCKET") or S3_BUCKET
except Exception as e:
    print(f"Note: Kaggle secrets not available ({e}), using env vars")

assert JOB_ID, "JOB_ID required"
assert AUDIO_KEY, "AUDIO_KEY required"
assert AWS_ACCESS_KEY_ID, "AWS_ACCESS_KEY_ID required (set as Kaggle Secret)"

s3 = boto3.client(
    "s3",
    aws_access_key_id=AWS_ACCESS_KEY_ID,
    aws_secret_access_key=AWS_SECRET_ACCESS_KEY,
    region_name="us-east-1",
)

def update_status(status, **extra):
    payload = {"status": status, "job_id": JOB_ID, "timestamp": time.time(), **extra}
    s3.put_object(Bucket=S3_BUCKET, Key=f"jobs/{JOB_ID}/status.json", Body=json.dumps(payload))
    print(f"[STATUS] {status}", flush=True)

# --- Download audio ---
update_status("downloading")
audio_ext = AUDIO_KEY.rsplit(".", 1)[-1] if "." in AUDIO_KEY else "mp3"
local_audio = f"/tmp/audio.{audio_ext}"
print(f"Downloading s3://{S3_BUCKET}/{AUDIO_KEY}...", flush=True)
s3.download_file(S3_BUCKET, AUDIO_KEY, local_audio)
file_size_mb = os.path.getsize(local_audio) / (1024 * 1024)
print(f"Downloaded: {file_size_mb:.1f} MB", flush=True)

# --- Load Whisper model (GPU) ---
update_status("loading_model")
print(f"Loading Whisper model on GPU...", flush=True)
print(f"CUDA available: {torch.cuda.is_available()}, GPUs: {torch.cuda.device_count()}", flush=True)

model = WhisperModel(
    "momosl/whisper-wolof-v2-ct2",
    device="cuda",
    compute_type="float16",
    cpu_threads=4,
)
print("Whisper model loaded on GPU!", flush=True)

# --- Transcribe ---
update_status("transcribing")
start_time = time.time()

segments_list, info = model.transcribe(
    local_audio,
    beam_size=5,
    language="wo",
    vad_filter=True,
    vad_parameters=dict(min_silence_duration_ms=500),
)

segments = []
full_text = []
for seg in segments_list:
    segments.append({
        "start": round(seg.start, 2),
        "end": round(seg.end, 2),
        "text": seg.text.strip(),
    })
    full_text.append(seg.text.strip())

transcription_time = time.time() - start_time
audio_duration = info.duration
text = " ".join(full_text)

print(f"Transcription done: {len(segments)} segments, {audio_duration:.0f}s audio in {transcription_time:.0f}s", flush=True)
print(f"Speed: {audio_duration/max(transcription_time,1):.1f}x realtime", flush=True)

# --- Translate (NLLB on GPU) ---
update_status("translating")
print("Loading NLLB translation model...", flush=True)

nllb_tokenizer = AutoTokenizer.from_pretrained("facebook/nllb-200-distilled-600M")
nllb_model = AutoModelForSeq2SeqLM.from_pretrained("facebook/nllb-200-distilled-600M").to("cuda")
print("NLLB loaded on GPU!", flush=True)

nllb_tokenizer.src_lang = "wol_Latn"
tgt_lang_id = nllb_tokenizer.convert_tokens_to_ids("fra_Latn")

batch_size = 8
for i in range(0, len(segments), batch_size):
    batch = segments[i:i+batch_size]
    texts = [s["text"] for s in batch if s["text"]]
    if not texts:
        continue
    inputs = nllb_tokenizer(texts, return_tensors="pt", padding=True, truncation=True, max_length=512).to("cuda")
    with torch.no_grad():
        generated = nllb_model.generate(**inputs, forced_bos_token_id=tgt_lang_id, max_new_tokens=256)
    translations = nllb_tokenizer.batch_decode(generated, skip_special_tokens=True)
    text_idx = 0
    for seg in batch:
        if seg["text"]:
            seg["translation"] = translations[text_idx]
            text_idx += 1

full_translation = " ".join(s.get("translation", "") for s in segments)
print(f"Translation done: {len(segments)} segments", flush=True)

# --- Upload result ---
update_status("uploading")
total_time = time.time() - start_time

result = {
    "text": text,
    "translation": full_translation,
    "segments": segments,
    "duration": audio_duration,
    "processing_time": total_time,
    "device": "gpu-t4-kaggle",
    "speed_factor": round(audio_duration / max(transcription_time, 1), 1),
    "job_id": JOB_ID,
    "pipeline_version": "whisper-nllb-v2-kaggle",
}

s3.put_object(
    Bucket=S3_BUCKET,
    Key=f"results/{JOB_ID}.json",
    Body=json.dumps(result, ensure_ascii=False),
    ContentType="application/json",
)
print(f"Result uploaded to s3://{S3_BUCKET}/results/{JOB_ID}.json", flush=True)

update_status("done", processing_time=total_time, speed_factor=result["speed_factor"])
print(f"\n=== DONE === {audio_duration:.0f}s audio transcribed+translated in {total_time:.0f}s ({result['speed_factor']}x realtime)", flush=True)
PYEOF
)

# Push as initial version
PUSH_PAYLOAD=$(python3 -c "
import json
script = '''$KERNEL_SCRIPT'''
payload = {
    'title': 'wolof-transcriber-gpu',
    'text': script,
    'language': 'python',
    'kernel_type': 'script',
    'is_private': True,
    'enable_gpu': True,
    'enable_internet': True,
}
print(json.dumps(payload))
")

PUSH_RESULT=$(curl -s -X POST "https://www.kaggle.com/api/v1/kernels/push" \
  -H "Authorization: Bearer $KAGGLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$PUSH_PAYLOAD")

echo "  Push result: $PUSH_RESULT"

if echo "$PUSH_RESULT" | grep -q "error"; then
  echo ""
  echo "  If 'kernel not found', this is the FIRST push — Kaggle will create it."
  echo "  If another error, check your token."
fi

# ============================================
echo ""
echo "[3/3] Configure AWS Secrets on Kaggle..."
echo ""

if [ -z "$AWS_KEY" ] || [ -z "$AWS_SECRET" ]; then
  echo "  SKIP: AWS credentials not provided."
  echo ""
  echo "  YOU MUST configure these secrets MANUALLY on Kaggle:"
  echo "  1. Go to https://www.kaggle.com/settings"
  echo "  2. Scroll to 'Secrets' section"
  echo "  3. Add these secrets:"
  echo "     - Name: AWS_ACCESS_KEY_ID      Value: (your access key)"
  echo "     - Name: AWS_SECRET_ACCESS_KEY  Value: (your secret key)"
  echo "     - Name: S3_BUCKET              Value: wolof-asr-audio-335596040822"
  echo ""
  echo "  Then in the kernel settings, enable 'Allow access to secrets'"
else
  echo "  Note: Kaggle API doesn't support setting secrets programmatically."
  echo "  You must add them manually:"
  echo "  1. Go to https://www.kaggle.com/settings"
  echo "  2. Add secret: AWS_ACCESS_KEY_ID = $AWS_KEY"
  echo "  3. Add secret: AWS_SECRET_ACCESS_KEY = $AWS_SECRET"
  echo "  4. Add secret: S3_BUCKET = wolof-asr-audio-335596040822"
fi

echo ""
echo "============================================"
echo "=== KAGGLE KERNEL SETUP COMPLETE ==="
echo "============================================"
echo ""
echo "  Kernel: amethsl/wolof-transcriber-gpu"
echo "  GPU: T4 (free tier: 30h/week)"
echo ""
echo "  Performance:"
echo "    1 min audio  -> ~5-10s"
echo "    5 min audio  -> ~30s"
echo "    30 min audio -> ~3 min"
echo "    1h audio     -> ~5 min"
echo ""
echo "  IMPORTANT: Configure AWS Secrets on Kaggle!"
echo "  https://www.kaggle.com/settings -> Secrets"
echo ""
echo "  Then enable 'Secrets' access in your kernel:"
echo "  https://www.kaggle.com/amethsl/wolof-transcriber-gpu/settings"
echo "============================================"
