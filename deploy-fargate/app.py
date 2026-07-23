"""Wolof ASR — Fargate HTTP server with faster-whisper."""
import os
import json
import base64
import tempfile
import time
import requests
from flask import Flask, request, jsonify
from flask_cors import CORS
from faster_whisper import WhisperModel

app = Flask(__name__)
CORS(app)

MODEL_DIR = "/opt/model"

config_path = os.path.join(MODEL_DIR, "config.json")
if os.path.exists(config_path):
    with open(config_path) as f:
        cfg = json.load(f)
    patched = False
    if cfg.get("begin_suppress_tokens") is None:
        cfg["begin_suppress_tokens"] = []
        patched = True
    if cfg.get("max_length") is None:
        cfg.pop("max_length", None)
        patched = True
    if patched:
        with open(config_path, "w") as f:
            json.dump(cfg, f, indent=2)
        print("Patched config.json (null values)", flush=True)

gen_config_path = os.path.join(MODEL_DIR, "generation_config.json")
if os.path.exists(gen_config_path):
    with open(gen_config_path) as f:
        gcfg = json.load(f)
    if "forced_decoder_ids" in gcfg:
        gcfg.pop("forced_decoder_ids")
        with open(gen_config_path, "w") as f:
            json.dump(gcfg, f, indent=2)
        print("Patched generation_config.json (removed forced_decoder_ids)", flush=True)

print("Loading model...", flush=True)
model = WhisperModel(
    MODEL_DIR,
    device="cpu",
    compute_type="int8",
    cpu_threads=4,
)
print("Model loaded!", flush=True)


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

        segments_gen, info = model.transcribe(
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


HF_API_TOKEN = os.environ.get("HF_API_TOKEN", "")
NLLB_URL = "https://api-inference.huggingface.co/models/facebook/nllb-200-distilled-600M"


@app.route("/api/translate", methods=["POST", "OPTIONS"])
def translate():
    if request.method == "OPTIONS":
        return "", 200

    data = request.get_json(force=True)
    text = data.get("text", "").strip()
    src_lang = data.get("src_lang", "wol_Latn")
    tgt_lang = data.get("tgt_lang", "fra_Latn")

    if not text:
        return jsonify({"error": "Texte vide"}), 400

    headers = {"Content-Type": "application/json"}
    if HF_API_TOKEN:
        headers["Authorization"] = f"Bearer {HF_API_TOKEN}"

    payload = {
        "inputs": text,
        "parameters": {"src_lang": src_lang, "tgt_lang": tgt_lang},
        "options": {"wait_for_model": True},
    }

    try:
        resp = requests.post(NLLB_URL, headers=headers, json=payload, timeout=60)

        if resp.status_code == 503:
            wait_time = min(resp.json().get("estimated_time", 20), 30)
            time.sleep(wait_time)
            resp = requests.post(NLLB_URL, headers=headers, json=payload, timeout=60)

        if resp.status_code != 200:
            return jsonify({"error": f"HuggingFace error: {resp.status_code}"}), 502

        result = resp.json()
        if isinstance(result, list) and len(result) > 0:
            translation = result[0].get("translation_text", "")
        elif isinstance(result, dict):
            translation = result.get("translation_text", "")
        else:
            translation = ""

        return jsonify({"translation_text": translation})

    except requests.Timeout:
        return jsonify({"error": "Timeout traduction"}), 504
    except Exception as e:
        return jsonify({"error": str(e)}), 500


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
