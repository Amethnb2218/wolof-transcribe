"""Wolof ASR — Fargate HTTP server with faster-whisper."""
import os
import json
import base64
import tempfile
from flask import Flask, request, jsonify
from flask_cors import CORS
from faster_whisper import WhisperModel

app = Flask(__name__)
CORS(app)

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


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok", "model_loaded": model is not None})


@app.route("/", methods=["POST", "OPTIONS"])
def transcribe():
    if request.method == "OPTIONS":
        return "", 200

    content_type = request.content_type or ""

    if "application/json" in content_type:
        data = request.get_json(force=True)
        audio_b64 = data.get("audio", data.get("body", ""))
        audio_bytes = base64.b64decode(audio_b64)
    else:
        audio_bytes = request.get_data()

    if not audio_bytes:
        return jsonify({"error": "No audio data"}), 400

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
            full_text += seg.text + " "

        return jsonify({
            "text": full_text.strip(),
            "segments": segments,
            "language": info.language,
            "duration": round(info.duration, 1),
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500
    finally:
        if tmp_path:
            os.unlink(tmp_path)


if __name__ == "__main__":
    print("Loading model...")
    get_model()
    print("Model loaded! Starting server on port 8080...")
    app.run(host="0.0.0.0", port=8080)
