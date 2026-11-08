#!/usr/bin/env python3
"""nEXUSWATCH : voix de la visite guidée, un fichier Resources/tour/tour-<langue>-<empreinte>.m4a par étape.

Textes lus dans Sources/L10n.swift (clés tour.<étape>.title et .text), dans l'ordre de Tour.steps (Sources/Tour.swift).
L'empreinte (SHA-256 de « langue|titre. texte », 16 caractères) est celle que recalcule l'appli (Tour.audioName) : une étape
réécrite n'a plus de fichier et l'appli la lit avec la voix du système jusqu'à la prochaine génération.
- français et anglais : ElevenLabs (voix de la visite de mORTEX, mêmes réglages). Coût mesuré : 0,4 crédit par caractère.
  Clé : ELEVENLABS_API_KEY (environnement) ou ~/.config/elevenlabs/.env. Son brut gardé dans ~/.cache/nexuswatch/tour-voice.
- espagnol et italien : voix locale Qwen3-TTS (commande voix-locale), gratuite.
ffmpeg et afconvert sont nécessaires (volume commun, AAC).
Usage : python3 tools/gen_tour_audio.py [--dry-run] [--only fr] [--step N] [--force]
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Resources/tour"
RAW = Path.home() / ".cache/nexuswatch/tour-voice"
LANGS = ["fr", "en", "es", "it"]
ELEVEN = {"fr": "mvhJVdVoTWVUtL4keT7W", "en": "aHYS10erl9IGphnXtDeD"}  # voix de la visite de mORTEX
MODEL, OUTPUT = "eleven_multilingual_v2", "mp3_44100_128"
SETTINGS = {
    "fr": {"stability": 0.3, "similarity_boost": 0.8, "style": 0.6, "speed": 1.0, "use_speaker_boost": True},
    "en": {"stability": 0.4, "similarity_boost": 0.8, "style": 0.5, "speed": 1.05, "use_speaker_boost": True},
}
LOCAL = {"es": "spanish", "it": "italian"}
LIMIT = "alimiter=limit=0.7:level=0:attack=2:release=40"
LOUDNESS = "I=-16:TP=-1.5:LRA=7"
SAY = {"nEXUSWATCH": "Nexus Watch", "API": "A P I"}


def steps() -> list[str]:
    src = (ROOT / "Sources/Tour.swift").read_text(encoding="utf-8")
    return re.findall(r'TourStep\(key: "(\w+)"', src)


def table(lang: str) -> dict[str, str]:
    src = (ROOT / "Sources/L10n.swift").read_text(encoding="utf-8")
    block = re.search(rf"private static let {lang}: \[String: String\] = \[(.*?)\n    \]", src, re.S).group(1)
    return {k: v.replace('\\"', '"') for k, v in re.findall(r'"([\w.]+)": "((?:[^"\\]|\\.)*)"', block)}


def audio_name(lang: str, title: str, text: str) -> str:
    return f"tour-{lang}-" + hashlib.sha256(f"{lang}|{title}. {text}".encode("utf-8")).hexdigest()[:16]


def spoken(title: str, text: str) -> str:
    s = f"{title}. {text}"
    for word, said in SAY.items():
        s = re.sub(rf"\b{re.escape(word)}\b", said, s)
    return s.replace("’", "'").replace(" ", " ").replace(" ", " ")


def ffmpeg(*args: str) -> str:
    return subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-y", *args], check=True, capture_output=True, text=True).stderr


def finish(source: Path, target: Path) -> None:
    """Crêtes limitées, volume commun en deux passes, puis AAC mono."""
    report = ffmpeg("-i", str(source), "-af", f"{LIMIT},loudnorm={LOUDNESS}:print_format=json", "-f", "null", "-")
    m = json.loads(re.findall(r"\{[^{}]*\}", report)[-1])
    norm = (f"loudnorm={LOUDNESS}:linear=true:measured_I={m['input_i']}:measured_TP={m['input_tp']}"
            f":measured_LRA={m['input_lra']}:measured_thresh={m['input_thresh']}:offset={m['target_offset']}")
    with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
        ffmpeg("-i", str(source), "-af", f"{LIMIT},{norm},aresample=44100", "-ac", "1", "-c:a", "pcm_s16le", tmp.name)
        target.unlink(missing_ok=True)
        subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "96000", tmp.name, str(target)], check=True)


def eleven_key() -> str:
    if os.environ.get("ELEVENLABS_API_KEY"):
        return os.environ["ELEVENLABS_API_KEY"]
    env = Path.home() / ".config/elevenlabs/.env"
    for line in env.read_text(encoding="utf-8").splitlines() if env.exists() else []:
        name, _, value = line.partition("=")
        if name.strip() == "ELEVENLABS_API_KEY":
            return value.strip().strip("\"'")
    sys.exit("ELEVENLABS_API_KEY absente.")


def eleven(path: str, body: dict | None = None) -> bytes:
    req = urllib.request.Request("https://api.elevenlabs.io/v1" + path, data=None if body is None else json.dumps(body).encode(),
                                 headers={"xi-api-key": eleven_key(), "Content-Type": "application/json", "Accept": "*/*"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.read()
    except urllib.error.HTTPError as err:
        sys.exit(f"ElevenLabs {err.code} : {err.read().decode('utf-8', 'replace')[:300]}")


def raw_path(lang: str, text: str) -> Path:
    key = json.dumps([MODEL, OUTPUT, ELEVEN[lang], SETTINGS[lang], text], sort_keys=True)
    return RAW / (hashlib.sha256(key.encode()).hexdigest()[:24] + ".mp3")


def speak(lang: str, text: str, target: Path) -> None:
    if lang in ELEVEN:
        raw = raw_path(lang, text)
        if not raw.exists():
            RAW.mkdir(parents=True, exist_ok=True)
            raw.write_bytes(eleven(f"/text-to-speech/{ELEVEN[lang]}?output_format={OUTPUT}",
                                   {"text": text, "model_id": MODEL, "voice_settings": SETTINGS[lang]}))
        finish(raw, target)
    else:
        with tempfile.TemporaryDirectory() as tmp:
            wav = Path(tmp) / "voix.wav"
            subprocess.run([str(Path.home() / ".local/bin/voix-locale"), text, "-o", str(wav), "-l", LOCAL[lang],
                            *os.environ.get("TOUR_LOCAL_VOICE", "-v serena").split()], check=True, capture_output=True)
            finish(wav, target)


def main() -> None:
    args = sys.argv[1:]
    only = args[args.index("--only") + 1] if "--only" in args else None
    step = int(args[args.index("--step") + 1]) if "--step" in args else None
    force, dry = "--force" in args, "--dry-run" in args
    keys = steps()
    jobs, wanted = [], set()
    for lang in LANGS:
        t = table(lang)
        for n, k in enumerate(keys, start=1):
            title, text = t[f"tour.{k}.title"], t[f"tour.{k}.text"]
            target = OUT / (audio_name(lang, title, text) + ".m4a")
            wanted.add(target.name)
            if (only and lang != only) or (step and n != step) or (target.exists() and not force):
                continue
            jobs.append((lang, n, k, spoken(title, text), target))
    paid = sum(len(j[3]) for j in jobs if j[0] in ELEVEN and not raw_path(j[0], j[3]).exists())
    info = json.loads(eleven("/user/subscription")) if paid else None
    left = info["character_limit"] - info["character_count"] if info else None
    print(f"{len(jobs)} fichiers ; ElevenLabs : {paid} caractères (~{round(paid * 0.4)} crédits)"
          + (f", {left} crédits restants" if left is not None else ""))
    if dry:
        return
    if left is not None and paid * 0.4 > left:
        sys.exit("Crédits insuffisants.")
    OUT.mkdir(parents=True, exist_ok=True)
    for lang, n, k, text, target in jobs:
        speak(lang, text, target)
        print(f"{target.name}  {lang} {n} {k}")
    if not only and not step:  # fichiers d'anciens textes
        for old in OUT.glob("tour-*.m4a"):
            if old.name not in wanted:
                old.unlink()


if __name__ == "__main__":
    main()
