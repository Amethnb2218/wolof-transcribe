"""Wolof ASR SQS Worker — polls jobs, transcribes + translates, writes results.
Short audio (<2 min) -> local CPU (4 vCPU, ~90s)
Long audio (>=2 min) -> Kaggle GPU (2x T4, ~10s/min)
"""
import os
import json
import time
import tempfile
import signal
import subprocess
import base64
import urllib.request
import boto3
from faster_whisper import WhisperModel
from transformers import AutoTokenizer, AutoModelForSeq2SeqLM

REGION = os.environ.get("AWS_REGION", "us-east-1")
QUEUE_URL = os.environ["SQS_QUEUE_URL"]
TABLE_NAME = os.environ.get("DYNAMODB_TABLE", "wolof-asr-jobs")
RESULTS_BUCKET = os.environ.get("RESULTS_BUCKET", "wolof-asr-audio-335596040822")
MODEL_DIR = "/opt/model"
NLLB_MODEL_DIR = "/opt/nllb"
VISIBILITY_TIMEOUT = 900
HEARTBEAT_INTERVAL = 300

# Kaggle config (for long audio offloading)
KAGGLE_USERNAME = os.environ.get("KAGGLE_USERNAME", "amethsl")
KAGGLE_API_TOKEN = os.environ.get("KAGGLE_API_TOKEN", "")
KAGGLE_KERNEL_SLUG = os.environ.get("KAGGLE_KERNEL_SLUG", "amethsl/wolof-transcriber-gpu")
LONG_AUDIO_THRESHOLD_SEC = 120  # 2 min — above this, use Kaggle GPU

sqs = boto3.client("sqs", region_name=REGION)
s3 = boto3.client("s3", region_name=REGION)
dynamodb = boto3.resource("dynamodb", region_name=REGION)
table = dynamodb.Table(TABLE_NAME)

running = True


def signal_handler(sig, frame):
    global running
    print("Shutting down gracefully...", flush=True)
    running = False


signal.signal(signal.SIGTERM, signal_handler)
signal.signal(signal.SIGINT, signal_handler)

# --- Load models at startup (once) ---
print("Loading Whisper model...", flush=True)
whisper_model = WhisperModel(
    MODEL_DIR,
    device="cpu",
    compute_type="int8",
    cpu_threads=4,
    num_workers=1,
)
print("Whisper model loaded!", flush=True)

nllb_tokenizer = None
nllb_model_inst = None
try:
    if os.path.exists(NLLB_MODEL_DIR):
        print("Loading NLLB translation model...", flush=True)
        nllb_tokenizer = AutoTokenizer.from_pretrained(NLLB_MODEL_DIR)
        nllb_model_inst = AutoModelForSeq2SeqLM.from_pretrained(NLLB_MODEL_DIR)
        print("NLLB model loaded!", flush=True)
    else:
        print("WARNING: NLLB model not found — translation disabled", flush=True)
except Exception as e:
    print(f"WARNING: NLLB failed to load: {e}", flush=True)


def update_job_status(job_id, status, **extra):
    item = {
        "status": status,
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        **extra,
    }
    expr_parts = []
    attr_values = {}
    attr_names = {}
    for i, (k, v) in enumerate(item.items()):
        placeholder = f":v{i}"
        name_placeholder = f"#k{i}"
        expr_parts.append(f"{name_placeholder} = {placeholder}")
        attr_values[placeholder] = v
        attr_names[name_placeholder] = k
    table.update_item(
        Key={"job_id": job_id},
        UpdateExpression="SET " + ", ".join(expr_parts),
        ExpressionAttributeValues=attr_values,
        ExpressionAttributeNames=attr_names,
    )


def is_already_completed(job_id):
    resp = table.get_item(Key={"job_id": job_id}, ProjectionExpression="#s", ExpressionAttributeNames={"#s": "status"})
    item = resp.get("Item")
    return item and item.get("status") == "COMPLETED"


def transcribe_audio(audio_path):
    segments_gen, info = whisper_model.transcribe(
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
    return {
        "text": full_text.strip(),
        "segments": segments,
        "language": info.language,
        "duration": round(info.duration, 1),
    }


def translate_text(text, src_lang="wol_Latn", tgt_lang="fra_Latn"):
    if not nllb_tokenizer or not nllb_model_inst:
        return None
    nllb_tokenizer.src_lang = src_lang
    inputs = nllb_tokenizer(text, return_tensors="pt", max_length=512, truncation=True)
    tgt_lang_id = nllb_tokenizer.convert_tokens_to_ids(tgt_lang)
    generated = nllb_model_inst.generate(
        **inputs,
        forced_bos_token_id=tgt_lang_id,
        max_new_tokens=256,
        num_beams=4,
    )
    return nllb_tokenizer.decode(generated[0], skip_special_tokens=True)


def translate_segments(segments, src_lang="wol_Latn", tgt_lang="fra_Latn"):
    if not nllb_tokenizer or not nllb_model_inst:
        return None, []
    translated_segments = []
    full_translation = ""
    for seg in segments:
        if seg["text"].strip():
            tr = translate_text(seg["text"], src_lang, tgt_lang)
            translated_segments.append({
                "start": seg["start"],
                "end": seg["end"],
                "text": tr or "",
            })
            full_translation += (tr or "") + " "
        else:
            translated_segments.append(seg)
    return full_translation.strip(), translated_segments


def get_audio_duration_ffprobe(filepath):
    """Get audio duration in seconds using ffprobe (if available) or file size estimate."""
    try:
        result = subprocess.run(
            ["ffprobe", "-v", "quiet", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", filepath],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0:
            return float(result.stdout.strip())
    except (FileNotFoundError, ValueError, subprocess.TimeoutExpired):
        pass
    # Rough estimate: 1 MB ~= 60s for compressed audio
    size_mb = os.path.getsize(filepath) / (1024 * 1024)
    return size_mb * 60


def trigger_kaggle_gpu(job_id, input_key):
    """Push a Kaggle kernel to process this job on GPU."""
    if not KAGGLE_API_TOKEN or not KAGGLE_KERNEL_SLUG:
        return False

    auth = f"Bearer {KAGGLE_API_TOKEN}"

    kernel_script = f'''import os
os.environ["JOB_ID"] = "{job_id}"
os.environ["AUDIO_KEY"] = "{input_key}"
os.environ["S3_BUCKET"] = "{RESULTS_BUCKET}"

from kaggle_secrets import UserSecretsClient
secrets = UserSecretsClient()
os.environ["AWS_ACCESS_KEY_ID"] = secrets.get_secret("AWS_ACCESS_KEY_ID")
os.environ["AWS_SECRET_ACCESS_KEY"] = secrets.get_secret("AWS_SECRET_ACCESS_KEY")

exec(open("/kaggle/input/wolof-transcriber-script/kaggle-kernel.py").read())
'''

    payload = json.dumps({
        "id": KAGGLE_KERNEL_SLUG,
        "newTitle": f"wolof-job-{job_id[:8]}",
        "text": kernel_script,
        "language": "python",
        "kernelType": "script",
        "isPrivate": True,
        "enableGpu": True,
        "enableInternet": True,
    }).encode()

    req = urllib.request.Request(
        "https://www.kaggle.com/api/v1/kernels/push",
        data=payload,
        headers={
            "Authorization": auth,
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        resp = urllib.request.urlopen(req, timeout=30)
        result = json.loads(resp.read().decode())
        print(f"  Kaggle kernel pushed: {result}", flush=True)
        return True
    except Exception as e:
        print(f"  Kaggle push failed: {e} — falling back to CPU", flush=True)
        return False


def poll_kaggle_completion(job_id, receipt_handle, timeout_sec=1800):
    """Poll S3 for Kaggle job completion (Kaggle writes results directly to S3)."""
    start = time.time()
    while time.time() - start < timeout_sec:
        try:
            obj = s3.get_object(Bucket=RESULTS_BUCKET, Key=f"jobs/{job_id}/status.json")
            status_data = json.loads(obj["Body"].read().decode("utf-8"))
            kaggle_status = status_data.get("status", "")

            if kaggle_status == "done":
                # Kaggle finished — update DynamoDB and delete SQS message
                update_job_status(
                    job_id, "COMPLETED",
                    stage="DONE",
                    progress=100,
                    completed_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    result_key=f"results/{job_id}.json",
                    duration=str(status_data.get("processing_time", 0)),
                    device="gpu-t4-kaggle",
                )
                sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=receipt_handle)
                print(f"  Job {job_id} COMPLETED via Kaggle GPU", flush=True)
                return True
            elif kaggle_status == "failed":
                error = status_data.get("error", "Kaggle execution failed")
                update_job_status(job_id, "FAILED", stage="ERROR", error=error)
                sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=receipt_handle)
                print(f"  Job {job_id} FAILED on Kaggle: {error}", flush=True)
                return True
            else:
                # Still processing — update stage in DynamoDB
                stage_label = kaggle_status.upper() if kaggle_status else "KAGGLE_GPU"
                update_job_status(job_id, "PROCESSING", stage=stage_label, progress=50)

        except s3.exceptions.NoSuchKey:
            pass
        except Exception as e:
            print(f"  Kaggle poll error: {e}", flush=True)

        # Extend SQS visibility if needed
        elapsed = time.time() - start
        if elapsed > 600 and elapsed % 300 < 15:
            try:
                sqs.change_message_visibility(
                    QueueUrl=QUEUE_URL,
                    ReceiptHandle=receipt_handle,
                    VisibilityTimeout=900,
                )
            except Exception:
                pass

        time.sleep(15)

    # Timeout — Kaggle took too long
    print(f"  Kaggle timeout for job {job_id} — marking failed", flush=True)
    update_job_status(job_id, "FAILED", stage="ERROR", error="Kaggle GPU timeout (30 min)")
    sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=receipt_handle)
    return False


def process_job(message):
    body = json.loads(message["Body"])
    job_id = body["job_id"]
    input_bucket = body["input_bucket"]
    input_key = body["input_key"]
    source_language = body.get("source_language", "wol")
    target_language = body.get("target_language", "fra")
    receipt_handle = message["ReceiptHandle"]

    print(f"Processing job {job_id}: s3://{input_bucket}/{input_key}", flush=True)

    if is_already_completed(job_id):
        print(f"Job {job_id} already completed — skipping", flush=True)
        sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=receipt_handle)
        return

    update_job_status(job_id, "PROCESSING", stage="DOWNLOADING")

    tmp_path = None
    try:
        # Download audio
        with tempfile.NamedTemporaryFile(delete=False, suffix=".audio") as f:
            s3.download_fileobj(input_bucket, input_key, f)
            tmp_path = f.name
        file_size = os.path.getsize(tmp_path)
        print(f"  Downloaded {file_size / (1024*1024):.1f} MB", flush=True)

        # Check duration — route to Kaggle GPU if long audio
        audio_duration_est = get_audio_duration_ffprobe(tmp_path)
        print(f"  Estimated duration: {audio_duration_est:.0f}s", flush=True)

        if audio_duration_est >= LONG_AUDIO_THRESHOLD_SEC and KAGGLE_USERNAME:
            print(f"  Long audio ({audio_duration_est:.0f}s) — routing to Kaggle GPU", flush=True)
            update_job_status(job_id, "PROCESSING", stage="KAGGLE_GPU", progress=10)
            # Clean up local file — Kaggle will download from S3 directly
            os.unlink(tmp_path)
            tmp_path = None
            if trigger_kaggle_gpu(job_id, input_key):
                poll_kaggle_completion(job_id, receipt_handle)
                return
            else:
                # Kaggle unavailable — fall back to local CPU
                print(f"  Kaggle unavailable — processing locally on CPU", flush=True)
                with tempfile.NamedTemporaryFile(delete=False, suffix=".audio") as f:
                    s3.download_fileobj(input_bucket, input_key, f)
                    tmp_path = f.name

        # === LOCAL CPU PROCESSING ===
        # Transcribe
        update_job_status(job_id, "PROCESSING", stage="TRANSCRIBING", progress=25)
        t0 = time.time()
        result = transcribe_audio(tmp_path)
        transcribe_time = time.time() - t0
        print(f"  Transcription done in {transcribe_time:.1f}s — {result['duration']}s audio", flush=True)

        # Translate
        translation = None
        translate_time = 0
        translated_segs = []
        if nllb_tokenizer and result["text"]:
            update_job_status(job_id, "PROCESSING", stage="TRANSLATING", progress=70)
            src_code = "wol_Latn" if source_language == "wol" else f"{source_language}_Latn"
            tgt_code = "fra_Latn" if target_language == "fra" else f"{target_language}_Latn"
            t1 = time.time()
            translation, translated_segs = translate_segments(result["segments"], src_code, tgt_code)
            translate_time = time.time() - t1
            print(f"  Translation done in {translate_time:.1f}s", flush=True)

        # Build final result
        final_result = {
            "text": result["text"],
            "segments": result["segments"],
            "language": result["language"],
            "duration": result["duration"],
            "processing_time": round(transcribe_time + translate_time, 1),
            "device": "cpu-4vcpu",
            "pipeline_version": "whisper-nllb-v2",
        }
        if translation:
            final_result["translation"] = translation
            final_result["translated_segments"] = translated_segs

        # Write results to S3
        result_key = f"results/{job_id}.json"
        s3.put_object(
            Bucket=RESULTS_BUCKET,
            Key=result_key,
            Body=json.dumps(final_result, ensure_ascii=False),
            ContentType="application/json",
        )

        # Also write status.json for backward compat with existing frontend polling
        status_data = {
            "status": "done",
            "completed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "duration": result["duration"],
            "result_key": result_key,
        }
        s3.put_object(
            Bucket=RESULTS_BUCKET,
            Key=f"jobs/{job_id}/status.json",
            Body=json.dumps(status_data, ensure_ascii=False),
            ContentType="application/json",
        )

        # Update DynamoDB
        update_job_status(
            job_id, "COMPLETED",
            stage="DONE",
            progress=100,
            completed_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            result_key=result_key,
            duration=str(result["duration"]),
            processing_time=str(final_result["processing_time"]),
        )

        # Delete message from SQS
        sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=receipt_handle)
        print(f"  Job {job_id} COMPLETED (CPU)", flush=True)

    except Exception as e:
        print(f"  ERROR processing job {job_id}: {e}", flush=True)
        update_job_status(
            job_id, "FAILED",
            stage="ERROR",
            error=str(e)[:500],
        )
        # Write failed status to S3 for frontend compat
        s3.put_object(
            Bucket=RESULTS_BUCKET,
            Key=f"jobs/{job_id}/status.json",
            Body=json.dumps({"status": "failed", "error": str(e)[:500]}, ensure_ascii=False),
            ContentType="application/json",
        )
    finally:
        if tmp_path and os.path.exists(tmp_path):
            os.unlink(tmp_path)


def main():
    print("Worker ready — polling SQS...", flush=True)
    while running:
        try:
            resp = sqs.receive_message(
                QueueUrl=QUEUE_URL,
                MaxNumberOfMessages=1,
                WaitTimeSeconds=20,
                VisibilityTimeout=VISIBILITY_TIMEOUT,
            )
            messages = resp.get("Messages", [])
            if not messages:
                continue
            process_job(messages[0])
        except Exception as e:
            print(f"Polling error: {e}", flush=True)
            time.sleep(5)
    print("Worker stopped.", flush=True)


if __name__ == "__main__":
    main()
