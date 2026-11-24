"""Score a mic recording of the trackpad playing along with the demo groove (speakers silent).
usage: micscore.py rec.wav bass|harmony
bass:    the trackpad restarts its tones every bass period, so the ear hears the bass note through
         harmonic spacing. Per eighth note the envelope's repetition rate (37-150 Hz) gives the heard bass pitch class.
harmony: per eighth note the strongest 300-700 Hz peak must sit a third or fifth above the bass note.
The recording start is unknown, so the alignment offset is searched. Pass bar: 75% of notes."""
import sys, wave, numpy as np
NOTES = [33,33,45,33,36,33,40,43, 31,31,43,31,35,31,38,40, 29,29,41,29,33,29,36,40, 28,28,40,28,32,35,38,40]
STEP = 60/100/2
w = wave.open(sys.argv[1]); sr = w.getframerate()
x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(float)/32768
mode = sys.argv[2] if len(sys.argv) > 2 else "bass"
NF = 16384
fq = np.fft.rfftfreq(NF, 1/sr)

def spectrum(t0, i):
    a = int((t0 + i*STEP + STEP*0.3)*sr); b = int((t0 + i*STEP + STEP*0.85)*sr)
    if b > len(x): return None
    return np.abs(np.fft.rfft(x[a:b]*np.hanning(b-a), NF))

def seg_at(t0, i):
    a = int((t0 + i*STEP + STEP*0.3)*sr); b = int((t0 + i*STEP + STEP*0.85)*sr)
    return x[a:b] if b <= len(x) else None

def period_pc(seg):
    """Envelope periodicity: the motor pulses once per bass period. (Waveform YIN fails on the real
    mic signal: room reflections scramble the carrier phase, the pulse envelope survives.)"""
    env = np.convolve(seg**2, np.hanning(64)/32, 'same'); env -= env.mean()
    n = len(env)
    ac = np.correlate(env, env, 'full')[n-1:]; ac /= ac[0] + 1e-12
    lo, hi = int(sr/150), int(sr/37)
    peak = ac[lo:hi].max()
    # Shortest lag close to the best (octave multiples tie).
    lag = next((t for t in range(lo, hi) if ac[t] >= peak * 0.9 and ac[t] >= ac[t-1] and ac[t] >= ac[t+1]), lo + int(np.argmax(ac[lo:hi])))
    return int(round(69 + 12*np.log2(sr/lag/440))) % 12, peak

def peak_pc(sp):
    m = (fq > 300) & (fq < 700)
    hz = fq[m][np.argmax(sp[m])]
    return int(round(69 + 12*np.log2(hz/440))) % 12, sp[m].max()/(np.median(sp[m])+1e-12)

def ok(pc, want):
    if mode == "bass": return pc == want
    return pc in ((want+3) % 12, (want+4) % 12, (want+7) % 12)

best = None
for off in np.arange(0, 2.0, 0.03):
    hits = n = 0
    for i in range(400):
        if mode == "bass":
            seg = seg_at(off, i)
            if seg is None: break
            pc, _ = period_pc(seg)
        else:
            sp = spectrum(off, i)
            if sp is None: break
            pc, _ = peak_pc(sp)
        hits += ok(pc, NOTES[i % 32] % 12); n += 1
    if n and (best is None or hits/n > best[0]): best = (hits/n, off, n)
acc, off, n = best
print(f"mic: {mode} pitch-class match {acc*100:.1f}% over {n} notes (offset {off:.2f}s)")
sys.exit(0 if acc >= 0.75 else 1)
