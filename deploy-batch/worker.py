"""Wolof ASR Batch Worker — Downloads audio from S3, transcribes, translates, uploads result."""
import os
import sys
import json
import time
import tempfile
import boto3
from faster_whisper import WhisperModel

s3 = boto3.client("s3")

S3_BUCKET = os.environ["S3_BUCKET"]
AUDIO_KEY = os.environ["AUDIO_KEY"]
RESULT_KEY = os.environ["RESULT_KEY"]
JOB_ID = os.environ.get("JOB_ID", "unknown")

MODEL_DIR = "/opt/model"
NLLB_MODEL_DIR = "/opt/nllb"


def update_status(status, extra=None):
    data = {"status": status, "job_id": JOB_ID, "audio_key": AUDIO_KEY}
    if extra:
        data.update(extra)
    s3.put_object(
        Bucket=S3_BUCKET,
        Key=f"jobs/{JOB_ID}/status.json",
        Body=json.dumps(data),
        ContentType="application/json",
    )


def patch_ct2_config():
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


def detect_device():
    try:
        import torch
        if torch.cuda.is_available():
            return "cuda", "float16"
    except ImportError:
        pass
    return "cpu", "int8"


def transcribe(audio_path, device, compute_type):
    print(f"Loading Whisper model (device={device}, compute_type={compute_type})...", flush=True)
    model = WhisperModel(
        MODEL_DIR,
        device=device,
        compute_type=compute_type,
        cpu_threads=4,
    )
    print("Model loaded. Transcribing...", flush=True)

    segments_gen, info = model.transcribe(
        audio_path,
        task="transcribe",
        beam_size=5,
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
        if len(segments) % 50 == 0:
            print(f"  {len(segments)} segments transcribed ({round(seg.end)}s)...", flush=True)

    print(f"Transcription done: {len(segments)} segments, {round(info.duration)}s audio", flush=True)
    return {
        "text": full_text.strip(),
        "segments": segments,
        "language": info.language,
        "duration": round(info.duration, 1),
    }


def translate_segments(segments, full_text):
    if not os.path.exists(NLLB_MODEL_DIR):
        print("NLLB model not found, skipping translation", flush=True)
        return None, segments

    print("Loading NLLB translation model...", flush=True)
    from transformers import AutoTokenizer, AutoModelForSeq2SeqLM

    tokenizer = AutoTokenizer.from_pretrained(NLLB_MODEL_DIR)
    model = AutoModelForSeq2SeqLM.from_pretrained(NLLB_MODEL_DIR)

    try:
        import torch
        if torch.cuda.is_available():
            model = model.to("cuda")
            print("NLLB on GPU", flush=True)
    except ImportError:
        pass

    print("Translating...", flush=True)
    tokenizer.src_lang = "wol_Latn"
    tgt_lang_id = tokenizer.convert_tokens_to_ids("fra_Latn")

    def translate_text(text):
        if not text.strip():
            return ""
        inputs = tokenizer(text, return_tensors="pt", max_length=512, truncation=True)
        try:
            import torch
            if torch.cuda.is_available():
                inputs = {k: v.to("cuda") for k, v in inputs.items()}
        except ImportError:
            pass
        generated = model.generate(
            **inputs,
            forced_bos_token_id=tgt_lang_id,
            max_new_tokens=256,
            num_beams=4,
        )
        return tokenizer.decode(generated[0], skip_special_tokens=True)

    for i, seg in enumerate(segments):
        seg["translation"] = translate_text(seg["text"])
        if (i + 1) % 50 == 0:
            print(f"  {i+1}/{len(segments)} segments translated...", flush=True)

    full_translation = translate_text(full_text[:1000]) if len(full_text) > 0 else ""
    print(f"Translation done", flush=True)
    return full_translation, segments


def main():
    start_time = time.time()
    print(f"=== WOLOF BATCH WORKER ===", flush=True)
    print(f"Job: {JOB_ID}", flush=True)
    print(f"Audio: s3://{S3_BUCKET}/{AUDIO_KEY}", flush=True)

    update_status("processing")

    device, compute_type = detect_device()
    print(f"Device: {device} ({compute_type})", flush=True)

    print("Downloading audio from S3...", flush=True)
    audio_path = tempfile.mktemp(suffix=".audio")
    s3.download_file(S3_BUCKET, AUDIO_KEY, audio_path)
    file_size = os.path.getsize(audio_path)
    print(f"Downloaded: {round(file_size / 1024 / 1024, 1)} MB", flush=True)

    patch_ct2_config()

    result = transcribe(audio_path, device, compute_type)

    full_translation, segments_with_translation = translate_segments(
        result["segments"], result["text"]
    )

    processing_time = round(time.time() - start_time, 1)

    output = {
        "job_id": JOB_ID,
        "text": result["text"],
        "segments": segments_with_translation,
        "translation": full_translation,
        "language": result["language"],
        "duration": result["duration"],
        "processing_time": processing_time,
        "device": device,
        "compute_type": compute_type,
    }

    print(f"Uploading result to s3://{S3_BUCKET}/{RESULT_KEY}...", flush=True)
    s3.put_object(
        Bucket=S3_BUCKET,
        Key=RESULT_KEY,
        Body=json.dumps(output, ensure_ascii=False, indent=2),
        ContentType="application/json",
    )

    update_status("done", {
        "result_key": RESULT_KEY,
        "duration": result["duration"],
        "processing_time": processing_time,
        "device": device,
        "segments_count": len(result["segments"]),
    })

    os.unlink(audio_path)
    print(f"=== DONE in {processing_time}s ===", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"FATAL ERROR: {e}", flush=True)
        try:
            update_status("failed", {"error": str(e)})
        except:
            pass
        sys.exit(1)
