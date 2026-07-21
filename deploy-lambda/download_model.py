"""Download model files one by one with retry — resistant to network cuts."""
import os
import time
import urllib.request

MODEL_DIR = "/opt/model"
REPO = "momosl/whisper-wolof-v1-ct2"
BASE_URL = f"https://huggingface.co/{REPO}/resolve/main"

FILES = [
    "config.json",
    "model.bin",
    "vocabulary.json",
    "tokenizer_config.json",
    "vocab.json",
    "merges.txt",
    "added_tokens.json",
    "special_tokens_map.json",
    "normalizer.json",
    "preprocessor_config.json",
    ".gitattributes",
]

os.makedirs(MODEL_DIR, exist_ok=True)

for filename in FILES:
    dest = os.path.join(MODEL_DIR, filename)
    url = f"{BASE_URL}/{filename}"

    for attempt in range(5):
        try:
            print(f"Downloading {filename} (attempt {attempt+1})...")
            urllib.request.urlretrieve(url, dest)
            size = os.path.getsize(dest)
            print(f"  OK — {size / 1024 / 1024:.1f} MB")
            break
        except Exception as e:
            print(f"  FAILED: {e}")
            if attempt < 4:
                wait = 10 * (attempt + 1)
                print(f"  Retrying in {wait}s...")
                time.sleep(wait)
            else:
                raise RuntimeError(f"Failed to download {filename} after 5 attempts")

print("\nAll files downloaded!")
print(f"Contents of {MODEL_DIR}:")
for f in os.listdir(MODEL_DIR):
    size = os.path.getsize(os.path.join(MODEL_DIR, f))
    print(f"  {f}: {size / 1024 / 1024:.1f} MB")
