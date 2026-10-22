# dhi-aio-studio

Debian-system (Ubuntu 24.04 + CUDA 13.4) all-in-one GPU studio, modeled on
`vastai/aio-studio` with extra specifics the user asked for.

## What's inside

- **Base:** `nvidia/cuda:13.4.2-cudnn-devel-ubuntu24.04` (matches `gwingz/dhi-nvidia-cuda:13` CUDA line)
- **uv** binary multi-stage copied from `gwingz/dhi-uv:0` (DHI)
- **User:** `nobbby` (uid 1000, sudo NOPASSWD, zsh login shell)
- **Shell stack:** Homebrew (linuxbrew), zsh, [Prezto](https://github.com/sorin-ionescu/prezto), [zplug](https://github.com/zplug/zplug) with `zsh-autosuggestions`, `zsh-syntax-highlighting`, `zsh-completions`
- **Python stack:** Python 3.12 venv at `/opt/venv` via uv; JupyterLab, PyTorch (cu130 → cu128 fallback), transformers, datasets, pandas, scikit-learn, tensorboard, …
- **Portal:** Caddy on `:8080` with landing + redirects to the dedicated subdomains
- **SSH:** sshd on `:22`, password + pubkey (seed with `NOBBBY_PASSWORD` + `NOBBBY_AUTHORIZED_KEYS`)
- **ai-toolkit** (Ostris): baked at `/opt/ai-toolkit`, UI on `:8675`, launched by `onstart.sh`
- **Cloudflare Tunnel:** `cloudflared` installed; `onstart.sh` runs it when `CF_TUNNEL_TOKEN` or `CF_TUNNEL_CONFIG` is set
- **Init:** `tini` → `/onstart.sh` orchestrates services; modes: `serve` (default), `oneshot`, `shell`

## Build

```powershell
.\build.ps1 -Tag ghcr.io/you/dhi-aio-studio:0.1
```

Or raw:

```powershell
docker build -t dhi-aio-studio:latest `
  --build-arg CUDA_BASE=nvidia/cuda:13.4.2-cudnn-devel-ubuntu24.04 `
  --build-arg UV_SOURCE=gwingz/dhi-uv:0 `
  .
```

## Run (local, with GPU)

```powershell
docker run --gpus all --rm -it `
  -p 8080:8080 -p 8888:8888 -p 2222:22 -p 6006:6006 -p 8675:8675 `
  -e NOBBBY_AUTHORIZED_KEYS="$(Get-Content $env:USERPROFILE\.ssh\id_ecdsa.pub)" `
  -e NOBBBY_PASSWORD="change-me" `
  -e JUPYTER_TOKEN="change-me" `
  -e AI_TOOLKIT_AUTH="change-me" `
  -v ${PWD}\workspace:/workspace `
  dhi-aio-studio:latest
```

Then:
- Portal: http://localhost:8080/
- JupyterLab direct: http://localhost:8888/?token=change-me
- ai-toolkit UI: http://localhost:8675/ (password from `AI_TOOLKIT_AUTH`)
- SSH: `ssh -p 2222 nobbby@localhost` (password or key)

### Shell mode

```powershell
docker run --gpus all --rm -it dhi-aio-studio:latest /onstart.sh shell
```

Drops you into zsh as `nobbby` with Prezto + zplug loaded.

## Cloudflare Tunnel (publish to the internet)

### Option A — Dashboard-managed tunnel (easiest)

1. Create a tunnel in the [Cloudflare Zero Trust dashboard](https://one.dash.cloudflare.com/) → Networks → Tunnels.
2. Copy the connector token.
3. Run with:

   ```powershell
   docker run --gpus all --rm `
     -e CF_TUNNEL_TOKEN="<token>" `
     -e NOBBBY_AUTHORIZED_KEYS="$(Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub)" `
     dhi-aio-studio:latest
   ```

4. In the dashboard, map public hostnames to:
   - `http://localhost:8080` (portal)
   - `http://localhost:8888` (jupyter)
   - `http://localhost:6006` (tensorboard)
   - `tcp://localhost:22`    (ssh — use `cloudflared access ssh` client-side)

### Option B — File-managed tunnel

1. `cloudflared tunnel login` on your workstation, then `cloudflared tunnel create aio-studio`.
2. Copy `~/.cloudflared/<uuid>.json` and a `config.yml` (see `tunnel.yml.example`) into a host dir.
3. Run with:

   ```powershell
   docker run --gpus all --rm `
     -v C:\path\to\cloudflared:/etc/cloudflared:ro `
     -e CF_TUNNEL_CONFIG=/etc/cloudflared/config.yml `
     dhi-aio-studio:latest
   ```

## Env vars (onstart.sh)

| Var | Default | Purpose |
|---|---|---|
| `JUPYTER_PORT` | `8888` | JupyterLab bind |
| `CADDY_PORT`   | `8080` | Portal bind |
| `SSH_PORT`     | `22`   | sshd bind |
| `TENSORBOARD_PORT` | `6006` | TensorBoard bind |
| `AITOOLKIT_PORT` | `8675` | ai-toolkit UI bind |
| `AITOOLKIT_HOME` | `/opt/ai-toolkit` | ai-toolkit install location (baked by Dockerfile) |
| `AI_TOOLKIT_AUTH` | *empty* | ai-toolkit UI password; empty disables auth |
| `JUPYTER_TOKEN` | *empty* | token for JupyterLab |
| `JUPYTER_PASSWORD` | *empty* | if set, replaces token with hashed password |
| `WORKSPACE` | `/workspace` | Jupyter root |
| `CF_TUNNEL_TOKEN` | *empty* | run tunnel with connector token |
| `CF_TUNNEL_CONFIG` | *empty* | run tunnel from config.yml path |
| `NOBBBY_AUTHORIZED_KEYS` | *empty* | newline-separated SSH pubkeys |
| `NOBBBY_PASSWORD` | *empty* | if set, enables SSH password auth for `nobbby` |

## Notes

- The `gwingz/dhi-*` images are distroless/non-root (uid 65532, no shell) — unsuitable as a dev-studio final base. We use `dhi-uv:0` only to copy the `uv` binary (reproducible, verified build), and match `dhi-nvidia-cuda:13`'s CUDA major on the Ubuntu NVIDIA image.
- PyTorch index tries cu130 first, falls back to cu128 if cu130 wheels aren't yet published for your platform.
- Portal is HTTP only inside the container; put TLS at the Cloudflare Tunnel edge.
