#!/usr/bin/env bash
# 1단계: 참고 스택(davidcanar/vllm-strix-halo, Apache-2.0)을 고정 커밋으로 받아 원본 그대로 빌드 → vllm-strix-halo:ref
#   빌드 중 vLLM(73859fec)과 OdinLink-Five 소스를 GitHub 에서 받는다. buildx 가 없어 기존 빌더(DOCKER_BUILDKIT=0)를 쓴다.
set -euo pipefail
D="$(cd "$(dirname "$0")/.." && pwd)"          # glm53/
REF=$D/ref; PIN=fe5ac1016737c1f68e04772e3ae9e7567bc40f22
if [ ! -d $REF/.git ]; then git clone -q https://github.com/davidcanar/vllm-strix-halo.git $REF; fi
git -C $REF checkout -q $PIN
mkdir -p $D/logs; L=$D/logs/build-ref-$(date +%m%d-%H%M).log; echo "log: $L"
cd $REF
DOCKER_BUILDKIT=0 docker build -t vllm-strix-halo:ref \
  --build-arg VLLM_COMMIT=73859fec5865700c5b2021b22890cb3b2005f66e \
  -f container/Dockerfile . 2>&1 | tee "$L"
echo "EXIT=${PIPESTATUS[0]}" | tee -a "$L"
