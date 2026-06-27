#!/usr/bin/env python3
# Procedural Vegas soundscape -> res://audio/*.wav (mono 22050, 16-bit, looping beds).
import numpy as np, wave, struct, os

SR = 22050
OUT = "audio"
os.makedirs(OUT, exist_ok=True)
rng = np.random.default_rng(7)

def save(name, x):
    x = np.asarray(x, dtype=np.float64)
    m = np.max(np.abs(x)) or 1.0
    x = (x / m) * 0.92
    pcm = np.clip(x * 32767, -32768, 32767).astype("<i2")
    with wave.open(os.path.join(OUT, name + ".wav"), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print("wrote", name, len(x)/SR, "s")

def loopfade(x, ms=60):
    L = int(SR*ms/1000)
    if L*2 >= len(x): return x
    head = x[:L].copy(); tail = x[-L:].copy()
    r = np.linspace(0,1,L)
    x[:L] = head*r + tail*(1-r)
    return x[:-L]

def tone(freq, n, kind="sine"):
    t = np.arange(n)/SR
    if kind=="saw":
        return 2*(t*freq - np.floor(0.5 + t*freq))
    if kind=="square":
        return np.sign(np.sin(2*np.pi*freq*t))
    return np.sin(2*np.pi*freq*t)

def env(n, a=0.01, d=0.2, s=0.6, r=0.2, sl=0.7):
    e = np.ones(n)*sl
    ai=int(n*a); di=int(n*d); ri=int(n*r)
    if ai>0: e[:ai]=np.linspace(0,1,ai)
    if di>0: e[ai:ai+di]=np.linspace(1,sl,di)
    if ri>0: e[-ri:]=np.linspace(sl,0,ri)
    return e

def lowpass(x, a=0.05):
    y=np.zeros_like(x); p=0.0
    for i in range(len(x)):
        p += a*(x[i]-p); y[i]=p
    return y

def highpass(x, a=0.4):
    return x - lowpass(x, a)

# ---- ENGINE (idle loop) ----
n = int(SR*1.6)
base = 52.0
eng = (0.6*tone(base,n,"saw") + 0.3*tone(base*2,n,"saw") + 0.18*tone(base*3,n)
       + 0.25*lowpass(rng.standard_normal(n),0.08))
eng *= (0.85 + 0.15*np.sin(2*np.pi*np.arange(n)/SR*6))
save("engine", loopfade(eng, 40))

# ---- TRAFFIC (rumble + passbys) ----
n = int(SR*4.0)
traf = 0.5*lowpass(rng.standard_normal(n), 0.02)
for c in range(3):
    start = rng.integers(0, n-SR)
    L = int(SR*1.2)
    sw = np.zeros(n)
    seg = lowpass(rng.standard_normal(L),0.15)*np.hanning(L)
    sw[start:start+L]=seg
    traf += 0.5*sw
save("traffic", loopfade(traf, 80))

# ---- CROWD (babble) ----
def babble(n, density, vol):
    out = np.zeros(n)
    for _ in range(density):
        L = int(SR*rng.uniform(0.12,0.35))
        if L>=n: continue
        start = rng.integers(0, n-L)
        f = rng.uniform(140, 420)
        seg = tone(f,L)*np.hanning(L)*(0.5+0.5*lowpass(rng.standard_normal(L),0.2))
        out[start:start+L]+=seg
    return out*vol
n=int(SR*4.0)
save("crowd", loopfade(babble(n, 90, 1.0)+0.15*lowpass(rng.standard_normal(n),0.05), 80))

# ---- CHATTER (sparser, near-NPC) ----
n=int(SR*3.0)
save("chatter", loopfade(babble(n, 28, 0.9), 70))

# ---- FOUNTAIN (water) ----
n=int(SR*3.0)
water = 0.6*highpass(rng.standard_normal(n), 0.5)
water = water*(0.6+0.4*np.sin(2*np.pi*np.arange(n)/SR*0.7))
for _ in range(40):  # bubbles
    L=int(SR*rng.uniform(0.02,0.06)); start=rng.integers(0,n-L)
    water[start:start+L]+=0.4*tone(rng.uniform(300,900),L)*np.hanning(L)
save("fountain", loopfade(water, 60))

# ---- CASINO (cheerful bells + pad) ----
n=int(SR*4.0)
scale=[523,587,659,784,880,1047]
cas=np.zeros(n)
for _ in range(26):
    f=scale[rng.integers(0,len(scale))]
    L=int(SR*rng.uniform(0.12,0.3)); start=rng.integers(0,n-L)
    cas[start:start+L]+=0.5*(tone(f,L)+0.3*tone(f*2,L))*env(L,0.005,0.1,0.4,0.4,0.5)
pad=0.18*(tone(261,n)+tone(329,n)+tone(392,n))*0.5
cas+=pad
save("casino", loopfade(cas, 60))

# ---- CLUB (4-on-the-floor) ----
bpm=124; beat=SR*60/bpm; n=int(beat*4)
club=np.zeros(n)
for b in range(4):
    s=int(b*beat)
    L=int(SR*0.18); 
    k=tone(60,L)*np.exp(-np.arange(L)/(SR*0.05))   # kick
    club[s:s+L]+=1.0*k
    # offbeat hat
    s2=int((b+0.5)*beat); Lh=int(SR*0.05)
    club[s2:s2+Lh]+=0.4*highpass(rng.standard_normal(Lh),0.6)*np.exp(-np.arange(Lh)/(SR*0.02))
bass_notes=[55,55,82,73]
for b in range(4):
    s=int(b*beat); L=int(beat*0.9)
    club[s:s+L]+=0.5*tone(bass_notes[b],L,"saw")*env(L,0.005,0.1,0.7,0.2,0.7)
save("club", loopfade(club, 20))

# ---- SFX ----
# slot: decelerating clicks + chime
parts=[]
t=0.0
for i in range(14):
    L=int(SR*0.03)
    parts.append(0.7*highpass(rng.standard_normal(L),0.7)*np.exp(-np.arange(L)/(SR*0.01)))
    gap=int(SR*(0.02+0.004*i))
    parts.append(np.zeros(gap))
Lc=int(SR*0.4)
chime=0.6*(tone(880,Lc)+tone(1320,Lc))*np.exp(-np.arange(Lc)/(SR*0.15))
parts.append(chime)
save("slot", np.concatenate(parts))

# win: ascending arpeggio + sparkle
notes=[523,659,784,1047,1319]; seg=[]
for f in notes:
    L=int(SR*0.12); seg.append(0.6*tone(f,L)*env(L,0.005,0.05,0.6,0.3,0.6))
Ls=int(SR*0.5); spark=0.3*tone(1760,Ls)*np.exp(-np.arange(Ls)/(SR*0.12))
seg.append(spark)
save("win", np.concatenate(seg))

# lose: descending wah
L=int(SR*0.5)
f=np.linspace(330,160,L)
ph=2*np.pi*np.cumsum(f)/SR
save("lose", 0.7*np.sin(ph)*np.exp(-np.arange(L)/(SR*0.25)))

# coin: bright ding
L=int(SR*0.3)
save("coin", 0.8*(tone(988,L)+0.6*tone(1319,L))*np.exp(-np.arange(L)/(SR*0.09)))

# chip: clack
L=int(SR*0.12)
clack=0.8*highpass(rng.standard_normal(L),0.6)*np.exp(-np.arange(L)/(SR*0.02))
clack+=0.4*tone(400,L)*np.exp(-np.arange(L)/(SR*0.03))
save("chip", clack)

# foot: soft thud
L=int(SR*0.16)
save("foot", 0.7*tone(95,L)*np.exp(-np.arange(L)/(SR*0.05))+0.2*lowpass(rng.standard_normal(L),0.1)*np.exp(-np.arange(L)/(SR*0.04)))

print("done")
