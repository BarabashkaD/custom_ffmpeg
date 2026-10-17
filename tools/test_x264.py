#!/usr/bin/env python3
"""
x264 smoke-test: download test clips, encode with multiple configs,
verify output file is created and non-empty (exit-code + file-size check only).

Usage:
    python tools/test_x264.py
    python tools/test_x264.py --x264 path/to/x264.exe --clips 3 --outdir tmp/test
    python tools/test_x264.py --list-configs
    python tools/test_x264.py --configs ultrafast,slow

Default x264 path: prebuilt/.deps/windows-x64/bin/x264.exe  (relative to repo root)
Clips are downloaded once into --clips-dir and reused.
"""

import argparse
import hashlib
import os
import subprocess
import sys
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# Test matrix
# ---------------------------------------------------------------------------

CLIP_CATALOG = [
    {
        "name": "akiyo_qcif",
        "url": "https://media.xiph.org/video/derf/y4m/akiyo_qcif.y4m",
        "desc": "176x144 QCIF, low-motion talking head",
    },
    {
        "name": "foreman_qcif",
        "url": "https://media.xiph.org/video/derf/y4m/foreman_qcif.y4m",
        "desc": "176x144 QCIF, moderate motion",
    },
    {
        "name": "bus_cif",
        "url": "https://media.xiph.org/video/derf/y4m/bus_cif.y4m",
        "desc": "352x288 CIF, high motion bus scene",
    },
    {
        "name": "mobile_cif",
        "url": "https://media.xiph.org/video/derf/y4m/mobile_cif.y4m",
        "desc": "352x288 CIF, complex motion / colorful",
    },
]

CONFIG_CATALOG = {
    "ultrafast": ["--preset", "ultrafast", "--crf", "28"],
    "fast":      ["--preset", "fast",      "--crf", "23"],
    "slow":      ["--preset", "slow",      "--crf", "23"],
    "veryslow":  ["--preset", "veryslow",  "--crf", "18"],
    "zerolatency": ["--preset", "ultrafast", "--tune", "zerolatency", "--crf", "28"],
    "hq":        ["--preset", "slow", "--tune", "film", "--crf", "18"],
}

DEFAULT_CLIPS   = 2   # how many clips from CLIP_CATALOG to use
DEFAULT_CONFIGS = ["ultrafast", "slow"]


# ---------------------------------------------------------------------------
# Data types
# ---------------------------------------------------------------------------

@dataclass
class TestResult:
    clip:    str
    config:  str
    passed:  bool
    message: str = ""
    out_bytes: int = 0


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def download_clip(url: str, dest: Path) -> None:
    if dest.exists():
        print(f"  [cache] {dest.name}")
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    print(f"  [download] {dest.name} ...", end="", flush=True)
    try:
        urllib.request.urlretrieve(url, dest)
        size_mb = dest.stat().st_size / 1024 / 1024
        print(f" {size_mb:.1f} MB")
    except Exception as exc:
        dest.unlink(missing_ok=True)
        raise RuntimeError(f"Failed to download {url}: {exc}") from exc


def run_x264(x264: Path, clip: Path, out: Path, extra_args: list[str],
             timeout: int = 120) -> tuple[int, str]:
    cmd = [str(x264), "-o", str(out)] + extra_args + [str(clip)]
    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
        )
        return proc.returncode, proc.stdout.decode(errors="replace")
    except subprocess.TimeoutExpired:
        return -1, f"Timed out after {timeout}s"
    except FileNotFoundError:
        return -1, f"x264 executable not found: {x264}"


# ---------------------------------------------------------------------------
# Core logic
# ---------------------------------------------------------------------------

def run_tests(
    x264: Path,
    clips: list[dict],
    configs: dict[str, list[str]],
    clips_dir: Path,
    out_dir: Path,
) -> list[TestResult]:
    out_dir.mkdir(parents=True, exist_ok=True)
    results: list[TestResult] = []

    # Download clips
    print("\n=== Downloading clips ===")
    clip_paths: list[tuple[dict, Path]] = []
    for clip in clips:
        dest = clips_dir / (clip["name"] + ".y4m")
        try:
            download_clip(clip["url"], dest)
            clip_paths.append((clip, dest))
        except RuntimeError as e:
            print(f"  [SKIP] {clip['name']}: {e}")

    if not clip_paths:
        print("No clips available, aborting.")
        return results

    # Run encode matrix
    print(f"\n=== Encoding: {len(clip_paths)} clip(s) × {len(configs)} config(s) ===\n")

    col_w = 14
    header = f"{'clip':<20}" + "".join(f"{c:>{col_w}}" for c in configs)
    print(header)
    print("-" * len(header))

    for clip_info, clip_path in clip_paths:
        row = f"{clip_info['name']:<20}"
        for cfg_name, cfg_args in configs.items():
            out_file = out_dir / f"{clip_info['name']}__{cfg_name}.h264"
            rc, output = run_x264(x264, clip_path, out_file, cfg_args)

            if rc != 0:
                result = TestResult(clip_info["name"], cfg_name, False,
                                    f"exit {rc}: {output[-200:].strip()}")
            elif not out_file.exists() or out_file.stat().st_size == 0:
                result = TestResult(clip_info["name"], cfg_name, False,
                                    "output file missing or empty")
            else:
                size_kb = out_file.stat().st_size // 1024
                result = TestResult(clip_info["name"], cfg_name, True,
                                    out_bytes=out_file.stat().st_size)
                cell = f"{size_kb} KB"
                row += f"{cell:>{col_w}}"
                results.append(result)
                continue

            row += f"{'FAIL':>{col_w}}"
            results.append(result)

        print(row)

    return results


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--x264", type=Path,
                   default=repo_root() / "prebuilt" / ".deps" / "windows-x64" / "bin" / "x264.exe",
                   help="path to x264 executable")
    p.add_argument("--clips", type=int, default=DEFAULT_CLIPS,
                   help=f"number of clips to use from catalog (default: {DEFAULT_CLIPS}, max: {len(CLIP_CATALOG)})")
    p.add_argument("--configs", type=str, default=",".join(DEFAULT_CONFIGS),
                   help=f"comma-separated list of configs (default: {','.join(DEFAULT_CONFIGS)})")
    p.add_argument("--clips-dir", type=Path,
                   default=repo_root() / "tmp" / "test-clips",
                   help="directory for cached test clips")
    p.add_argument("--outdir", type=Path,
                   default=repo_root() / "tmp" / "test-output",
                   help="directory for encoded output files")
    p.add_argument("--list-configs", action="store_true",
                   help="print available configs and exit")
    p.add_argument("--list-clips", action="store_true",
                   help="print available clips and exit")
    return p


def main() -> int:
    args = build_parser().parse_args()

    if args.list_configs:
        print("Available configs:")
        for name, flags in CONFIG_CATALOG.items():
            print(f"  {name:<14} {' '.join(flags)}")
        return 0

    if args.list_clips:
        print("Available clips:")
        for i, c in enumerate(CLIP_CATALOG):
            print(f"  [{i}] {c['name']:<20} {c['desc']}")
        return 0

    # Resolve x264
    x264 = args.x264.resolve()
    if not x264.exists():
        print(f"ERROR: x264 not found at {x264}", file=sys.stderr)
        return 1
    print(f"x264:    {x264}")

    # Resolve clips
    n_clips = min(args.clips, len(CLIP_CATALOG))
    clips = CLIP_CATALOG[:n_clips]

    # Resolve configs
    requested = [c.strip() for c in args.configs.split(",")]
    unknown = [c for c in requested if c not in CONFIG_CATALOG]
    if unknown:
        print(f"ERROR: unknown config(s): {unknown}  (use --list-configs)", file=sys.stderr)
        return 1
    configs = {name: CONFIG_CATALOG[name] for name in requested}

    print(f"clips:   {[c['name'] for c in clips]}")
    print(f"configs: {list(configs.keys())}")

    results = run_tests(x264, clips, configs, args.clips_dir, args.outdir)

    # Summary
    failed = [r for r in results if not r.passed]
    print(f"\n=== Result: {len(results) - len(failed)}/{len(results)} passed ===")
    for f in failed:
        print(f"  FAIL  {f.clip} / {f.config}: {f.message}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
