# How the demo video was made

- `../stage.html` is the recording stage: the live dashboard (`dashboard/?compact=1`) on the left and the
  output of `script/e2e.py` on the right. It was captured with `ffmpeg -f x11grab` at 1920×1080 while
  `e2e.py` fired real transactions on Base Sepolia, Unichain Sepolia and Lasna (output: `../run.log`).
- `slides/*.html` are rendered to PNG with headless Chrome; the explorer shot is Reactscan's page for the
  budget-lock reactive transaction.
- `lines.json` is the narration, spoken with the offline Piper TTS voice `en_US-ryan-high`.
- `build.py` cuts the take (with two close-ups on the dashboard), adds the slides, mixes the voiceover and
  burns in `captions.ass`. Nothing in the live segment is sped up or edited out of order.
