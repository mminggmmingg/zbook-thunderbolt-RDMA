#!/usr/bin/env bash
# GLM-5.3 TP=2 한 판: B worker → A head(serve+probe). 커널 이상(tbv/TB) 감지 시 양쪽 컨테이너 즉시 kill.
#   MODE=tcp|tbv ./run_tp2.sh
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"; B=parks-zbook@10.99.0.2
MODE="${MODE:-tcp}"; INNER_TO="${INNER_TO:-1800}"
L=$D/log-$MODE-$(date +%m%d-%H%M).log
# 복구된 native retransmit(ACK matched after retry)는 정상 동작이라 감시 대상에서 뺀다(2026-10-25 SYNC 실행이 이것 때문에 중단됨).
PAT='active timeout|retransmit.*exhaust|list_del|blocked for more|WARNING:.*(thunderbolt|ibverbs|tbv)|BUG:|Oops'
since=$(date '+%Y-%m-%d %H:%M:%S')
killall_(){ docker kill glm53-head >/dev/null 2>&1; ssh $B 'docker kill glm53-worker >/dev/null 2>&1'; }
killall_; sleep 1
scp -q $D/glm53_node.sh $B:glm53-run/
ssh $B "MODE=$MODE INNER_TO=$INNER_TO PEER=10.99.0.1 PEER_SELF=10.99.0.2 MODEL=/home/parks-zbook/models/GLM-5.3-Flash-Uncensored-AWQ MOECFG=/home/parks-zbook/glm53-run/moe-configs CACHE=/home/parks-zbook/glm53-run/cache RUND=/home/parks-zbook/glm53-run NCCL_DEBUG=${NCCL_DEBUG:-WARN} TBV_CAP=${TBV_CAP:-4194304} TBV_WDOG=${TBV_WDOG:-10} VLLM_DISABLE_SHARED_EXPERTS_STREAM=${VLLM_DISABLE_SHARED_EXPERTS_STREAM:-0} CHAT_REPS=${CHAT_REPS:-1} CHAT_FIRST=${CHAT_FIRST:-0} AR2=${AR2:-1} TBV_ASYNC=${TBV_ASYNC:-1} HSA_INT=${HSA_INT:-1} TBV_KWAIT=${TBV_KWAIT:-0} HWQ=${HWQ:-} AR2=${AR2:-1} TBVSO=${TBVSO:+/home/parks-zbook/glm53-run/libtbvcoll.so} bash glm53-run/glm53_node.sh worker" > $D/worker-$MODE.log 2>&1 &
sleep 8
MODE=$MODE INNER_TO=$INNER_TO PEER=10.99.0.2 MODEL=/data/parksThink/hf-models/GLM-5.3-Flash-Uncensored-AWQ MOECFG=$D/../ref/host/moe-configs CACHE=$D/cache RUND=$D \
  NCCL_DEBUG=${NCCL_DEBUG:-WARN} TBV_CAP=${TBV_CAP:-4194304} TBV_WDOG=${TBV_WDOG:-10} VLLM_DISABLE_SHARED_EXPERTS_STREAM=${VLLM_DISABLE_SHARED_EXPERTS_STREAM:-0} CHAT_REPS=${CHAT_REPS:-1} CHAT_FIRST=${CHAT_FIRST:-0} AR2=${AR2:-1} TBV_ASYNC=${TBV_ASYNC:-1} HSA_INT=${HSA_INT:-1} TBV_KWAIT=${TBV_KWAIT:-0} HWQ=${HWQ:-} AR2=${AR2:-1} TBVSO=${TBVSO:+$D/so/libtbvcoll.so} bash $D/glm53_node.sh head > $L 2>&1 &
RUN=$!
trip=""
while kill -0 $RUN 2>/dev/null; do
  a=$(journalctl -k --since "$since" --no-pager 2>/dev/null | grep -E "$PAT" | head -3)
  b=$(ssh -o ConnectTimeout=5 $B "journalctl -k --since '$since' --no-pager | grep -E '$PAT' | head -3" 2>/dev/null)
  [ -n "$a$b" ] && { trip="A:$a | B:$b"; break; }
  sleep 3
done
[ -n "$trip" ] && { echo "### 감시 중단 $(date +%T): $trip" | tee -a $L | cut -c1-300; killall_; }
wait $RUN 2>/dev/null; killall_
echo "=== 결과 ($L)"; grep -aE "\[serve\]|\[probe\]|Error|error:|Traceback|OOM|out of memory|tbv_ar|tbvcoll\]|NET/IB : Using|NET/Socket|Using network" $L | head -30
echo "--- 커널 이상: A=$(journalctl -k --since "$since" --no-pager | grep -cE "$PAT") B=$(ssh $B "journalctl -k --since '$since' --no-pager | grep -cE '$PAT'")"
echo "RUN_DONE"
