#!/usr/bin/env bash
# llama.cpp(HIP gfx1151 + RPC + Linux RDMA 전송) 빌드 — 사용자 승인 후 실행.
# 호스트 ROCm 7.2.1 에는 hipcc 가 없어 같은 ROCm 7.2.1 컨테이너(rocm/vllm-dev:rocm7.2.1)에서 빌드한다.
# RDMA 전송(GGML_RPC_RDMA)은 libibverbs 가 있어야 켜지므로 호스트의 헤더·라이브러리(v61, tbv provider 와 같은 판)를 읽기 전용으로 넣는다.
# 결과 바이너리는 호스트 /opt/rocm/lib(gfx1151 rocBLAS·hipBLASLt 커널 있음)로 실행하는 것을 먼저 시도한다.
#   build_llama.sh            → llama.cpp/build-rocm/bin/{llama-server,llama-cli,llama-bench,llama-perplexity,ggml-rpc-server}
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); SRC=${SRC:-$D/llama.cpp}; IMG=rocm/vllm-dev:rocm7.2.1_v0.18.0_20260330
V=/usr/lib/x86_64-linux-gnu/libibverbs.so.1.15.61.0
docker run --rm --user "$(id -u):$(id -g)" -v "$SRC":"$SRC" -w "$SRC" \
  -v /usr/include/infiniband:/usr/include/infiniband:ro \
  -v $V:$V:ro -v $V:/usr/lib/x86_64-linux-gnu/libibverbs.so.1:ro -v $V:/usr/lib/x86_64-linux-gnu/libibverbs.so:ro \
  --entrypoint bash "$IMG" -c '
    export HOME=/tmp
    cmake -S . -B build-rocm -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1151 -DGPU_TARGETS=gfx1151 \
      -DGGML_RPC=ON -DGGML_RPC_RDMA=ON -DLLAMA_CURL=OFF -DBUILD_SHARED_LIBS=OFF \
      -DCMAKE_C_COMPILER=/opt/rocm/llvm/bin/clang -DCMAKE_CXX_COMPILER=/opt/rocm/llvm/bin/clang++ &&
    cmake --build build-rocm -j 24 --target llama-server llama-cli llama-bench llama-perplexity ggml-rpc-server' \
  > "${LOG:-$D/build-hip.log}" 2>&1
echo "rc=$?"; tail -3 "${LOG:-$D/build-hip.log}"
grep -E 'GGML_RPC_RDMA|RDMA' "$SRC/build-rocm/CMakeCache.txt" 2>/dev/null | head -3
ls -la "$SRC/build-rocm/bin/" 2>/dev/null
