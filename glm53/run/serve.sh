#!/usr/bin/env bash
# head 컨테이너 안: Ray 에 GPU 2개가 붙을 때까지 기다린 뒤 vllm serve → 시험 요청 → 종료
# 튜닝 손잡이(기본값 = 처음 검증한 eager·추측디코딩 끔):
#   EAGER=1|0          0 이면 breakable PIECEWISE CUDA 그래프. TP 집합통신은 그래프 밖에서 eager 로 돈다
#                      (vsh-cg-eager-collectives) → libtbvcoll 훅 그대로 사용. CG_SIZES(기본 "1 2 4 8"), CG_MODE(PIECEWISE)
#   SPEC=none|mtp|dflash  SPEC_K(기본 mtp 3 / dflash 3), DRAFT(dflash drafter 경로, 컨테이너 안)
#   REASONING=0|1      1 이면 glm47 reasoning·tool 파서(생각 과정을 reasoning_content 로 분리)
set -uo pipefail
for i in $(seq 1 120); do
  n=$(python -c "import ray;ray.init(address='auto',logging_level='ERROR');print(int(ray.cluster_resources().get('GPU',0)))" 2>/dev/null)
  [ "$n" = 2 ] && break; sleep 2
done
echo "[serve] ray GPUs=$n"; [ "$n" = 2 ] || exit 3

CG=(--enforce-eager)
if [ "${EAGER:-1}" = 0 ]; then
  export VLLM_USE_BREAKABLE_CUDAGRAPH=1     # VLLM_ 접두사라 Ray 가 워커(B)에도 복사한다
  CG=(--cudagraph-capture-sizes ${CG_SIZES:-1 2 4 8}
      --compilation-config "{\"cudagraph_mode\": \"${CG_MODE:-PIECEWISE}\"}")
fi
SP_ARGS=()
case "${SPEC:-none}" in
  mtp)    SP_ARGS=(--speculative-config "{\"method\":\"glm5_next_mtp\",\"num_speculative_tokens\":${SPEC_K:-3}}") ;;
  dflash) SP_ARGS=(--speculative-config "{\"method\":\"dflash\",\"model\":\"${DRAFT:-/draft}\",\"num_speculative_tokens\":${SPEC_K:-3},\"attention_backend\":\"TRITON_ATTN\"}") ;;
  none)   ;;
  *) echo "[serve] SPEC?"; exit 5 ;;
esac
PF=()
# PROF=1: torch 프로파일러. probe 가 chat#1 앞뒤로 /start_profile·/stop_profile 을 부른다. 트레이스는 각 노드 /cache/prof
[ "${PROF:-0}" = 1 ] && PF=(--profiler-config "{\"profiler\":\"torch\",\"torch_profiler_dir\":\"/cache/prof\",\"torch_profiler_with_stack\":false,\"delay_iterations\":20,\"active_iterations\":12}")
RP=()
[ "${REASONING:-0}" = 1 ] && RP=(--enable-auto-tool-choice --tool-call-parser glm47 --reasoning-parser glm47)
echo "[serve] EAGER=${EAGER:-1} CG_SIZES=${CG_SIZES:-1 2 4 8} SPEC=${SPEC:-none} K=${SPEC_K:-3} REASONING=${REASONING:-0}"

vllm serve /model --served-model-name glm-5.3-flash --tensor-parallel-size 2 \
  --distributed-executor-backend ray --quantization compressed-tensors "${CG[@]}" \
  --skip-mm-profiling --kv-cache-memory-bytes ${KV_BYTES:-4294967296} \
  --max-model-len ${MAX_CTX:-32768} --max-num-batched-tokens 2048 --max-num-seqs 8 \
  --trust-remote-code "${SP_ARGS[@]}" "${RP[@]}" "${PF[@]}" --host 127.0.0.1 --port 18080 &
SP=$!
t0=$(date +%s)
until curl -sf http://127.0.0.1:18080/health >/dev/null; do
  kill -0 $SP 2>/dev/null || { echo "[serve] vllm 종료됨"; exit 4; }; sleep 5; done
echo "[serve] READY 기동 $(( $(date +%s) - t0 ))s"
python /zrun/probe.py http://127.0.0.1:18080 || echo "[serve] probe 실패 rc=$?"
kill $SP; wait $SP 2>/dev/null; ray stop --force >/dev/null 2>&1; exit 0
