"""Backend local offline — Wolof ASR avec faster-whisper."""
import os
import sys
import tempfile
from pathlib import Path

from fastapi import FastAPI, UploadFile, File, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydub import AudioSegment
import numpy as np

app = FastAPI(title="Wolof Transcriber — Local")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

MODEL_DIR = os.environ.get(
    "WOLOF_MODEL_DIR",
    str(Path(__file__).parent / "models" / "whisper-wolof-ct2")
)
FALLBACK_HF_MODEL = "momosl/whisper-wolof-v1-ct2"

model = None


def get_model():
    global model
    if model is not None:
        return model

    from faster_whisper import WhisperModel

    if os.path.exists(os.path.join(MODEL_DIR, "config.json")):
        print(f"Chargement modèle local: {MODEL_DIR}")
        model = WhisperModel(MODEL_DIR, device="cpu", compute_type="int8", cpu_threads=4)
    else:
        print(f"Modèle local non trouvé dans {MODEL_DIR}")
        print(f"Téléchargement depuis HuggingFace: {FALLBACK_HF_MODEL}")
        print("(Nécessite internet la première fois uniquement)")
        from huggingface_hub import snapshot_download
        os.makedirs(MODEL_DIR, exist_ok=True)
        snapshot_download(FALLBACK_HF_MODEL, local_dir=MODEL_DIR)
        model = WhisperModel(MODEL_DIR, device="cpu", compute_type="int8", cpu_threads=4)

    print("Modèle chargé — prêt pour la transcription offline !")
    return model


def convert_to_wav(input_path: str) -> str:
    output_path = input_path.rsplit(".", 1)[0] + ".wav"
    audio = AudioSegment.from_file(input_path)
    audio = audio.set_frame_rate(16000).set_channels(1).set_sample_width(2)
    audio.export(output_path, format="wav")
    return output_path


@app.on_event("startup")
async def startup():
    import asyncio
    loop = asyncio.get_event_loop()
    loop.run_in_executor(None, get_model)


@app.post("/")
async def transcribe_raw(request: Request):
    """Endpoint compatible avec le format Lambda Function URL."""
    content_type = request.headers.get("content-type", "")
    body = await request.body()

    if not body:
        return JSONResponse({"error": "No audio data"}, status_code=400)

    ext = ".webm"
    if "wav" in content_type:
        ext = ".wav"
    elif "mp3" in content_type or "mpeg" in content_type:
        ext = ".mp3"
    elif "ogg" in content_type:
        ext = ".ogg"

    tmp_path = None
    wav_path = None
    try:
        with tempfile.NamedTemporaryFile(delete=False, suffix=ext) as tmp:
            tmp.write(body)
            tmp_path = tmp.name

        wav_path = convert_to_wav(tmp_path)

        m = get_model()
        segments_gen, info = m.transcribe(
            wav_path,
            language="fr",
            task="transcribe",
            beam_size=3,
            vad_filter=True,
            vad_parameters=dict(min_silence_duration_ms=500, speech_pad_ms=200),
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

        return JSONResponse({
            "text": full_text.strip(),
            "segments": segments,
            "language": "wo",
            "duration": round(info.duration, 1),
        })

    except Exception as e:
        return JSONResponse({"error": str(e)}, status_code=500)

    finally:
        for path in [tmp_path, wav_path]:
            try:
                if path and os.path.exists(path):
                    os.unlink(path)
            except Exception:
                pass


@app.post("/api/transcribe")
async def transcribe_upload(file: UploadFile = File(...)):
    """Endpoint multipart pour upload de fichier."""
    if not file.filename:
        raise HTTPException(status_code=400, detail="Aucun fichier")

    tmp_path = None
    wav_path = None
    try:
        ext = os.path.splitext(file.filename)[1].lower() or ".webm"
        with tempfile.NamedTemporaryFile(delete=False, suffix=ext) as tmp:
            content = await file.read()
            tmp.write(content)
            tmp_path = tmp.name

        wav_path = convert_to_wav(tmp_path)

        m = get_model()
        segments_gen, info = m.transcribe(
            wav_path,
            language="fr",
            task="transcribe",
            beam_size=3,
            vad_filter=True,
            vad_parameters=dict(min_silence_duration_ms=500, speech_pad_ms=200),
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

        return JSONResponse({
            "text": full_text.strip(),
            "segments": segments,
            "language": "wo",
            "duration": round(info.duration, 1),
        })

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

    finally:
        for path in [tmp_path, wav_path]:
            try:
                if path and os.path.exists(path):
                    os.unlink(path)
            except Exception:
                pass


@app.post("/api/translate")
async def translate(request: Request):
    """Traduction Wolof vers d'autres langues — offline avec argos-translate."""
    try:
        data = await request.json()
        text = data.get("text", "").strip()
        target_lang = data.get("target_lang", "fr")

        if not text:
            return JSONResponse({"error": "No text to translate"}, status_code=400)

        import argostranslate.package
        import argostranslate.translate

        lang_map = {
            "fr": "French",
            "en": "English",
            "ar": "Arabic",
            "es": "Spanish",
            "pt": "Portuguese",
        }
        target_name = lang_map.get(target_lang, "French")

        installed = argostranslate.translate.get_installed_languages()
        from_lang = next((l for l in installed if l.name == "French"), None)
        to_lang = next((l for l in installed if l.name == target_name), None)

        if not from_lang or not to_lang:
            argostranslate.package.update_package_index()
            available = argostranslate.package.get_available_packages()
            pkg = next(
                (p for p in available if p.from_code == "fr" and p.to_code == target_lang),
                None
            )
            if pkg:
                argostranslate.package.install_from_path(pkg.download())
                installed = argostranslate.translate.get_installed_languages()
                from_lang = next((l for l in installed if l.name == "French"), None)
                to_lang = next((l for l in installed if l.name == target_name), None)

        if from_lang and to_lang:
            translation = from_lang.get_translation(to_lang)
            translated = translation.translate(text)
        else:
            translated = "[Package de traduction non installé pour cette langue]"

        return JSONResponse({"translated_text": translated, "source_lang": "wo", "target_lang": target_lang})

    except ImportError:
        return JSONResponse(
            {"error": "argostranslate non installé. Lancez: pip install argostranslate"},
            status_code=500
        )
    except Exception as e:
        return JSONResponse({"error": str(e)}, status_code=500)


@app.get("/api/health")
async def health():
    return {
        "status": "ok",
        "model": MODEL_DIR,
        "offline": True,
        "loaded": model is not None,
    }


if __name__ == "__main__":
    import uvicorn
    print("=" * 60)
    print("   WOLOF TRANSCRIBER — MODE LOCAL OFFLINE")
    print(f"   Modèle: {MODEL_DIR}")
    print("   URL: http://localhost:8000")
    print("=" * 60)
    uvicorn.run(app, host="0.0.0.0", port=8000)
