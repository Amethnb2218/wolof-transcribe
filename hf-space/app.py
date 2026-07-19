import os
import torch
import spaces
import gradio as gr
import numpy as np
from transformers import WhisperForConditionalGeneration, WhisperProcessor, pipeline
from peft import PeftModel

MODEL_ID = "openai/whisper-large-v3"
ADAPTER_PATH = "./adapter"

pipe = None

def load_model():
    global pipe
    if pipe is not None:
        return pipe

    processor = WhisperProcessor.from_pretrained(ADAPTER_PATH)

    base_model = WhisperForConditionalGeneration.from_pretrained(
        MODEL_ID,
        torch_dtype=torch.float16,
        device_map="auto",
    )
    model = PeftModel.from_pretrained(base_model, ADAPTER_PATH)
    model = model.merge_and_unload()

    pipe = pipeline(
        "automatic-speech-recognition",
        model=model,
        tokenizer=processor.tokenizer,
        feature_extractor=processor.feature_extractor,
        torch_dtype=torch.float16,
        device="cuda",
        chunk_length_s=30,
        batch_size=4,
    )
    return pipe

@spaces.GPU(duration=60)
def transcribe(audio):
    if audio is None:
        return "Aucun audio fourni."

    p = load_model()

    if isinstance(audio, tuple):
        sr, audio_data = audio
        audio_data = audio_data.astype(np.float32)
        if audio_data.ndim > 1:
            audio_data = audio_data.mean(axis=1)
        if sr != 16000:
            import librosa
            audio_data = librosa.resample(audio_data, orig_sr=sr, target_sr=16000)
            sr = 16000
        input_audio = {"array": audio_data, "sampling_rate": sr}
    else:
        input_audio = audio

    result = p(
        input_audio,
        return_timestamps=True,
        generate_kwargs={"language": "fr", "task": "transcribe"},
    )

    return result["text"]

@spaces.GPU(duration=60)
def transcribe_api(audio_path):
    """API endpoint for external calls."""
    if not audio_path:
        return {"error": "No audio provided"}

    p = load_model()

    result = p(
        audio_path,
        return_timestamps=True,
        generate_kwargs={"language": "fr", "task": "transcribe"},
    )

    segments = []
    if result.get("chunks"):
        for chunk in result["chunks"]:
            ts = chunk.get("timestamp", (0, 0))
            segments.append({
                "start": round(ts[0] or 0, 2),
                "end": round(ts[1] or 0, 2),
                "text": chunk["text"].strip(),
            })

    return {
        "text": result["text"].strip(),
        "segments": segments,
        "language": "wo",
    }

demo = gr.Interface(
    fn=transcribe,
    inputs=gr.Audio(sources=["upload", "microphone"], type="numpy", label="Audio Wolof"),
    outputs=gr.Textbox(label="Transcription"),
    title="Wolof ASR — Whisper Large V3 Fine-tuné",
    description="Transcription audio Wolof avec Whisper Large V3 + LoRA fine-tuning",
)

if __name__ == "__main__":
    demo.launch()
