import sys
sys.modules['triton.ops'] = type(sys)('triton.ops')

"""
Fine-tuning Whisper Large-V3 — Wolof avec QLoRA
MAX QUALITÉ EN 1H — PARTIE 4 (samples 9000-12000)
"""

import os
os.environ["BNB_CUDA_VERSION"] = "121"
os.environ["PYTORCH_CUDA_ALLOC_CONF"] = "expandable_segments:True"

import random
import numpy as np
import torch
from datasets import load_dataset, Audio, concatenate_datasets
from transformers import (
    WhisperFeatureExtractor, WhisperTokenizer, WhisperProcessor,
    WhisperForConditionalGeneration, Seq2SeqTrainingArguments,
    Seq2SeqTrainer, BitsAndBytesConfig
)
from peft import prepare_model_for_kbit_training, LoraConfig, get_peft_model
from dataclasses import dataclass
from typing import Any, Dict, List, Union
import evaluate

BASE_MODEL = "openai/whisper-large-v3"
OUTPUT_DIR = "/content/whisper-wolof-max-p4"

BATCH_SIZE = 2
EVAL_BATCH_SIZE = 4
GRADIENT_ACCUMULATION = 2
LEARNING_RATE = 3e-4
WARMUP_STEPS = 20
MAX_STEPS = 750
EVAL_STEPS = 750
SAVE_STEPS = 750
LOGGING_STEPS = 10
AUGMENT_PROB = 0.3

os.makedirs(OUTPUT_DIR, exist_ok=True)

print(f"\n{'='*60}")
print(f"   TRAINING WOLOF — MAX 1H — PARTIE 4")
print(f"   Samples 9000-12000")
print(f"   {MAX_STEPS} steps, LoRA r=64 étendu")
print(f"{'='*60}")
print(f"\nGPU: {torch.cuda.get_device_name(0)} ({torch.cuda.get_device_properties(0).total_memory / 1e9:.1f} GB)")

print("\nTéléchargement dataset (samples 9000-12000)...")
train_ds = load_dataset("soynade-research/Wolof-ASR-Data", split="train[9000:12000]")
test_ds = load_dataset("soynade-research/Wolof-ASR-Data", split="test[:150]")
print(f"Chargé: {len(train_ds):,} train, {len(test_ds):,} test")

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

print("Bonus: galsenai/wolof_tts (samples 6000-8000)...")
try:
    galsen = load_dataset("galsenai/wolof_tts", split="train[6000:8000]")
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
        print(f"   +{len(galsen):,} exemples")
except Exception as e:
    print(f"   Pas dispo: {e}")

print(f"Total: {len(train_ds):,} train, {len(test_ds):,} test")

feature_extractor = WhisperFeatureExtractor.from_pretrained(BASE_MODEL)
tokenizer = WhisperTokenizer.from_pretrained(BASE_MODEL, language="french", task="transcribe")
processor = WhisperProcessor.from_pretrained(BASE_MODEL, language="french", task="transcribe")

train_ds = train_ds.cast_column("audio", Audio(sampling_rate=16000))
test_ds = test_ds.cast_column("audio", Audio(sampling_rate=16000))

MAX_LABEL_LENGTH = 448
def filter_labels_length(example):
    return len(tokenizer(example["sentence"]).input_ids) < (MAX_LABEL_LENGTH - 5)
train_ds = train_ds.filter(filter_labels_length, num_proc=2)
test_ds = test_ds.filter(filter_labels_length, num_proc=2)
print(f"Après filtrage: {len(train_ds):,} train, {len(test_ds):,} test")

def augment_audio(audio_array, sr=16000):
    audio = audio_array.copy().astype(np.float32)
    if random.random() < 0.4:
        audio += np.random.randn(len(audio)).astype(np.float32) * random.uniform(0.002, 0.015)
    if random.random() < 0.3:
        speed = random.uniform(0.9, 1.1)
        indices = np.round(np.arange(0, len(audio), speed)).astype(int)
        audio = audio[indices[indices < len(audio)]]
    if random.random() < 0.4:
        audio *= random.uniform(0.6, 1.4)
    mx = np.max(np.abs(audio))
    if mx > 0: audio = audio / mx * 0.95
    return audio.astype(np.float32)

class WhisperDataset(torch.utils.data.Dataset):
    def __init__(self, hf_dataset, feature_extractor, tokenizer, augment=False):
        self.dataset = hf_dataset
        self.feature_extractor = feature_extractor
        self.tokenizer = tokenizer
        self.augment = augment
    def __len__(self): return len(self.dataset)
    def __getitem__(self, idx):
        item = self.dataset[idx]
        audio_array = np.array(item["audio"]["array"], dtype=np.float32)
        sr = item["audio"]["sampling_rate"]
        if self.augment and random.random() < AUGMENT_PROB:
            audio_array = augment_audio(audio_array, sr)
        input_features = self.feature_extractor(audio_array, sampling_rate=sr).input_features[0]
        labels = self.tokenizer(item["sentence"]).input_ids
        return {"input_features": input_features, "labels": labels}

train_dataset = WhisperDataset(train_ds, feature_extractor, tokenizer, augment=True)
test_dataset = WhisperDataset(test_ds, feature_extractor, tokenizer, augment=False)
print(f"Dataset prêt: {len(train_dataset):,} train, {len(test_dataset):,} test")

print("\nChargement Whisper Large V3 (4-bit)...")
bnb_config = BitsAndBytesConfig(
    load_in_4bit=True, bnb_4bit_quant_type="nf4",
    bnb_4bit_compute_dtype=torch.float16, bnb_4bit_use_double_quant=True,
)
model = WhisperForConditionalGeneration.from_pretrained(
    BASE_MODEL, quantization_config=bnb_config, device_map="auto"
)
model.config.use_cache = False
model.generation_config.language = "fr"
model.generation_config.task = "transcribe"
model.generation_config.forced_decoder_ids = None

model = prepare_model_for_kbit_training(model)
lora_config = LoraConfig(
    r=64, lora_alpha=128,
    target_modules=["q_proj", "v_proj", "k_proj", "out_proj", "fc1", "fc2"],
    lora_dropout=0.05, bias="none",
)
model = get_peft_model(model, lora_config)
print("\nParamètres entraînables :")
model.print_trainable_parameters()

@dataclass
class DataCollatorSpeechSeq2SeqWithPadding:
    processor: Any
    decoder_start_token_id: int
    def __call__(self, features):
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
    return {"wer": 100 * metric.compute(predictions=pred_str, references=label_str)}

training_args = Seq2SeqTrainingArguments(
    output_dir=OUTPUT_DIR, per_device_train_batch_size=BATCH_SIZE,
    per_device_eval_batch_size=EVAL_BATCH_SIZE, gradient_accumulation_steps=GRADIENT_ACCUMULATION,
    learning_rate=LEARNING_RATE, lr_scheduler_type="cosine", warmup_steps=WARMUP_STEPS,
    weight_decay=0.01, max_steps=MAX_STEPS, gradient_checkpointing=True, fp16=True,
    eval_strategy="steps", eval_steps=EVAL_STEPS, save_steps=SAVE_STEPS, save_total_limit=1,
    logging_steps=LOGGING_STEPS, report_to=["tensorboard"], load_best_model_at_end=False,
    predict_with_generate=True, generation_max_length=225, remove_unused_columns=False,
    label_names=["labels"], push_to_hub=False, dataloader_num_workers=2,
)

trainer = Seq2SeqTrainer(
    args=training_args, model=model, train_dataset=train_dataset,
    eval_dataset=test_dataset, data_collator=data_collator,
    compute_metrics=compute_metrics, processing_class=processor.feature_extractor,
)

print(f"\n{'='*60}")
print(f"   ENTRAINEMENT MAX — PARTIE 4 (samples 9000-12000)")
print(f"   {MAX_STEPS} steps — LoRA r=64")
print(f"   Durée: ~1h | Loss toutes les {LOGGING_STEPS} steps")
print(f"{'='*60}\n")

trainer.train()

print("\n\nÉvaluation finale...")
results = trainer.evaluate()
print(f"\n   WER: {results['eval_wer']:.1f}%")

FINAL_DIR = "/content/whisper-wolof-final-p4"
trainer.save_model(FINAL_DIR)
processor.save_pretrained(FINAL_DIR)
tokenizer.save_pretrained(FINAL_DIR)

print(f"\n{'='*60}")
print(f"   TERMINÉ — PARTIE 4 !")
print(f"   WER: {results['eval_wer']:.1f}%")
print(f"{'='*60}")

import shutil
shutil.make_archive("/content/whisper-wolof-model-p4", "zip", FINAL_DIR)
from google.colab import files
print("\n>>> Téléchargement du modèle PARTIE 4... <<<")
files.download("/content/whisper-wolof-model-p4.zip")
