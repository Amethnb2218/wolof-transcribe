#!/bin/bash
# ============================================================
# SCRIPT CLOUDSHELL — Build + Deploy wolof-asr Lambda Docker
# Copier-coller TOUT dans CloudShell en une seule fois
# ============================================================

set -e
echo "=========================================="
echo "  WOLOF-ASR DOCKER LAMBDA DEPLOYMENT"
echo "=========================================="

# 1. Créer le dossier de travail
mkdir -p ~/wolof-asr && cd ~/wolof-asr

# 2. Créer requirements.txt
cat > requirements.txt << 'EOF'
faster-whisper==1.0.3
huggingface_hub
requests
numpy<2
EOF

# 3. Créer le handler
cat > handler.py << 'HANDLER'
"""AWS Lambda handler — Wolof ASR avec faster-whisper sur CPU."""
import os
import json
import base64
import tempfile
from faster_whisper import WhisperModel

MODEL_DIR = "/opt/model"
model = None


def get_model():
    global model
    if model is None:
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

# 4. Créer le Dockerfile
cat > Dockerfile << 'DOCKERFILE'
FROM public.ecr.aws/lambda/python:3.11

RUN pip install --upgrade pip

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY wolof-model/ /opt/model/

COPY handler.py ${LAMBDA_TASK_ROOT}/

CMD ["handler.lambda_handler"]
DOCKERFILE

# 5. Télécharger le modèle
echo ""
echo "Telechargement du modele wolof CT2 (~1.5GB)..."
mkdir -p wolof-model
cd wolof-model
for f in config.json vocabulary.json tokenizer_config.json vocab.json merges.txt added_tokens.json special_tokens_map.json normalizer.json preprocessor_config.json; do
  curl -sL -o "$f" "https://huggingface.co/momosl/whisper-wolof-v1-ct2/resolve/main/$f"
  echo "  OK: $f"
done
echo "  Downloading model.bin (1.5GB)..."
curl -L -o model.bin "https://huggingface.co/momosl/whisper-wolof-v1-ct2/resolve/main/model.bin"
echo "  OK: model.bin ($(du -h model.bin | cut -f1))"
cd ..

# 6. Build Docker
echo ""
echo "Build Docker image..."
docker build --platform linux/amd64 -t wolof-asr .

# 7. Login ECR + Push
echo ""
echo "Push vers ECR..."
ACCOUNT=335596040822
REGION=us-east-1
REPO=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/wolof-asr

aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ACCOUNT.dkr.ecr.$REGION.amazonaws.com
docker tag wolof-asr:latest $REPO:latest
docker push $REPO:latest

# 8. Mettre à jour Lambda
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
