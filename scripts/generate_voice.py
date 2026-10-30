#!/usr/bin/env python3
"""Pre-renders the body scan's spoken lines into audio clips bundled with the app.

The scan used to synthesise speech on the phone with AVSpeechSynthesizer, which came out
choppy. Every line the scan says is fixed text (or fixed text with a small number or a
position name), so each sentence is rendered once here and played as a file.

Engine: Chatterbox Multilingual (Resemble AI, MIT licence, code and weights), which
speaks Turkish and English. Its outputs carry Resemble's imperceptible Perth watermark.
Each line is rendered three times and each take transcribed back with Whisper
(large-v3-turbo); the take whose transcript is closest to the text is kept (short lines
get up to twelve tries). Numbers are spoken as words, and Turkish is rendered a little
slower and calmer than the model's default (`SETTINGS`). Silence is trimmed, loudness is normalised to −18
LUFS, and the clip is encoded as 48 kbit/s mono AAC.

Clip names: voice_<first 16 hex digits of SHA-256 of the NFC sentence>.m4a, the same
key ScanVoice computes in the app, so a line is found by its text. Sentences are split
after . ! ? : followed by whitespace, exactly as ScanVoice splits them.

Keep LINES in step with what BodyScanViewModel says (its say/audio.say calls,
PoseIssue.instruction, StationGuide). A line without a clip still plays, through the
system synthesizer.

Usage: run with the TTS virtualenv; --fresh renders every clip again:
    tts-venv/Scripts/python scripts/generate_voice.py [--fresh]
Needs chatterbox-tts, torch (CUDA), transformers, librosa, soundfile, pyloudnorm and
ffmpeg on the PATH.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import unicodedata

import librosa
import numpy as np
import pyloudnorm
import soundfile as sf
import torch

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "WearIQ", "Resources", "Localizable.xcstrings")
OUT = os.path.join(ROOT, "WearIQ", "Resources", "Voice")

# English source strings, as in the code.
LINES = [
    "Stand about three steps back from the phone, facing it, arms slightly away from your body.",
    "Great. Now I'll measure you from eight sides. Hold your arms straight out at shoulder height and keep them there. Each time, turn 45 degrees clockwise, to your right, and wait for the tone.",
    "Your clothes look loose, which makes the measurements too large. Take them off or put on something fitted.",
    "Good, now hold still.",
    "Turn a little further clockwise.",
    "A little too far. Turn back slightly, counter-clockwise.",
    "Come a little closer to the phone.",
    "Move to the middle of the picture.",
    "Raise your arms to shoulder height, straight out to the sides.",
    "Step back until you're fully visible, head to feet.",
    "Step back until your hands fit in the picture too.",
    "Good.",
    "Step back into the frame.",
    "Stop and hold still for a moment.",
    "Done. You can turn back to the phone.",
    "These measurements look larger than your body, probably because of your clothes. For the right sizes, scan again in fitted clothes or underwear.",
    "Scan complete. Your measurements are ready.",
    "Let's try the turn again.",
    "We couldn't find you in the photo. Make sure your whole body is visible and the room is well lit.",
    "Some body points weren't visible. Wear fitted clothes and keep your whole body in frame.",
    # PoseIssue.instruction
    "Step into the frame.",
    "Your head is cut off. Step back or tilt the phone.",
    "Your feet aren't visible. Step back.",
    "Step back a little.",
    "Come a little closer.",
    "Move to the centre of the frame.",
    "Face the phone directly.",
    "Hold your arms slightly away from your body.",
    "Turn fully to your side.",
    # StationGuide.instruction
    "Face the phone, arms straight out to the sides, and hold still.",
    "Turn 45 degrees clockwise and stop.",
    "Another 45 degrees clockwise, so your left side faces the phone.",
    "Another 45 degrees clockwise, so your back faces the phone.",
    "Another 45 degrees clockwise, so your right side faces the phone.",
    "Last one: another 45 degrees clockwise, and stop.",
    "Another 45 degrees clockwise, and stop.",
]
RETAKE = "One more look at %lld position(s)."
NUMBER_WORDS = {
    "en": {1: "one", 2: "two", 3: "three"},
    "tr": {1: "bir", 2: "iki", 3: "üç"},
}
COUNTDOWN = {"en": {"3": "Three!", "2": "Two!", "1": "One!"}, "tr": {"3": "Üç!", "2": "İki!", "1": "Bir!"}}


# Lines the model stumbles on as written (a word repeated, sounds after it); said in
# other words with the same meaning.
SPOKEN = {"Done.": "All done.", "Your measurements are ready.": "Your measurements are ready to see.",
          "Your feet aren't visible.": "I can't see your feet."}
# Numbers are said in words: the model reads digits unreliably, Turkish ones worst.
NUMBERS = {"en": {"45": "forty-five"}, "tr": {"45": "kırk beş"}}
# Sampling per language. A lower CFG weight gives slower, more deliberate speech, which
# keeps Turkish instructions clear; a little less exaggeration keeps the tone calm.
SETTINGS = {"en": dict(exaggeration=0.45, cfg_weight=0.4, temperature=0.75),
            "tr": dict(exaggeration=0.4, cfg_weight=0.3, temperature=0.7)}


def spoken_numbers(text, lang):
    for digits, words in NUMBERS[lang].items():
        text = text.replace(digits, words)
    return text


def split(text):
    """Sentences, split after . ! ? : followed by whitespace (as ScanVoice does)."""
    parts = re.split(r"(?<=[.!?:])\s+", text.strip())
    return [p.strip() for p in parts if p.strip()]


def key(sentence):
    nfc = unicodedata.normalize("NFC", " ".join(sentence.split()))
    return "voice_" + hashlib.sha256(nfc.encode("utf-8")).hexdigest()[:16]


def translations():
    catalog = json.load(open(CATALOG, encoding="utf-8"))["strings"]
    def tr(k):
        v = catalog.get(k, {}).get("localizations", {}).get("tr", {}).get("stringUnit", {}).get("value")
        if v is None:
            print("no Turkish for:", k, file=sys.stderr)
        return v or k
    return tr


def sentences(lang, tr):
    """(text the app shows, text to speak) pairs."""
    value = (lambda k: k) if lang == "en" else tr
    out = []
    for line in LINES:
        for s in split(value(line)):
            out.append((s, spoken_numbers(SPOKEN.get(s, s) if lang == "en" else s, lang)))
    for digit, spoken in COUNTDOWN[lang].items():
        out.append((digit, spoken))
    # The retake line, for one to three stops.
    for n in (1, 2, 3):
        line = value(RETAKE).replace("%lld", str(n))
        out.append((line, line.replace(str(n), NUMBER_WORDS[lang][n], 1)))
    seen, unique = set(), []
    for shown, spoken in out:
        if key(shown) not in seen:
            seen.add(key(shown))
            unique.append((shown, spoken))
    return unique


DIGITS = {"tr": {"45": "kırk beş", "8": "sekiz", "1": "bir", "2": "iki", "3": "üç"},
          "en": {"45": "forty five", "8": "eight", "1": "one", "2": "two", "3": "three"}}


def cer(a, b, lang="tr"):
    """Character error rate between two strings, ignoring case and punctuation (Whisper
    writes numbers as digits)."""
    for digit, word in DIGITS[lang].items():
        b = b.replace(digit, word)
    norm = lambda s: re.sub(r"[^\w]", "", unicodedata.normalize("NFC", s).casefold())
    a, b = norm(a), norm(b)
    if not a:
        return 0.0 if not b else 1.0
    d = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        prev, d[0] = d[0], i
        for j, cb in enumerate(b, 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (ca != cb))
    return d[len(b)] / len(a)


def main():
    from chatterbox.mtl_tts import ChatterboxMultilingualTTS
    from transformers import pipeline

    os.makedirs(OUT, exist_ok=True)
    tts = ChatterboxMultilingualTTS.from_pretrained(device="cuda")
    asr = pipeline("automatic-speech-recognition", model="openai/whisper-large-v3-turbo", device=0,
                   torch_dtype=torch.float16)
    meter = pyloudnorm.Meter(tts.sr)
    tr = translations()
    manifest = {}
    if "--fresh" in sys.argv:
        for f in os.listdir(OUT):
            if f.startswith("voice_") and f.endswith(".m4a"):
                os.remove(os.path.join(OUT, f))
    for lang in ("tr", "en"):
        for shown, spoken in sentences(lang, tr):
            name = key(shown)
            path = os.path.join(OUT, name + ".m4a")
            manifest[name] = {"lang": lang, "text": shown}
            if os.path.exists(path):
                continue
            best = None
            # Three takes of each line, the clearest kept. Very short lines are where the
            # model stumbles (a word repeated, sounds added after it), so they get more.
            short = len(spoken) < 20
            for attempt in range(12 if short else 3):
                torch.manual_seed(1000 + attempt)
                try:
                    wav = tts.generate(spoken, language_id=lang, **SETTINGS[lang]).squeeze().cpu().numpy().astype("float32")
                except Exception as error:  # the model occasionally produces nothing for a word
                    print(f"  attempt {attempt}: {error}", flush=True)
                    continue
                wav, _ = librosa.effects.trim(wav, top_db=40)
                if len(wav) < tts.sr * 0.2:
                    continue
                heard = asr({"raw": librosa.resample(wav, orig_sr=tts.sr, target_sr=16000), "sampling_rate": 16000},
                            generate_kwargs={"language": "turkish" if lang == "tr" else "english"})["text"]
                err = cer(spoken, heard, lang)
                if best is None or err < best[0]:
                    best = (err, wav, heard)
                if err == 0 or (short and err <= 0.12):
                    break
            if best is None:
                print(f"[{lang}] FAILED {shown!r}", flush=True)
                continue
            err, wav, heard = best
            manifest[name]["heard"] = heard.strip()
            manifest[name]["cer"] = round(err, 3)
            print(f"[{lang}] {err:.2f} {shown!r} -> {heard.strip()!r}", flush=True)
            pad = np.zeros(int(0.06 * tts.sr), dtype="float32")
            wav = np.concatenate([pad, wav, pad])
            loudness = meter.integrated_loudness(wav)
            if np.isfinite(loudness):
                wav = pyloudnorm.normalize.loudness(wav, loudness, -18.0)
            wav = np.clip(wav, -0.98, 0.98)
            with tempfile.TemporaryDirectory() as tmp:
                raw = os.path.join(tmp, "clip.wav")
                sf.write(raw, wav, tts.sr)
                subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", raw, "-ac", "1", "-ar", "24000",
                                "-c:a", "aac", "-b:a", "48k", path], check=True)
    # Clips no line uses any more.
    for f in os.listdir(OUT):
        if f.startswith("voice_") and f.endswith(".m4a") and f[:-4] not in manifest:
            os.remove(os.path.join(OUT, f))
    with open(os.path.join(ROOT, "scripts", "voice_manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1, sort_keys=True)
    bad = {k: v for k, v in manifest.items() if v.get("cer", 0) > 0.12}
    print(f"{len(manifest)} clips, {len(bad)} above 12% character error")


if __name__ == "__main__":
    main()
