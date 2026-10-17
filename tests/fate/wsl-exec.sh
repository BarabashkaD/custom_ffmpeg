#!/usr/bin/env bash
# wsl-exec.sh — FATE target-exec wrapper for Windows builds tested from WSL.
# FATE starts programs as "<target-exec> <target-path>/<program>.exe args…",
# with the target path in Windows form (D:/…). Map the program path back to
# WSL so it can be started; WSL interop then runs it natively on Windows. The
# arguments stay Windows paths — that is what the Windows program needs.
prog="$1"
shift
case "$prog" in
    [A-Za-z]:/*|[A-Za-z]:\\*) prog="$(wslpath -u "$prog")" ;;
esac
exec "$prog" "$@"
