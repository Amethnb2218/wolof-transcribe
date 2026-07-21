#!/bin/bash
set -e

cat > /tmp/handler.py << 'EOF'
"""AWS Lambda handler — Wolof ASR avec faster-whisper sur CPU."""
import os
import json
import base64
import tempfile

MODEL_DIR = "/opt/model"
model = None


def get_model():
    global model
    if model is None:
        from faster_whisper import WhisperModel
        model = WhisperModel(MODEL_DIR, device="cpu", compute_type="int8", cpu_threads=4)
    return model


def lambda_handler(event, context):
    headers = {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "POST, OPTIONS", "Access-Control-Allow-Headers": "Content-Type"}
    if event.get("warmup"):
        return {"statusCode": 200, "headers": headers, "body": json.dumps({"status": "warm"})}
    if event.get("requestContext", {}).get("http", {}).get("method") == "OPTIONS":
        return {"statusCode": 200, "headers": headers, "body": ""}
    if event.get("isBase64Encoded"):
        audio_bytes = base64.b64decode(event["body"])
    elif event.get("body"):
        try:
            audio_bytes = base64.b64decode(event["body"])
        except Exception:
            try:
                audio_bytes = event["body"].encode("latin-1")
            except Exception:
                return {"statusCode": 400, "headers": headers, "body": json.dumps({"error": "Invalid audio data"})}
    else:
        return {"statusCode": 400, "headers": headers, "body": json.dumps({"error": "No audio data"})}
    if not audio_bytes:
        return {"statusCode": 400, "headers": headers, "body": json.dumps({"error": "Empty audio"})}
    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile(delete=False, suffix=".audio") as f:
            f.write(audio_bytes)
            tmp_path = f.name
        m = get_model()
        segments_gen, info = m.transcribe(tmp_path, language="fr", task="transcribe", beam_size=5, vad_filter=True)
        segments = []
        full_text = ""
        for seg in segments_gen:
            segments.append({"start": round(seg.start, 2), "end": round(seg.end, 2), "text": seg.text.strip()})
            full_text += seg.text + " "
        return {"statusCode": 200, "headers": headers, "body": json.dumps({"text": full_text.strip(), "segments": segments, "language": info.language, "duration": round(info.duration, 1)})}
    except Exception as e:
        return {"statusCode": 500, "headers": headers, "body": json.dumps({"error": str(e)})}
    finally:
        if tmp_path:
            os.unlink(tmp_path)
EOF

REPO=335596040822.dkr.ecr.us-east-1.amazonaws.com/wolof-asr
docker create --name temp-handler $REPO:latest
docker cp /tmp/handler.py temp-handler:/var/task/handler.py
docker commit temp-handler wolof-asr:updated
docker rm temp-handler
docker tag wolof-asr:updated $REPO:latest
docker push $REPO:latest
aws lambda update-function-code --function-name wolof-asr --image-uri $REPO:latest --region us-east-1
echo "DONE - Handler updated!"
