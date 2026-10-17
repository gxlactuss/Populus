# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy"]
# ///
"""Synthesize the background music and sound effects. Everything is generated here, no samples.

Usage: uv run Scripts/make_audio.py [out_dir]   (default Populus/Resources/Audio)

Writes lobby.caf (a seamless ALAC loop) and one short .caf per sound effect. Needs macOS afconvert.
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


def ep(m, dur, vel=1.0):
    """Electric piano: two-operator FM with a fading bell tone."""
    n = int((dur + 1.2) * SR)
    t = np.arange(n) / SR
    f = midi_hz(m)
    index = 1.6 * np.exp(-t / 0.25) + 0.2
    tone = np.sin(2 * np.pi * f * t + index * np.sin(2 * np.pi * f * t))
    tone += 0.15 * np.sin(2 * np.pi * 4 * f * t) * np.exp(-t / 0.08)
    return release(tone * env(n, 0.004, 0.9) * vel, 1.0)


def bass(m, dur, vel=1.0):
    n = int((dur + 0.1) * SR)
    t = np.arange(n) / SR
    f = midi_hz(m)
    tone = np.sin(2 * np.pi * f * t) + 0.3 * np.sin(4 * np.pi * f * t) + 0.08 * np.sin(6 * np.pi * f * t)
    return release(tone * env(n, 0.01, 0.6) * vel, 0.08)


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


def brush(vel=1.0):
    n = int(0.12 * SR)
    noise = rng.standard_normal(n)
    hiss = noise - lowpass(noise, 4000)
    return hiss * env(n, 0.003, 0.035) * vel


def kick(vel=1.0):
    n = int(0.3 * SR)
    t = np.arange(n) / SR
    f = 50 + 60 * np.exp(-t / 0.03)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * env(n, 0.002, 0.12) * vel


def place(buf, sound, at):
    i = int(at * SR)
    end = min(len(buf), i + len(sound))
    buf[i:end] += sound[: end - i]


def lobby():
    bpm = 92
    beat = 60 / bpm
    swing = beat * 2 / 3  # where the swung "and" lands
    # (root, chord tones as midi) in C major, two beats or four beats per chord.
    bars = [
        [(48, [64, 67, 71, 74])],                           # Cmaj9
        [(45, [64, 67, 69, 72])],                           # Am7
        [(50, [65, 69, 72, 76])],                           # Dm9
        [(43, [65, 69, 71, 74])],                           # G13
        [(52, [62, 67, 71, 74])],                           # Em7
        [(45, [61, 64, 67, 71])],                           # A7
        [(50, [65, 69, 72, 74])],                           # Dm7
        [(43, [65, 67, 71, 74]), (43, [65, 68, 71, 75])],   # G7 G7#5
    ]
    bars = bars + bars
    length = len(bars) * 4 * beat
    buf = np.zeros(int((length + 3) * SR))

    for b, chords in enumerate(bars):
        t0 = b * 4 * beat
        per = 4 / len(chords)
        for c, (root, tones) in enumerate(chords):
            tc = t0 + c * per * beat
            # Comping: on the beat, then a lighter push on the swung "and" of two.
            for m in tones:
                place(buf, ep(m - 12, 1.2, 0.16), tc)
                if per == 4:
                    place(buf, ep(m - 12, 0.6, 0.09), tc + beat + swing)
            # Walking bass.
            steps = [root, root + 7, root + 12, root + 10] if per == 4 else [root, root + 4]
            if per == 4 and b % 2:
                steps = [root, root + 3 + (tones[0] - root) % 2, root + 7, root + 11]
            for i, m in enumerate(steps):
                place(buf, bass(m - 12, beat * 0.9, 0.45), tc + i * beat)
        # Drums: soft kick on 1 and 3, brushes on swung eighths.
        for k in range(4):
            place(buf, kick(0.35 if k % 2 == 0 else 0.15), t0 + k * beat)
            place(buf, brush(0.10 if k % 2 else 0.06), t0 + k * beat)
            place(buf, brush(0.05), t0 + k * beat + swing)

    # Melody on vibes, a call in the first half and a lighter answer in the second.
    motif = [(0, 0), (1 + 2 / 3, 1), (2, 2), (3, 3)]
    answer = [(0.5, 2), (1 + 2 / 3, 1), (3, 0)]
    for b, chords in enumerate(bars):
        if b % 4 == 3:
            continue  # breathe
        tones = sorted(set(chords[0][1]))
        rhythm = motif if b < 8 else answer
        order = rng.permutation(len(tones))
        for (at, idx) in rhythm:
            m = tones[order[idx % len(tones)]] + 12
            place(buf, vibes(m, beat, 0.22), b * 4 * beat + at * beat)

    # Seamless loop: fold the ringing tail back onto the start.
    n = int(length * SR)
    tail = buf[n:]
    buf = buf[:n]
    buf[: len(tail)] += tail
    return buf


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
        # ALAC so the loop has no encoder padding and plays back gaplessly.
        subprocess.run(["afconvert", "-f", "caff", "-d", "alac", tmp.name, str(path)], check=True)


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "Populus/Resources/Audio")
    out.mkdir(parents=True, exist_ok=True)
    write(out / "lobby.caf", lobby(), 0.8)
    for name, x in sounds().items():
        write(out / f"{name}.caf", x, 0.8)
    for p in sorted(out.iterdir()):
        print(f"{p.name:16} {p.stat().st_size / 1024:8.0f} KB")


if __name__ == "__main__":
    main()
