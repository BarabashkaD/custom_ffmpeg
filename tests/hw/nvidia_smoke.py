#!/usr/bin/env python3
"""Hardware smoke test of FFmpeg's NVIDIA support (NVENC / NVDEC / CUVID / CUDA
filters) against a built FFmpeg — needs an NVIDIA GPU with its driver.

There are no upstream tests for nv-codec-headers (headers only), and CI
runners have no GPU: this script is run by hand on a machine with one. It
skips cleanly (exit 0) when the build has no NVENC or no CUDA device can be
opened.

  * encode a test pattern with h264_nvenc / hevc_nvenc, check with ffprobe
  * av1_nvenc: encodes on GPUs with AV1 NVENC (Ada and newer); on older ones
    it must fail with an error message, not crash
  * decode those files with -hwaccel cuda (NVDEC; frames must stay on the
    GPU — a silent fallback to software decoding fails the test) and with
    the h264_cuvid / hevc_cuvid decoders
  * scale_cuda (CUDA filter compiled to PTX by clang, --enable-cuda-llvm)

Usage:
  python tests/hw/nvidia_smoke.py <ffmpeg-root>   # dir with bin/ffmpeg, bin/ffprobe
Exit status: 0 when nothing failed (skips included).
"""
import os
import re
import subprocess
import sys
import tempfile
import time

EXE = ".exe" if os.name == "nt" else ""
FRAMES = 60
SRC = f"testsrc2=size=1280x720:rate=30:duration={FRAMES // 30}"


class Smoke:
    def __init__(self, root):
        self.ffmpeg = os.path.join(root, "bin", "ffmpeg" + EXE)
        self.ffprobe = os.path.join(root, "bin", "ffprobe" + EXE)
        self.tmp = tempfile.mkdtemp(prefix="nvidia-smoke-")
        self.failed = 0

    def run(self, args):
        proc = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              timeout=600)
        return proc.returncode, proc.stdout.decode("utf-8", "replace")

    def ff(self, *args):
        return self.run([self.ffmpeg, "-hide_banner", "-nostdin", "-y", *args])

    def path(self, name):
        return os.path.join(self.tmp, name)

    def report(self, status, name, seconds, detail=""):
        if status == "FAIL":
            self.failed += 1
        print(f"{status:5} {name:28} {seconds:6.1f}s  {detail}", flush=True)

    @staticmethod
    def crashed(code):
        # POSIX: killed by a signal (negative). Windows reports the exit code
        # unsigned: FFmpeg's negative AVERROR codes (e.g. 0xDFABA7BB, "Generic
        # error in an external library") are clean errors, while unhandled
        # exceptions end with an NTSTATUS 0xC0xxxxxx (0xC0000005 access
        # violation, 0xC0000409 stack buffer overrun) or 0x80000003.
        if os.name != "nt":
            return code < 0
        return (code & 0xFF000000) == 0xC0000000 or code == 0x80000003

    @staticmethod
    def last_error(out, tag=None):
        lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
        if tag:   # messages of the component itself, e.g. "[av1_nvenc @ 0x..] ..."
            own = [ln.split("] ", 1)[-1] for ln in lines if ln.startswith(f"[{tag} @")]
            if own:
                return "; ".join(own)
        return lines[-1] if lines else ""

    def probe(self, f):
        code, out = self.run([self.ffprobe, "-v", "error", "-count_frames", "-select_streams", "v:0",
                              "-show_entries", "stream=codec_name,width,height,nb_read_frames",
                              "-of", "default=noprint_wrappers=1", f])
        return dict(ln.split("=", 1) for ln in out.splitlines() if "=" in ln) if code == 0 else {}

    @staticmethod
    def frames(out):
        n = re.findall(r"frame=\s*(\d+)", out)
        return int(n[-1]) if n else 0

    # ── tests ──────────────────────────────────────────────────────────────
    def encode(self, encoder, codec, out_name, optional=False):
        t = time.time()
        f = self.path(out_name)
        code, out = self.ff("-f", "lavfi", "-i", SRC, "-c:v", encoder, f)
        dt = time.time() - t
        if code != 0:
            if self.crashed(code):
                self.report("FAIL", encoder, dt, f"crashed (exit {code:#x})")
            elif optional:
                self.report("SKIP", encoder, dt,
                            f"clean error, not supported by this GPU/driver: {self.last_error(out, encoder)}")
            else:
                self.report("FAIL", encoder, dt, self.last_error(out, encoder))
            return None
        p = self.probe(f)
        ok = p.get("codec_name") == codec and p.get("nb_read_frames") == str(FRAMES)
        self.report("PASS" if ok else "FAIL", encoder, dt,
                    f"{p.get('codec_name')} {p.get('width')}x{p.get('height')}, {p.get('nb_read_frames')} frames")
        return f if ok else None

    def decode(self, name, args):
        t = time.time()
        code, out = self.ff(*args, "-f", "null", "-")
        dt = time.time() - t
        n = self.frames(out)
        ok = code == 0 and n == FRAMES
        detail = f"{n} frames" if code == 0 else self.last_error(out)
        self.report("PASS" if ok else "FAIL", name, dt, detail)

    def cuda_filter(self, src):
        t = time.time()
        f = self.path("scaled.mp4")
        code, out = self.ff("-hwaccel", "cuda", "-hwaccel_output_format", "cuda", "-i", src,
                            "-vf", "scale_cuda=w=640:h=360", "-c:v", "h264_nvenc", f)
        dt = time.time() - t
        if code != 0:
            self.report("FAIL", "scale_cuda", dt, self.last_error(out))
            return
        p = self.probe(f)
        ok = (p.get("width"), p.get("height"), p.get("nb_read_frames")) == ("640", "360", str(FRAMES))
        self.report("PASS" if ok else "FAIL", "scale_cuda", dt,
                    f"{p.get('width')}x{p.get('height')}, {p.get('nb_read_frames')} frames")

    def main(self):
        if not os.path.isfile(self.ffmpeg) or not os.path.isfile(self.ffprobe):
            print(f"ERROR: {self.ffmpeg} / ffprobe not found", file=sys.stderr)
            return 2
        _, encoders = self.ff("-encoders")
        if "h264_nvenc" not in encoders:
            print("SKIP: this FFmpeg build has no NVENC")
            return 0
        code, out = self.ff("-init_hw_device", "cuda=gpu", "-f", "lavfi", "-i", "nullsrc=d=0.1",
                            "-f", "null", "-")
        if code != 0:
            print(f"SKIP: no usable NVIDIA GPU / driver ({self.last_error(out, 'CUDA')})")
            return 0

        h264 = self.encode("h264_nvenc", "h264", "h264.mp4")
        hevc = self.encode("hevc_nvenc", "hevc", "hevc.mp4")
        self.encode("av1_nvenc", "av1", "av1.mp4", optional=True)
        # NVDEC frames stay in GPU memory; hwdownload fails on software frames,
        # so a silent fallback to the software decoder does not pass
        for name, f in (("h264", h264), ("hevc", hevc)):
            if not f:
                self.report("SKIP", f"{name} decode", 0, "no input (encode failed)")
                continue
            self.decode(f"{name} -hwaccel cuda", ["-hwaccel", "cuda", "-hwaccel_output_format", "cuda",
                                                 "-i", f, "-vf", "hwdownload,format=nv12"])
            self.decode(f"{name}_cuvid", ["-c:v", f"{name}_cuvid", "-i", f])
        if h264:
            self.cuda_filter(h264)
        print(f"{'FAILED' if self.failed else 'OK'} (files in {self.tmp})")
        return 1 if self.failed else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(Smoke(sys.argv[1]).main())
