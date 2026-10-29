#!/usr/bin/env bash
# TP 실행: rpc-server 두 개(장치 2개)에 llama-bench 가 -sm tensor 로 매 층을 반씩 나눠 쓴다. AR 은 두 rpc-server 가 직접 주고받는다.
#   run_tp.sh <q4|iq4|q8|GGUF경로> local        A 혼자 점검(T2): rpc-server 2개를 A 에(포트 50052, 50053) — 같은 GPU 를 나눠 씀
#   run_tp.sh <q4|q8> 2node [tcp|rdma]   B(10.99.0.2:50052, rank 0) + A(127.0.0.1:50052, rank 1)  (기본 rdma; tcp 면 GGML_RPC_NO_RDMA=1)
# 모델 파일은 A 에만 있으면 된다. 결과: runs/tp-<q>-<topo>-<mode>-<시각>/
# TRACE=1 이면 두 서버의 AR 호출별 기록(GGML_RPC_COMM_PROF_TRACE)을 runs/.../trace-{a,b}.txt 로 모은다(GGML_RPC_COMM_PROF 도 켜야 함).
# APREFIX="rocprofv3 ... --" 면 A 서버를 그 명령 아래에서 띄우고, 끝낼 때 SIGINT 로 멈춰 결과를 쓰게 한다.
# SRV_ENV="A=1 B=2" 는 두 서버(A·B) 모두에 넘길 환경변수(예: GGML_CUDA_DISABLE_GRAPHS=1).
# FFN 만 따로 나누기(클라이언트 쪽): LLAMA_TP_FFN_GRAN, LLAMA_TP_FFN_SPLIT(장치 0 = B 의 몫) — llama-model.cpp 참고
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); Q=${1:?q4|q8}; TOPO=${2:?local|2node}; MODE=${3:-rdma}
B=parks-zbook@10.99.0.2; BIN=${BIN:-$D/llama.cpp/build-rocm/bin}; BBIN=/home/parks-zbook/engine2n/bin
case $Q in q4) M=/data/parksThink/hf-models/qwen38-flash-next-gguf/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf ;;
           iq4) M=/data/parksThink/hf-models/qwen38-flash-next-gguf/UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf ;;
           q8) M=/data/parksThink/hf-models/qwen38-flash-next-gguf/Q8_0/Qwen3.8-Flash-Next-Q8_0-00001-of-00006.gguf ;;
           *) M=$Q ;; esac
OUT=$D/runs/tp-$(basename "$Q" .gguf)-$TOPO-$MODE-$(date +%m%d-%H%M%S); mkdir -p "$OUT"
NORDMA=""; [ "$MODE" = tcp ] && NORDMA="GGML_RPC_NO_RDMA=1"
export LD_LIBRARY_PATH=/opt/rocm/lib
export GGML_RDMA_CHUNK=${GGML_RDMA_CHUNK:-65536}   # 64 KiB × 48 수신 칸 + 4 송신 칸 ≈ 3.3 MiB/연결 — 연결 2개도 8 MiB memlock 안
export GGML_RDMA_RX_DEPTH=${GGML_RDMA_RX_DEPTH:-48}
export GGML_RDMA_TX_SLOTS=${GGML_RDMA_TX_SLOTS:-4}
SRV_ENV=${SRV_ENV-GGML_CUDA_DISABLE_GRAPHS=1}  # HIP 그래프 끔: 전체 어텐션 부분그래프에서 hipGraphLaunch 가 ≈620 µs GPU 를 멈춤(RESULTS.md GPU 활용)
export GGML_RPC_COMM_OVERLAP=${GGML_RPC_COMM_OVERLAP:-2}  # AR 뒤 발행 겹치기 2(도우미 수신). 3 은 정확하지만 이 APU 에서 GPU 클럭이 떨어져 느림(RESULTS.md)
export LLAMA_TP_FFN_GRAN=${LLAMA_TP_FFN_GRAN:-32}  # 전문가 FFN 폭 640 을 320/320 으로(기본 128 알갱이면 층마다 256/384) — RESULTS.md 로드맵 a

TRA=""; TRB=""
if [ "${TRACE:-0}" = 1 ]; then TRA="GGML_RPC_COMM_PROF_TRACE=$OUT/trace-a.txt"; TRB="GGML_RPC_COMM_PROF_TRACE=$BBIN/trace-b.txt"; fi
start_local() {  # $1 = port, $2 = bind host
  env $NORDMA $TRA ${SRV_ENV:-} nohup ${APREFIX:-} "$BIN/ggml-rpc-server" -H "${2:-127.0.0.1}" -p "$1" > "$OUT/rpc-a-$1.log" 2>&1 &
  echo $! >> "$OUT/pids"
}
case $TOPO in
  local) start_local 50052; start_local 50053
         DEVS="RPC0/RPC1"; RPC=127.0.0.1:50052,127.0.0.1:50053 ;;
  2node) start_local 50052 127.0.0.1
         ssh -o BatchMode=yes $B "mkdir -p $BBIN; pkill -x ggml-rpc-server; sleep 1"; scp -q "$BIN/ggml-rpc-server" "$B:$BBIN/" || exit 3
         ssh -o BatchMode=yes $B "cd $BBIN && LD_LIBRARY_PATH=/opt/rocm/lib GGML_RDMA_RX_DEPTH=$GGML_RDMA_RX_DEPTH GGML_RDMA_CHUNK=$GGML_RDMA_CHUNK GGML_RDMA_TX_SLOTS=$GGML_RDMA_TX_SLOTS GGML_RPC_COMM_PROF=${GGML_RPC_COMM_PROF:-0} GGML_RPC_COMM_OVERLAP=${GGML_RPC_COMM_OVERLAP:-0} $TRB ${SRV_ENV:-} $NORDMA setsid -f ./ggml-rpc-server -H 10.99.0.2 -p 50052 -c > rpc-server.log 2>&1 < /dev/null"
         DEVS="RPC0/RPC1"; RPC=10.99.0.2:50052,127.0.0.1:50052 ;;
  *) echo "모름: $TOPO"; exit 2 ;;
esac
sleep 3
env $NORDMA "$BIN/llama-bench" -m "$M" --rpc "$RPC" -dev "$DEVS" -sm tensor -fa on -ngl 99 ${BENCH:--p 512 -n 128 -r 3} -o md \
  > "$OUT/bench.md" 2> "$OUT/bench.err"
echo "rc=$?"; cat "$OUT/bench.md"
grep -iE 'rdma|transport|comm|allreduce|split' "$OUT/bench.err" | head -8
grep -ihE 'rdma|comm|joined' "$OUT"/rpc-a-*.log | head -4
[ "$TOPO" = 2node ] && ssh -o BatchMode=yes $B "grep -iE 'rdma|comm|joined' $BBIN/rpc-server.log | head -4; pkill -x ggml-rpc-server"
if [ "$TOPO" = 2node ]; then
  scp -q "$B:$BBIN/rpc-server.log" "$OUT/rpc-b.log"
  [ -n "$TRB" ] && scp -q "$B:$BBIN/trace-b.txt" "$OUT/trace-b.txt"
fi
if [ -n "${APREFIX:-}" ]; then pkill -INT -x ggml-rpc-server; sleep 10; pkill -KILL -x ggml-rpc-server; else xargs -r kill < "$OUT/pids" 2>/dev/null; fi
