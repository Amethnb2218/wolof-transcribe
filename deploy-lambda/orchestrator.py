"""
Orchestrator Lambda — Wolof ASR S3 Pipeline
Triggered by S3 upload event. Downloads audio, splits into 5-min chunks,
invokes wolof-asr Lambda in parallel, assembles results, saves to S3.
"""
import os
import json
import uuid
import time
import base64
import subprocess
import boto3
from concurrent.futures import ThreadPoolExecutor, as_completed

S3_BUCKET = os.environ.get("S3_BUCKET", "wolof-asr-audio-335596040822")
ASR_FUNCTION_NAME = os.environ.get("ASR_FUNCTION_NAME", "wolof-asr")
CHUNK_DURATION_SEC = 300  # 5 minutes per chunk
MAX_PARALLEL = 20  # Max parallel Lambda invocations

s3 = boto3.client("s3")
lambda_client = boto3.client("lambda")


def lambda_handler(event, context):
    """Handle S3 event trigger."""
    print(f"Event received: {json.dumps(event)[:500]}")

    # Extract S3 key from event
    record = event["Records"][0]
    bucket = record["s3"]["bucket"]["name"]
    key = record["s3"]["object"]["key"]

    # Extract job_id from key: uploads/{job_id}/{filename}
    parts = key.split("/")
    if len(parts) < 3 or parts[0] != "uploads":
        print(f"Ignoring key: {key}")
        return {"statusCode": 200, "body": "Ignored"}

    job_id = parts[1]
    filename = "/".join(parts[2:])
    print(f"Processing job_id={job_id}, file={filename}")

    # Write initial status
    write_status(job_id, {
        "status": "processing",
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "filename": filename,
        "chunks_done": 0,
        "chunks_total": 0,
    })

    try:
        # Download audio from S3
        local_input = f"/tmp/{job_id}_input"
        print(f"Downloading s3://{bucket}/{key} to {local_input}")
        s3.download_file(bucket, key, local_input)
        file_size = os.path.getsize(local_input)
        print(f"Downloaded {file_size / (1024*1024):.1f} MB")

        # Get audio duration
        duration = get_audio_duration(local_input)
        print(f"Audio duration: {duration:.1f}s ({duration/60:.1f} min)")

        # Split into chunks
        chunk_dir = f"/tmp/{job_id}_chunks"
        os.makedirs(chunk_dir, exist_ok=True)
        chunk_files = split_audio(local_input, chunk_dir, CHUNK_DURATION_SEC)
        print(f"Split into {len(chunk_files)} chunks")

        # Update status with total chunks
        write_status(job_id, {
            "status": "processing",
            "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "filename": filename,
            "duration": round(duration, 1),
            "chunks_done": 0,
            "chunks_total": len(chunk_files),
        })

        # Transcribe chunks in parallel
        results = transcribe_chunks_parallel(chunk_files, job_id)

        # Assemble final result
        final_result = assemble_results(results, duration, filename)

        # Save result to S3
        result_key = f"results/{job_id}.json"
        s3.put_object(
            Bucket=S3_BUCKET,
            Key=result_key,
            Body=json.dumps(final_result, ensure_ascii=False),
            ContentType="application/json",
        )

        # Update final status
        write_status(job_id, {
            "status": "done",
            "completed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "filename": filename,
            "duration": round(duration, 1),
            "chunks_total": len(chunk_files),
            "chunks_done": len(chunk_files),
            "result_key": result_key,
        })

        print(f"Job {job_id} completed successfully")
        return {"statusCode": 200, "body": json.dumps({"job_id": job_id, "status": "done"})}

    except Exception as e:
        print(f"Error processing job {job_id}: {e}")
        write_status(job_id, {
            "status": "error",
            "error": str(e),
            "filename": filename,
        })
        raise

    finally:
        # Cleanup /tmp
        cleanup_tmp(job_id)


def write_status(job_id, status_data):
    """Write job status to S3."""
    s3.put_object(
        Bucket=S3_BUCKET,
        Key=f"jobs/{job_id}/status.json",
        Body=json.dumps(status_data, ensure_ascii=False),
        ContentType="application/json",
    )


def get_audio_duration(filepath):
    """Get audio duration using ffprobe."""
    cmd = [
        "ffprobe", "-v", "quiet",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        filepath,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        raise RuntimeError(f"ffprobe failed: {result.stderr}")
    return float(result.stdout.strip())


def split_audio(input_path, output_dir, segment_duration):
    """Split audio into chunks using ffmpeg segment muxer."""
    output_pattern = os.path.join(output_dir, "chunk_%04d.mp3")

    cmd = [
        "ffmpeg", "-y",
        "-i", input_path,
        "-f", "segment",
        "-segment_time", str(segment_duration),
        "-c:a", "libmp3lame",
        "-ac", "1",          # mono
        "-ar", "16000",      # 16kHz (Whisper native rate)
        "-b:a", "64k",       # 64kbps (good quality, small files)
        "-reset_timestamps", "1",
        output_pattern,
    ]

    result = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    if result.returncode != 0:
        raise RuntimeError(f"ffmpeg split failed: {result.stderr[:500]}")

    # Collect chunk files in order
    chunks = sorted([
        os.path.join(output_dir, f)
        for f in os.listdir(output_dir)
        if f.startswith("chunk_") and f.endswith(".mp3")
    ])

    if not chunks:
        raise RuntimeError("ffmpeg produced no chunks")

    return chunks


def transcribe_single_chunk(chunk_path, chunk_index, total_chunks, job_id):
    """Invoke wolof-asr Lambda for a single chunk."""
    print(f"  Transcribing chunk {chunk_index + 1}/{total_chunks}")

    # Read chunk and base64 encode
    with open(chunk_path, "rb") as f:
        audio_bytes = f.read()

    chunk_size_mb = len(audio_bytes) / (1024 * 1024)
    print(f"  Chunk {chunk_index + 1} size: {chunk_size_mb:.2f} MB")

    # Build the payload matching wolof-asr handler expectations
    # The handler checks isBase64Encoded first, then tries to decode body
    payload = {
        "body": base64.b64encode(audio_bytes).decode("utf-8"),
        "isBase64Encoded": True,
        "requestContext": {"http": {"method": "POST"}},
    }

    # Invoke Lambda synchronously
    response = lambda_client.invoke(
        FunctionName=ASR_FUNCTION_NAME,
        InvocationType="RequestResponse",
        Payload=json.dumps(payload).encode("utf-8"),
    )

    # Parse response
    response_payload = json.loads(response["Payload"].read())

    if response.get("FunctionError"):
        raise RuntimeError(
            f"Chunk {chunk_index + 1} Lambda error: {response_payload}"
        )

    # The response has statusCode, headers, body structure
    if isinstance(response_payload.get("body"), str):
        result = json.loads(response_payload["body"])
    else:
        result = response_payload

    if response_payload.get("statusCode", 200) != 200:
        error_msg = result.get("error", "Unknown error")
        raise RuntimeError(f"Chunk {chunk_index + 1} transcription error: {error_msg}")

    return {
        "index": chunk_index,
        "text": result.get("text", ""),
        "segments": result.get("segments", []),
        "duration": result.get("duration", 0),
    }


def transcribe_chunks_parallel(chunk_files, job_id):
    """Transcribe all chunks in parallel using ThreadPoolExecutor."""
    total = len(chunk_files)
    results = [None] * total

    with ThreadPoolExecutor(max_workers=min(MAX_PARALLEL, total)) as executor:
        futures = {
            executor.submit(
                transcribe_single_chunk, chunk_path, i, total, job_id
            ): i
            for i, chunk_path in enumerate(chunk_files)
        }

        completed = 0
        for future in as_completed(futures):
            chunk_idx = futures[future]
            try:
                result = future.result()
                results[result["index"]] = result
                completed += 1
                print(f"  Completed {completed}/{total} chunks")
            except Exception as e:
                print(f"  ERROR on chunk {chunk_idx + 1}: {e}")
                # Store error but continue with other chunks
                results[chunk_idx] = {
                    "index": chunk_idx,
                    "text": f"[Erreur chunk {chunk_idx + 1}]",
                    "segments": [],
                    "duration": CHUNK_DURATION_SEC,
                    "error": str(e),
                }

    return results


def assemble_results(results, total_duration, filename):
    """Assemble chunk results into final transcription."""
    all_segments = []
    all_text_parts = []
    cumulative_offset = 0.0
    errors = []

    for chunk_result in results:
        if chunk_result is None:
            cumulative_offset += CHUNK_DURATION_SEC
            continue

        chunk_duration = chunk_result.get("duration", CHUNK_DURATION_SEC)

        # Offset segments by cumulative time
        for seg in chunk_result.get("segments", []):
            all_segments.append({
                "start": round(seg["start"] + cumulative_offset, 2),
                "end": round(seg["end"] + cumulative_offset, 2),
                "text": seg["text"],
            })

        all_text_parts.append(chunk_result.get("text", ""))

        if chunk_result.get("error"):
            errors.append({
                "chunk": chunk_result["index"] + 1,
                "error": chunk_result["error"],
            })

        cumulative_offset += chunk_duration

    full_text = " ".join(part for part in all_text_parts if part)

    result = {
        "text": full_text.strip(),
        "segments": all_segments,
        "language": "wo",
        "duration": round(total_duration, 1),
        "filename": filename,
        "chunks_processed": len(results),
    }

    if errors:
        result["errors"] = errors

    return result


def cleanup_tmp(job_id):
    """Clean up temporary files."""
    import shutil
    for path in [f"/tmp/{job_id}_input", f"/tmp/{job_id}_chunks"]:
        try:
            if os.path.isfile(path):
                os.unlink(path)
            elif os.path.isdir(path):
                shutil.rmtree(path)
        except Exception:
            pass
