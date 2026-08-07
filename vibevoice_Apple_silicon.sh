#!/usr/bin/env bash
# =============================================================================
# VibeVoice for Apple Silicon — reproducible installer & runner
#
# A clean-room rewrite inspired by sammcj/VibeVoice4macOS, with every version
# pinned to a combination proven working on a Mac Mini M4 (64 GB, macOS, MPS):
#
#   Python 3.12 (provisioned by uv — identical on every machine)
#   torch 2.13.0 / transformers 4.51.3 / gradio 5.50.0 / accelerate 1.6.0
#   VibeVoice code pinned to an exact git commit
#
# Fixes baked in (bugs present in the original installer):
#   1. FFMPEG_DIR exported before the Python ffmpeg fallback (KeyError fix)
#   2. No obsolete `--resume` flag passed to the `hf` CLI
#   3. bash 3.2-safe launch (no empty-array `unbound variable` crash)
#   4. gradio pinned to 5.50.0 (gradio 6 breaks the demo UI)
#
# Usage:
#   bash vibevoice_apple_silicon.sh                # install + memory-aware model picker + web UI
#   bash vibevoice_apple_silicon.sh --model microsoft/VibeVoice-1.5B   # skip the picker
#   bash vibevoice_apple_silicon.sh --model aoi-ot/VibeVoice-Large     # skip the picker
#   bash vibevoice_apple_silicon.sh --port 7861
#   bash vibevoice_apple_silicon.sh --share        # also create a public gradio link
#   bash vibevoice_apple_silicon.sh --clean        # remove everything this script created
#
# Everything lives under ~/vibevoice (override with VIBEVOICE_HOME=/path).
# Nothing is installed system-wide except the tiny `uv` binary (~/.local/bin).
# =============================================================================
set -euo pipefail
 
# ----------------------------------------------------------------------------
# Configuration (pinned, known-good)
# ----------------------------------------------------------------------------
PROJECT_DIR="${VIBEVOICE_HOME:-$HOME/vibevoice}"
PYTHON_VERSION="3.12"
 
REPO_URL="https://github.com/WhoPaidItAll/VibeVoice"
REPO_COMMIT="ed8d04b029cef13c33bfe80f3a532e93eb66466d"   # pinned 2026-08-07
 
MODEL_LARGE="aoi-ot/VibeVoice-Large"     # community mirror of the 7B/Large weights
MODEL_SMALL="microsoft/VibeVoice-1.5B"   # smaller & faster official model
MODEL_ID=""                               # chosen interactively unless --model given
MODEL_EXPLICIT=0
PORT="${PORT:-7860}"
SHARE=0
CLEAN=0
 
# If a previous sammcj/VibeVoice4macOS install already downloaded the model,
# reuse those files instead of re-downloading ~18 GB.
LEGACY_MODELS_DIR="$HOME/vibevoice_mac/models"
 
VENV_DIR="$PROJECT_DIR/.venv"
REPO_DIR="$PROJECT_DIR/VibeVoice"
MODELS_DIR="$PROJECT_DIR/models"
TOOLS_DIR="$PROJECT_DIR/tools"
FFMPEG_DIR="$TOOLS_DIR/ffmpeg"
OUTPUTS_DIR="$PROJECT_DIR/outputs"
 
info()  { printf '\033[1;34m[INFO]\033[0m %s\n'  "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m %s\n'  "$*" >&2; }
error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
done_() { printf '\033[1;32m[DONE]\033[0m %s\n'  "$*"; }
 
# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --model) shift; MODEL_ID="${1:-}"; [ -z "$MODEL_ID" ] && { error "--model requires a value"; exit 2; }; MODEL_EXPLICIT=1 ;;
    --port)  shift; PORT="${1:-}";     [ -z "$PORT" ]     && { error "--port requires a value";  exit 2; } ;;
    --share) SHARE=1 ;;
    --clean) CLEAN=1 ;;
    -h|--help)
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) error "Unknown option: $1 (try --help)"; exit 2 ;;
  esac
  shift
done
 
# ----------------------------------------------------------------------------
# --clean: remove everything this script created
# ----------------------------------------------------------------------------
if [ "$CLEAN" -eq 1 ]; then
  printf 'This will delete %s (venv, code, models, outputs). Continue? [y/N] ' "$PROJECT_DIR"
  read -r reply
  case "$reply" in
    y|Y|yes|YES) rm -rf "$PROJECT_DIR"; done_ "Removed $PROJECT_DIR" ;;
    *) info "Aborted; nothing deleted." ;;
  esac
  exit 0
fi
 
# ----------------------------------------------------------------------------
# Platform guard
# ----------------------------------------------------------------------------
if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  error "This script targets Apple Silicon Macs only (detected: $(uname -s)/$(uname -m))."
  exit 1
fi
 
# ----------------------------------------------------------------------------
# Model selection — memory-aware prompt (skipped when --model is given)
# ----------------------------------------------------------------------------
if [ "$MODEL_EXPLICIT" -eq 0 ]; then
  RAM_BYTES="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
  RAM_GB=$(( RAM_BYTES / 1073741824 ))
 
  if [ "$RAM_GB" -ge 32 ]; then
    RECOMMENDED="$MODEL_LARGE"; DEFAULT_CHOICE=1
    REC_NOTE="your ${RAM_GB} GB comfortably fits the Large model"
  else
    RECOMMENDED="$MODEL_SMALL"; DEFAULT_CHOICE=2
    REC_NOTE="with ${RAM_GB} GB, the 1.5B model is the safe choice (Large wants ~20 GB free)"
  fi
 
  if [ -t 0 ]; then
    echo ""
    info "Detected ${RAM_GB} GB unified memory — ${REC_NOTE}."
    echo ""
    echo "  Which model would you like to use?"
    echo ""
    m1="  1) VibeVoice-Large (7B) — best quality, ~18 GB download, needs ~20 GB memory"
    m2="  2) VibeVoice-1.5B       — smaller & faster, ~5 GB download, needs ~8 GB memory"
    if [ "$DEFAULT_CHOICE" -eq 1 ]; then m1="$m1  [recommended]"; else m2="$m2  [recommended]"; fi
    echo "$m1"
    echo "$m2"
    echo ""
    printf "  Choice [%s]: " "$DEFAULT_CHOICE"
    read -r model_choice
    [ -z "$model_choice" ] && model_choice="$DEFAULT_CHOICE"
    case "$model_choice" in
      1) MODEL_ID="$MODEL_LARGE" ;;
      2) MODEL_ID="$MODEL_SMALL" ;;
      *) warn "Unrecognized choice '$model_choice'; using recommended."; MODEL_ID="$RECOMMENDED" ;;
    esac
    echo ""
  else
    # Non-interactive run (piped/CI): auto-pick the recommendation, don't hang.
    MODEL_ID="$RECOMMENDED"
    info "Non-interactive run: auto-selecting $MODEL_ID based on ${RAM_GB} GB RAM."
  fi
fi
info "Selected model: $MODEL_ID"
info "Tip: models are cached — re-run anytime and pick the other one; switching is instant after first download."
 
mkdir -p "$PROJECT_DIR" "$MODELS_DIR" "$TOOLS_DIR" "$FFMPEG_DIR" "$OUTPUTS_DIR"
 
# Keep all Hugging Face caches inside the project (fully self-contained).
export HF_HOME="$PROJECT_DIR/cache/huggingface"
export HF_HUB_CACHE="$HF_HOME/hub"
export HF_HUB_DISABLE_TELEMETRY=1
 
# ----------------------------------------------------------------------------
# Step 1/6 — uv (installs its own pinned Python; no Homebrew, no sudo)
# ----------------------------------------------------------------------------
export PATH="$HOME/.local/bin:$PATH"
if ! command -v uv >/dev/null 2>&1; then
  info "Installing uv (single binary into ~/.local/bin) ..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi
command -v uv >/dev/null 2>&1 || { error "uv installation failed."; exit 1; }
info "uv: $(uv --version)"
 
# ----------------------------------------------------------------------------
# Step 2/6 — Python + virtual environment (pinned ${PYTHON_VERSION})
# ----------------------------------------------------------------------------
if [ ! -x "$VENV_DIR/bin/python" ]; then
  info "Creating venv with Python $PYTHON_VERSION at $VENV_DIR ..."
  uv venv --python "$PYTHON_VERSION" "$VENV_DIR"
else
  info "Reusing venv at $VENV_DIR"
fi
# shellcheck disable=SC1091
. "$VENV_DIR/bin/activate"
info "Python: $(python --version) at $(command -v python)"
 
# ----------------------------------------------------------------------------
# Step 3/6 — VibeVoice source, pinned to an exact commit
# ----------------------------------------------------------------------------
if [ ! -d "$REPO_DIR/.git" ]; then
  info "Fetching VibeVoice source at pinned commit ${REPO_COMMIT:0:12} ..."
  git init -q "$REPO_DIR"
  git -C "$REPO_DIR" remote add origin "$REPO_URL"
  git -C "$REPO_DIR" fetch -q --depth 1 origin "$REPO_COMMIT"
  git -C "$REPO_DIR" checkout -q FETCH_HEAD
else
  info "Reusing VibeVoice source at $REPO_DIR"
fi
 
# ----------------------------------------------------------------------------
# Step 4/6 — Python packages (exact versions proven working together)
# ----------------------------------------------------------------------------
CONSTRAINTS="$PROJECT_DIR/constraints.txt"
cat > "$CONSTRAINTS" <<'EOF'
# Exact versions verified working on Mac Mini M4 / macOS / MPS (2026-08-07)
accelerate==1.6.0
diffusers==0.39.0
gradio==5.50.0
gradio_client==1.14.0
huggingface_hub==0.36.2
numpy==2.4.6
safetensors==0.8.0
scipy==1.18.0
soundfile==0.14.0
tokenizers==0.21.4
torch==2.13.0
transformers==4.51.3
EOF
 
info "Installing pinned Python packages (first run takes a few minutes) ..."
uv pip install --constraint "$CONSTRAINTS" -e "$REPO_DIR"
uv pip install --constraint "$CONSTRAINTS" "huggingface_hub[cli]" soundfile imageio-ffmpeg
 
# ----------------------------------------------------------------------------
# Step 5/6 — ffmpeg (system copy if present, else portable copy in project)
# ----------------------------------------------------------------------------
if command -v ffmpeg >/dev/null 2>&1; then
  info "System ffmpeg found: $(command -v ffmpeg)"
elif [ -x "$FFMPEG_DIR/ffmpeg" ]; then
  info "Reusing portable ffmpeg at $FFMPEG_DIR/ffmpeg"
else
  info "No ffmpeg on PATH; obtaining a portable copy via imageio-ffmpeg ..."
  # NOTE: FFMPEG_DIR is passed explicitly into the child env (original bug #1).
  FFMPEG_DIR="$FFMPEG_DIR" python - <<'PY'
import os, shutil
from pathlib import Path
import imageio_ffmpeg
exe = imageio_ffmpeg.get_ffmpeg_exe()
target_dir = Path(os.environ["FFMPEG_DIR"])
target_dir.mkdir(parents=True, exist_ok=True)
target = target_dir / "ffmpeg"
shutil.copy2(exe, target)
os.chmod(target, 0o755)
print(f"[ffmpeg] portable binary at: {target}")
PY
  [ -x "$FFMPEG_DIR/ffmpeg" ] || { error "Could not obtain ffmpeg."; exit 1; }
fi
export PATH="$FFMPEG_DIR:$PATH"
 
# ----------------------------------------------------------------------------
# Step 6/6 — Model weights (download once, reuse forever)
# ----------------------------------------------------------------------------
MODEL_SAFE_NAME="$(printf '%s' "$MODEL_ID" | tr '/' '_')"
MODEL_PATH="$MODELS_DIR/$MODEL_SAFE_NAME"
LEGACY_PATH="$LEGACY_MODELS_DIR/$(printf '%s' "$MODEL_ID" | sed 's|/|__|')"
 
if [ -d "$MODEL_PATH" ] && [ -n "$(ls -A "$MODEL_PATH" 2>/dev/null || true)" ]; then
  info "Reusing model at $MODEL_PATH"
elif [ -d "$LEGACY_PATH" ] && [ -n "$(ls -A "$LEGACY_PATH" 2>/dev/null || true)" ]; then
  info "Found existing download from a previous VibeVoice4macOS install; reusing it."
  MODEL_PATH="$LEGACY_PATH"
else
  info "Downloading $MODEL_ID (large — interrupted downloads resume automatically) ..."
  # NOTE: no `--resume` flag — modern `hf` CLI resumes by default (original bug #2).
  hf download "$MODEL_ID" --repo-type model --local-dir "$MODEL_PATH"
fi
done_ "Model ready at: $MODEL_PATH"
 
# ----------------------------------------------------------------------------
# Launcher bootstrap: forces SDPA attention + MPS placement, never CUDA
# ----------------------------------------------------------------------------
cat > "$PROJECT_DIR/.vv_bootstrap.py" <<'PY'
import os, sys, runpy
 
os.environ.setdefault('ACCELERATE_DISABLE_CUDA', '1')
os.environ.setdefault('CUDA_VISIBLE_DEVICES', '')
os.environ.setdefault('PYTORCH_ENABLE_MPS_FALLBACK', '1')
 
try:
    from transformers import modeling_utils as _mu
    import torch
 
    try:
        _mu.caching_allocator_warmup = lambda *a, **k: None
    except Exception:
        pass
 
    _orig = _mu.PreTrainedModel.from_pretrained
    def _patched_from_pretrained(cls, path, *args, **kwargs):
        kwargs.pop('use_flash_attention_2', None)
        if kwargs.get('attn_implementation') != 'sdpa':
            kwargs['attn_implementation'] = 'sdpa'
        kwargs.pop('caching_allocator_warmup', None)
 
        want_mps = torch.backends.mps.is_available()
        target_dev = 'mps' if want_mps else 'cpu'
        dm = kwargs.get('device_map', 'auto')
        if (
            dm == 'auto'
            or (isinstance(dm, str) and 'cuda' in dm)
            or (isinstance(dm, dict) and any('cuda' in str(v) for v in dm.values()))
        ):
            kwargs['device_map'] = target_dev
 
        if want_mps and kwargs.get('torch_dtype') is None:
            kwargs['torch_dtype'] = torch.float16
 
        return _orig.__func__(cls, path, *args, **kwargs)
 
    _mu.PreTrainedModel.from_pretrained = classmethod(_patched_from_pretrained)
except Exception as e:
    print(f"[WARN] bootstrap: could not patch transformers: {e}", file=sys.stderr)
 
demo = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'VibeVoice', 'demo', 'gradio_demo.py')
sys.argv = [demo] + sys.argv[1:]
runpy.run_path(demo, run_name='__main__')
PY
 
# ----------------------------------------------------------------------------
# Launch the web UI
# ----------------------------------------------------------------------------
if command -v lsof >/dev/null 2>&1 && lsof -iTCP:"$PORT" -sTCP:LISTEN -n >/dev/null 2>&1; then
  error "Port $PORT is already in use. Re-run with --port <other_port>."
  exit 1
fi
 
DEVICE="$(python -c 'import torch; print("mps" if torch.backends.mps.is_available() else "cpu")')"
info "Launching Gradio web UI on http://127.0.0.1:$PORT (device: $DEVICE)"
info "Loading ~18 GB of weights takes a few minutes — wait for the 'Running on local URL' line."
 
# bash 3.2-safe optional flag (original bug #3: no empty-array expansion)
SHARE_FLAG=""
if [ "$SHARE" -eq 1 ]; then SHARE_FLAG="--share"; fi
 
cd "$PROJECT_DIR"
exec env ACCELERATE_DISABLE_CUDA=1 CUDA_VISIBLE_DEVICES="" PYTORCH_ENABLE_MPS_FALLBACK=1 \
  python .vv_bootstrap.py \
    --model_path "$MODEL_PATH" \
    --port "$PORT" \
    --device "$DEVICE" \
    ${SHARE_FLAG:+"$SHARE_FLAG"}
 
