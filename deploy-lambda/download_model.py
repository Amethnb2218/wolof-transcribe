"""Télécharge le modèle HF au moment du build Docker — embarqué dans l'image."""
from huggingface_hub import snapshot_download

MODEL_ID = "momosl/whisper-wolof-v1"
MODEL_DIR = "/opt/model"

print(f"Downloading {MODEL_ID}...")
snapshot_download(MODEL_ID, local_dir=MODEL_DIR)
print("Model downloaded!")
