#!/usr/bin/env bash
# A 1노드 기준: llama-bench(prefill 512, decode 128, 3회). 호스트 ROCm 런타임으로 실행.
#   run_1node.sh <q4|iq4|GGUF경로>      결과: runs/1node-q4-<시각>/bench.md
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); Q=${1:-q4}; BIN=$D/llama.cpp/build-rocm/bin
G=/data/parksThink/hf-models/qwen38-flash-next-gguf
case $Q in q4)  M=$G/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf ;;
           iq4) M=$G/UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf ;;
           *)   M=$Q ;; esac
OUT=$D/runs/1node-$(basename "$Q" .gguf)-$(date +%m%d-%H%M%S); mkdir -p "$OUT"
LD_LIBRARY_PATH=/opt/rocm/lib "$BIN/llama-bench" -m "$M" -ngl 99 -p 512 -n 128 -r 3 -o md > "$OUT/bench.md" 2> "$OUT/bench.err"
echo "rc=$?"; cat "$OUT/bench.md"; tail -3 "$OUT/bench.err"
