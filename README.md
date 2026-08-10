# VibeVoice for Apple Silicon

One-script, fully reproducible setup for running [VibeVoice](https://github.com/vibevoice-community/VibeVoice) — the open-source long-form multi-speaker TTS model originally released by Microsoft — locally on Apple Silicon Macs (M1–M4). No CUDA, no Homebrew, no Docker, no ComfyUI.

Tested working on a Mac Mini M4 (64 GB RAM) with the VibeVoice-Large (7B) model.

## Quick start

```bash
git clone https://github.com/cyberirishman/Vibe-Voice-MacM4-2026.git
cd Vibe-Voice-MacM4-2026
bash vibevoice_apple_silicon.sh
```

On first run the script detects your Mac's unified memory and asks which model you want — VibeVoice-Large (7B, best quality, ~18 GB download) or VibeVoice-1.5B (smaller and faster, ~5 GB download) — with the right choice for your RAM marked as the default. Whichever you pick is both downloaded and launched. When you see `Running on local URL: http://127.0.0.1:7860`, open that address in your browser. Model loading itself takes a few quiet minutes — don't ctrl-C.

Models are cached after download: re-run the script anytime and pick the other model to switch (instant once both are downloaded). Passing `--model` on the command line skips the picker entirely.

## What the script does

Everything is sandboxed under `~/vibevoice` (override with `VIBEVOICE_HOME=/path`) — the cloned installer repo stays tiny, and models live outside it:

```
~/vibevoice/
├── .venv/                                  ← Python 3.12 + all pinned packages
├── VibeVoice/                              ← VibeVoice source code (pinned commit)
│   └── demo/voices/                        ← drop your voice-clone samples here
├── models/
│   ├── aoi-ot_VibeVoice-Large/             ← ~18 GB (if you chose Large)
│   └── microsoft_VibeVoice-1.5B/           ← ~5 GB  (if you chose 1.5B)
├── cache/huggingface/                      ← Hugging Face download cache
├── tools/ffmpeg/                           ← portable ffmpeg (only if system ffmpeg missing)
├── outputs/                                ← generated audio
└── constraints.txt                         ← the exact package pins used
```

Step by step:

1. Installs [uv](https://docs.astral.sh/uv/) if missing (single binary in `~/.local/bin` — the only thing outside the project folder).
2. Provisions **Python 3.12** via uv — everyone gets the identical interpreter, regardless of what their Mac ships with.
3. Fetches the VibeVoice source at a **pinned git commit**.
4. Installs **exact pinned package versions** (see `constraints.txt` written into the project folder) — a combination verified working together on macOS/MPS, including `torch 2.13.0`, `transformers 4.51.3`, and `gradio 5.50.0`.
5. Uses system ffmpeg if present, otherwise fetches a portable copy into the project folder.
6. Downloads the model weights from Hugging Face (default: `aoi-ot/VibeVoice-Large`, the community mirror of the 7B weights). Interrupted downloads resume automatically. If you previously used sammcj/VibeVoice4macOS, its downloaded weights are detected and reused.
7. Launches the Gradio web UI on MPS (Apple GPU), forcing SDPA attention and float16 — never CUDA.

## Options

```
--model <hf_repo>   Model to use, skipping the interactive picker
                    e.g. --model aoi-ot/VibeVoice-Large
                         --model microsoft/VibeVoice-1.5B
--port <port>       Web UI port (default: 7860)
--share             Also create a public gradio.live share link
--clean             Delete ~/vibevoice entirely (venv, code, models, outputs)
--help              Show usage
```

Run non-interactively (piped input, automation): the picker is skipped and the script auto-selects the model recommended for the machine's RAM.

## Hardware guidance

| Model | Unified memory needed | Notes |
|---|---|---|
| VibeVoice-1.5B | ~8 GB (fp16) | Fine on 16 GB Macs |
| VibeVoice-Large (7B) | ~20 GB (fp16) | Recommended 32 GB+; comfortable on 64 GB |

Generation on MPS is slower than on NVIDIA GPUs but very usable, especially for the 1.5B model. For long scripts, split text into shorter chunks.

## Cloning your own voice

VibeVoice does zero-shot voice cloning from a short audio sample — and adding your own voice is just "drop a file in a folder." The web UI builds its speaker dropdown by scanning `demo/voices/` inside the VibeVoice code directory at startup; every audio file found there becomes a selectable voice.

1. **Record a sample**
2. (instructions for using voice memo app near end of readme)     
3. — roughly 30 seconds (20–60s) of natural speech, e.g. reading a paragraph aloud. Quiet room, one speaker, no background music. Accepted formats: `.wav`, `.mp3`, `.flac`, `.ogg`, `.m4a`, `.aac` — so a raw QuickTime or Voice Memos recording works without conversion.

4. **Name the file** following the convention the built-in voices use — `language-Name_gender.ext`:

   ```
   en-Andrew_man.wav
   ```

   The filename (minus extension) becomes the dropdown label. The convention is cosmetic; any filename works.

5. **Copy it into the voices folder:**

   ```bash
   cp en-Andrew_man.wav ~/vibevoice/VibeVoice/demo/voices/
   ```

6. **Restart the demo** (ctrl-C, then re-run the script). Your voice now appears in the speaker dropdown — select it, enter text, generate.

## Sampling Voices from Youtube ##
Only if you have permission.  
from inside the project folder :  
```bash
uvx yt-dlp -x --audio-format wav --download-sections "*1:00-1:35" \
  -o ~/Desktop/en-Speaker_man.wav "https://youtube.com/watch?v=VIDEO_ID"
``` 
  Adjust `*1:00-1:35` to a ~30-second stretch where only the target speaker is talking   
 — one voice, no music, no background noise.  
   
If yt-dlp complains it can't find ffmpeg (it needs it for the WAV conversion),   
install ffmpeg with homebrew  
```bash  
brew install ffmpeg    
```
OR point uvx to the portable version installed with this repo:
```bash  
uvx yt-dlp -x --audio-format wav --download-sections "*1:00-1:35" \
  --ffmpeg-location ~/vibevoice/tools/ffmpeg \
  -o ~/Desktop/en-Speaker_man.wav "https://youtube.com/watch?v=VIDEO_ID"
```
Tips: the clone inherits the character of the sample, so speak with the energy you want in the output — a flat sample produces flat speech. If results sound off, try a *different* 30 seconds rather than a longer file. You can add as many voices as you like and combine them in multi-speaker scripts.


## Capturing your own voice on a Mac ##  
Voice memos app create .m4a files, which project can use.  

Voice Memos (simplest — same app as on iPhone):

Open *Voice Memos* (Cmd+Space, type "Voice Memos").
Click the red record button, read a paragraph aloud for ~30 seconds, click done.  
Drag the new recording from the app's sidebar straight onto your Desktop — that gives you the audio file.  
Rename it to the convention, keeping the extension: en-Andrew_man.m4a, then copy to ~/vibevoice/VibeVoice/demo/voices/   

## Why this exists

The excellent [sammcj/VibeVoice4macOS](https://github.com/sammcj/VibeVoice4macOS) installer proved the approach, but a fresh install in mid-2026 hits four issues: an unexported `FFMPEG_DIR` crashing the ffmpeg fallback, an obsolete `--resume` flag rejected by the modern `hf` CLI, an empty-array expansion that crashes macOS's bash 3.2, and unpinned dependencies pulling in Gradio 6, which breaks the demo UI. This script is a clean rewrite with those fixed and every version pinned, so it keeps working tomorrow.

## Credits

- Original model and code: [Microsoft VibeVoice](https://github.com/vibevoice-community/VibeVoice) (MIT)
- Code preservation fork used here: [WhoPaidItAll/VibeVoice](https://github.com/WhoPaidItAll/VibeVoice)
- Large-model weight mirror: [aoi-ot/VibeVoice-Large](https://huggingface.co/aoi-ot/VibeVoice-Large)
- Prior art for macOS setup: [sammcj/VibeVoice4macOS](https://github.com/sammcj/VibeVoice4macOS)

## Responsible use

VibeVoice can clone voices convincingly. Don't generate audio of real people without their consent, and disclose AI-generated audio where listeners could reasonably mistake it for a real recording.
