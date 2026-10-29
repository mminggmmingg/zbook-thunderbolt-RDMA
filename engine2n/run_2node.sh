#!/usr/bin/env bash
# 폐기(PP, 층 분할) — 사용하지 않는다. TP 는 run_tp.sh. 기록용으로만 남김.
# 2노드 실행: B 에서 ggml-rpc-server(GPU), A 에서 llama-bench 가 --rpc 10.99.0.2 로 층을 나눠 쓴다.
#   run_2node.sh <q4|q8> [tcp|rdma]      (기본 rdma. tcp 면 양쪽에 GGML_RPC_NO_RDMA=1 → 같은 경로의 TCP 와 비교)
# 모델 파일은 A 에만 있으면 된다(원격 층 가중치는 로드 때 RPC 로 B 에 보낸다). 결과: runs/2node-<q>-<mode>-<시각>/
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); Q=${1:?q4|q8}; MODE=${2:-rdma}
B=parks-zbook@10.99.0.2; BIN=$D/llama.cpp/build-hip/bin; BBIN=/home/parks-zbook/engine2n/bin
case $Q in q4) M=/data/parksThink/hf-models/qwen38-flash-next-gguf/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf ;;
           q8) M=/data/parksThink/hf-models/qwen38-flash-next-gguf/Q8_0/Qwen3.8-Flash-Next-Q8_0-00001-of-00006.gguf ;; esac
OUT=$D/runs/2node-$Q-$MODE-$(date +%m%d-%H%M); mkdir -p "$OUT"
NORDMA=""; [ "$MODE" = tcp ] && NORDMA="GGML_RPC_NO_RDMA=1"
export LD_LIBRARY_PATH=/opt/rocm/lib
ssh -o BatchMode=yes $B "mkdir -p $BBIN"; scp -q "$BIN/ggml-rpc-server" "$B:$BBIN/"
ssh -o BatchMode=yes $B "pkill -x ggml-rpc-server; cd $BBIN && LD_LIBRARY_PATH=/opt/rocm/lib $NORDMA nohup ./ggml-rpc-server -H 10.99.0.2 -p 50052 -c > rpc-server.log 2>&1 &"
sleep 3
env $NORDMA "$BIN/llama-bench" -m "$M" -ngl 99 --rpc 10.99.0.2:50052 -p 512 -n 128 -r 3 -o md > "$OUT/bench.md" 2> "$OUT/bench.err"
echo "rc=$?"; cat "$OUT/bench.md"
grep -iE 'rdma|transport|tcp' "$OUT/bench.err" | head -5
ssh -o BatchMode=yes $B "grep -iE 'rdma|transport|accepted' $BBIN/rpc-server.log | head -5; pkill -x ggml-rpc-server"
