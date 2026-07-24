"""
Kaggle Kernel: Wolof ASR + Translation (GPU T4)
Triggered via Kaggle API, downloads audio from S3, transcribes, translates, uploads result.
"""
import os
import sys
import json
import time
import subprocess

subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", "faster-whisper", "transformers", "sentencepiece", "boto3"])

import boto3
from faster_whisper import WhisperModel

# --- Config from environment (set via kernel metadata) ---
S3_BUCKET = os.environ.get("S3_BUCKET", "wolof-transcriber-audio")
AUDIO_KEY = os.environ.get("AUDIO_KEY", "")
JOB_ID = os.environ.get("JOB_ID", "")
AWS_ACCESS_KEY_ID = os.environ.get("AWS_ACCESS_KEY_ID", "")
AWS_SECRET_ACCESS_KEY = os.environ.get("AWS_SECRET_ACCESS_KEY", "")
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")

# Try Kaggle secrets first, fallback to env vars
try:
    from kaggle_secrets import UserSecretsClient
    secrets = UserSecretsClient()
    AWS_ACCESS_KEY_ID = secrets.get_secret("AWS_ACCESS_KEY_ID") or AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY = secrets.get_secret("AWS_SECRET_ACCESS_KEY") or AWS_SECRET_ACCESS_KEY
    S3_BUCKET = secrets.get_secret("S3_BUCKET") or S3_BUCKET
except:
    pass

assert AUDIO_KEY, "AUDIO_KEY environment variable required"
assert JOB_ID, "JOB_ID environment variable required"

s3 = boto3.client(
    "s3",
    aws_access_key_id=AWS_ACCESS_KEY_ID,
    aws_secret_access_key=AWS_SECRET_ACCESS_KEY,
    region_name=AWS_REGION,
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
MODEL_ID = "momosl/whisper-wolof-v2-ct2"
print(f"Loading Whisper model: {MODEL_ID} on GPU...", flush=True)

model = WhisperModel(
    MODEL_ID,
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
print(f"Speed: {audio_duration/transcription_time:.1f}x realtime", flush=True)


# --- Translate (NLLB) ---
update_status("translating")
print("Loading NLLB translation model...", flush=True)

from transformers import AutoTokenizer, AutoModelForSeq2SeqLM
import torch

nllb_model_id = "facebook/nllb-200-distilled-600M"
nllb_tokenizer = AutoTokenizer.from_pretrained(nllb_model_id)
nllb_model = AutoModelForSeq2SeqLM.from_pretrained(nllb_model_id).to("cuda")
print("NLLB loaded on GPU!", flush=True)

nllb_tokenizer.src_lang = "wol_Latn"
tgt_lang_id = nllb_tokenizer.convert_tokens_to_ids("fra_Latn")

translated_segments = []
batch_size = 8
for i in range(0, len(segments), batch_size):
    batch = segments[i:i+batch_size]
    texts = [s["text"] for s in batch]
    inputs = nllb_tokenizer(texts, return_tensors="pt", padding=True, truncation=True, max_length=512).to("cuda")
    with torch.no_grad():
        generated = nllb_model.generate(**inputs, forced_bos_token_id=tgt_lang_id, max_new_tokens=256)
    translations = nllb_tokenizer.batch_decode(generated, skip_special_tokens=True)
    for seg, trans in zip(batch, translations):
        seg["translation"] = trans
        translated_segments.append(seg)

full_translation = " ".join(s["translation"] for s in translated_segments)
print(f"Translation done: {len(translated_segments)} segments", flush=True)


# --- Upload result ---
update_status("uploading")
total_time = time.time() - start_time

result = {
    "text": text,
    "translation": full_translation,
    "segments": translated_segments,
    "duration": audio_duration,
    "processing_time": total_time,
    "device": "gpu-t4-kaggle",
    "speed_factor": round(audio_duration / transcription_time, 1),
    "job_id": JOB_ID,
}

s3.put_object(
    Bucket=S3_BUCKET,
    Key=f"results/{JOB_ID}.json",
    Body=json.dumps(result, ensure_ascii=False),
    ContentType="application/json",
)
print(f"Result uploaded to s3://{S3_BUCKET}/results/{JOB_ID}.json", flush=True)

update_status("done", processing_time=total_time, speed_factor=result["speed_factor"])
print(f"\n=== DONE === {audio_duration:.0f}s audio transcribed in {total_time:.0f}s ({result['speed_factor']}x realtime)", flush=True)
