#!/usr/bin/env bash
# 주의: 이미지 기본 libibverbs(rdma-core 62)는 tbv provider(rdma-core 61 빌드)와 segfault → vllm-strix-halo:tbv(9c627fe0) 부터 이미지에 v61 내장. 예전 이미지(:tbv-20261025a)로 돌릴 땐 호스트 v61 마운트 필요.
# GLM-5.3 TP=2 노드 컨테이너 실행기(양 노드 공용). Ray: A=head(+vllm serve), B=worker.
#   ./glm53_node.sh head|worker
# 환경: MODE=tcp|tbv  INNER_TO(초, 컨테이너 안 timeout)  MODEL  MOECFG  CACHE  PEER(상대 TB IP)
set -uo pipefail
ROLE="$1"
MODE="${MODE:-tcp}"; INNER_TO="${INNER_TO:-1800}"; IMG="${IMG:-vllm-strix-halo:tbv}"
HEAD_IP=10.99.0.1
# vLLM 의 노드 간 메시지 큐(zmq)·분산 초기화가 기본경로(Wi-Fi) IP 를 고르면, 두 노드가 다른 망에 있을 때 상대가 닿지 못해
# 초기화에서 멈춘다(2026-10-29, A 192.168.0.199 / B 10.197.2.40). TB IP 를 명시한다.
SELF_IP=$([ "$ROLE" = head ] && echo "$HEAD_IP" || echo "${PEER_SELF:?worker 는 PEER_SELF 필요}")
case "$MODE" in
  tcp) NET="-e NCCL_IB_DISABLE=1 -e DS4_ODL_AR2=0" ;;
  tbv) NET="-e NCCL_IB_DISABLE=0 -e NCCL_IB_HCA=usb4_rdma0,usb4_rdma5 -e NCCL_IB_GID_INDEX=1 -e NCCL_IB_MERGE_NICS=0 -e NCCL_MAX_NCHANNELS=2 -e NCCL_MIN_NCHANNELS=2 -e NCCL_CROSS_NIC=1 -e DS4_ODL_AR2=${AR2:-1}
            -e TBV_PEER=$PEER -e TBV_DEVS=usb4_rdma0,usb4_rdma5 -e TBV_PORT=18996 -e TBV_CAP=${TBV_CAP:-4194304} -e TBV_ASYNC=${TBV_ASYNC:-1} -e TBV_NSLOT=${TBV_NSLOT:-8} -e TBV_UNCACHED=1
            -v /usr/lib/x86_64-linux-gnu/libibverbs/libusb4_rdma-rdmav59.so:/usr/lib/x86_64-linux-gnu/libibverbs/libusb4_rdma-rdmav59.so:ro
            -v /etc/libibverbs.d/usb4_rdma.driver:/etc/libibverbs.d/usb4_rdma.driver:ro --device=/dev/infiniband
            -e TBV_WDOG=${TBV_WDOG:-10} -e TBV_KWAIT=${TBV_KWAIT:-0} ${HWQ:+-e GPU_MAX_HW_QUEUES=$HWQ} ${TBVSO:+-v $TBVSO:/opt/venv/lib/python3.12/site-packages/libtbvcoll.so:ro}" ;;
  *) echo "MODE?"; exit 1 ;;
esac
if [ "$ROLE" = head ]; then
  IN="ray start --head --node-ip-address=$HEAD_IP --port=6379 --num-gpus=1 --disable-usage-stats >/dev/null && bash /zrun/serve.sh"
else
  IN="ray start --address=$HEAD_IP:6379 --node-ip-address=$PEER_SELF --num-gpus=1 --disable-usage-stats --block"
fi
exec docker run --rm --name glm53-$ROLE --label glm53=1 \
  --device=/dev/kfd --device=/dev/dri --group-add video --group-add render \
  --network host --ipc=host --shm-size 32G --ulimit memlock=-1:-1 --security-opt seccomp=unconfined \
  -v "$MODEL":/model:ro -v "$MOECFG":/moecfg:ro -v "$CACHE":/cache -v "$RUND":/zrun:ro ${DRAFTDIR:+-v $DRAFTDIR:/draft:ro} ${ODLPY:+-v $ODLPY:/opt/venv/lib/python3.12/site-packages/odl_ar2.py:ro} \
  -e VLLM_HOST_IP=$SELF_IP -e NCCL_SOCKET_IFNAME=thunderbolt0 -e GLOO_SOCKET_IFNAME=thunderbolt0 -e NCCL_NET_GDR_LEVEL=0 -e NCCL_ALGO=Ring \
  -e NCCL_DEBUG=${NCCL_DEBUG:-WARN} -e NCCL_DEBUG_SUBSYS=INIT,NET \
  -e TORCH_NCCL_HEARTBEAT_TIMEOUT_SEC=2400 -e TORCH_NCCL_ENABLE_MONITORING=0 \
  -e RAY_EXPERIMENTAL_NOSET_ROCR_VISIBLE_DEVICES=1 -e RAY_memory_monitor_refresh_ms=0 -e RAY_memory_usage_threshold=0.99 \
  -e PYTHONHASHSEED=0 -e PYTHONFAULTHANDLER=1 -e HIP_VISIBLE_DEVICES=0 \
  -e PYTORCH_HIP_ALLOC_CONF=expandable_segments:True,garbage_collection_threshold:0.85 \
  -e TRITON_CACHE_DIR=/cache/triton -e TORCHINDUCTOR_CACHE_DIR=/cache/inductor \
  -e VLLM_ROCM_USE_AITER=1 -e VLLM_ROCM_USE_AITER_MOE=0 -e VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS=1800 \
  -e HSA_ENABLE_INTERRUPT=${HSA_INT:-1} -e VLLM_DISABLE_SHARED_EXPERTS_STREAM=${VLLM_DISABLE_SHARED_EXPERTS_STREAM:-0} -e CHAT_REPS=${CHAT_REPS:-1} -e CHAT_FIRST=${CHAT_FIRST:-0} -e EAGER=${EAGER:-1} -e CG_SIZES="${CG_SIZES:-1 2 4 8}" -e SPEC=${SPEC:-none} -e SPEC_K=${SPEC_K:-3} -e REASONING=${REASONING:-0} ${FP8BMM:+-e VLLM_ROCM_USE_AITER_FP8BMM=$FP8BMM} ${W8A16:+-e VSH_W8A16=$W8A16} -e PROF=${PROF:-0} -e TBV_STATS_EVERY=${TBV_STATS_EVERY:-0} ${TBV_CPU:+-e TBV_CPU=$TBV_CPU} ${AK:+-e VSH_ADAPTIVE_K=$AK -e VSH_ADAPTIVE_K_DEBUG=1} $( [ "${EAGER:-1}" = 0 ] && printf '%s' '-e VLLM_USE_BREAKABLE_CUDAGRAPH=1' ) -e VLLM_TUNED_CONFIG_FOLDER=/moecfg -e VLLM_LOGGING_LEVEL=INFO \
  $NET "$IMG" timeout -k 15 "$INNER_TO" bash -c "$IN"
