"""AWS Lambda handler — Wolof ASR avec faster-whisper sur CPU."""
import os
import json
import base64
import tempfile
from faster_whisper import WhisperModel
from huggingface_hub import snapshot_download

MODEL_ID = "momosl/whisper-wolof-v1-ct2"
MODEL_DIR = "/tmp/model"
model = None


def get_model():
    global model
    if model is None:
        if not os.path.exists(os.path.join(MODEL_DIR, "config.json")):
            snapshot_download(MODEL_ID, local_dir=MODEL_DIR)
        model = WhisperModel(
            MODEL_DIR,
            device="cpu",
            compute_type="int8",
            cpu_threads=4,
        )
    return model


def lambda_handler(event, context):
    # Function URL encode le body binaire en base64 automatiquement
    if event.get("isBase64Encoded"):
        audio_bytes = base64.b64decode(event["body"])
    elif event.get("body"):
        body = event["body"]
        try:
            data = json.loads(body)
            audio_bytes = base64.b64decode(data.get("audio", ""))
        except (json.JSONDecodeError, Exception):
            try:
                audio_bytes = base64.b64decode(body)
            except Exception:
                return {
                    "statusCode": 400,
                    "body": json.dumps({"error": "Invalid audio data"}),
                }
    else:
        return {
            "statusCode": 400,
            "body": json.dumps({"error": "No audio data"}),
        }

    if not audio_bytes:
        return {
            "statusCode": 400,
            "body": json.dumps({"error": "Empty audio"}),
        }

    with tempfile.NamedTemporaryFile(delete=False, suffix=".wav") as tmp:
        tmp.write(audio_bytes)
        tmp_path = tmp.name

    try:
        m = get_model()
        segments_gen, info = m.transcribe(
            tmp_path,
            language="fr",
            task="transcribe",
            beam_size=3,
            vad_filter=True,
            vad_parameters=dict(
                min_silence_duration_ms=500,
                speech_pad_ms=200,
            ),
        )

        segments = []
        full_text = ""
        for seg in segments_gen:
            segments.append({
                "start": round(seg.start, 2),
                "end": round(seg.end, 2),
                "text": seg.text.strip(),
            })
            full_text += seg.text

        return {
            "statusCode": 200,
            "headers": {
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": "*",
            },
            "body": json.dumps({
                "text": full_text.strip(),
                "segments": segments,
                "language": "wo",
                "duration": round(info.duration, 1),
            }),
        }
    finally:
        os.unlink(tmp_path)
