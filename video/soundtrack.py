# Synthesized soundtrack for the OmaStats launch video: A minor, 112.5 BPM,
# with the effects in key and mixed under the music.
import numpy as np, wave, sys

SR = 48000
DUR = 51.0
N = int(SR * DUR)
BEAT = 60 / 112.5
rng = np.random.default_rng(7)
t_all = np.arange(N) / SR

def hz(m): return 440.0 * 2 ** ((m - 69) / 12)
def env_ad(n, a, d):
    e = np.ones(n); na = max(1, int(a * SR)); e[:na] = np.linspace(0, 1, na)
    e[na:] = np.exp(-np.arange(n - na) / (d * SR)); return e
def onepole(x, fc):
    a = np.exp(-2 * np.pi * fc / SR); y = np.empty_like(x); z = 0.0
    for i in range(len(x)): z = (1 - a) * x[i] + a * z; y[i] = z
    return y
def add(buf, x, at, g=1.0):
    i = int(at * SR); j = min(len(buf), i + len(x)); buf[i:j] += g * x[: j - i]

def pluck(m, length=1.2, bright=1.0):
    n = int(length * SR); t = np.arange(n) / SR; f = hz(m)
    x = sum((0.6 ** k) * bright ** k * np.sin(2 * np.pi * f * (k + 1) * t) for k in range(5))
    return x * env_ad(n, 0.004, 0.28) * 0.5
def bell(m, length=2.0):
    n = int(length * SR); t = np.arange(n) / SR; f = hz(m)
    x = np.sin(2 * np.pi * f * t) + 0.35 * np.sin(2 * np.pi * f * 2.76 * t) * np.exp(-t * 6) + 0.2 * np.sin(2 * np.pi * f * 4.07 * t) * np.exp(-t * 9)
    return x * env_ad(n, 0.003, 0.55) * 0.35
def kick():
    n = int(0.4 * SR); t = np.arange(n) / SR
    f = 45 + 80 * np.exp(-t * 30); ph = 2 * np.pi * np.cumsum(f) / SR
    return np.tanh(1.6 * np.sin(ph) * np.exp(-t * 9))
def hat():
    n = int(0.06 * SR); x = rng.standard_normal(n); x = x - onepole(x, 6000)
    return x * np.exp(-np.arange(n) / (0.012 * SR)) * 0.25
def tick():
    n = int(0.05 * SR); x = rng.standard_normal(n); x = onepole(x, 3500)
    return x * np.exp(-np.arange(n) / (0.006 * SR)) * 0.8
def whoosh(length, peak):
    n = int(length * SR); x = onepole(rng.standard_normal(n), 1800); x = x - onepole(x, 200)
    t = np.arange(n) / SR; e = np.where(t < peak, (t / peak) ** 2, np.exp(-(t - peak) * 7))
    return x * e * 1.2
def pad_chord(notes, length, att=0.6, rel=0.8):
    n = int(length * SR); t = np.arange(n) / SR; x = np.zeros(n)
    for m in notes:
        for d in (-0.08, 0.08):
            f = hz(m) * 2 ** (d / 12); ph = (f * t) % 1.0; x += (2 * ph - 1) * 0.5
    x = onepole(x, 1400) / len(notes)
    e = np.minimum(1, t / att) * np.minimum(1, (length - t) / rel).clip(0, 1)
    return x * e

music = np.zeros(N); sfx = np.zeros(N); drums = np.zeros(N)
CH = {"Am": [57, 60, 64], "F": [53, 57, 60], "C": [52, 55, 60], "G": [50, 55, 59]}
prog = ["Am", "F", "C", "G"]
BAR = 4 * BEAT
DROP, BREAK, BACK, OUTRO = 3.5, 13.8, 21.1, 45.4

def chord_at(t):
    return CH["Am"] if t < DROP else CH[prog[int((t - DROP) // BAR) % 4]]

# pad: one chord per bar, a long Am to close
add(music, pad_chord(CH["Am"], DROP + 0.4, att=1.2), 0.0, 0.5)
t0 = DROP
while t0 < OUTRO - 0.01:
    L = min(BAR, OUTRO - t0) + 0.35
    add(music, pad_chord(chord_at(t0 + 0.01), L, att=0.08, rel=0.35), t0, 0.42 if BREAK <= t0 < BACK else 0.5); t0 += BAR
add(music, pad_chord(CH["Am"] + [57, 69, 72], DUR - OUTRO, att=0.05, rel=2.2), OUTRO, 0.55)

# arpeggio: eighths, sparse in the intro
k = 0; t = 0.0
while t < OUTRO:
    ch = chord_at(t); notes = [ch[0] + 12, ch[1] + 12, ch[2] + 12, ch[1] + 24]
    if t >= DROP or k % 2 == 0:
        add(music, pluck(notes[k % 4], 0.9), t, 0.22 if t < DROP else (0.26 if BREAK <= t < BACK else 0.3))
    t += BEAT / 2; k += 1

# bass and drums; the looks section breaks down to hats only
t = DROP; b = 0
while t < OUTRO - 0.01:
    root = chord_at(t)[0] - 12
    brk = BREAK <= t < BACK
    if not brk:
        n = int(BEAT / 2 * SR); tt = np.arange(n) / SR
        add(music, np.tanh(2.0 * np.sin(2 * np.pi * hz(root) * tt)) * env_ad(n, 0.005, 0.18), t, 0.28)
        if b % 2 == 0: add(drums, kick(), t, 0.75)
    if b % 2 == 1: add(drums, hat(), t, 0.35 if brk else 0.5)
    t += BEAT / 2; b += 1
add(drums, kick(), BACK, 0.8); add(drums, kick(), OUTRO, 0.9)

duck = np.ones(N); t = DROP
while t < OUTRO:
    if not (BREAK <= t < BACK):
        i = int(t * SR); n = int(0.3 * SR); j = min(N, i + n)
        duck[i:j] = np.minimum(duck[i:j], 1 - 0.45 * np.exp(-np.arange(j - i) / (0.08 * SR)))
    t += BEAT
music *= duck

# ---- sound effects, in key, following the picture ----
add(sfx, whoosh(1.4, 1.1), 0.0, 0.1)
add(sfx, bell(76, 1.6), 0.4, 0.16)
add(sfx, whoosh(1.4, 1.0), 2.1, 0.16)                   # pull back from the macro shot
for i, m in enumerate([69, 72, 74, 76, 79, 81, 84, 86]):  # readout by readout
    add(sfx, pluck(m, 0.8, 1.1), 4.6 + i * 0.95, 0.26)
add(sfx, bell(81, 2.0), 12.3, 0.22)                    # every figure keeps its width
add(sfx, whoosh(0.6, 0.3), 13.6, 0.1)
for at, m in zip([14.95, 15.6, 16.25, 16.9, 17.5, 17.85], [76, 79, 81, 79, 76, 84]):  # looks
    add(sfx, tick(), at, 0.28); add(sfx, pluck(m, 0.6, 1.2), at + 0.02, 0.2)
add(sfx, whoosh(0.9, 0.45), 18.4, 0.16)                 # vertical bar slides in
add(sfx, whoosh(0.9, 0.5), 20.9, 0.14)                  # back to the desktop
add(sfx, tick(), 21.65, 0.45); add(sfx, bell(81, 1.4), 21.72, 0.2)   # click, panel opens
for at, m in zip([24.3, 26.7, 29.1, 31.5, 33.9, 36.3, 38.7], [76, 79, 81, 84, 81, 79, 88]):  # tabs
    add(sfx, tick(), at - 0.1, 0.3); add(sfx, pluck(m, 0.7, 1.1), at, 0.2)
add(sfx, whoosh(2.0, 1.2), 39.9, 0.08)                  # settings scroll
add(sfx, whoosh(1.0, 0.6), 42.0, 0.14)                  # pull out for themes
for at, m in [(42.9, 76), (43.6, 79), (44.3, 83), (45.0, 81)]:
    add(sfx, bell(m, 1.6), at, 0.26)
add(sfx, whoosh(1.2, 0.35), 45.2, 0.2)                  # outro swell
for i in range(0, 64, 4):
    add(sfx, tick(), 46.6 + 1.1 * i / 64, 0.07)
add(sfx, bell(88, 2.5), 47.6, 0.12)

# ---- mix ----
def reverb(x, secs=1.6, wet=0.22):
    n = int(secs * SR); ir = rng.standard_normal(n) * np.exp(-np.arange(n) / (0.35 * SR))
    ir = onepole(ir, 5000); ir /= np.sqrt((ir ** 2).sum())
    L = len(x) + n; F = 1 << (L - 1).bit_length()
    y = np.fft.irfft(np.fft.rfft(x, F) * np.fft.rfft(ir, F), F)[: len(x)]
    return x + wet * y
music = reverb(music, 1.8, 0.28)
sfx = reverb(sfx, 1.8, 0.35)          # same space as the music
mix = 0.9 * music + 0.75 * sfx + 0.8 * drums
mix -= onepole(mix, 30)               # clear sub rumble
fade = np.ones(N); fs = int(1.6 * SR); fade[-fs:] = np.linspace(1, 0, fs) ** 2
fade[: int(0.02 * SR)] = np.linspace(0, 1, int(0.02 * SR))
mix *= fade
mix = np.tanh(1.3 * mix / np.max(np.abs(mix))) ; mix *= 10 ** (-1.0 / 20) / np.max(np.abs(mix))
st = np.stack([mix, mix], 1)
# a little width: delay the right channel of the sfx+music by 9 ms
d = int(0.009 * SR); st[d:, 1] = 0.85 * mix[d:] + 0.15 * mix[:-d]
pcm = (st * 32767).astype("<i2")
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())
print("wrote", sys.argv[1])
