#!/bin/bash
set -e
cd /tmp
rm -rf /tmp/wolof-asr /tmp/wolof-* 2>/dev/null
docker system prune -af 2>/dev/null || true
mkdir -p wolof-asr && cd wolof-asr

cat > handler.py << 'EOF'
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

ACCOUNT=335596040822
REGION=us-east-1
REPO=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/wolof-asr

cat > Dockerfile << DEOF
FROM $REPO:latest
COPY handler.py /var/task/
CMD ["handler.lambda_handler"]
DEOF

aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ACCOUNT.dkr.ecr.$REGION.amazonaws.com
docker pull $REPO:latest
docker build --platform linux/amd64 -t wolof-asr .
docker tag wolof-asr:latest $REPO:latest
docker push $REPO:latest
aws lambda update-function-code --function-name wolof-asr --image-uri $REPO:latest --region $REGION
echo ""
echo "DONE - Handler mis a jour avec lazy import!"
