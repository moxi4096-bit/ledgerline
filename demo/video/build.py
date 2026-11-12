"""Assemble the Ledgerline demo video: slides + live take + explorer pan, TTS voiceover, burned-in captions."""
import json, re, subprocess, sys
from pathlib import Path
R = Path(__file__).parent
OUT = Path("/workspace/reactive-omni/ledgerline/demo/ledgerline-demo.mp4")
lines = json.load(open(R / "vo/lines.json"))
lines["s4"] = "On the Reactscan explorer, that one Lasna transaction fans out into two callbacks: one to Base, one to Unichain, both confirmed."
LIVE_IN, LIVE_LEN = 4.0, 68.0
# (kind, source, duration, [(vo key, offset)])
segs = [
    ("img", "slides/s1.png", 10.5, [("s1", 0.6)]),
    ("img", "slides/s2.png", 13.6, [("s2", 0.5)]),
    ("img", "slides/s3.png", 23.0, [("s3", 0.6)]),
    ("live", "live.mkv", LIVE_LEN, [("l1", 0.5), ("l2", 8.5), ("l3", 19.5), ("l4", 32.0), ("l5", 46.0)]),
    ("pan", "slides/ex_lasna_tall.png", 10.5, [("s4", 0.8)]),
    ("img", "slides/s5.png", 11.2, [("s5", 0.5)]),
    ("img", "slides/s6.png", 10.0, [("s6", 0.5)]),
    ("img", "slides/s7.png", 11.0, [("s7", 0.6)]),
]
chips = [(8.7, 19.5, "✓ Auto-save on Base  ·  3.85 s"), (19.9, 32.0, "✓ Auto-save on Unichain  ·  5.32 s"),
         (32.4, 39.0, "Spend 70 on Unichain  ·  today 70 / 100"),
         (39.2, 45.8, "Limit crossed → vaults locked: Base 3.05 s · Unichain 3.54 s"),
         (46.0, 54.5, "Own-wallet move: not income, not spending"), (54.7, LIVE_LEN, "✓ Statement written to Base  ·  2.5 s")]

def dur(p): return float(subprocess.run(["ffprobe","-v","error","-show_entries","format=duration","-of","csv=p=0",str(p)],capture_output=True,text=True).stdout)
def run(cmd): subprocess.run(cmd, check=True)

parts = []
V = ["-c:v","libx264","-preset","medium","-crf","20","-pix_fmt","yuv420p","-r","30","-an"]
for i, (kind, src, d, _) in enumerate(segs):
    out = R / f"seg{i}.mp4"; parts.append(out)
    if kind == "img":
        run(["ffmpeg","-y","-loglevel","error","-loop","1","-t",str(d),"-i",str(R/src),"-vf","scale=1920:1080,fade=in:0:12",*V,str(out)])
    elif kind == "live":
        # Full stage, with two close-ups on the dashboard's budget + vault cards (auto-save and the lock).
        cuts = [(0, 9.5, False), (9.5, 17.0, True), (17.0, 38.5, False), (38.5, 46.0, True), (46.0, d, False)]
        sub = []
        for j, (a, b, zoom) in enumerate(cuts):
            vf = "fps=30" + (",crop=1180:664:0:56,scale=1920:1080:flags=lanczos" if zoom else "") + (",fade=in:0:10" if j == 0 else "")
            o = R / f"seg{i}_{j}.mp4"; sub.append(o)
            run(["ffmpeg","-y","-loglevel","error","-ss",str(LIVE_IN + a),"-t",str(b - a),"-i",str(R/src),"-vf",vf,*V,str(o)])
        (R/"live_concat.txt").write_text("".join(f"file '{p}'\n" for p in sub))
        run(["ffmpeg","-y","-loglevel","error","-f","concat","-safe","0","-i",str(R/"live_concat.txt"),"-c","copy",str(out)])
    else:  # slow vertical pan over a tall screenshot
        run(["ffmpeg","-y","-loglevel","error","-loop","1","-t",str(d),"-i",str(R/src),"-vf",
             f"crop=1920:1080:0:'min(ih-1080,max(0,(t-1)/({d}-2.5))*(ih-1080))',fade=in:0:12",*V,str(out)])
(R/"concat.txt").write_text("".join(f"file '{p}'\n" for p in parts))
run(["ffmpeg","-y","-loglevel","error","-f","concat","-safe","0","-i",str(R/"concat.txt"),"-c","copy",str(R/"video.mp4")])

# Voiceover: place each line at its absolute time.
starts, t = [], 0.0
for s in segs: starts.append(t); t += s[2]
total = t
cues, inputs, filt = [], [], []
for si, (_, _, _, vos) in enumerate(segs):
    for key, off in vos:
        at = starts[si] + off; wav = R/"vo"/f"{key}.wav"
        inputs += ["-i", str(wav)]; n = len(inputs)//2
        filt.append(f"[{n}:a]adelay={int(at*1000)}|{int(at*1000)}[a{n}]")
        cues.append((at, dur(wav), lines[key]))
mix = "".join(f"[a{k}]" for k in range(1, len(inputs)//2+1))
filt.append(f"{mix}amix=inputs={len(inputs)//2}:normalize=0,apad,atrim=0:{total},afade=t=out:st={total-1.5}:d=1.5,loudnorm=I=-16[aout]")

# Captions (ASS): split each line into short chunks timed by character count.
def ts(x): h=int(x//3600); m=int(x%3600//60); s=x%60; return f"{h}:{m:02d}:{s:05.2f}"
ev = []
for at, d, text in cues:
    chunks, cur = [], ""
    for w in re.split(r"(?<=[.,:;!?])\s+", text):
        for word in w.split():
            if len(cur) + len(word) > 62 and cur: chunks.append(cur); cur = ""
            cur = (cur + " " + word).strip()
        if len(cur) > 28: chunks.append(cur); cur = ""
    if cur: chunks.append(cur)
    total_c = sum(len(c) for c in chunks); t0 = at
    for c in chunks:
        d1 = d * len(c) / total_c
        ev.append(f"Dialogue: 0,{ts(t0)},{ts(t0+d1)},Sub,,0,0,0,,{c}"); t0 += d1
live0 = starts[3]
for a, b, text in chips:
    ev.append(f"Dialogue: 1,{ts(live0+a)},{ts(live0+b)},Chip,,0,0,0,,{{\\fad(200,200)}}{text}")
ass = f"""[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Sub,Noto Sans,42,&H00FFFFFF,&H00FFFFFF,&H00000000,&H90000000,1,0,0,0,100,100,0,0,3,14,0,2,120,120,36,1
Style: Chip,Noto Sans,40,&H0050E05A,&H00FFFFFF,&H00000000,&H20101010,1,0,0,0,100,100,0,0,3,16,0,9,40,40,80,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
""" + "\n".join(ev) + "\n"
(R/"captions.ass").write_text(ass)
OUT.parent.mkdir(parents=True, exist_ok=True)
run(["ffmpeg","-y","-loglevel","error","-i",str(R/"video.mp4"),*inputs,"-filter_complex",";".join(filt)+f";[0:v]ass={R/'captions.ass'}[vout]",
     "-map","[vout]","-map","[aout]","-c:v","libx264","-preset","slow","-crf","21","-pix_fmt","yuv420p","-profile:v","high",
     "-c:a","aac","-b:a","160k","-ar","48000","-movflags","+faststart","-t",str(total),str(OUT)])
print("total", total, "->", OUT)
