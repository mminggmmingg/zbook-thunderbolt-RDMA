#!/usr/bin/env bash
# RCCL all-reduce 시험(A=rank0, B=rank1), GLM 과 같은 이미지·NCCL 설정. 컨테이너 안에서 180 s 제한.
#   run_rccl.sh <라벨>   결과: ../raw/rccl_<라벨>.rank{0,1}.log
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); L=$1; B=parks-zbook@10.99.0.2; BD=/home/parks-zbook/step4-tbthroughput/rccl
IMG=vllm-strix-halo:tbv; OUT=$D/../raw/rccl_$L; mkdir -p "$(dirname "$OUT")"
DK="docker run --rm --name rccltest --device=/dev/kfd --device=/dev/dri --device=/dev/infiniband --group-add video --group-add render
 --network host --ipc=host --ulimit memlock=-1:-1 --security-opt seccomp=unconfined
 -e NCCL_SOCKET_IFNAME=thunderbolt0 -e GLOO_SOCKET_IFNAME=thunderbolt0 -e NCCL_NET_GDR_LEVEL=0 -e NCCL_ALGO=Ring
 -e NCCL_IB_DISABLE=0 -e NCCL_IB_HCA=usb4_rdma0,usb4_rdma5 -e NCCL_IB_GID_INDEX=1 -e NCCL_IB_MERGE_NICS=0 -e NCCL_CROSS_NIC=1
 -e NCCL_MIN_NCHANNELS=2 -e NCCL_MAX_NCHANNELS=2 -e NCCL_DEBUG=INFO -e NCCL_DEBUG_SUBSYS=INIT,NET
 -e HIP_VISIBLE_DEVICES=0 -e MASTER_ADDR=10.99.0.1 -e MASTER_PORT=29555 -e PYTHONFAULTHANDLER=1"
DK=$(echo "$DK" | tr '\n' ' ')   # ssh 로 넘길 때 줄바꿈이 명령을 나누지 않게 한 줄로
ssh -o BatchMode=yes $B "mkdir -p $BD; docker rm -f rccltest >/dev/null 2>&1"; docker rm -f rccltest >/dev/null 2>&1
scp -q "$D/rccl_test.py" "$B:$BD/"
$DK -v "$D":/w -e RANK=0 --entrypoint timeout $IMG -s KILL 180 /opt/venv/bin/python /w/rccl_test.py > "$OUT.rank0.log" 2>&1 &
sleep 2
ssh -o BatchMode=yes $B "$DK -v $BD:/w -e RANK=1 --entrypoint timeout $IMG -s KILL 180 /opt/venv/bin/python /w/rccl_test.py" > "$OUT.rank1.log" 2>&1
wait
grep -E '^\[r0\]|^\[r1\]|Error|error|Timeout|timed out' "$OUT.rank0.log" | head -12
echo "-- rank1: $(grep -E '^\[r1\]' "$OUT.rank1.log" | tr '\n' ' ')"
echo "-- 마지막 NCCL 줄(A): $(grep -E 'NCCL INFO' "$OUT.rank0.log" | tail -1 | cut -c1-160)"
