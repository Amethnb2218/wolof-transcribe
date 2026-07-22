FROM python:3.11-slim

RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN pip install --no-cache-dir flask flask-cors faster-whisper gunicorn requests

RUN mkdir -p /opt/model && \
    curl -sL -o /opt/model/config.json https://huggingface.co/momosl/whisper-wolof-v2-ct2/resolve/main/config.json && \
    curl -sL -o /opt/model/vocabulary.json https://huggingface.co/momosl/whisper-wolof-v2-ct2/resolve/main/vocabulary.json && \
    curl -sL -o /opt/model/tokenizer_config.json https://huggingface.co/momosl/whisper-wolof-v2-ct2/resolve/main/tokenizer_config.json && \
    curl -sL -o /opt/model/vocab.json https://huggingface.co/momosl/whisper-wolof-v2-ct2/resolve/main/vocab.json && \
    curl -sL -o /opt/model/merges.txt https://huggingface.co/momosl/whisper-wolof-v2-ct2/resolve/main/merges.txt && \
    curl -sL -o /opt/model/added_tokens.json https://huggingface.co/momosl/whisper-wolof-v2-ct2/resolve/main/added_tokens.json && \
    curl -sL -o /opt/model/special_tokens_map.json https://huggingface.co/momosl/whisper-wolof-v2-ct2/resolve/main/special_tokens_map.json && \
    curl -sL -o /opt/model/normalizer.json https://huggingface.co/momosl/whisper-wolof-v2-ct2/resolve/main/normalizer.json && \
    curl -sL -o /opt/model/preprocessor_config.json https://huggingface.co/momosl/whisper-wolof-v2-ct2/resolve/main/preprocessor_config.json && \
    curl --http1.1 --retry 3 --retry-delay 5 -L -o /opt/model/model.bin https://huggingface.co/momosl/whisper-wolof-v2-ct2/resolve/main/model.bin

COPY app.py .

EXPOSE 8080

CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--timeout", "300", "--workers", "1", "app:app"]
