"""
Fine-tuning Whisper Large-V3 — Wolof (281h)
AWS p4d.24xlarge (8x A100 80GB)
Lancer avec: accelerate launch train_aws.py
"""

import os
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
)
from dataclasses import dataclass
from typing import Any, Dict, List, Union
import evaluate

# ============================================================
# CONFIG
# ============================================================
BASE_MODEL = "openai/whisper-large-v3"
OUTPUT_DIR = "./whisper-wolof-mega"
BATCH_SIZE = 16  # par GPU (8 GPUs x 16 = 128 effectif)
GRADIENT_ACCUMULATION = 2  # effectif total = 256
LEARNING_RATE = 1e-5
WARMUP_STEPS = 500
MAX_STEPS = 5000
EVAL_STEPS = 500
SAVE_STEPS = 500
AUGMENT_PROB = 0.4

os.makedirs(OUTPUT_DIR, exist_ok=True)

# ============================================================
# 1. CHARGER TOUT LE DATASET (144K + bonus)
# ============================================================
print("=" * 60)
print("   Telechargement du dataset complet...")
print("=" * 60)

train_ds = load_dataset(
    "soynade-research/Wolof-ASR-Data",
    split="train",
    trust_remote_code=True,
)

test_ds = load_dataset(
    "soynade-research/Wolof-ASR-Data",
    split="test[:3000]",
    trust_remote_code=True,
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

# Bonus: galsenai
print("Bonus: galsenai/wolof_tts...")
try:
    galsen = load_dataset("galsenai/wolof_tts", split="train", trust_remote_code=True)
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
# 4. DATA AUGMENTATION
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
    if random.random() < 0.15:
        try:
            from scipy.signal import butter, filtfilt
            b, a = butter(4, [300/(sr/2), 3400/(sr/2)], btype='band')
            audio = filtfilt(b, a, audio).astype(np.float32)
        except:
            pass
    mx = np.max(np.abs(audio))
    if mx > 0:
        audio = audio / mx * 0.95
    return audio.astype(np.float32)

# ============================================================
# 5. DATASET ON-THE-FLY
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

print(f"Train: {len(train_dataset):,} | Test: {len(test_dataset):,}")

# ============================================================
# 6. MODELE
# ============================================================
model = WhisperForConditionalGeneration.from_pretrained(BASE_MODEL)
model.generation_config.language = "fr"
model.generation_config.task = "transcribe"
model.generation_config.forced_decoder_ids = None
model.config.use_cache = False

print(f"Modele: {BASE_MODEL} ({model.num_parameters() / 1e6:.0f}M params)")

# ============================================================
# 7. DATA COLLATOR + METRICS
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
# 8. ENTRAINEMENT MULTI-GPU
# ============================================================
training_args = Seq2SeqTrainingArguments(
    output_dir=OUTPUT_DIR,
    per_device_train_batch_size=BATCH_SIZE,
    per_device_eval_batch_size=BATCH_SIZE,
    gradient_accumulation_steps=GRADIENT_ACCUMULATION,
    learning_rate=LEARNING_RATE,
    lr_scheduler_type="cosine",
    warmup_steps=WARMUP_STEPS,
    weight_decay=0.01,
    max_steps=MAX_STEPS,
    gradient_checkpointing=True,
    bf16=True,  # A100 supporte bf16
    eval_strategy="steps",
    eval_steps=EVAL_STEPS,
    save_steps=SAVE_STEPS,
    save_total_limit=3,
    logging_steps=10,
    report_to=["tensorboard"],
    load_best_model_at_end=True,
    metric_for_best_model="wer",
    greater_is_better=False,
    predict_with_generate=True,
    generation_max_length=225,
    remove_unused_columns=False,
    label_names=["labels"],
    push_to_hub=False,
    dataloader_num_workers=4,
    ddp_find_unused_parameters=False,
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
print(f"   ENTRAINEMENT MULTI-GPU (8x A100)")
print(f"   Batch effectif: {BATCH_SIZE} x 8 GPUs x {GRADIENT_ACCUMULATION} = {BATCH_SIZE * 8 * GRADIENT_ACCUMULATION}")
print(f"   {MAX_STEPS} steps")
print(f"{'='*60}\n")

trainer.train()

# ============================================================
# 9. EVALUATION FINALE
# ============================================================
results = trainer.evaluate()
print(f"\nWER final: {results['eval_wer']:.1f}%")

# ============================================================
# 10. SAUVEGARDER
# ============================================================
trainer.save_model(OUTPUT_DIR)
processor.save_pretrained(OUTPUT_DIR)
tokenizer.save_pretrained(OUTPUT_DIR)

print(f"\n{'='*60}")
print(f"   TERMINE !")
print(f"   Modele sauvegarde: {OUTPUT_DIR}")
print(f"   WER: {results['eval_wer']:.1f}%")
print(f"{'='*60}")
print(f"\n   Pour telecharger sur ton PC:")
print(f"   scp -r ubuntu@<IP>:{OUTPUT_DIR} ./whisper-wolof-mega/")
