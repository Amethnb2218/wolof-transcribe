# Datasets Wolof pour Fine-tuning Whisper
Source: https://github.com/WolofProcessing/online_wolof_data

## Datasets ASR (Reconnaissance Vocale)

### 1. Mozilla Common Voice 17 (Wolof)
- **HuggingFace**: `mozilla-foundation/common_voice_17_0` (config: `wo`)
- **Site**: https://commonvoice.mozilla.org/wo/datasets
- **Contenu**: Phrases wolof lues par des locuteurs natifs
- **Format**: MP3 + transcriptions
- **Licence**: CC-0
- **Note**: Il faut accepter les conditions sur HuggingFace avant utilisation

### 2. Google FLEURS (Wolof - Senegal)
- **HuggingFace**: `google/fleurs` (config: `wo_sn`)
- **Contenu**: Dataset multilingue haute qualite (12h par langue)
- **Format**: Audio + transcriptions
- **Licence**: CC-BY-4.0

### 3. ALFFA PUBLIC (Wolof)
- **GitHub**: https://github.com/getalp/ALFFA_PUBLIC/tree/master/ASR/WOLOF
- **Contenu**: Dataset ASR academique (~5h), Universite Grenoble Alpes
- **Format**: Kaldi (wav.scp + text)
- **Splits**: train / dev / test
- **Licence**: Open

### 4. Kallaama Speech Dataset (55h wolof !)
- **GitHub**: https://github.com/gauthelo/kallaama-speech-dataset
- **Contenu**: 55h de wolof transcrit (theme: agriculture)
- **Sous-datasets**: Jokalante, Orange, EPT
- **13h validees** par un expert linguiste
- **Licence**: CC-BY-4.0
- **Paper**: RAIL 2024 Workshop

### 5. Waxal Multilingual (519h audio, 6.45h transcrites)
- **GitHub**: https://github.com/Waxal-Multilingual/speech-data
- **Audio**: https://github.com/Waxal-Multilingual/audio-files
- **Contenu**: Crowdsource via WhatsApp (4,242 participants, 86,296 enregistrements)
- **Format**: CSV + audio sur GCP

### 6. AI4D URBAN / Baamtu Datamation
- **Lien**: https://zindi.africa/competitions/ai4d-baamtu-datamation-automatic-speech-recognition-in-wolof/data
- **Zenodo TTS**: https://zenodo.org/record/4498861
- **Contenu**: ASR urbain wolof (competition Zindi)
- **Note**: Necessite inscription Zindi pour telecharger

### 7. Google WaxalNLP (TTS utilisable pour ASR)
- **HuggingFace**: `google/WaxalNLP` (viewer: `wol_tts`)
- **Contenu**: Paires audio/texte wolof

### 8. UDHR Audio (Declaration Universelle des Droits de l'Homme)
- **Site**: https://udhr.audio/
- **Contenu**: Lecture de la DUDH en wolof

### 9. Keyword Spotting Dataset
- **Zenodo**: https://zenodo.org/record/7561858
- **Contenu**: Mots-cles wolof

---

## Datasets Texte (pour correction LLM)

- **FineWeb 2 Wolof**: https://huggingface.co/datasets/HuggingFaceFW/fineweb-2/viewer/wol_Latn
- **Aya Collection Wolof**: https://huggingface.co/datasets/CohereForAI/aya_collection_language_split/viewer/wolof
- **Jolof (Open LLM)**: https://github.com/dofbi/jolof/
- **Wikipedia Wolof**: https://wo.wikipedia.org
- **AfriQA**: https://huggingface.co/datasets/masakhane/afriqa
- **MADLAD-400**: https://github.com/google-research/google-research/tree/master/madlad_400

---

## Sources YouTube (pour creer plus de donnees)
- **TFM News Wolof**: https://www.youtube.com/watch?v=1UEpQhsIxE0&list=PLdGJr0E0g2bNsbRQZ_HyzuGvU1Mo1XcvK
- **Elmourabitoune (Wolof/Pulaar/Arabe)**: https://www.youtube.com/c/Elmourabitoune

---

## Le notebook MEGA telecharge automatiquement :
1. Common Voice (wo)
2. FLEURS (wo_sn)
3. ALFFA PUBLIC (clone GitHub)
4. Kallaama (clone GitHub ou HF)
5. Waxal (clone GitHub)
6. + Vos donnees perso (depuis Google Drive)

**Total potentiel: 70+ heures de wolof transcrit**

Ouvrez `whisper_wolof_MEGA_finetune.ipynb` sur Colab et lancez !
