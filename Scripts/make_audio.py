# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy"]
# ///
"""Synthesize the sound effects. Everything is generated here, no samples.

Usage: uv run Scripts/make_audio.py [out_dir]   (default Populus/Resources/Audio)

Writes one short .caf per sound effect. Needs macOS afconvert.
"""
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

import numpy as np

SR = 44100
rng = np.random.default_rng(7)


def midi_hz(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def env(n, attack, decay):
    """Short linear attack, then exponential decay with time constant `decay` seconds."""
    t = np.arange(n) / SR
    a = np.minimum(1, t / max(attack, 1e-4))
    return a * np.exp(-t / decay)


def release(x, seconds):
    n = min(len(x), int(seconds * SR))
    x[-n:] *= np.linspace(1, 0, n)
    return x


def vibes(m, dur, vel=1.0):
    n = int((dur + 1.5) * SR)
    t = np.arange(n) / SR
    f = midi_hz(m)
    tone = np.sin(2 * np.pi * f * t) + 0.25 * np.sin(2 * np.pi * 4 * f * t) * np.exp(-t / 0.15)
    tremolo = 1 - 0.25 * (0.5 + 0.5 * np.sin(2 * np.pi * 5 * t))
    return release(tone * tremolo * env(n, 0.002, 1.1) * vel, 1.2)


def lowpass(x, cutoff):
    """One-pole low-pass, enough to soften noise. `cutoff` can be a number or one value per sample."""
    a = np.broadcast_to(np.exp(-2 * np.pi * np.asarray(cutoff, float) / SR), x.shape)
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc = (1 - a[i]) * v + a[i] * acc
        y[i] = acc
    return y


def place(buf, sound, at):
    i = int(at * SR)
    end = min(len(buf), i + len(sound))
    buf[i:end] += sound[: end - i]


def arpeggio(notes, step, voice=vibes, vel=0.6, hold=0.5):
    buf = np.zeros(int((len(notes) * step + hold + 1.5) * SR))
    for i, m in enumerate(notes):
        place(buf, voice(m, hold, vel), i * step)
    return trim(buf)


def trim(x, floor=1e-3):
    idx = np.nonzero(np.abs(x) > floor * np.abs(x).max())[0]
    return release(x[: idx[-1] + 1].copy(), 0.02)


def blip(f0, f1, dur, vel=0.5):
    n = int(dur * SR)
    f = np.linspace(f0, f1, n)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * env(n, 0.002, dur / 3) * vel


def whoosh():
    n = int(0.55 * SR)
    t = np.arange(n) / SR
    noise = rng.standard_normal(n)
    shaped = noise - lowpass(noise, 300 + 2500 * t / t[-1])
    shaped = lowpass(shaped, 6000)
    swell = np.sin(np.pi * t / t[-1]) ** 2
    rise = np.sin(2 * np.pi * np.cumsum(300 + 500 * t / t[-1]) / SR) * 0.15
    return (shaped * 0.35 + rise) * swell


def sounds():
    return {
        "click": blip(1800, 1500, 0.03, 0.25),
        "draw": blip(500, 900, 0.07, 0.35),
        "undo": blip(900, 500, 0.07, 0.3),
        "guess": whoosh(),
        "round": arpeggio([79, 84], 0.09, vel=0.45),
        "great": arpeggio([72, 76, 79, 84], 0.08),
        "good": arpeggio([72, 79], 0.1, vel=0.5),
        "bad": arpeggio([62, 58], 0.18, voice=ep, vel=0.5, hold=0.35),
        "highscore": arpeggio([72, 76, 79, 84, 88, 91, 96], 0.065, vel=0.5, hold=0.8),
    }


def write(path, x, peak):
    x = x / np.abs(x).max() * peak
    pcm = (np.clip(x, -1, 1) * 32767).astype("<i2")
    with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
        with wave.open(tmp.name, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes(pcm.tobytes())
        # ALAC so the effects have no encoder padding and play back without delay.
        subprocess.run(["afconvert", "-f", "caff", "-d", "alac", tmp.name, str(path)], check=True)


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "Populus/Resources/Audio")
    out.mkdir(parents=True, exist_ok=True)
    for name, x in sounds().items():
        write(out / f"{name}.caf", x, 0.8)
    for p in sorted(out.iterdir()):
        print(f"{p.name:16} {p.stat().st_size / 1024:8.0f} KB")


if __name__ == "__main__":
    main()
