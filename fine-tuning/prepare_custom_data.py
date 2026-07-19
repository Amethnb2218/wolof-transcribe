"""
Script pour préparer vos données audio wolof pour le fine-tuning.

Usage:
    python prepare_custom_data.py --audio mon_audio_2h.mp3 --transcription transcription.txt --output wolof_data/

Ce script:
1. Découpe votre audio long en segments de 10-30 secondes
2. Associe chaque segment à sa transcription
3. Génère un CSV prêt pour le fine-tuning

Format du fichier transcription.txt attendu:
    [00:00:00 - 00:00:15] Texte du premier segment en wolof
    [00:00:15 - 00:00:28] Texte du deuxième segment
    ...

OU format simple (un segment par ligne, découpage automatique toutes les 15s):
    Texte du premier segment
    Texte du deuxième segment
    ...
"""

import os
import re
import csv
import argparse
from pydub import AudioSegment


def parse_timestamped_transcription(filepath):
    """Parse une transcription avec timestamps."""
    segments = []
    pattern = r'\[(\d{2}:\d{2}:\d{2})\s*-\s*(\d{2}:\d{2}:\d{2})\]\s*(.+)'

    with open(filepath, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            match = re.match(pattern, line)
            if match:
                start = timestamp_to_ms(match.group(1))
                end = timestamp_to_ms(match.group(2))
                text = match.group(3).strip()
                segments.append({"start": start, "end": end, "text": text})

    return segments


def parse_simple_transcription(filepath, segment_duration_ms=15000):
    """Parse une transcription simple (une phrase par ligne, découpe fixe)."""
    segments = []
    with open(filepath, 'r', encoding='utf-8') as f:
        lines = [l.strip() for l in f if l.strip()]

    for i, line in enumerate(lines):
        start = i * segment_duration_ms
        end = (i + 1) * segment_duration_ms
        segments.append({"start": start, "end": end, "text": line})

    return segments


def timestamp_to_ms(ts):
    """Convertit HH:MM:SS en millisecondes."""
    parts = ts.split(':')
    h, m, s = int(parts[0]), int(parts[1]), int(parts[2])
    return (h * 3600 + m * 60 + s) * 1000


def main():
    parser = argparse.ArgumentParser(description="Prépare les données wolof pour fine-tuning Whisper")
    parser.add_argument("--audio", required=True, help="Chemin vers le fichier audio (MP3, WAV, M4A...)")
    parser.add_argument("--transcription", required=True, help="Chemin vers le fichier de transcription (.txt)")
    parser.add_argument("--output", default="wolof_data", help="Dossier de sortie")
    parser.add_argument("--segment-duration", type=int, default=15, help="Durée des segments en secondes (si pas de timestamps)")
    args = parser.parse_args()

    os.makedirs(f"{args.output}/audios", exist_ok=True)

    print(f"Chargement de l'audio: {args.audio}")
    audio = AudioSegment.from_file(args.audio)
    audio = audio.set_frame_rate(16000).set_channels(1)
    print(f"Durée totale: {len(audio) / 1000 / 60:.1f} minutes")

    print(f"Lecture de la transcription: {args.transcription}")
    with open(args.transcription, 'r', encoding='utf-8') as f:
        first_line = f.readline().strip()

    if re.match(r'\[\d{2}:\d{2}:\d{2}', first_line):
        print("Format détecté: timestamps [HH:MM:SS - HH:MM:SS]")
        segments = parse_timestamped_transcription(args.transcription)
    else:
        print(f"Format détecté: simple (découpe toutes les {args.segment_duration}s)")
        segments = parse_simple_transcription(args.transcription, args.segment_duration * 1000)

    print(f"Segments trouvés: {len(segments)}")

    csv_rows = []
    for i, seg in enumerate(segments):
        segment_audio = audio[seg["start"]:seg["end"]]

        if len(segment_audio) < 500:
            continue

        filename = f"segment_{i:04d}.wav"
        filepath = f"{args.output}/audios/{filename}"
        segment_audio.export(filepath, format="wav")

        csv_rows.append({
            "audio_path": os.path.abspath(filepath),
            "sentence": seg["text"],
        })

        if (i + 1) % 50 == 0:
            print(f"  Traité {i + 1}/{len(segments)} segments...")

    csv_path = f"{args.output}/transcriptions.csv"
    with open(csv_path, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=["audio_path", "sentence"])
        writer.writeheader()
        writer.writerows(csv_rows)

    print(f"\nTerminé !")
    print(f"  Segments audio: {args.output}/audios/ ({len(csv_rows)} fichiers)")
    print(f"  CSV: {csv_path}")
    print(f"\nProchaine étape: uploadez le dossier '{args.output}' sur Google Drive")
    print(f"  dans: Mon Drive/wolof_data/")


if __name__ == "__main__":
    main()
