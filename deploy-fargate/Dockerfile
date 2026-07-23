FROM python:3.11-slim

RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN pip install --no-cache-dir flask flask-cors faster-whisper gunicorn transformers torch --extra-index-url https://download.pytorch.org/whl/cpu
RUN pip install --no-cache-dir sentencepiece protobuf

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
    curl -sL -o /opt/model/generation_config.json https://huggingface.co/momosl/whisper-wolof-v2-ct2/resolve/main/generation_config.json && \
    curl --http1.1 --retry 3 --retry-delay 5 -L -o /opt/model/model.bin https://huggingface.co/momosl/whisper-wolof-v2-ct2/resolve/main/model.bin

RUN pip install --no-cache-dir ctranslate2

RUN python3 -c "from transformers import AutoTokenizer, AutoModelForSeq2SeqLM; \
    t = AutoTokenizer.from_pretrained('facebook/nllb-200-distilled-600M'); \
    m = AutoModelForSeq2SeqLM.from_pretrained('facebook/nllb-200-distilled-600M'); \
    t.save_pretrained('/opt/nllb-hf'); \
    m.save_pretrained('/opt/nllb-hf')"

RUN ct2-transformers-converter --model /opt/nllb-hf --output_dir /opt/nllb \
      --quantization int8 --force && \
    cp /opt/nllb-hf/sentencepiece.bpe.model /opt/nllb/ && \
    rm -rf /opt/nllb-hf

COPY app.py .

EXPOSE 8080

CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--timeout", "300", "--workers", "1", "app:app"]
