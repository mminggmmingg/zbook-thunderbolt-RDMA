#!/usr/bin/env bash
# 2단계: vllm-strix-halo:ref 위에 전송만 tbv 로 바꾼 vllm-strix-halo:tbv 를 만든다(Dockerfile.tbv).
#   빌드 컨텍스트 = 이 폴더의 Dockerfile.tbv·odl_ar2.py + libtbvcoll 서브모듈 정본 + 호스트 libibverbs v61.
#   (이미지 기본 libibverbs 는 rdma-core 62 라 tbv provider(61 빌드)와 ibv_open_device 에서 segfault 난다.)
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$D/../.." && pwd)"
V=/usr/lib/x86_64-linux-gnu/libibverbs.so.1.15.61.0
[ -f $V ] || { echo "호스트에 $V 없음(Ubuntu 26.04 libibverbs1 61.0 필요)"; exit 1; }
[ -f $ROOT/libtbvcoll/step4/libtbvcoll.cpp ] || { echo "libtbvcoll 서브모듈 없음: git submodule update --init"; exit 1; }
C=$(mktemp -d); trap 'rm -rf "$C"' EXIT
cp $D/Dockerfile.tbv $D/odl_ar2.py $ROOT/libtbvcoll/step4/libtbvcoll.cpp $V $C/
DOCKER_BUILDKIT=0 docker build -t vllm-strix-halo:tbv -f $C/Dockerfile.tbv $C
