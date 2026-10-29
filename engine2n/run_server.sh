#!/usr/bin/env bash
# llama-server 로 실제 생성 속도 측정(추측 디코딩 포함): 서버를 띄우고 tools/spec_bench.py 를 돌린 뒤 내린다.
#   run_server.sh <1node|2node> <none|mtp> [max_tokens=256]
# 2node 는 run_tp.sh 와 같은 구성(B rank 0, A 127.0.0.1, OVERLAP=2, 그래프 끔, FFN 320/320). 결과: runs/srv-<topo>-<spec>-<시각>/
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); TOPO=${1:?1node|2node}; SPEC=${2:?none|mtp}; NMAX=${3:-256}
B=parks-zbook@10.99.0.2; BIN=${BIN:-$D/llama.cpp/build-rocm/bin}; BBIN=/home/parks-zbook/engine2n/bin
M=/data/parksThink/hf-models/qwen38-flash-next-gguf/UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf
# 공유형 MTP 파일에 본 모델의 token_embd·output 을 붙인 파일(tools/gguf_merge_mtp.py) — 이 llama.cpp 는 공유형을 단독으로 못 연다
MTP=${MTP:-/data/parksThink/hf-models/qwen38-flash-next-gguf/MTP/mtp-Qwen3.8-Flash-Next-merged-IQ4embd.gguf}
OUT=$D/runs/srv-$TOPO-$SPEC-$(date +%m%d-%H%M%S); mkdir -p "$OUT"; PORT=8077
export LD_LIBRARY_PATH=/opt/rocm/lib
export GGML_RDMA_CHUNK=${GGML_RDMA_CHUNK:-65536} GGML_RDMA_RX_DEPTH=${GGML_RDMA_RX_DEPTH:-48} GGML_RDMA_TX_SLOTS=${GGML_RDMA_TX_SLOTS:-4}
export GGML_RPC_COMM_OVERLAP=${GGML_RPC_COMM_OVERLAP:-2} LLAMA_TP_FFN_GRAN=${LLAMA_TP_FFN_GRAN:-32}
SRV_ENV=${SRV_ENV-GGML_CUDA_DISABLE_GRAPHS=1}
ARGS=(-m "$M" -ngl 99 -fa on -c 8192 -np 1 --port $PORT --host 127.0.0.1 ${SRV_EXTRA:-})
[ "$SPEC" = mtp ] && ARGS+=(-md "$MTP" --spec-type draft-mtp -ngld 99 ${SPEC_EXTRA:-})
if [ "$TOPO" = 2node ]; then
  env $SRV_ENV nohup "$BIN/ggml-rpc-server" -H 127.0.0.1 -p 50052 > "$OUT/rpc-a.log" 2>&1 & echo $! >> "$OUT/pids"
  ssh -o BatchMode=yes $B "mkdir -p $BBIN; pkill -x ggml-rpc-server; sleep 1"; scp -q "$BIN/ggml-rpc-server" "$B:$BBIN/" || exit 3
  ssh -o BatchMode=yes $B "cd $BBIN && LD_LIBRARY_PATH=/opt/rocm/lib GGML_RDMA_RX_DEPTH=$GGML_RDMA_RX_DEPTH GGML_RDMA_CHUNK=$GGML_RDMA_CHUNK GGML_RDMA_TX_SLOTS=$GGML_RDMA_TX_SLOTS GGML_RPC_COMM_OVERLAP=$GGML_RPC_COMM_OVERLAP $SRV_ENV setsid -f ./ggml-rpc-server -H 10.99.0.2 -p 50052 -c > rpc-server.log 2>&1 < /dev/null"
  ARGS+=(--rpc 10.99.0.2:50052,127.0.0.1:50052 -sm tensor -dev RPC0,RPC1)
  sleep 3
fi
env ${CLI_ENV:-} nohup "$BIN/llama-server" "${ARGS[@]}" > "$OUT/server.log" 2>&1 & echo $! >> "$OUT/pids"
for i in $(seq 600); do curl -sf http://127.0.0.1:$PORT/health > /dev/null && break; sleep 1; done
curl -sf http://127.0.0.1:$PORT/health > /dev/null || { echo "server not ready"; tail -20 "$OUT/server.log"; }
python3 -I "$D/tools/spec_bench.py" http://127.0.0.1:$PORT "$D/eval/spec_prompts.json" "$NMAX" "$OUT/results.jsonl" | tee "$OUT/bench.txt"
grep -iE 'draft|mtp|spec' "$OUT/server.log" | grep -v '^\s*$' | head -6
# llama-server 를 먼저 내리고(끝날 때 RPC 서버에 메모리를 묻는다) 그다음 RPC 서버
SP=$(tail -1 "$OUT/pids"); kill $SP 2>/dev/null; while kill -0 $SP 2>/dev/null; do sleep 1; done
xargs -r kill < "$OUT/pids" 2>/dev/null
# 다음 실행이 메모리 부족을 겪지 않게, 프로세스가 끝나 GPU 메모리를 돌려줄 때까지 기다린다
for p in $(cat "$OUT/pids"); do while kill -0 $p 2>/dev/null; do sleep 1; done; done; sleep 3
[ "$TOPO" = 2node ] && ssh -o BatchMode=yes $B "pkill -x ggml-rpc-server"
echo "$OUT"
