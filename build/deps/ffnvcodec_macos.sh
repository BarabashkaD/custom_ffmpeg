#!/usr/bin/env bash
# ffnvcodec on macOS: NVIDIA has no NVENC/NVDEC/CUDA driver for macOS and
# FFmpeg's configure disables ffnvcodec there — nothing to install.
set -euo pipefail
echo "=== ffnvcodec: not applicable on macOS, skipping ==="
