#!/usr/bin/env bash
# 정합성 점검: 같은 글(eval/ppl_text.txt)의 perplexity 를 1노드와 TP 에서 비교한다(flash attention 은 둘 다 on — TP 필수 조건과 맞춤).
#   eval_ppl.sh <GGUF> 1node | tplocal | tp2node      결과: runs/ppl-<모델>-<모드>-<시각>/ppl.log, 마지막 줄 PPL
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); M=${1:?GGUF}; MODE=${2:?1node|tplocal|tp2node}
B=parks-zbook@10.99.0.2; BIN=$D/llama.cpp/build-rocm/bin; BBIN=/home/parks-zbook/engine2n/bin
OUT=$D/runs/ppl-$(basename "$M" .gguf)-$MODE-$(date +%m%d-%H%M%S); mkdir -p "$OUT"
export LD_LIBRARY_PATH=/opt/rocm/lib
export GGML_RDMA_CHUNK=${GGML_RDMA_CHUNK:-65536}   # 64 KiB × 48 수신 칸 + 4 송신 칸 ≈ 3.3 MiB/연결 — 연결 2개도 8 MiB memlock 안
export GGML_RDMA_RX_DEPTH=${GGML_RDMA_RX_DEPTH:-48}
export GGML_RDMA_TX_SLOTS=${GGML_RDMA_TX_SLOTS:-4}
ARGS=(-m "$M" -f "$D/eval/ppl_text.txt" -c 512 --chunks ${CHUNKS:-40} -ngl 99 -fa on ${PPL_EXTRA:-})
case $MODE in
  1node)   ;;
  tplocal) "$BIN/ggml-rpc-server" -H 127.0.0.1 -p 50052 > "$OUT/rpc-50052.log" 2>&1 & echo $! >> "$OUT/pids"
           "$BIN/ggml-rpc-server" -H 127.0.0.1 -p 50053 > "$OUT/rpc-50053.log" 2>&1 & echo $! >> "$OUT/pids"
           ARGS+=(--rpc 127.0.0.1:50052,127.0.0.1:50053 -sm tensor -dev RPC0,RPC1) ;;
  tp2node) "$BIN/ggml-rpc-server" -H 127.0.0.1 -p 50052 > "$OUT/rpc-50052.log" 2>&1 & echo $! >> "$OUT/pids"
           ssh -o BatchMode=yes $B "mkdir -p $BBIN; pkill -x ggml-rpc-server; sleep 1"; scp -q "$BIN/ggml-rpc-server" "$B:$BBIN/" || exit 3
           ssh -o BatchMode=yes $B "cd $BBIN && LD_LIBRARY_PATH=/opt/rocm/lib GGML_RDMA_RX_DEPTH=$GGML_RDMA_RX_DEPTH GGML_RDMA_CHUNK=$GGML_RDMA_CHUNK GGML_RDMA_TX_SLOTS=$GGML_RDMA_TX_SLOTS GGML_RPC_COMM_OVERLAP=${GGML_RPC_COMM_OVERLAP:-0} setsid -f ./ggml-rpc-server -H 10.99.0.2 -p 50052 -c > rpc-server.log 2>&1 < /dev/null"
           ARGS+=(--rpc 10.99.0.2:50052,127.0.0.1:50052 -sm tensor -dev RPC0,RPC1) ;;
  *) echo "모름: $MODE"; exit 2 ;;
esac
sleep 2
"$BIN/llama-perplexity" "${ARGS[@]}" > "$OUT/ppl.log" 2>&1
echo "rc=$?"; grep -E 'Final estimate|^\[' "$OUT/ppl.log" | tail -2
[ -f "$OUT/pids" ] && xargs -r kill < "$OUT/pids" 2>/dev/null
[ "$MODE" = tp2node ] && ssh -o BatchMode=yes $B "pkill -x ggml-rpc-server"
exit 0
