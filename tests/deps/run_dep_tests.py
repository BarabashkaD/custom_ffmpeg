#!/usr/bin/env python3
"""Run the test programs and command line tools of the codec dependencies.

Every dependency is tested with its own means only (FFmpeg has FATE):

  * test programs from <deps-dir>/tests/<dep>/ described by tests.tsv
    (name, program, args, env, kind) — installed by build/deps/*.sh;
    libvpl: vpl-tests (dispatcher unit tests) with the stub runtimes next to it
  * round trips through the dependency's own command line tools in
    <deps-dir>/bin (x264, x265, vpxenc/vpxdec, cwebp/dwebp/webpinfo/webpmux,
    lame, opus_demo/opus_compare, zlib's minigzip, SvtAv1EncApp, dav1d)
  * AMF (headers only, no tools/tests upstream): version and header set check
  * libdrm (Linux): upstream's meson tests (hash, drmsl, drmdevice) from the
    manifest; libva (Linux): libva-utils' vainfo and test_va_api — they need
    a DRM device + VA driver and are skipped without one
  * official test vectors when a test data root is given (--data or
    CUSTOM_FFMPEG_TEST_DATA): <data>/libvpx for test_libvpx, <data>/opus for
    the Opus RFC 8251 vectors, <data>/dav1d for dav1d-test-data (its meson
    test definitions, see meson_tests.py), <data>/svtav1 for SvtAv1E2ETests'
    clips; without data those tests are skipped

Usage:
  python tests/deps/run_dep_tests.py prebuilt/.deps/<platform> [--data DIR]
         [--only dep,dep] [--jobs N] [--log FILE]
Exit status: 0 when nothing failed.
"""
import argparse
import os
import platform
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
import zlib

EXE = ".exe" if os.name == "nt" else ""
MISSING_DATA_MARKERS = ("file open failed", "Filename:")
# A plain test program exiting with 77 skipped itself (automake / meson test
# convention, e.g. libdrm's drmdevice without any DRM device)
SKIP_EXIT_CODE = 77


def available_ram_gb():
    """Memory available to new processes right now, in GB (0 if unknown).
    Memory-heavy tests are gated on this, not on the installed total: other
    processes (e.g. a Docker / WSL VM) may hold a large part of it."""
    try:
        if sys.platform.startswith("linux"):
            with open("/proc/meminfo") as f:
                for line in f:
                    if line.startswith("MemAvailable:"):
                        return int(line.split()[1]) / 1024 / 1024
        elif sys.platform == "darwin":
            # free + inactive + speculative pages (what vm_stat reports as reclaimable)
            out = subprocess.run(["vm_stat"], stdout=subprocess.PIPE).stdout.decode()
            page = int(out.split("page size of ")[1].split()[0])
            pages = 0
            for line in out.splitlines():
                if line.startswith(("Pages free", "Pages inactive", "Pages speculative")):
                    pages += int(line.split(":")[1].strip().rstrip("."))
            return pages * page / 1024 ** 3
        elif os.name == "nt":
            import ctypes

            class MEMORYSTATUSEX(ctypes.Structure):
                _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong),
                            ("ullTotalPhys", ctypes.c_ulonglong), ("ullAvailPhys", ctypes.c_ulonglong),
                            ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                            ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong),
                            ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]
            st = MEMORYSTATUSEX()
            st.dwLength = ctypes.sizeof(st)
            ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st))
            return st.ullAvailPhys / 1024 ** 3
    except Exception:       # noqa: BLE001 — unknown memory: treat as 0
        pass
    return 0


class Runner:
    def __init__(self, deps_dir, data, jobs, log):
        self.deps = os.path.abspath(deps_dir)
        self.bin = os.path.join(self.deps, "bin")
        self.data = os.path.abspath(data) if data else None
        self.jobs = jobs
        self.log = log
        self.results = []          # (dep, name, status, seconds, detail)
        self.scratch = tempfile.mkdtemp(prefix="dep-tests-")

    # ── helpers ────────────────────────────────────────────────────────────
    def say(self, text):
        print(text, flush=True)
        if self.log:
            self.log.write(text + "\n")
            self.log.flush()

    def record(self, dep, name, status, seconds, detail=""):
        self.results.append((dep, name, status, seconds, detail))
        line = f"{status:5} {dep:10} {name:32} {seconds:7.1f}s"
        self.say(line + (f"  {detail}" if detail else ""))

    def tool(self, name):
        path = os.path.join(self.bin, name + EXE)
        return path if os.path.isfile(path) else None

    def tmpdir(self, tag):
        d = tempfile.mkdtemp(prefix=tag + "-", dir=self.scratch)
        return d

    def run(self, cmd, cwd=None, env=None, timeout=1800):
        proc = subprocess.run(cmd, cwd=cwd, env=env, timeout=timeout,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        out = proc.stdout.decode("utf-8", "replace")
        if self.log:
            self.log.write(f"$ {' '.join(cmd)}\n{out}\n")
        return proc.returncode, out

    def subst(self, text, tmp, test_dir=""):
        return (text.replace("{tmp}", tmp).replace("{dir}", test_dir)
                .replace("{data}", self.data or ""))

    # ── test programs from tests.tsv ───────────────────────────────────────
    def run_manifests(self, only):
        root = os.path.join(self.deps, "tests")
        if not os.path.isdir(root):
            self.say(f"(no test programs in {root})")
            return
        for dep in sorted(os.listdir(root)):
            if only and dep not in only:
                continue
            manifest = os.path.join(root, dep, "tests.tsv")
            if not os.path.isfile(manifest):
                continue
            with open(manifest, encoding="utf-8") as f:
                rows = [line.rstrip("\n").split("\t") for line in f if line.strip()]
            for row in rows:
                row += [""] * (6 - len(row))
                name, program, args, env_spec, kind, opts = row[:6]
                self.run_manifest_test(dep, os.path.join(root, dep), name, program,
                                       args, env_spec, kind or "plain", opts)

    def run_manifest_test(self, dep, test_dir, name, program, args, env_spec, kind, opts=""):
        exe = os.path.join(test_dir, program + EXE)
        if not os.path.isfile(exe):
            self.record(dep, name, "FAIL", 0, f"missing {program}{EXE}")
            return
        needs_data = "{data}" in args or "{data}" in env_spec
        if needs_data and not self.data and kind != "gtest":
            self.record(dep, name, "SKIP", 0, "needs test data (--data)")
            return
        tmp = self.tmpdir(f"{dep}-{name}")
        env = dict(os.environ)
        for item in filter(None, env_spec.split(";")):
            k, _, v = item.partition("=")
            # gtest without data: point data paths at an empty dir, data tests
            # are skipped; {dir} = the test program's directory
            env[k] = self.subst(v, tmp, test_dir) if self.data or "{data}" not in v else tmp
        argv = [exe] + [self.subst(a, tmp, test_dir) for a in args.split()]
        start = time.time()
        if kind == "gtest":
            status, detail = self.run_gtest(argv, tmp, env, opts)
        else:
            code, out = self.run(argv, cwd=tmp, env=env)
            status = "PASS" if code == 0 else "FAIL"
            detail = "" if code == 0 else f"exit {code}: {out.strip().splitlines()[-1:] }"
            if code == SKIP_EXIT_CODE:      # automake/meson convention
                status = "SKIP"
        self.record(dep, name, status, time.time() - start, detail)

    def run_gtest(self, argv, tmp, env, opts=""):
        """Googletest run: parallel shards, then memory-heavy tests one at a time.
        Failures caused by missing test data count as skipped (no --data)."""
        serial, mem_skipped, excluded = [], [], []     # serial: (pattern, GB needed)
        markers = list(MISSING_DATA_MARKERS)
        shard_gb = 0.0
        ram = available_ram_gb()
        for item in filter(None, opts.split(";")):
            key, _, patterns = item.partition("=")
            pats = [p for p in patterns.split(":") if p]
            if key == "missing_data":
                markers += [m for m in patterns.split("|") if m]
            elif key == "serial":
                serial += [(p, 0.0) for p in pats]
            elif key == "exclude":
                excluded += pats
            elif key == "shard_mem_gb":
                shard_gb = float(patterns)
            elif key.startswith("needs_mem_gb."):
                serial += [(p, float(key.split(".", 1)[1])) for p in pats]
        heavy = [p for p, _ in serial] + excluded

        runs = []       # (process, xml, log handle)
        # parallel shards limited by the available memory (shard_mem_gb each)
        shards = max(1, self.jobs)
        if shard_gb > 0 and ram > 0:
            shards = max(1, min(shards, int(ram // shard_gb)))
        self.say(f"      {shards} shard(s), {ram:.1f} GB available")
        neg = (":-" + ":".join(heavy)) if heavy else ""
        for i in range(shards):
            e = dict(env, GTEST_TOTAL_SHARDS=str(shards), GTEST_SHARD_INDEX=str(i))
            xml = os.path.join(tmp, f"shard{i}.xml")
            out = open(os.path.join(tmp, f"shard{i}.log"), "wb")
            runs.append((subprocess.Popen(argv + [f"--gtest_filter=*{neg}", f"--gtest_output=xml:{xml}"],
                                          cwd=tmp, env=e, stdout=out, stderr=subprocess.STDOUT), xml, out))
        for p, _, out in runs:
            p.wait()
            out.close()
        for k, (pat, need_gb) in enumerate(serial):
            # memory is checked right before the test, not at start: the shards
            # and other processes on the machine change what is available
            if need_gb:
                now = available_ram_gb()
                if now < need_gb:
                    mem_skipped.append(f"{pat} (needs {need_gb:g} GB, {now:.1f} available)")
                    continue
            xml = os.path.join(tmp, f"serial{k}.xml")
            with open(os.path.join(tmp, f"serial{k}.log"), "wb") as out:
                p = subprocess.Popen(argv + [f"--gtest_filter={pat}", f"--gtest_output=xml:{xml}"],
                                     cwd=tmp, env=env, stdout=out, stderr=subprocess.STDOUT)
                p.wait()
            runs.append((p, xml, None))

        passed = failed = skipped = disabled = 0
        failures, failure_msgs = [], []
        for p, xml, _ in runs:
            if not os.path.isfile(xml):
                return "FAIL", f"crashed (exit {p.returncode}), see {tmp}"
            for case in ET.parse(xml).getroot().iter("testcase"):
                # DISABLED_ tests are listed with status="notrun" (result
                # "suppressed"): never executed, so not counted as passed
                if case.get("status") == "notrun":
                    disabled += 1
                    continue
                if case.get("result") == "skipped" or case.find("skipped") is not None:
                    skipped += 1
                    continue
                msgs = [f.get("message", "") + (f.text or "") for f in case.findall("failure")]
                if not msgs:
                    passed += 1
                # Without data a test that could not open its input also fails
                # follow-up assertions (md5 mismatch, ...): the missing file is
                # the cause, so one missing-data message marks the whole test
                elif not self.data and any(m in msg for msg in msgs for m in markers):
                    skipped += 1
                else:
                    failed += 1
                    failures.append(f"{case.get('classname')}.{case.get('name')}")
                    failure_msgs.append((failures[-1], "\n".join(msgs)))
        # the assertion text of the first failures (the shard logs stay in tmp)
        for name, msg in failure_msgs[:3]:
            self.say(f"      {name}:")
            for line in msg.strip().splitlines()[:8]:
                self.say(f"        {line}")
        detail = f"{passed} passed, {skipped} skipped, {failed} failed"
        if disabled:
            detail += f", {disabled} disabled upstream (DISABLED_)"
        if mem_skipped:
            detail += "; not run (not enough free memory): " + ", ".join(mem_skipped)
        if excluded:
            detail += "; excluded (fail upstream too): " + ", ".join(excluded)
        if failures:
            detail += " — " + ", ".join(failures[:5]) + (" …" if len(failures) > 5 else "")
        return ("PASS" if failed == 0 else "FAIL"), detail

    # ── generated inputs ───────────────────────────────────────────────────
    def make_y4m(self, path, w=352, h=288, frames=30):
        with open(path, "wb") as f:
            f.write(f"YUV4MPEG2 W{w} H{h} F30:1 Ip A1:1 C420jpeg\n".encode())
            for n in range(frames):
                f.write(b"FRAME\n")
                f.write(bytes(((x + y + 4 * n) & 0xFF) for y in range(h) for x in range(w)))
                f.write(bytes(((x * 2 + n) & 0xFF) for y in range(h // 2) for x in range(w // 2)))
                f.write(bytes(((y * 2 + n) & 0xFF) for y in range(h // 2) for x in range(w // 2)))
        return w, h, frames

    def make_pcm(self, rate=48000, channels=2, seconds=2):
        import math
        n = rate * seconds
        samples = []
        for i in range(n):
            v = int(12000 * math.sin(2 * math.pi * 440 * i / rate))
            samples += [v] * channels
        return struct.pack(f"<{len(samples)}h", *samples)

    def make_wav(self, path, rate=44100, channels=2, seconds=2):
        pcm = self.make_pcm(rate, channels, seconds)
        with open(path, "wb") as f:
            f.write(b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVE")
            f.write(b"fmt " + struct.pack("<IHHIIHH", 16, 1, channels, rate,
                                          rate * channels * 2, channels * 2, 16))
            f.write(b"data" + struct.pack("<I", len(pcm)) + pcm)

    def make_ppm(self, path, w=320, h=240):
        with open(path, "wb") as f:
            f.write(f"P6\n{w} {h}\n255\n".encode())
            f.write(bytes(c for y in range(h) for x in range(w)
                          for c in (x & 0xFF, y & 0xFF, (x ^ y) & 0xFF)))
        return w, h

    def make_bmp(self, path, w=320, h=240):
        """The make_ppm picture as a 24-bit BMP (bottom-up rows, BGR)."""
        stride = (w * 3 + 3) & ~3
        rows = []
        for y in reversed(range(h)):
            row = bytes(c for x in range(w) for c in ((x ^ y) & 0xFF, y & 0xFF, x & 0xFF))
            rows.append(row + b"\0" * (stride - w * 3))
        pixels = b"".join(rows)
        with open(path, "wb") as f:
            f.write(b"BM" + struct.pack("<IHHI", 54 + len(pixels), 0, 0, 54))
            f.write(struct.pack("<IiiHHIIiiII", 40, w, h, 1, 24, 0, len(pixels), 2835, 2835, 0, 0))
            f.write(pixels)
        return w, h

    # ── command line tool round trips ──────────────────────────────────────
    def cli(self, dep, name, func):
        tmp = self.tmpdir(f"{dep}-{name}")
        start = time.time()
        try:
            detail = func(tmp)
            self.record(dep, name, "PASS", time.time() - start, detail or "")
        except Exception as e:      # noqa: BLE001 — report any failure
            self.record(dep, name, "FAIL", time.time() - start, str(e))

    def check(self, cond, msg):
        if not cond:
            raise RuntimeError(msg)

    def run_ok(self, cmd, cwd):
        code, out = self.run(cmd, cwd=cwd)
        self.check(code == 0, f"{os.path.basename(cmd[0])} exit {code}: "
                              f"{out.strip().splitlines()[-1:] }")
        return out

    def run_cli_tests(self, only):
        def want(dep):
            return not only or dep in only

        if want("x264") and self.tool("x264"):
            def x264(tmp):
                self.make_y4m(os.path.join(tmp, "in.y4m"))
                for preset in ("ultrafast", "medium"):
                    out = self.run_ok([self.tool("x264"), "--preset", preset, "-o",
                                       f"out-{preset}.264", "in.y4m"], tmp)
                    self.check("encoded 30 frames" in out, f"{preset}: frame count")
                    self.check(os.path.getsize(os.path.join(tmp, f"out-{preset}.264")) > 0, "empty")
                return "y4m -> H.264 (ultrafast, medium)"
            self.cli("x264", "cli-encode", x264)

        if want("x265") and self.tool("x265"):
            def x265(tmp):
                self.make_y4m(os.path.join(tmp, "in.y4m"))
                out = self.run_ok([self.tool("x265"), "--preset", "ultrafast", "--input",
                                   "in.y4m", "--output", "out.hevc"], tmp)
                self.check("encoded 30 frames" in out, "frame count")
                self.check(os.path.getsize(os.path.join(tmp, "out.hevc")) > 0, "empty")
                return "y4m -> HEVC"
            self.cli("x265", "cli-encode", x265)

        if want("libvpx") and self.tool("vpxenc") and self.tool("vpxdec"):
            def vpx(tmp):
                w, h, frames = self.make_y4m(os.path.join(tmp, "in.y4m"))
                for codec in ("vp8", "vp9"):
                    self.run_ok([self.tool("vpxenc"), f"--codec={codec}", "--good", "--cpu-used=8",
                                 "--limit=30", "-o", f"{codec}.webm", "in.y4m"], tmp)
                    self.run_ok([self.tool("vpxdec"), "--i420", "-o", f"{codec}.yuv",
                                 f"{codec}.webm"], tmp)
                    size = os.path.getsize(os.path.join(tmp, f"{codec}.yuv"))
                    self.check(size == frames * w * h * 3 // 2, f"{codec}: decoded size {size}")
                return "y4m -> VP8/VP9 webm -> yuv"
            self.cli("libvpx", "cli-roundtrip", vpx)

        if want("svtav1") and self.tool("SvtAv1EncApp"):
            def svtav1(tmp):
                w, h, frames = self.make_y4m(os.path.join(tmp, "in.y4m"))
                for preset in ("12", "8"):
                    ivf = f"p{preset}.ivf"
                    self.run_ok([self.tool("SvtAv1EncApp"), "--preset", preset, "-i", "in.y4m",
                                 "-b", ivf, "--progress", "0"], tmp)
                    # IVF: 32-byte header (DKIF, fourcc AV01, size), then per
                    # temporal unit a 12-byte header (size, pts) + payload
                    with open(os.path.join(tmp, ivf), "rb") as f:
                        data = f.read()
                    self.check(data[:4] == b"DKIF" and data[8:12] == b"AV01", f"p{preset}: not AV1 IVF")
                    self.check(struct.unpack("<HH", data[12:16]) == (w, h), f"p{preset}: frame size")
                    pos, units = struct.unpack("<H", data[6:8])[0], 0
                    while pos + 12 <= len(data):
                        pos += 12 + struct.unpack("<I", data[pos:pos + 4])[0]
                        units += 1
                    self.check(pos == len(data) and units == frames,
                               f"p{preset}: {units} temporal units, expected {frames}")
                # No SVT decoder: decode with dav1d when its CLI is present too
                if self.tool("dav1d"):
                    self.run_ok([self.tool("dav1d"), "-q", "-i", "p8.ivf", "-o", "p8.yuv"], tmp)
                    size = os.path.getsize(os.path.join(tmp, "p8.yuv"))
                    self.check(size == frames * w * h * 3 // 2, f"dav1d: decoded size {size}")
                    return "y4m -> AV1 ivf (preset 12, 8) -> yuv (dav1d)"
                return "y4m -> AV1 ivf (preset 12, 8)"
            self.cli("svtav1", "cli-encode", svtav1)

        if want("libwebp") and self.tool("cwebp") and self.tool("dwebp"):
            def webp(tmp):
                w, h = self.make_ppm(os.path.join(tmp, "in.ppm"))
                # cwebp on Windows reads its input through WIC (falling back
                # to WebP only), which has no PPM codec: feed it a BMP there
                src = "in.ppm"
                if EXE:
                    self.make_bmp(os.path.join(tmp, "in.bmp"))
                    src = "in.bmp"
                for mode in (["-q", "80"], ["-lossless"]):
                    self.run_ok([self.tool("cwebp")] + mode + [src, "-o", "out.webp"], tmp)
                    self.run_ok([self.tool("dwebp"), "out.webp", "-ppm", "-o", "back.ppm"], tmp)
                    with open(os.path.join(tmp, "back.ppm"), "rb") as f:
                        header = f.read(20).split()
                    self.check(header[1:3] == [str(w).encode(), str(h).encode()], "size")
                    if mode == ["-lossless"]:
                        self.check(open(os.path.join(tmp, "back.ppm"), "rb").read()
                                   == open(os.path.join(tmp, "in.ppm"), "rb").read(),
                                   "lossless round trip differs")
                if self.tool("webpinfo"):
                    self.run_ok([self.tool("webpinfo"), "out.webp"], tmp)
                if self.tool("webpmux"):
                    self.run_ok([self.tool("webpmux"), "-info", "out.webp"], tmp)
                return f"{src[3:]} -> webp (lossy, lossless) -> ppm"
            self.cli("libwebp", "cli-roundtrip", webp)

        if want("mp3lame") and self.tool("lame"):
            def lame(tmp):
                self.make_wav(os.path.join(tmp, "in.wav"))
                self.run_ok([self.tool("lame"), "--quiet", "-b", "192", "in.wav", "out.mp3"], tmp)
                self.run_ok([self.tool("lame"), "--quiet", "--decode", "out.mp3", "back.wav"], tmp)
                with open(os.path.join(tmp, "back.wav"), "rb") as f:
                    hdr = f.read(44)
                channels, rate = struct.unpack("<HI", hdr[22:28])
                self.check((channels, rate) == (2, 44100), f"format {channels}ch {rate}Hz")
                secs = (os.path.getsize(os.path.join(tmp, "back.wav")) - 44) / (rate * 4)
                self.check(1.9 < secs < 2.2, f"duration {secs:.2f}s")
                return "wav -> mp3 -> wav"
            self.cli("mp3lame", "cli-roundtrip", lame)

        if want("opus") and self.tool("opus_demo"):
            def opus(tmp):
                pcm = self.make_pcm(48000, 2, 2)
                with open(os.path.join(tmp, "in.raw"), "wb") as f:
                    f.write(pcm)
                self.run_ok([self.tool("opus_demo"), "-e", "audio", "48000", "2", "64000",
                             "in.raw", "out.bit"], tmp)
                self.run_ok([self.tool("opus_demo"), "-d", "48000", "2", "out.bit", "back.raw"], tmp)
                size = os.path.getsize(os.path.join(tmp, "back.raw"))
                self.check(abs(size - len(pcm)) <= 48000 * 4 // 10, f"decoded size {size}")
                return "pcm -> opus -> pcm"
            self.cli("opus", "cli-roundtrip", opus)

        if want("dav1d") and self.tool("dav1d"):
            # AV1 sample present in both the FATE suite and dav1d-test-data;
            # expected decode md5 from dav1d-test-data 8-bit/features/meson.build
            sample = ("non_uniform_tiling.ivf", "e82617e3d4e694a5598447606c0fcda7",
                      "43d8ce1effb7fc38d3503d3d0f515dcb")
            found = [p for p in (os.path.join(self.data, "fate-suite", "av1", sample[0]),
                                 os.path.join(self.data, "dav1d", "8-bit", "features", sample[0]))
                     if os.path.isfile(p)] if self.data else []
            if not found:
                self.record("dav1d", "cli-decode", "SKIP", 0, "needs <data>/fate-suite or <data>/dav1d")
            else:
                def dav1d(tmp):
                    import hashlib
                    exe, src = self.tool("dav1d"), found[0]
                    self.check(hashlib.md5(open(src, "rb").read()).hexdigest() == sample[1],
                               f"unexpected sample {src}")
                    version = self.run_ok([exe, "--version"], tmp).strip()
                    # the same decode through the md5, yuv and y4m muxers
                    self.run_ok([exe, "-q", "-i", src, "--muxer", "md5", "-o", "out.md5"], tmp)
                    self.run_ok([exe, "-q", "-i", src, "-o", "out.yuv"], tmp)
                    self.run_ok([exe, "-q", "-i", src, "-o", "out.y4m"], tmp)
                    md5 = open(os.path.join(tmp, "out.md5")).read().strip()
                    self.check(md5 == sample[2], f"md5 muxer {md5}, expected {sample[2]}")
                    yuv = open(os.path.join(tmp, "out.yuv"), "rb").read()
                    self.check(hashlib.md5(yuv).hexdigest() == md5, "yuv output differs from md5")
                    y4m = open(os.path.join(tmp, "out.y4m"), "rb").read()
                    header, _, body = y4m.partition(b"\n")
                    tags = dict((t[:1], t[1:]) for t in header.split()[1:])
                    w, h = int(tags[b"W"]), int(tags[b"H"])
                    frames = body.split(b"FRAME\n")[1:]
                    self.check(frames and all(len(f) == w * h * 3 // 2 for f in frames),
                               f"y4m {w}x{h}: frame sizes")
                    self.check(b"".join(frames) == yuv, "y4m frames differ from yuv")
                    self.run_ok([exe, "-q", "-i", src, "--limit", "2", "-o", "two.yuv"], tmp)
                    self.check(os.path.getsize(os.path.join(tmp, "two.yuv")) == 2 * w * h * 3 // 2,
                               "--limit 2")
                    return f"dav1d {version}: {len(frames)} frames {w}x{h}, md5/yuv/y4m agree"
                self.cli("dav1d", "cli-decode", dav1d)

        if want("zlib"):
            mg = os.path.join(self.deps, "tests", "zlib", "static_minigzip" + EXE)
            if os.path.isfile(mg):
                def minigzip(tmp):
                    data = os.urandom(1 << 16) + bytes(1 << 18)
                    with open(os.path.join(tmp, "f.bin"), "wb") as f:
                        f.write(data)
                    self.run_ok([mg, "f.bin"], tmp)                 # -> f.bin.gz
                    gz = os.path.join(tmp, "f.bin.gz")
                    self.check(os.path.isfile(gz), "no .gz written")
                    self.check(zlib.decompress(open(gz, "rb").read(), 47) == data,
                               "python cannot read it back")
                    self.run_ok([mg, "-d", "f.bin.gz"], tmp)
                    self.check(open(os.path.join(tmp, "f.bin"), "rb").read() == data, "differs")
                    return "minigzip compress/decompress"
                self.cli("zlib", "minigzip", minigzip)

        # AMF: headers only (no library, no tools, no upstream tests) — check
        # the installed set against what FFmpeg n8.1.3 needs (configure wants
        # >= 1.4.36; vsrc_amf.c compiles only with the C-safe headers of 1.5.0+)
        amf_version_h = os.path.join(self.deps, "include", "AMF", "core", "Version.h")
        if want("amf") and os.path.isfile(amf_version_h):
            def amf_headers(tmp):
                v = {}
                for line in open(amf_version_h, encoding="utf-8", errors="replace"):
                    parts = line.split()
                    if len(parts) >= 3 and parts[0] == "#define" and parts[1].startswith("AMF_VERSION_"):
                        v[parts[1][12:]] = int(parts[2]) if parts[2].isdigit() else parts[2]
                full = tuple(v.get(k, 0) for k in ("MAJOR", "MINOR", "RELEASE", "BUILD_NUM"))
                self.check(full >= (1, 5, 0, 0), f"AMF {full} older than 1.5.0")
                inc = os.path.join(self.deps, "include", "AMF")
                for h in ("core/Factory.h", "core/Surface.h", "core/Trace.h", "core/VulkanAMF.h",
                          "components/VideoEncoderVCE.h", "components/VideoEncoderHEVC.h",
                          "components/VideoEncoderAV1.h", "components/VideoDecoderUVD.h",
                          "components/VideoConverter.h", "components/HQScaler.h",
                          "components/DisplayCapture.h"):
                    self.check(os.path.isfile(os.path.join(inc, *h.split("/"))), f"missing AMF/{h}")
                return "AMF headers " + ".".join(map(str, full))
            self.cli("amf", "headers", amf_headers)

        # libva (Linux): vainfo and the VA-API conformance tests (test_va_api)
        # from libva-utils, linked against the static libva. Both need a DRM
        # device and a VA driver from the system (selected by the kernel
        # driver, or LIBVA_DRIVER_NAME / LIBVA_DRIVERS_PATH as with any libva);
        # without them they are skipped. Even then vainfo checks that libva
        # starts and searches the driver in a system directory (the search
        # path compiled into libva), not in a build-machine path.
        if want("libva") and self.tool("vainfo"):
            self.run_libva(os.path.join(self.deps, "tests", "libva", "test_va_api" + EXE))

    def run_libva(self, test_va_api):
        import glob
        import re
        # the driver directories libva searches by default (build/deps/libva.sh)
        system_dirs = ("/usr/lib/", "/usr/lib64/")
        nodes = sorted(glob.glob("/dev/dri/renderD*")) + sorted(glob.glob("/dev/dri/card*"))
        usable = [n for n in nodes if os.access(n, os.R_OK | os.W_OK)]
        tmp = self.tmpdir("libva-vainfo")
        start = time.time()
        if not usable:
            why = ("no DRM device (/dev/dri)" if not nodes else
                   f"no access to {', '.join(nodes)} (user not in the render/video group)")
            self.record("libva", "vainfo", "SKIP", 0, why)
            self.record("libva", "test_va_api", "SKIP", 0, why)
            return
        nodes = usable
        code, out = self.run([self.tool("vainfo"), "--display", "drm", "--device", nodes[0]], cwd=tmp)
        took = time.time() - start
        m = re.search(r"VA-API version (\d+\.\d+\.\d+)", out)
        if not m:
            self.record("libva", "vainfo", "FAIL", took,
                        f"libva did not start (exit {code}): {out.strip().splitlines()[-1:]}")
            return
        tried = re.findall(r"Trying to open (\S+)", out)
        if not os.environ.get("LIBVA_DRIVERS_PATH"):
            bad = [p for p in tried if not p.startswith(system_dirs)]
            if bad:
                self.record("libva", "vainfo", "FAIL", took, f"driver searched outside the system dirs: {bad}")
                return
        if code != 0:
            why = (f"no usable VA driver for {nodes[0]} (tried {', '.join(tried)})" if tried
                   else f"{nodes[0]}: {out.strip().splitlines()[-1:]}")
            self.record("libva", "vainfo", "SKIP", took, f"libva {m.group(1)}; {why}")
            self.record("libva", "test_va_api", "SKIP", 0, "no usable VA driver (see vainfo)")
            return
        driver = re.search(r"Driver version:\s*(.+)", out)
        profiles = sorted(set(re.findall(r"^\s*(VAProfile\w+)\s*:", out, re.M)))
        if not profiles:
            self.record("libva", "vainfo", "FAIL", took, "vainfo lists no profiles")
            return
        self.record("libva", "vainfo", "PASS", took,
                    f"libva {m.group(1)}, {driver.group(1).strip() if driver else '?'}: "
                    f"{len(profiles)} profiles")
        if not os.path.isfile(test_va_api):
            self.record("libva", "test_va_api", "FAIL", 0, f"missing {test_va_api}")
            return
        tmp = self.tmpdir("libva-test_va_api")
        start = time.time()
        status, detail = self.run_gtest([test_va_api], tmp, dict(os.environ))
        self.record("libva", "test_va_api", status, time.time() - start, detail)

    # ── official test vectors ──────────────────────────────────────────────
    def run_opus_vectors(self, only):
        if only and "opus" not in only:
            return
        demo, compare = self.tool("opus_demo"), self.tool("opus_compare")
        if not (demo and compare):
            return
        vectors = os.path.join(self.data, "opus") if self.data else None
        if not vectors or not os.path.isfile(os.path.join(vectors, "testvector01.bit")):
            self.record("opus", "rfc8251-vectors", "SKIP", 0, "needs <data>/opus")
            return

        def check_vectors(tmp):
            # tests/run_vectors.sh: decode mono + stereo at each rate; either
            # reference (.dec or m.dec) must match
            for rate in ("48000", "24000", "16000", "12000", "8000"):
                for ch, extra in (("1", []), ("2", ["-s"])):
                    for n in range(1, 13):
                        v = os.path.join(vectors, f"testvector{n:02d}")
                        self.run_ok([demo, "-d", rate, ch, "-ignore_extensions", v + ".bit",
                                     "tmp.out"], tmp)
                        ok = any(self.run([compare] + extra + ["-r", rate, ref, "tmp.out"],
                                          cwd=tmp)[0] == 0 for ref in (v + ".dec", v + "m.dec"))
                        self.check(ok, f"vector {n:02d} {ch}ch {rate} Hz does not match")
            return "12 vectors x mono/stereo x 5 rates"
        self.cli("opus", "rfc8251-vectors", check_vectors)

    def run_dav1d_testdata(self, only):
        """dav1d-test-data (<data>/dav1d, tools/fetch_test_data.sh): the test()
        definitions of its meson.build files — what `meson test` runs upstream
        with -Dtestdata_tests=true — evaluated by meson_tests.py and run with
        the installed dav1d CLI, fuzzer drivers and seek_stress."""
        if only and "dav1d" not in only:
            return
        if not self.tool("dav1d"):
            return
        root = os.path.join(self.data, "dav1d") if self.data else None
        if not root or not os.path.isfile(os.path.join(root, "meson.build")):
            self.record("dav1d", "testdata", "SKIP", 0, "needs <data>/dav1d")
            return
        import concurrent.futures
        import meson_tests

        programs = {"dav1d": self.tool("dav1d")}
        for name in ("dav1d_fuzzer", "dav1d_fuzzer_mt", "seek_stress"):
            path = os.path.join(self.deps, "tests", "dav1d", name + EXE)
            if os.path.isfile(path):
                programs[name] = path
        # build/deps/dav1d.sh: both bit depths, tools, fuzzer drivers, seek_stress
        variables = {"dav1d_bitdepths": ["8", "16"]}
        if "dav1d_fuzzer" in programs:
            variables["dav1d_fuzzer_sources"] = []
        options = {"enable_tools": True, "testdata_tests": True,
                   "enable_seek_stress": "seek_stress" in programs}
        start = time.time()
        try:
            tests = meson_tests.load_tests(root, programs, options, variables)
        except (meson_tests.MesonError, OSError) as e:
            self.record("dav1d", "testdata", "FAIL", time.time() - start, f"test definitions: {e}")
            return
        tmp = self.tmpdir("dav1d-testdata")

        def run_one(t):
            argv = [programs[t["program"]]] + t["args"]
            t0 = time.time()
            try:
                proc = subprocess.run(argv, cwd=tmp, timeout=t["timeout"],
                                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                out = proc.stdout.decode("utf-8", "replace")
                ok = (proc.returncode == 0) != bool(t["should_fail"])
                detail = "" if ok else f"exit {proc.returncode}: {out.strip().splitlines()[-1:]}"
            except subprocess.TimeoutExpired:
                out, ok, detail = "", False, f"timeout ({t['timeout']} s)"
            return t, ok, detail, out, time.time() - t0

        # one result line per suite (testdata-8/-10/-12/-multi, seek-stress, oss-fuzz-*)
        suites = {}
        with concurrent.futures.ThreadPoolExecutor(max(1, self.jobs)) as pool:
            for t, ok, detail, out, secs in pool.map(run_one, tests):
                s = suites.setdefault(t["suites"][0], {"n": 0, "secs": 0.0, "failed": []})
                s["n"] += 1
                s["secs"] += secs
                if not ok:
                    s["failed"].append(f"{t['name']} ({detail})")
                    if self.log:
                        self.log.write(f"FAIL {t['suites'][0]}/{t['name']}: "
                                       f"{' '.join([t['program']] + t['args'])}\n{out}\n")
        for name, s in suites.items():
            detail = f"{s['n'] - len(s['failed'])}/{s['n']} passed"
            if s["failed"]:
                detail += " — " + ", ".join(s["failed"][:5]) + (" …" if len(s["failed"]) > 5 else "")
            self.record("dav1d", name, "FAIL" if s["failed"] else "PASS", s["secs"], detail)

    def summary(self):
        by = {}
        for _, _, status, _, _ in self.results:
            by[status] = by.get(status, 0) + 1
        self.say("-" * 72)
        self.say("  ".join(f"{k}: {v}" for k, v in sorted(by.items())))
        return by.get("FAIL", 0) == 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("deps_dir", help="prebuilt/.deps/<platform>")
    ap.add_argument("--data", default=os.environ.get("CUSTOM_FFMPEG_TEST_DATA"),
                    help="test data root (default: $CUSTOM_FFMPEG_TEST_DATA)")
    ap.add_argument("--only", default="", help="comma-separated deps")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 2)
    ap.add_argument("--log", help="write full output to this file")
    ap.add_argument("--keep", action="store_true", help="keep the scratch directory")
    a = ap.parse_args()

    log = open(a.log, "w", encoding="utf-8") if a.log else None
    r = Runner(a.deps_dir, a.data, a.jobs, log)
    only = set(filter(None, a.only.split(",")))
    r.say(f"deps: {r.deps}  data: {r.data or '(none)'}  host: {platform.system()} {platform.machine()}")
    # SIMD paths tested depend on the CPU (e.g. AVX-512 tests are filtered out
    # without it): record what this machine has
    try:
        with open("/proc/cpuinfo", encoding="utf-8") as f:
            info = f.read()
        model = re.search(r"^model name\s*:\s*(.+)$", info, re.M)
        avx512 = sorted(set(re.findall(r"\b(avx512\w*)", info)))
        r.say(f"cpu: {model.group(1) if model else '?'}  avx512: {' '.join(avx512) or 'none'}")
    except OSError:
        pass                                # not Linux
    try:
        r.run_manifests(only)
        r.run_cli_tests(only)
        r.run_opus_vectors(only)
        r.run_dav1d_testdata(only)
        ok = r.summary()
    finally:
        if a.keep:
            r.say(f"scratch kept: {r.scratch}")
        else:
            shutil.rmtree(r.scratch, ignore_errors=True)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
