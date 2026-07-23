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

# CTranslate2 reads config.json expecting its OWN format (suppress_ids, suppress_ids_begin,
# alignment_heads, lang_ids). The HuggingFace repo ships the wrong config.json (transformers
# format with begin_suppress_tokens, d_model, etc.) which causes:
#   [json.exception.type_error.302] type must be number, but is number
# Fix: overwrite with the correct CTranslate2-format config.
config_path = os.path.join(MODEL_DIR, "config.json")
ct2_config = {
    "suppress_ids": [
        1, 2, 7, 8, 9, 10, 14, 25, 26, 27, 28, 29, 31, 58, 59, 60, 61, 62,
        63, 90, 91, 92, 93, 359, 503, 522, 542, 873, 893, 902, 918, 922, 931,
        1350, 1853, 1982, 2460, 2627, 3246, 3253, 3268, 3536, 3846, 3961,
        4183, 4667, 6585, 6647, 7273, 9061, 9383, 10428, 10929, 11938, 12033,
        12331, 12562, 13793, 14157, 14635, 15265, 15618, 16553, 16604, 18362,
        18956, 20075, 21675, 22520, 26130, 26161, 26435, 28279, 29464, 31650,
        32302, 32470, 36865, 42863, 47425, 49870, 50254, 50258, 50359, 50360,
        50361, 50362, 50363
    ],
    "suppress_ids_begin": [220, 50257],
    "alignment_heads": [
        [7, 0], [10, 17], [12, 18], [13, 12], [16, 1],
        [17, 14], [19, 11], [21, 4], [24, 1], [25, 6]
    ],
    "lang_ids": list(range(50259, 50359))
}
with open(config_path, "w") as f:
    json.dump(ct2_config, f, indent=2)
print("Wrote correct CTranslate2 config.json", flush=True)

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
            task="transcribe",
            beam_size=1,
            vad_filter=True,
            vad_parameters=dict(
                min_silence_duration_ms=300,
                speech_pad_ms=300,
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
