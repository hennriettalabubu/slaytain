#!/usr/bin/env bash
# Install ai-toolkit into the dhi-aio-studio image.
# Works at BUILD time (Dockerfile RUN) and RUNTIME (idempotent re-run).
#
# Usage: install-ai-toolkit.sh [TARGET_DIR]
#   TARGET_DIR defaults to ${AITOOLKIT_HOME:-/opt/ai-toolkit}
set -euxo pipefail

TARGET_DIR="${1:-${AITOOLKIT_HOME:-/opt/ai-toolkit}}"
NODE_MAJOR="${NODE_MAJOR:-23}"

LOG_DIR="/var/log/aio"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/ai-toolkit-install.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== $(date -Is) START install-ai-toolkit → $TARGET_DIR ==="

# ---------- 1. Clone (or update) ai-toolkit ----------
mkdir -p "$(dirname "$TARGET_DIR")"
if [ ! -d "$TARGET_DIR/.git" ]; then
  git clone https://github.com/ostris/ai-toolkit.git "$TARGET_DIR"
fi
cd "$TARGET_DIR"
git fetch --all
git submodule update --init --recursive || true

# ---------- 2. Node ${NODE_MAJOR} (needed for the UI) ----------
if ! command -v node >/dev/null 2>&1 || [ "$(node -v | sed 's/v//' | cut -d. -f1)" -lt "$NODE_MAJOR" ]; then
  echo "--- installing Node ${NODE_MAJOR} ---"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o /tmp/nodesource_setup.sh
  bash /tmp/nodesource_setup.sh
  DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
  rm -f /tmp/nodesource_setup.sh
fi
node --version
npm --version

# ---------- 3. Python deps (into /opt/venv) ----------
# shellcheck disable=SC1091
source /opt/venv/bin/activate
echo "--- python version ---"
python -V

# Pin torch to ai-toolkit's required stack so flash-attn/natten/torchcodec wheels resolve.
# Non-standard version — ostris + mjun0812 custom wheels for CUDA 13 / torch 2.13.
uv pip install --python /opt/venv/bin/python \
  torch==2.13.0 torchvision==0.28.0 torchaudio==2.11.0 \
  --index-url https://download.pytorch.org/whl/cu130

uv pip install --python /opt/venv/bin/python -r requirements.txt
# setuptools pin — ai-toolkit's requirements leave this unspecified and newer
# setuptools breaks one of its build-time hooks. Revisit if upstream pins it.
uv pip install --python /opt/venv/bin/python setuptools==69.5.1

# Accelerators (versions straight from ostris docker/Dockerfile)
# NOTE: `-U` can drag torch to 2.14 which breaks flash-attn's c10 ABI. Install
# accelerators first, then re-pin torch 2.13 so the wheels line up again.
uv pip install --python /opt/venv/bin/python -U \
  torchcodec==0.15.0 \
  natten==0.21.7+torch2130cu130 \
  --find-links https://whl.natten.org \
  https://github.com/mjun0812/flash-attention-prebuild-wheels/releases/download/v0.9.47/flash_attn-2.8.3+cu130torch2.13-cp312-cp312-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl

# Re-pin torch to the exact ABI the accelerators were compiled against.
uv pip install --python /opt/venv/bin/python --reinstall \
  --index-url https://download.pytorch.org/whl/cu130 \
  torch==2.13.0 torchvision==0.28.0 torchaudio==2.11.0

python - <<'PY'
import torch, flash_attn, natten, torchcodec
print("accelerators OK:",
      "torch=%s" % torch.__version__,
      "flash_attn=%s" % flash_attn.__version__,
      "natten=%s" % natten.__version__,
      "torchcodec=%s" % torchcodec.__version__)
print("cuda available:", torch.cuda.is_available(), "device count:", torch.cuda.device_count())
PY

# ---------- 4. UI build ----------
cd "$TARGET_DIR/ui"
npm ci --no-audit --no-fund
npm run update_db
npm run build

# Permissions — nobbby owns the install so UI can write its sqlite db / cache / etc.
chown -R nobbby:nobbby "$TARGET_DIR"

echo "=== $(date -Is) DONE install-ai-toolkit → $TARGET_DIR ==="
echo "Start service:  cd $TARGET_DIR && npm --prefix ui start   # listens :\${AITOOLKIT_PORT:-8675}"
