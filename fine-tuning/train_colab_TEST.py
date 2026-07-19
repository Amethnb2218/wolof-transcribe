"""
Fine-tuning Whisper Large-V3 — Wolof avec QLoRA
Colab T4 — Version test UTILISABLE (~2h30)
Produit un modèle téléchargeable pour tester l'app en attendant le full training.
"""

# ============================================================
# INSTALLATION
# ============================================================
import subprocess
print("Installation des librairies...")
subprocess.run("pip install -q -U bitsandbytes==0.43.3 peft transformers==4.46.0 datasets==3.1.0 accelerate==1.1.0 evaluate jiwer soundfile librosa scipy".split())

import os
os.environ["BNB_CUDA_VERSION"] = "121"
os.environ["PYTORCH_CUDA_ALLOC_CONF"] = "expandable_segments:True"

import random
import numpy as np
import torch
from datasets import load_dataset, Audio, concatenate_datasets
from transformers import (
    WhisperFeatureExtractor,
    WhisperTokenizer,
    WhisperProcessor,
    WhisperForConditionalGeneration,
    Seq2SeqTrainingArguments,
    Seq2SeqTrainer,
    BitsAndBytesConfig
)
from peft import prepare_model_for_kbit_training, LoraConfig, get_peft_model
from dataclasses import dataclass
from typing import Any, Dict, List, Union
import evaluate

# ============================================================
# CONFIG — Optimisé pour qualité + temps raisonnable
# ============================================================
BASE_MODEL = "openai/whisper-large-v3"
OUTPUT_DIR = "/content/whisper-wolof-test"

BATCH_SIZE = 2
EVAL_BATCH_SIZE = 4
GRADIENT_ACCUMULATION = 4   # Batch effectif = 2 x 1 GPU x 4 = 8
LEARNING_RATE = 2e-4        # Plus agressif pour un training court
WARMUP_STEPS = 30
MAX_STEPS = 800             # Plus de steps grâce à accumulation réduite
EVAL_STEPS = 800            # 1 seule éval à la fin
SAVE_STEPS = 800
LOGGING_STEPS = 10
AUGMENT_PROB = 0.3

os.makedirs(OUTPUT_DIR, exist_ok=True)

print(f"\n{'='*60}")
print(f"   TRAINING WOLOF — VERSION TEST UTILISABLE")
print(f"   {MAX_STEPS} steps, ~10h audio, ~1h sur T4")
print(f"{'='*60}")
print(f"\nGPU: {torch.cuda.get_device_name(0)} ({torch.cuda.get_device_properties(0).total_memory / 1e9:.1f} GB)")

# ============================================================
# 1. DATASET (~10 000 samples = ~20h audio)
# ============================================================
print("\nTéléchargement du dataset (~10h d'audio wolof)...")
train_ds = load_dataset(
    "soynade-research/Wolof-ASR-Data",
    split="train[:5000]",
    trust_remote_code=False,
)
test_ds = load_dataset(
    "soynade-research/Wolof-ASR-Data",
    split="test[:200]",
    trust_remote_code=False,
)
print(f"Wolof-ASR-Data: {len(train_ds):,} train, {len(test_ds):,} test")

# Normaliser colonnes
cols = train_ds.column_names
text_col = next((c for c in ["sentence", "text", "transcription"] if c in cols), None)
audio_col = next((c for c in ["audio", "path", "audio_path"] if c in cols), None)

if text_col and text_col != "sentence":
    train_ds = train_ds.rename_column(text_col, "sentence")
    test_ds = test_ds.rename_column(text_col, "sentence")
if audio_col and audio_col != "audio":
    train_ds = train_ds.rename_column(audio_col, "audio")
    test_ds = test_ds.rename_column(audio_col, "audio")

keep = ["audio", "sentence"]
train_ds = train_ds.remove_columns([c for c in train_ds.column_names if c not in keep])
test_ds = test_ds.remove_columns([c for c in test_ds.column_names if c not in keep])

train_ds = train_ds.filter(lambda x: x["sentence"] and len(x["sentence"].strip()) > 0)
test_ds = test_ds.filter(lambda x: x["sentence"] and len(x["sentence"].strip()) > 0)

# Bonus galsenai
print("Bonus: galsenai/wolof_tts...")
try:
    galsen = load_dataset("galsenai/wolof_tts", split="train[:5000]")
    gcols = galsen.column_names
    gtxt = next((c for c in ["sentence", "text", "transcription"] if c in gcols), None)
    gaud = next((c for c in ["audio", "path", "audio_path"] if c in gcols), None)
    if gtxt and gaud:
        if gtxt != "sentence": galsen = galsen.rename_column(gtxt, "sentence")
        if gaud != "audio": galsen = galsen.rename_column(gaud, "audio")
        galsen = galsen.remove_columns([c for c in galsen.column_names if c not in keep])
        galsen = galsen.cast_column("audio", Audio(sampling_rate=16000))
        train_ds = train_ds.cast_column("audio", Audio(sampling_rate=16000))
        train_ds = concatenate_datasets([train_ds, galsen])
        print(f"   +{len(galsen):,} exemples galsenai")
except Exception as e:
    print(f"   Pas dispo: {e}")

print(f"\nTotal: {len(train_ds):,} train, {len(test_ds):,} test")

# ============================================================
# 2. PROCESSEUR WHISPER
# ============================================================
feature_extractor = WhisperFeatureExtractor.from_pretrained(BASE_MODEL)
tokenizer = WhisperTokenizer.from_pretrained(BASE_MODEL, language="french", task="transcribe")
processor = WhisperProcessor.from_pretrained(BASE_MODEL, language="french", task="transcribe")

# ============================================================
# 3. RESAMPLE 16kHz
# ============================================================
train_ds = train_ds.cast_column("audio", Audio(sampling_rate=16000))
test_ds = test_ds.cast_column("audio", Audio(sampling_rate=16000))

# ============================================================
# 4. FILTRAGE SEQUENCES TROP LONGUES
# ============================================================
print("\nFiltrage des séquences trop longues...")
MAX_LABEL_LENGTH = 448

def filter_labels_length(example):
    label_ids = tokenizer(example["sentence"]).input_ids
    return len(label_ids) < (MAX_LABEL_LENGTH - 5)

train_ds = train_ds.filter(filter_labels_length, num_proc=2)
test_ds = test_ds.filter(filter_labels_length, num_proc=2)
print(f"Après filtrage: {len(train_ds):,} train, {len(test_ds):,} test")

# ============================================================
# 5. DATA AUGMENTATION
# ============================================================
def augment_audio(audio_array, sr=16000):
    audio = audio_array.copy().astype(np.float32)
    if random.random() < 0.4:
        audio = audio + np.random.randn(len(audio)).astype(np.float32) * random.uniform(0.002, 0.02)
    if random.random() < 0.3:
        speed = random.uniform(0.88, 1.12)
        indices = np.round(np.arange(0, len(audio), speed)).astype(int)
        indices = indices[indices < len(audio)]
        audio = audio[indices]
    if random.random() < 0.5:
        audio = audio * random.uniform(0.5, 1.5)
    if random.random() < 0.25:
        delay = int(sr * random.uniform(0.02, 0.1))
        decay = random.uniform(0.1, 0.4)
        echo = np.zeros(len(audio) + delay, dtype=np.float32)
        echo[:len(audio)] += audio
        echo[delay:delay+len(audio)] += audio * decay
        audio = echo[:len(audio)]
    if random.random() < 0.35:
        t = np.arange(len(audio)) / sr
        audio = audio + 0.008 * np.sin(2 * np.pi * random.uniform(30, 250) * t).astype(np.float32)
    mx = np.max(np.abs(audio))
    if mx > 0:
        audio = audio / mx * 0.95
    return audio.astype(np.float32)

# ============================================================
# 6. DATASET ON-THE-FLY
# ============================================================
class WhisperDataset(torch.utils.data.Dataset):
    def __init__(self, hf_dataset, feature_extractor, tokenizer, augment=False):
        self.dataset = hf_dataset
        self.feature_extractor = feature_extractor
        self.tokenizer = tokenizer
        self.augment = augment

    def __len__(self):
        return len(self.dataset)

    def __getitem__(self, idx):
        item = self.dataset[idx]
        audio = item["audio"]
        audio_array = np.array(audio["array"], dtype=np.float32)
        sr = audio["sampling_rate"]

        if self.augment and random.random() < AUGMENT_PROB:
            audio_array = augment_audio(audio_array, sr)

        input_features = self.feature_extractor(
            audio_array, sampling_rate=sr
        ).input_features[0]

        labels = self.tokenizer(item["sentence"]).input_ids
        return {"input_features": input_features, "labels": labels}

train_dataset = WhisperDataset(train_ds, feature_extractor, tokenizer, augment=True)
test_dataset = WhisperDataset(test_ds, feature_extractor, tokenizer, augment=False)
print(f"Dataset prêt: {len(train_dataset):,} train, {len(test_dataset):,} test")

# ============================================================
# 7. MODELE QLoRA 4-bit
# ============================================================
print("\nChargement Whisper Large V3 (Quantification 4-bit)...")
bnb_config = BitsAndBytesConfig(
    load_in_4bit=True,
    bnb_4bit_quant_type="nf4",
    bnb_4bit_compute_dtype=torch.float16,
    bnb_4bit_use_double_quant=True,
)

model = WhisperForConditionalGeneration.from_pretrained(
    BASE_MODEL,
    quantization_config=bnb_config,
    device_map="auto"
)

model.config.use_cache = False
model.generation_config.language = "fr"
model.generation_config.task = "transcribe"
model.generation_config.forced_decoder_ids = None

model = prepare_model_for_kbit_training(model)
lora_config = LoraConfig(
    r=32,
    lora_alpha=64,
    target_modules=["q_proj", "v_proj"],
    lora_dropout=0.05,
    bias="none",
)
model = get_peft_model(model, lora_config)
print("\nParamètres entraînables :")
model.print_trainable_parameters()

# ============================================================
# 8. DATA COLLATOR + METRICS
# ============================================================
@dataclass
class DataCollatorSpeechSeq2SeqWithPadding:
    processor: Any
    decoder_start_token_id: int

    def __call__(self, features: List[Dict[str, Union[List[int], torch.Tensor]]]) -> Dict[str, torch.Tensor]:
        input_features = [{"input_features": f["input_features"]} for f in features]
        batch = self.processor.feature_extractor.pad(input_features, return_tensors="pt")
        label_features = [{"input_ids": f["labels"]} for f in features]
        labels_batch = self.processor.tokenizer.pad(label_features, return_tensors="pt")
        labels = labels_batch["input_ids"].masked_fill(labels_batch.attention_mask.ne(1), -100)
        if (labels[:, 0] == self.decoder_start_token_id).all().cpu().item():
            labels = labels[:, 1:]
        batch["labels"] = labels
        return batch

data_collator = DataCollatorSpeechSeq2SeqWithPadding(
    processor=processor,
    decoder_start_token_id=processor.tokenizer.convert_tokens_to_ids("<|startoftranscript|>"),
)

metric = evaluate.load("wer")

def compute_metrics(pred):
    pred_ids = pred.predictions
    label_ids = pred.label_ids
    label_ids[label_ids == -100] = tokenizer.pad_token_id
    pred_str = tokenizer.batch_decode(pred_ids, skip_special_tokens=True)
    label_str = tokenizer.batch_decode(label_ids, skip_special_tokens=True)
    wer = 100 * metric.compute(predictions=pred_str, references=label_str)
    return {"wer": wer}

# ============================================================
# 9. ENTRAINEMENT
# ============================================================
training_args = Seq2SeqTrainingArguments(
    output_dir=OUTPUT_DIR,
    per_device_train_batch_size=BATCH_SIZE,
    per_device_eval_batch_size=EVAL_BATCH_SIZE,
    gradient_accumulation_steps=GRADIENT_ACCUMULATION,
    learning_rate=LEARNING_RATE,
    lr_scheduler_type="cosine",
    warmup_steps=WARMUP_STEPS,
    weight_decay=0.01,
    max_steps=MAX_STEPS,
    gradient_checkpointing=True,
    fp16=True,
    eval_strategy="steps",
    eval_steps=EVAL_STEPS,
    save_steps=SAVE_STEPS,
    save_total_limit=2,
    logging_steps=LOGGING_STEPS,
    report_to=["tensorboard"],
    load_best_model_at_end=False,
    predict_with_generate=True,
    generation_max_length=225,
    remove_unused_columns=False,
    label_names=["labels"],
    push_to_hub=False,
    dataloader_num_workers=2,
)

trainer = Seq2SeqTrainer(
    args=training_args,
    model=model,
    train_dataset=train_dataset,
    eval_dataset=test_dataset,
    data_collator=data_collator,
    compute_metrics=compute_metrics,
    processing_class=processor.feature_extractor,
)

print(f"\n{'='*60}")
print(f"   ENTRAINEMENT WOLOF — TEST UTILISABLE")
print(f"   Batch effectif: {BATCH_SIZE} x 1 GPU x {GRADIENT_ACCUMULATION} = {BATCH_SIZE * GRADIENT_ACCUMULATION}")
print(f"   {MAX_STEPS} steps — Loss affichée toutes les {LOGGING_STEPS} steps")
print(f"   Durée estimée: ~1h")
print(f"   NE FERMEZ PAS CETTE PAGE !")
print(f"{'='*60}\n")

trainer.train()

# ============================================================
# 10. EVALUATION FINALE
# ============================================================
print("\n\nÉvaluation finale sur 200 samples...")
results = trainer.evaluate()
print(f"\n   WER: {results['eval_wer']:.1f}%")

# ============================================================
# 11. SAUVEGARDER
# ============================================================
FINAL_DIR = "/content/whisper-wolof-final"
trainer.save_model(FINAL_DIR)
processor.save_pretrained(FINAL_DIR)
tokenizer.save_pretrained(FINAL_DIR)

print(f"\n{'='*60}")
print(f"   ENTRAINEMENT TERMINE !")
print(f"   WER: {results['eval_wer']:.1f}%")
print(f"   Modèle sauvegardé: {FINAL_DIR}")
print(f"{'='*60}")

# ============================================================
# 12. TELECHARGER LE MODELE
# ============================================================
import shutil

print("\nPréparation du téléchargement...")
shutil.make_archive("/content/whisper-wolof-model", "zip", FINAL_DIR)

from google.colab import files
print("\n>>> Le téléchargement va démarrer automatiquement <<<")
print(">>> Décompresse le zip dans: wolof-transcriber/backend/models/whisper-wolof/ <<<\n")
files.download("/content/whisper-wolof-model.zip")
