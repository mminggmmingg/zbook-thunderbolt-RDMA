#!/usr/bin/env bash
# head 컨테이너 안: Ray 에 GPU 2개가 붙을 때까지 기다린 뒤 vllm serve(eager, MTP 끔) → 시험 요청 → 종료
set -uo pipefail
for i in $(seq 1 120); do
  n=$(python -c "import ray;ray.init(address='auto',logging_level='ERROR');print(int(ray.cluster_resources().get('GPU',0)))" 2>/dev/null)
  [ "$n" = 2 ] && break; sleep 2
done
echo "[serve] ray GPUs=$n"; [ "$n" = 2 ] || exit 3
vllm serve /model --served-model-name glm-5.3-flash --tensor-parallel-size 2 \
  --distributed-executor-backend ray --quantization compressed-tensors --enforce-eager \
  --skip-mm-profiling --kv-cache-memory-bytes ${KV_BYTES:-4294967296} \
  --max-model-len ${MAX_CTX:-32768} --max-num-batched-tokens 2048 --max-num-seqs 8 \
  --trust-remote-code --host 127.0.0.1 --port 18080 &
SP=$!
t0=$(date +%s)
until curl -sf http://127.0.0.1:18080/health >/dev/null; do
  kill -0 $SP 2>/dev/null || { echo "[serve] vllm 종료됨"; exit 4; }; sleep 5; done
echo "[serve] READY 기동 $(( $(date +%s) - t0 ))s"
python /zrun/probe.py http://127.0.0.1:18080 || echo "[serve] probe 실패 rc=$?"
kill $SP; wait $SP 2>/dev/null; ray stop --force >/dev/null 2>&1; exit 0
