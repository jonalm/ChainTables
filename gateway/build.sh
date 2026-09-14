#!/usr/bin/env bash
# Build the gateway's deployment zip from the locked dependencies.
#
#   gateway/build.sh [--arch arm64|x86_64] [--python 3.13] [--policy <file>] [--out <zip>]
#
# The zip holds handler.py, every runtime dependency pinned in uv.lock (boto3 included, so
# the gateway never depends on whichever boto3 the Lambda runtime happens to ship), and, when
# --policy is given, that file as policy.json. Wheels are resolved for the Lambda platform
# (manylinux_2_28 on the chosen architecture: the python3.13 runtime is Amazon Linux 2023,
# glibc 2.34) and Python version, not for this machine, so the build is the same from macOS
# or Linux. Timestamps are pinned, so the same inputs give the
# same zip bytes. The policy file is private: never commit one, and never pass a default.
set -euo pipefail

arch=arm64
python=3.13
policy=""
out=""
while [ $# -gt 0 ]; do
    case "$1" in
        --arch) arch="$2"; shift 2 ;;
        --python) python="$2"; shift 2 ;;
        --policy) policy="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "build.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done

case "$arch" in
    arm64) platform=aarch64-manylinux_2_28 ;;
    x86_64) platform=x86_64-manylinux_2_28 ;;
    *) echo "build.sh: --arch must be arm64 or x86_64, not $arch" >&2; exit 2 ;;
esac

here="$(cd "$(dirname "$0")" && pwd)"
build="$here/build"
pkg="$build/pkg"
[ -n "$out" ] || out="$build/gateway-$arch.zip"
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac   # zip runs from inside the package dir
command -v uv >/dev/null || { echo "build.sh: uv is required (https://docs.astral.sh/uv/)" >&2; exit 1; }
if [ -n "$policy" ] && [ ! -f "$policy" ]; then echo "build.sh: policy file $policy not found" >&2; exit 1; fi

rm -rf "$pkg"
mkdir -p "$pkg"

uv export --directory "$here" --frozen --no-dev --no-emit-project --no-editable -o "$build/requirements.txt" >/dev/null
uv pip install \
    --python-platform "$platform" --python-version "$python" --only-binary :all: \
    --require-hashes --no-compile-bytecode \
    --target "$pkg" -r "$build/requirements.txt" >/dev/null

cp "$here/handler.py" "$pkg/handler.py"
if [ -n "$policy" ]; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$policy"  # fail here, not at cold start
    cp "$policy" "$pkg/policy.json"
fi
find "$pkg" -name '__pycache__' -type d -prune -exec rm -rf {} +
find "$pkg" -exec touch -t 200001010000 {} +

rm -f "$out"
(cd "$pkg" && find . -type f | sort | TZ=UTC zip -X -q -@ "$out")
echo "built $out ($(du -h "$out" | cut -f1)) for $arch / python$python$([ -n "$policy" ] && echo " with policy.json" || echo ", no policy.json")"
