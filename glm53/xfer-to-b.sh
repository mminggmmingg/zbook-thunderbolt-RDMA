#!/usr/bin/env bash
# A → B (TB, 10.99.0.2): GLM-5.3 Uncensored AWQ 모델 + vllm-strix-halo:tbv 이미지. --delete 쓰지 않음.
set -uo pipefail
L=/data/parksThink/macos_reversing/codex/zbook-rdma/experiments/glm53/build-logs/xfer-$(date +%m%d-%H%M).log
B=parks-zbook@10.99.0.2
{
echo "== $(date) 모델 rsync 시작"
rsync -a --partial --info=progress2,stats2 --exclude='.cache/' --exclude='.download.log' \
  /data/parksThink/hf-models/GLM-5.3-Flash-Uncensored-AWQ/ $B:/home/parks-zbook/models/GLM-5.3-Flash-Uncensored-AWQ/
echo "MODEL_EXIT=$?"
echo "== $(date) 이미지 전송 시작"
docker save vllm-strix-halo:tbv | ssh $B docker load
echo "IMAGE_EXIT=${PIPESTATUS[0]}/${PIPESTATUS[1]}"
echo "== $(date) 끝"
} 2>&1 | tee "$L"
echo "XFER_DONE"
