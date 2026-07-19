"""
Push le modèle Wolof fine-tuné sur Hugging Face Hub.
À exécuter sur Colab (GPU) ou en local.

Cellule 1 sur Colab:
!pip install -q huggingface_hub peft transformers==4.46.0 accelerate torch

Cellule 2:
from huggingface_hub import login
login()  # entre ton token HF

Cellule 3: colle ce script
"""

import os
import torch
from transformers import WhisperForConditionalGeneration, WhisperProcessor
from peft import PeftModel

MODEL_ID = "openai/whisper-large-v3"
ADAPTER_PATH = "/content/model"  # là où tu as extrait le zip
HF_REPO = "momosl/whisper-wolof-v1"  # ton repo HF

print("Chargement du processeur...")
processor = WhisperProcessor.from_pretrained(ADAPTER_PATH)

print("Chargement de Whisper Large V3...")
base_model = WhisperForConditionalGeneration.from_pretrained(
    MODEL_ID,
    torch_dtype=torch.float16,
    device_map="auto",
)

print("Application du LoRA...")
model = PeftModel.from_pretrained(base_model, ADAPTER_PATH)
model = model.merge_and_unload()

print(f"Push vers {HF_REPO}...")
model.push_to_hub(HF_REPO, safe_serialization=True)
processor.push_to_hub(HF_REPO)

print(f"\n{'='*60}")
print(f"   MODÈLE PUBLIÉ !")
print(f"   https://huggingface.co/{HF_REPO}")
print(f"{'='*60}")
