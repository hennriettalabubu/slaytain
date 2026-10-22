#Requires -Version 7
# Build dhi-aio-studio locally.
# Usage: .\build.ps1 [-Tag <name>] [-Push <registry/name:tag>]
[CmdletBinding()]
param(
    [string]$Tag = "dhi-aio-studio:latest",
    [string]$Push = ""
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $here
try {
    Write-Host "==> Building $Tag" -ForegroundColor Cyan
    docker build -t $Tag `
        --build-arg CUDA_BASE=nvidia/cuda:13.4.2-cudnn-devel-ubuntu24.04 `
        --build-arg UV_SOURCE=gwingz/dhi-uv:0 `
        --build-arg PY_VERSION=3.12 `
        .

    if ($Push) {
        Write-Host "==> Tagging and pushing to $Push" -ForegroundColor Cyan
        docker tag $Tag $Push
        docker push $Push
    }

    Write-Host "==> Done. See README.md for the run command (requires `$env:CF_TUNNEL_TOKEN, `$env:NOBBBY_PASSWORD, etc.)." -ForegroundColor Green
}
finally {
    Pop-Location
}
