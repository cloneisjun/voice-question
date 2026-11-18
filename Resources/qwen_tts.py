#!/usr/bin/env python3
"""Local, one-shot Qwen3-TTS adapter. Question text arrives only on stdin.

The app owns the process and private output directory, including cancellation and cleanup.
Model downloads are a separate setup step; inference never contacts Hugging Face.
"""
import argparse
import os
import sys
import wave
from pathlib import Path

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["TOKENIZERS_PARALLELISM"] = "false"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--speaker", required=True)
    parser.add_argument("--language", default="auto")
    parser.add_argument("--instruct", default="")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    text = sys.stdin.read().strip()
    if not text or not (Path(args.model) / "config.json").is_file():
        raise ValueError("Missing text or local model")

    import mlx.core as mx
    import numpy as np
    from mlx_audio.tts.utils import load_model

    languages = {"ko": "Korean", "en": "English", "ja": "Japanese", "zh": "Chinese"}
    model = load_model(args.model)
    chunks = []
    sample_rate = None
    for result in model.generate_custom_voice(
        text=text, speaker=args.speaker,
        language=languages.get(args.language, args.language),
        instruct=args.instruct, max_tokens=2048, verbose=False,
    ):
        mx.eval(result.audio)
        chunks.append(np.asarray(result.audio, dtype=np.float32).reshape(-1))
        sample_rate = result.sample_rate
    audio = np.concatenate(chunks) if chunks else np.array([])
    if not audio.size or not np.isfinite(audio).all():
        raise ValueError("No valid audio generated")
    pcm = (np.clip(audio, -1, 1) * 32767).astype("<i2")
    with wave.open(args.output, "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(pcm.tobytes())


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Upstream exceptions may contain question text. Never include them in app logs.
        print("Local Qwen synthesis failed.", file=sys.stderr)
        sys.exit(1)
