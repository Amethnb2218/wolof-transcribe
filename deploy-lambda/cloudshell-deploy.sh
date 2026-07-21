#!/bin/bash
# ============================================================
# SCRIPT CLOUDSHELL — Build + Deploy wolof-asr Lambda Docker
# Le modèle est téléchargé DANS le Docker build (pas sur le filesystem)
# ============================================================

set -e
echo "=========================================="
echo "  WOLOF-ASR DOCKER LAMBDA DEPLOYMENT"
echo "=========================================="

cd /tmp
rm -rf wolof-asr 2>/dev/null
mkdir -p wolof-asr && cd wolof-asr

# 1. requirements.txt
cat > requirements.txt << 'EOF'
faster-whisper==1.0.3
huggingface_hub
requests
numpy<2
EOF

# 2. handler.py
cat > handler.py << 'HANDLER'
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
        model = WhisperModel(
            MODEL_DIR,
            device="cpu",
            compute_type="int8",
            cpu_threads=4,
        )
    return model


def lambda_handler(event, context):
    headers = {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type",
    }

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
                return {
                    "statusCode": 400,
                    "headers": headers,
                    "body": json.dumps({"error": "Invalid audio data"}),
                }
    else:
        return {
            "statusCode": 400,
            "headers": headers,
            "body": json.dumps({"error": "No audio data"}),
        }

    if not audio_bytes:
        return {
            "statusCode": 400,
            "headers": headers,
            "body": json.dumps({"error": "Empty audio"}),
        }

    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile(delete=False, suffix=".audio") as f:
            f.write(audio_bytes)
            tmp_path = f.name

        m = get_model()
        segments_gen, info = m.transcribe(
            tmp_path,
            language="fr",
            task="transcribe",
            beam_size=5,
            vad_filter=True,
        )

        segments = []
        full_text = ""
        for seg in segments_gen:
            segments.append({
                "start": round(seg.start, 2),
                "end": round(seg.end, 2),
                "text": seg.text.strip(),
            })
            full_text += seg.text + " "

        return {
            "statusCode": 200,
            "headers": headers,
            "body": json.dumps({
                "text": full_text.strip(),
                "segments": segments,
                "language": info.language,
                "duration": round(info.duration, 1),
            }),
        }
    except Exception as e:
        return {
            "statusCode": 500,
            "headers": headers,
            "body": json.dumps({"error": str(e)}),
        }
    finally:
        if tmp_path:
            os.unlink(tmp_path)
HANDLER

# 3. Dockerfile — télécharge le modèle PENDANT le build Docker
cat > Dockerfile << 'DOCKERFILE'
FROM public.ecr.aws/lambda/python:3.11

RUN pip install --upgrade pip

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Télécharger le modèle pendant le build (dans l'image Docker, pas sur le filesystem)
RUN mkdir -p /opt/model && \
    curl -sL -o /opt/model/config.json https://huggingface.co/momosl/whisper-wolof-v1-ct2/resolve/main/config.json && \
    curl -sL -o /opt/model/vocabulary.json https://huggingface.co/momosl/whisper-wolof-v1-ct2/resolve/main/vocabulary.json && \
    curl -sL -o /opt/model/tokenizer_config.json https://huggingface.co/momosl/whisper-wolof-v1-ct2/resolve/main/tokenizer_config.json && \
    curl -sL -o /opt/model/vocab.json https://huggingface.co/momosl/whisper-wolof-v1-ct2/resolve/main/vocab.json && \
    curl -sL -o /opt/model/merges.txt https://huggingface.co/momosl/whisper-wolof-v1-ct2/resolve/main/merges.txt && \
    curl -sL -o /opt/model/added_tokens.json https://huggingface.co/momosl/whisper-wolof-v1-ct2/resolve/main/added_tokens.json && \
    curl -sL -o /opt/model/special_tokens_map.json https://huggingface.co/momosl/whisper-wolof-v1-ct2/resolve/main/special_tokens_map.json && \
    curl -sL -o /opt/model/normalizer.json https://huggingface.co/momosl/whisper-wolof-v1-ct2/resolve/main/normalizer.json && \
    curl -sL -o /opt/model/preprocessor_config.json https://huggingface.co/momosl/whisper-wolof-v1-ct2/resolve/main/preprocessor_config.json && \
    curl -L -o /opt/model/model.bin https://huggingface.co/momosl/whisper-wolof-v1-ct2/resolve/main/model.bin && \
    ls -la /opt/model/

COPY handler.py ${LAMBDA_TASK_ROOT}/

CMD ["handler.lambda_handler"]
DOCKERFILE

# 4. Build Docker
echo ""
echo "Build Docker image (telecharge le modele dans l'image)..."
docker build --platform linux/amd64 -t wolof-asr .

# 5. Login ECR + Push
echo ""
echo "Push vers ECR..."
ACCOUNT=335596040822
REGION=us-east-1
REPO=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/wolof-asr

aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ACCOUNT.dkr.ecr.$REGION.amazonaws.com
docker tag wolof-asr:latest $REPO:latest
docker push $REPO:latest

# 6. Mettre à jour Lambda
echo ""
echo "Mise a jour Lambda..."
aws lambda update-function-code \
  --function-name wolof-asr \
  --image-uri $REPO:latest \
  --region $REGION

echo ""
echo "=========================================="
echo "  DEPLOIEMENT TERMINE !"
echo "  Lambda wolof-asr mise a jour"
echo "  Plus de telechargement au cold start"
echo "=========================================="
