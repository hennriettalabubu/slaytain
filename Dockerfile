# dhi-aio-studio: Debian-system (Ubuntu 24.04) all-in-one GPU studio.
# Pulls uv binary from gwingz/dhi-uv:0 (DHI) and matches gwingz/dhi-nvidia-cuda:13 for CUDA stack.

ARG CUDA_BASE=nvidia/cuda:13.4.2-cudnn-devel-ubuntu24.04
ARG UV_SOURCE=gwingz/dhi-uv:0

# ---------- Stage 1: pull uv binary from gwingz DHI ----------
FROM ${UV_SOURCE} AS uv-src

# ---------- Stage 2: runtime ----------
FROM ${CUDA_BASE} AS runtime
ARG PY_VERSION=3.12

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Etc/UTC \
    SHELL=/usr/bin/zsh \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    PATH=/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    UV_PYTHON_INSTALL_DIR=/opt/uv-python \
    JUPYTER_PORT=8888 \
    CADDY_PORT=8080 \
    SSH_PORT=22 \
    TENSORBOARD_PORT=6006 \
    AITOOLKIT_PORT=8675 \
    AITOOLKIT_HOME=/opt/ai-toolkit

SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

# OS packages
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg lsb-release \
        git git-lfs \
        sudo zsh bash \
        build-essential pkg-config \
        openssh-server openssh-client \
        tini \
        jq locales tzdata procps htop tmux \
        file less vim nano \
        rsync unzip zip \
        libffi-dev libssl-dev zlib1g-dev \
        fzf eza \
        python-is-python3 \
        ffmpeg \
    ; \
    locale-gen en_US.UTF-8; \
    mkdir -p /run/sshd

# Caddy (portal reverse proxy) — direct static binary from caddyserver.com
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) cad_arch=amd64 ;; \
      arm64) cad_arch=arm64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl --retry 5 --retry-all-errors --retry-delay 2 -fsSL "https://caddyserver.com/api/download?os=linux&arch=${cad_arch}" \
      -o /usr/local/bin/caddy; \
    chmod +x /usr/local/bin/caddy; \
    /usr/local/bin/caddy version

# cloudflared (Cloudflare Tunnel client) — multi-arch
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) cfurl="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;; \
      arm64) cfurl="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl --retry 5 --retry-all-errors --retry-delay 2 -fsSL -o /usr/local/bin/cloudflared "$cfurl"; \
    chmod +x /usr/local/bin/cloudflared; \
    cloudflared --version

# uv (Astral) — copy prebuilt binary from gwingz DHI
COPY --from=uv-src /usr/local/bin/uv /usr/local/bin/uv
RUN chmod +x /usr/local/bin/uv && /usr/local/bin/uv --version

# nobbby user (sudo, NOPASSWD, zsh shell)
ARG NOBBBY_UID=1000
ARG NOBBBY_GID=1000
RUN set -eux; \
    if getent group ubuntu >/dev/null; then groupdel ubuntu || true; fi; \
    if id ubuntu >/dev/null 2>&1; then userdel -r ubuntu || true; fi; \
    groupadd -g ${NOBBBY_GID} nobbby; \
    useradd -m -u ${NOBBBY_UID} -g ${NOBBBY_GID} -G sudo,video -s /usr/bin/zsh nobbby; \
    echo 'nobbby ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-nobbby; \
    chmod 0440 /etc/sudoers.d/90-nobbby

# Homebrew (linuxbrew) — installed as nobbby, lives in /home/linuxbrew
RUN set -eux; \
    mkdir -p /home/linuxbrew; chown -R nobbby:nobbby /home/linuxbrew; \
    sudo -u nobbby -H bash -lc 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'; \
    sudo -u nobbby -H bash -lc 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" && brew --version'

# Prezto + zplug + Powerlevel10k for nobbby
USER nobbby
WORKDIR /home/nobbby
RUN set -eux; \
    git clone --recursive https://github.com/sorin-ionescu/prezto.git /home/nobbby/.zprezto; \
    git clone https://github.com/zplug/zplug.git /home/nobbby/.zplug; \
    for rc in zlogin zlogout zpreztorc zprofile zshenv zshrc; do \
      ln -sf "/home/nobbby/.zprezto/runcoms/${rc}" "/home/nobbby/.${rc}"; \
    done; \
    # Prezto owns the symlink target; copy to a real file we can edit, then relink.
    cp -L /home/nobbby/.zpreztorc /home/nobbby/.zpreztorc.real; \
    rm /home/nobbby/.zpreztorc; mv /home/nobbby/.zpreztorc.real /home/nobbby/.zpreztorc; \
    sed -ri "s/^(zstyle ':prezto:module:prompt' theme).*/\\1 'off'/" /home/nobbby/.zpreztorc; \
    { \
      echo ''; \
      echo '# --- dhi-aio-studio additions ---'; \
      echo '# Powerlevel10k instant prompt (must stay near the top of .zshrc)'; \
      echo '[[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]] && \\'; \
      echo '  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"'; \
      echo 'export ZPLUG_HOME="$HOME/.zplug"'; \
      echo 'source "$ZPLUG_HOME/init.zsh"'; \
      echo 'zplug "zsh-users/zsh-autosuggestions"'; \
      echo 'zplug "zsh-users/zsh-syntax-highlighting", defer:2'; \
      echo 'zplug "zsh-users/zsh-completions"'; \
      echo 'zplug "romkatv/powerlevel10k", as:theme, depth:1'; \
      echo 'zplug load'; \
      echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"'; \
      echo 'export PATH="$HOME/.local/bin:$PATH"'; \
      echo '# Load p10k config if present (run `p10k configure` to regenerate)'; \
      echo '[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh'; \
      echo '# Shared extras (fzf, eza, nvm, gcloud, aliases, ~/.zshrc.local hook)'; \
      echo '[[ -f ~/.zshrc.extra ]] && source ~/.zshrc.extra'; \
    } >> /home/nobbby/.zshrc; \
    /usr/bin/zsh -i -c 'source $HOME/.zshrc && zplug install' || true
COPY --chown=nobbby:nobbby p10k.zsh    /home/nobbby/.p10k.zsh
COPY --chown=nobbby:nobbby zshrc.extra /home/nobbby/.zshrc.extra

# nvm (per-user Node version manager for nobbby) + Google Cloud SDK
RUN set -eux; \
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | PROFILE=/dev/null bash; \
    curl -fsSL https://sdk.cloud.google.com -o /tmp/gcloud-install.sh; \
    bash /tmp/gcloud-install.sh --disable-prompts --install-dir="$HOME"; \
    rm /tmp/gcloud-install.sh

# Python + Jupyter + PyTorch (CUDA 13) via uv — installed in /opt/venv as root for shared use
USER root
ENV VENV=/opt/venv
RUN --mount=type=cache,target=/root/.cache/uv,sharing=locked \
    set -eux; \
    uv venv --python ${PY_VERSION} ${VENV}; \
    . ${VENV}/bin/activate; \
    uv pip install \
        "jupyterlab>=4.2" \
        "notebook>=7.2" \
        "ipywidgets" \
        "jupyter-server-proxy" \
        "jupyterlab-git" \
        "tensorboard" \
        "numpy" "pandas" "scipy" "scikit-learn" \
        "matplotlib" "seaborn" "pillow" \
        "requests" "httpx" "pydantic" "rich" "typer" \
        "transformers" "datasets" "accelerate" "safetensors" \
        "huggingface-hub" ; \
    uv pip install --index-url https://download.pytorch.org/whl/cu130 \
        "torch" "torchvision" "torchaudio" || \
    uv pip install --index-url https://download.pytorch.org/whl/cu128 \
        "torch" "torchvision" "torchaudio" ; \
    ln -sf ${VENV}/bin/jupyter /usr/local/bin/jupyter; \
    ln -sf ${VENV}/bin/jupyter-lab /usr/local/bin/jupyter-lab; \
    ln -sf ${VENV}/bin/tensorboard /usr/local/bin/tensorboard

# ai-toolkit (ostris) — baked at build time at ${AITOOLKIT_HOME}
# NOTE: pulls in ~5 GB of torch 2.13 / cu130 wheels + flash-attn + natten + Node 23 + full UI build
COPY --chmod=0755 scripts/install-ai-toolkit.sh /opt/scripts/install-ai-toolkit.sh
RUN --mount=type=cache,target=/root/.cache/uv,sharing=locked \
    --mount=type=cache,target=/root/.npm,sharing=locked \
    /opt/scripts/install-ai-toolkit.sh "${AITOOLKIT_HOME}"

# Portal (Caddy config) and onstart entrypoint
RUN mkdir -p /opt/portal-aio /workspace /var/log/aio && \
    chown -R nobbby:nobbby /workspace /var/log/aio /opt/portal-aio
COPY --chown=root:root Caddyfile /opt/portal-aio/Caddyfile
COPY --chown=root:root --chmod=0755 onstart.sh /onstart.sh

# SSH host keys generated at container start (not baked)
RUN set -eux; \
    sed -ri 's/^#?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config; \
    sed -ri 's/^#?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config; \
    sed -ri 's/^#?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

EXPOSE 22 8080 8888 6006 8675

WORKDIR /workspace
# Tini reaps zombies; onstart.sh orchestrates services
ENTRYPOINT ["/usr/bin/tini", "--", "/onstart.sh"]
CMD ["serve"]
