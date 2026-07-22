import os
import tempfile
import json
import asyncio
import httpx
from pathlib import Path
from dotenv import load_dotenv

load_dotenv()

import numpy as np
import noisereduce as nr
import soundfile as sf
import librosa
from fastapi import FastAPI, UploadFile, File, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydub import AudioSegment

app = FastAPI(title="Wolof Transcriber")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

MODEL_SIZE = os.environ.get("WHISPER_MODEL", "large-v3")
GROQ_API_KEY = os.environ.get("GROQ_API_KEY", "")
CUSTOM_MODEL_PATH = os.environ.get("CUSTOM_MODEL_PATH", "./models/whisper-wolof-mega")
USE_GROQ_WHISPER = os.environ.get("USE_GROQ_WHISPER", "true").lower() == "true"
WOLOF_API_URL = os.environ.get("WOLOF_API_URL", "")
HF_MODEL_ID = os.environ.get("HF_MODEL_ID", "")  # ex: "momosl/whisper-wolof-v1"
HF_API_TOKEN = os.environ.get("HF_API_TOKEN", "")
model = None
hf_pipeline = None
use_finetuned = False
CHUNK_DURATION = 300


async def transcribe_with_wolof_api(audio_path: str) -> dict:
    """Transcription via Modal.com (GPU T4, audio envoyé en base64)."""
    import base64

    with open(audio_path, "rb") as f:
        audio_bytes = f.read()

    audio_b64 = base64.b64encode(audio_bytes).decode("utf-8")

    async with httpx.AsyncClient(timeout=180.0) as client:
        response = await client.post(
            WOLOF_API_URL,
            json={"audio": audio_b64},
            headers={"Content-Type": "application/json"},
        )

    if response.status_code != 200:
        raise Exception(f"Wolof API error {response.status_code}: {response.text}")

    data = response.json()
    return {
        "text": data.get("text", "").strip(),
        "segments": data.get("segments", []),
    }


async def transcribe_with_hf_inference(audio_path: str) -> dict:
    """Transcription via HuggingFace Inference API — gratuit et permanent 24/7."""
    api_url = f"https://api-inference.huggingface.co/models/{HF_MODEL_ID}"
    headers = {}
    if HF_API_TOKEN:
        headers["Authorization"] = f"Bearer {HF_API_TOKEN}"

    with open(audio_path, "rb") as f:
        audio_bytes = f.read()

    async with httpx.AsyncClient(timeout=180.0) as client:
        response = await client.post(
            api_url,
            headers=headers,
            content=audio_bytes,
        )

    if response.status_code == 503:
        data = response.json()
        wait_time = data.get("estimated_time", 20)
        await asyncio.sleep(min(wait_time, 60))
        async with httpx.AsyncClient(timeout=180.0) as client:
            with open(audio_path, "rb") as f:
                audio_bytes = f.read()
            response = await client.post(
                api_url,
                headers=headers,
                content=audio_bytes,
            )

    if response.status_code != 200:
        raise Exception(f"HF Inference API error {response.status_code}: {response.text}")

    data = response.json()
    text = data.get("text", "") if isinstance(data, dict) else str(data)
    return {
        "text": text.strip(),
        "segments": [],
    }


async def transcribe_with_groq(audio_path: str) -> dict:
    """Transcription via Groq Whisper API — ultra rapide (GPU distant)."""
    async with httpx.AsyncClient(timeout=120.0) as client:
        with open(audio_path, "rb") as f:
            response = await client.post(
                "https://api.groq.com/openai/v1/audio/transcriptions",
                headers={"Authorization": f"Bearer {GROQ_API_KEY}"},
                files={"file": (os.path.basename(audio_path), f, "audio/wav")},
                data={
                    "model": "whisper-large-v3",
                    "response_format": "verbose_json",
                    "timestamp_granularities[]": "segment",
                    "prompt": "Wolof transcription: Naka nga def? Mangi fi rekk. Jërejëf. Ndax mën nga ma dimbalé? Waaw, baax na. Alxamdulillaay. Bismillaay. Inshallah.",
                },
            )

    if response.status_code != 200:
        raise Exception(f"Groq API error {response.status_code}: {response.text}")

    data = response.json()
    segments = []
    for seg in data.get("segments", []):
        segments.append({
            "start": round(seg["start"], 2),
            "end": round(seg["end"], 2),
            "text": seg["text"].strip(),
        })

    return {
        "text": data.get("text", "").strip(),
        "segments": segments,
    }


def get_model():
    global model, hf_pipeline, use_finetuned

    if model is not None or hf_pipeline is not None:
        return

    if USE_GROQ_WHISPER and GROQ_API_KEY:
        print("Mode Groq Whisper API active — pas de modele local a charger.")
        return

    # Priorité 1 : modèle fine-tuné LoRA
    if os.path.exists(CUSTOM_MODEL_PATH) and os.path.isdir(CUSTOM_MODEL_PATH):
        adapter_config = os.path.join(CUSTOM_MODEL_PATH, "adapter_config.json")
        is_lora = os.path.exists(adapter_config)

        try:
            if is_lora:
                from transformers import WhisperForConditionalGeneration, WhisperProcessor
                from peft import PeftModel
                import torch

                print(f"Chargement du modele LoRA: {CUSTOM_MODEL_PATH}")
                device = "cuda" if _has_cuda() else "cpu"

                base_model = WhisperForConditionalGeneration.from_pretrained(
                    "openai/whisper-large-v3",
                    torch_dtype=torch.float16 if device == "cuda" else torch.float32,
                    device_map="auto" if device == "cuda" else None,
                )
                lora_model = PeftModel.from_pretrained(base_model, CUSTOM_MODEL_PATH)
                lora_model = lora_model.merge_and_unload()

                processor = WhisperProcessor.from_pretrained(CUSTOM_MODEL_PATH)

                from transformers import pipeline as hf_pipe
                hf_pipeline = hf_pipe(
                    "automatic-speech-recognition",
                    model=lora_model,
                    tokenizer=processor.tokenizer,
                    feature_extractor=processor.feature_extractor,
                    device=device if device == "cuda" else -1,
                    chunk_length_s=30,
                    batch_size=4,
                    torch_dtype=torch.float16 if device == "cuda" else torch.float32,
                )
                use_finetuned = True
                print("Modele LoRA fusionne et charge !")
                return
            else:
                from transformers import pipeline as hf_pipe
                print(f"Chargement du modele fine-tune: {CUSTOM_MODEL_PATH}")
                hf_pipeline = hf_pipe(
                    "automatic-speech-recognition",
                    model=CUSTOM_MODEL_PATH,
                    device="cuda" if _has_cuda() else "cpu",
                    chunk_length_s=30,
                    batch_size=4,
                )
                use_finetuned = True
                print("Modele fine-tune charge !")
                return
        except Exception as e:
            print(f"Erreur chargement modele fine-tune: {e}")
            print("Fallback vers Whisper standard...")

    # Priorité 2 : Whisper standard
    import whisper
    print(f"Chargement du modele Whisper {MODEL_SIZE}...")
    model = whisper.load_model(MODEL_SIZE)
    use_finetuned = False
    print("Modele Whisper charge !")


def _has_cuda():
    try:
        import torch
        return torch.cuda.is_available()
    except ImportError:
        return False


def convert_to_wav(input_path: str) -> str:
    output_path = input_path.rsplit(".", 1)[0] + "_converted.wav"
    audio = AudioSegment.from_file(input_path)
    audio = audio.set_frame_rate(16000).set_channels(1).set_sample_width(2)
    audio.export(output_path, format="wav")
    return output_path


def denoise_audio(audio_data: np.ndarray, sample_rate: int) -> np.ndarray:
    return nr.reduce_noise(
        y=audio_data,
        sr=sample_rate,
        prop_decrease=0.75,
        n_fft=2048,
        hop_length=512,
    )


def vad_filter(audio_data: np.ndarray, sr: int, threshold: float = 0.01) -> np.ndarray:
    """Voice Activity Detection simple - supprime les silences longs."""
    frame_length = int(0.025 * sr)
    hop = int(0.010 * sr)
    energy = np.array([
        np.sum(np.abs(audio_data[i:i+frame_length])**2)
        for i in range(0, len(audio_data) - frame_length, hop)
    ])
    energy_norm = energy / (np.max(energy) + 1e-8)

    voice_frames = energy_norm > threshold
    # Garder l'audio tel quel mais marquer les zones de voix
    # On ne coupe pas pour ne pas casser les timestamps
    return audio_data


def get_audio_chunks(audio_path: str, chunk_duration: int = CHUNK_DURATION):
    audio_data, sr = librosa.load(audio_path, sr=16000)
    total_duration = len(audio_data) / sr
    chunk_samples = chunk_duration * sr
    chunks = []

    for start_sample in range(0, len(audio_data), chunk_samples):
        end_sample = min(start_sample + chunk_samples, len(audio_data))
        chunk = audio_data[start_sample:end_sample]
        start_time = start_sample / sr
        chunks.append({
            "audio": chunk,
            "start_time": start_time,
            "sr": sr,
        })

    return chunks, total_duration


async def correct_with_llm(text: str) -> str:
    if not GROQ_API_KEY or not text.strip():
        return text

    prompt = (
        "Tu es un correcteur expert en langue wolof. "
        "Corrige UNIQUEMENT l'orthographe et la ponctuation du texte wolof suivant. "
        "NE CHANGE PAS le sens, ne traduis pas, ne reformule pas, ne supprime rien. "
        "Si le texte contient du français melange au wolof, garde les deux langues telles quelles. "
        "Retourne UNIQUEMENT le texte corrige, rien d'autre.\n\n"
        f"Texte: {text}"
    )

    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(
                "https://api.groq.com/openai/v1/chat/completions",
                headers={
                    "Authorization": f"Bearer {GROQ_API_KEY}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": "llama-3.3-70b-versatile",
                    "messages": [
                        {"role": "system", "content": "Tu es un correcteur expert en wolof. Corrige uniquement l'orthographe et la ponctuation sans changer le sens ou le contenu."},
                        {"role": "user", "content": prompt},
                    ],
                    "temperature": 0.1,
                    "max_tokens": 4096,
                },
            )

        if response.status_code == 200:
            data = response.json()
            corrected = data["choices"][0]["message"]["content"].strip()
            return corrected
        else:
            return text
    except Exception:
        return text


def transcribe_chunk_local(audio_data: np.ndarray, sr: int, time_offset: float = 0.0) -> dict:
    get_model()

    denoised = denoise_audio(audio_data, sr)

    if use_finetuned and hf_pipeline is not None:
        result = hf_pipeline(
            {"array": denoised, "sampling_rate": sr},
            return_timestamps=True,
            generate_kwargs={"language": "wo", "task": "transcribe"},
        )
        segments = []
        if result.get("chunks"):
            for chunk in result["chunks"]:
                ts = chunk.get("timestamp", (0, 0))
                segments.append({
                    "start": round((ts[0] or 0) + time_offset, 2),
                    "end": round((ts[1] or 0) + time_offset, 2),
                    "text": chunk["text"].strip(),
                })
        return {
            "text": result["text"].strip(),
            "segments": segments,
        }
    else:
        import whisper
        with tempfile.NamedTemporaryFile(delete=False, suffix=".wav") as tmp:
            sf.write(tmp.name, denoised, sr)
            tmp_path = tmp.name

        try:
            result = model.transcribe(
                tmp_path,
                language="wo",
                task="transcribe",
                beam_size=5,
                best_of=5,
                temperature=(0.0, 0.2, 0.4, 0.6, 0.8, 1.0),
                condition_on_previous_text=True,
                compression_ratio_threshold=2.4,
                logprob_threshold=-1.0,
                no_speech_threshold=0.6,
            )
        finally:
            os.unlink(tmp_path)

        segments = []
        for seg in result.get("segments", []):
            segments.append({
                "start": round(seg["start"] + time_offset, 2),
                "end": round(seg["end"] + time_offset, 2),
                "text": seg["text"].strip(),
            })

        return {
            "text": result["text"].strip(),
            "segments": segments,
        }


@app.on_event("startup")
async def startup():
    asyncio.get_event_loop().run_in_executor(None, get_model)


@app.websocket("/ws/transcribe")
async def websocket_transcribe(websocket: WebSocket):
    await websocket.accept()

    try:
        data = await websocket.receive_bytes()

        await websocket.send_json({
            "type": "status",
            "message": "Fichier recu, conversion en cours..."
        })

        with tempfile.NamedTemporaryFile(delete=False, suffix=".audio") as tmp:
            tmp.write(data)
            tmp_path = tmp.name

        wav_path = None
        try:
            wav_path = convert_to_wav(tmp_path)

            audio_data, sr = librosa.load(wav_path, sr=16000)
            total_duration = len(audio_data) / sr

            await websocket.send_json({
                "type": "info",
                "total_duration": round(total_duration, 1),
                "total_chunks": 1,
            })

            if WOLOF_API_URL:
                msg = "Transcription en cours (Wolof fine-tuné)..."
            elif HF_MODEL_ID:
                msg = "Transcription en cours (Wolof HF Inference)..."
            elif USE_GROQ_WHISPER and GROQ_API_KEY:
                msg = "Transcription en cours (Groq Whisper API)..."
            else:
                msg = "Transcription en cours..."

            await websocket.send_json({
                "type": "progress",
                "chunk": 1,
                "total_chunks": 1,
                "message": msg,
            })

            if WOLOF_API_URL:
                result = await transcribe_with_wolof_api(wav_path)
            elif HF_MODEL_ID:
                result = await transcribe_with_hf_inference(wav_path)
            elif USE_GROQ_WHISPER and GROQ_API_KEY:
                result = await transcribe_with_groq(wav_path)
            else:
                chunks, total_duration = get_audio_chunks(wav_path)
                full_text = ""
                all_segs = []
                for i, chunk in enumerate(chunks):
                    await websocket.send_json({
                        "type": "progress",
                        "chunk": i + 1,
                        "total_chunks": len(chunks),
                        "message": f"Transcription du segment {i + 1}/{len(chunks)}..."
                    })
                    loop = asyncio.get_event_loop()
                    r = await loop.run_in_executor(
                        None, transcribe_chunk_local, chunk["audio"], chunk["sr"], chunk["start_time"]
                    )
                    full_text += " " + r["text"]
                    all_segs.extend(r["segments"])
                result = {"text": full_text.strip(), "segments": all_segs}

            raw_text = result["text"]
            corrected_text = await correct_with_llm(raw_text)

            corrected_segments = []
            for seg in result["segments"]:
                corrected_seg_text = await correct_with_llm(seg["text"])
                corrected_segments.append({
                    "start": seg["start"],
                    "end": seg["end"],
                    "text": corrected_seg_text,
                })

            await websocket.send_json({
                "type": "partial",
                "chunk": 1,
                "text": corrected_text,
                "segments": corrected_segments,
                "raw_text": raw_text,
            })

            await websocket.send_json({
                "type": "complete",
                "text": corrected_text,
                "segments": corrected_segments,
                "language": "wo",
                "duration": round(total_duration, 1),
            })

        finally:
            for path in [tmp_path, wav_path]:
                try:
                    if path and os.path.exists(path):
                        os.unlink(path)
                except Exception:
                    pass

    except WebSocketDisconnect:
        pass
    except Exception as e:
        try:
            await websocket.send_json({
                "type": "error",
                "message": str(e),
            })
        except Exception:
            pass


@app.post("/api/transcribe")
async def transcribe_upload(file: UploadFile = File(...)):
    if not file.filename:
        raise HTTPException(status_code=400, detail="Aucun fichier fourni")

    allowed_extensions = {".mp3", ".wav", ".m4a", ".ogg", ".flac", ".webm", ".mp4", ".aac", ".wma"}
    ext = os.path.splitext(file.filename)[1].lower()
    if ext not in allowed_extensions:
        raise HTTPException(
            status_code=400,
            detail=f"Format non supporte. Formats acceptes: {', '.join(allowed_extensions)}"
        )

    tmp_path = None
    wav_path = None
    try:
        with tempfile.NamedTemporaryFile(delete=False, suffix=ext) as tmp:
            content = await file.read()
            tmp.write(content)
            tmp_path = tmp.name

        wav_path = convert_to_wav(tmp_path)

        if WOLOF_API_URL:
            result = await transcribe_with_wolof_api(wav_path)
            audio_data, sr = librosa.load(wav_path, sr=16000)
            total_duration = len(audio_data) / sr
        elif HF_MODEL_ID:
            result = await transcribe_with_hf_inference(wav_path)
            audio_data, sr = librosa.load(wav_path, sr=16000)
            total_duration = len(audio_data) / sr
        elif USE_GROQ_WHISPER and GROQ_API_KEY:
            result = await transcribe_with_groq(wav_path)
            audio_data, sr = librosa.load(wav_path, sr=16000)
            total_duration = len(audio_data) / sr
        else:
            chunks, total_duration = get_audio_chunks(wav_path)
            full_text = ""
            all_segs = []
            for chunk in chunks:
                r = transcribe_chunk_local(chunk["audio"], chunk["sr"], chunk["start_time"])
                full_text += " " + r["text"]
                all_segs.extend(r["segments"])
            result = {"text": full_text.strip(), "segments": all_segs}

        corrected_text = await correct_with_llm(result["text"])
        all_segments = []
        for seg in result["segments"]:
            corrected_seg = await correct_with_llm(seg["text"])
            all_segments.append({
                "start": seg["start"],
                "end": seg["end"],
                "text": corrected_seg,
            })

        return JSONResponse({
            "success": True,
            "text": corrected_text,
            "segments": all_segments,
            "language": "wo",
            "duration": round(total_duration, 1),
        })

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Erreur: {str(e)}")

    finally:
        for path in [tmp_path, wav_path]:
            try:
                if path and os.path.exists(path):
                    os.unlink(path)
            except Exception:
                pass


@app.post("/api/translate")
async def translate_text(request: dict = None):
    from fastapi import Request
    import json

    if request is None:
        raise HTTPException(status_code=400, detail="Body requis")

    text = request.get("text", "")
    src_lang = request.get("src_lang", "wol_Latn")
    tgt_lang = request.get("tgt_lang", "fra_Latn")

    if not text.strip():
        raise HTTPException(status_code=400, detail="Texte vide")

    token = HF_API_TOKEN or os.environ.get("HF_API_KEY", "") or os.environ.get("HUGGINGFACE_API_KEY", "")

    try:
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"

        async with httpx.AsyncClient(timeout=60.0) as client:
            response = await client.post(
                "https://api-inference.huggingface.co/models/facebook/nllb-200-distilled-600M",
                headers=headers,
                json={
                    "inputs": text,
                    "parameters": {"src_lang": src_lang, "tgt_lang": tgt_lang},
                    "options": {"wait_for_model": True},
                },
            )

        if response.status_code == 503:
            data = response.json()
            wait_time = min(data.get("estimated_time", 20), 30)
            await asyncio.sleep(wait_time)
            async with httpx.AsyncClient(timeout=60.0) as client:
                response = await client.post(
                    "https://api-inference.huggingface.co/models/facebook/nllb-200-distilled-600M",
                    headers=headers,
                    json={
                        "inputs": text,
                        "parameters": {"src_lang": src_lang, "tgt_lang": tgt_lang},
                        "options": {"wait_for_model": True},
                    },
                )

        if response.status_code != 200:
            raise HTTPException(status_code=502, detail=f"HuggingFace error: {response.status_code}")

        data = response.json()
        if isinstance(data, list) and len(data) > 0:
            translation = data[0].get("translation_text", "")
        elif isinstance(data, dict):
            translation = data.get("translation_text", "")
        else:
            translation = ""

        return {"translation_text": translation}

    except httpx.TimeoutException:
        raise HTTPException(status_code=504, detail="Timeout traduction")
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Erreur traduction: {str(e)}")


@app.get("/api/health")
async def health():
    return {
        "status": "ok",
        "model": CUSTOM_MODEL_PATH if use_finetuned else MODEL_SIZE,
        "model_type": "finetuned" if use_finetuned else "whisper-standard",
        "model_loaded": model is not None or hf_pipeline is not None,
        "llm_correction": bool(GROQ_API_KEY),
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
