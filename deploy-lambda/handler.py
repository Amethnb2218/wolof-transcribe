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
        import ctranslate2
        ctranslate2.set_random_seed(42)
        from faster_whisper import WhisperModel
        model = WhisperModel(
            MODEL_DIR,
            device="cpu",
            compute_type="int8",
            cpu_threads=2,
            num_workers=1,
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

    with tempfile.NamedTemporaryFile(delete=False, suffix=".wav") as tmp:
        tmp.write(audio_bytes)
        tmp_path = tmp.name

    try:
        m = get_model()
        segments_gen, info = m.transcribe(
            tmp_path,
            language="fr",
            task="transcribe",
            beam_size=1,
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
            "headers": headers,
            "body": json.dumps({
                "text": full_text.strip(),
                "segments": segments,
                "language": "wo",
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
        os.unlink(tmp_path)
