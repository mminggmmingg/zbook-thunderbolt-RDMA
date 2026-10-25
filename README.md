# zbook-thunderbolt-RDMA

HP ZBook Ultra G1a 두 대를 **Thunderbolt 케이블 2개**로 묶어, 한 대에 들어가지 않는 LLM 을 두 대에서 나눠 돌리는 프로젝트의
루트 저장소다. 실제 코드는 두 서브모듈에 있고, 여기에는 둘을 묶는 실행 구성(GLM-5.3)과 진행 기록이 있다.

```
git clone --recurse-submodules <이 저장소>
```

| 경로 | 내용 |
|---|---|
| [`tbv/`](https://github.com/mminggmmingg/thunderbolt-ibverbs-zbook/tree/zbook-gpu-direct-fixes) | **thunderbolt-ibverbs-zbook** — USB4/Thunderbolt NHI 위의 RDMA(ibverbs) 커널 드라이버와 rdma-core provider. ZBook 용 수정(dma-buf GPU 직통, 2레일, 크레딧 교착 수정, thunderbolt 코어 패치) |
| [`libtbvcoll/`](https://github.com/mminggmmingg/libtbvcoll) | **libtbvcoll** — tbv 위의 2랭크 TP all-reduce 라이브러리(HIP, gfx1151). vLLM 의 디코드 all-reduce 를 NCCL 대신 처리 |
| [`glm53/`](glm53/) | GLM-5.3-Flash TP=2 실행 구성 — 참고 스택 이미지 위에 전송만 tbv+libtbvcoll 로 바꾼 오버레이, 2노드 실행기 |
| [`host/`](host/) | 양 노드에 설치된 bring-up 스크립트·systemd·udev·모듈 옵션 |

## 구성

| | 노드 A | 노드 B |
|---|---|---|
| 기기 | HP ZBook Ultra G1a 14 (Ryzen AI MAX+ PRO 395, Radeon 8060S gfx1151, 128 GB) | 같음 |
| OS | Ubuntu 26.04.1, 커널 7.0.0-1015-oem | 같음 |
| 메모리 | BIOS VRAM 4 GiB, GTT 112 GiB (`ttm.pages_limit=29360128`) | 같음 |
| 링크 | Thunderbolt 케이블 2개 → RDMA 레일 `usb4_rdma0`, `usb4_rdma5` + 제어용 IP `thunderbolt0` 10.99.0.1 / 10.99.0.2 | |

## 로드맵 진행 상황 (2026-10-25)

진행 순서는 2 → 3 → 1 → 4.

| 단계 | 상태 | 결과 |
|---|---|---|
| **2. LLM TP 벤치마크** | ✅ 완료 | RCCL all-reduce 를 tbv 위에서 실행한 뒤, 자체 all-reduce(libtbvcoll)로 NCCL 보다 빠르게 |
| **3. 실제 LLM 추론** | ✅ 도달 | GLM-5.3-Flash(177.7 GiB, 한 대에 안 들어감)를 vLLM serve(OpenAI API)로 두 대에서 실행, 출력 정상 |
| **1. TB 처리량** | 🔶 상당 부분 | 67 MiB/s 에서 시작 → 2레일 합산 약 20 Gb/s. RX zero-copy·kernel-bypass 는 보류 |
| **4. 링크 2개로 분산 추론** | 🔶 동작 | GLM-5.3 이 두 레일 위에서 실행(RCCL·libtbvcoll 모두 2레일). 남은 일은 성능 |

최종 목표 중 **vLLM 외 엔진(llama.cpp, diffusion 등)** 연결은 아직 시작하지 않았다.

## 결과

### Qwen2.5-7B-Instruct, vLLM TP=2 (출력 해시 NCCL 과 동일)

| batch | NCCL (tok/s) | libtbvcoll (tok/s) |
|---|---|---|
| 8 | 175.7 | 194.6 ~ 200.2 |
| 32 | 421 ~ 444 | 626 ~ 639 |
| 128 | 749 ~ 887 | 1174 ~ 1182 |

### GLM-5.3-Flash Uncensored AWQ (W4A16), vLLM TP=2

랭크당 가중치 82.75 GiB, KV 4 GiB, 최대 문맥 32K. **eager 실행, 추측 디코딩 끔** 상태의 기준값.

| 전송 | 채팅 256 토큰 | 출력 |
|---|---|---|
| RCCL over TCP (thunderbolt0) | 8.9 tok/s | 기준 |
| RCCL over tbv IB + libtbvcoll | **9.6 ~ 10.4 tok/s** | greedy 완성 3개 해시가 TCP 와 동일 |

참고 스택은 CUDA 그래프 + MTP/DFlash2 추측 디코딩으로 20~28 tok/s 를 보고한다 — 다음 작업.

## 고친 결함

| 결함 | 증상 | 원인 | 수정 위치 |
|---|---|---|---|
| 출력 오염 | libtbvcoll ASYNC 에서 간헐적으로 문장이 깨짐 | 송신 바운스(hipMalloc, MTYPE NC)에 GPU 가 쓴 값이 `__threadfence_system` 뒤에도 NHI DMA 에 안 보임 | libtbvcoll `TBV_UNCACHED` 기본 1(송신 버퍼 비캐시) |
| 크레딧 교착 | batch 128 에서 레일 정지(`tx_credits 0/768`) | raw stream 중 제어 큐(크레딧 반환)가 막히는데 시작 크레딧은 32 만 요구 | tbv `kernel/path.c` (8ee9b96) |
| 부팅 30초 지연 | 케이블 없이 부팅하면 30초 멈춤 | bring-up 스크립트가 피어 없이 링크를 기다림 | [`host/sbin/tbv-multirail-up.sh`](host/) v3 |
| 독 연결 후 종료 멈춤 | TB 독을 꽂았다 뺀 뒤 재부팅이 영원히 멈춤 | DP 터널 DPRX 취소 시 도메인 참조 누수 + OEM 커널이 백포트한 `domain_released` 대기 | 업스트림 v7.3 수정 3개 백포트 (tbv `kernel-workflow/patches`, b9a5032). Launchpad 에 신고 |
| ibverbs segfault | 컨테이너 안 RCCL 이 `ibv_open_device` 에서 죽음 | 이미지 libibverbs(rdma-core 62) ↔ provider(61 빌드) 내부 구조 불일치 | 이미지에 v61 내장 (`glm53/image/Dockerfile.tbv`) |
| 요청 경계 정지 | GLM-5.3 에서 새 요청 prefill 직후 GPU 영구 대기 | 호스트가 슬롯 재사용 때 `rails_done` 을 지워, 1레일 디코드→2레일 prefill 전환에서 rail1 완료가 누락 → gflag 미기록 | libtbvcoll (deaa5b2). GPU 발자국 진단으로 확인 |

## GLM-5.3 재현

1. 모델: `hell0ks/GLM-5.3-Flash-Uncensored-AWQ` 를 양 노드에 둔다(A `/data/parksThink/hf-models/`, B `~/models/`).
2. 이미지 (A 에서 빌드 후 B 로 `docker save | ssh B docker load`):
   ```
   glm53/image/build-ref.sh         # 참고 스택 그대로 → vllm-strix-halo:ref (vLLM 73859fec 소스 빌드, ~12분)
   glm53/image/build-tbv-image.sh   # 전송 교체 → vllm-strix-halo:tbv
   ```
3. 실행 (A 에서, 양 노드 컨테이너를 띄우고 시험 요청 후 종료):
   ```
   MODE=tbv glm53/run/run_tp2.sh    # MODE=tcp 는 비교용 기준선
   ```
   양 노드 커널 로그에 tbv/TB 이상이 찍히면 즉시 두 컨테이너를 정리하고, 컨테이너 안에 시간 제한이 있다.
   (호스트 쪽 timeout 만 쓰면 B 컨테이너가 멈춘 QP 를 붙잡고 남아, 케이블 재연결 때 커널 손상까지 간 적이 있다.)

경로·IP·사용자명은 이 두 대 기준으로 스크립트에 들어 있다.

## 참고

- 참고 스택: [davidcanar/vllm-strix-halo](https://github.com/davidcanar/vllm-strix-halo) (Apache-2.0) @ `fe5ac10` — gfx1151 용 vLLM 패치와 OdinLink 전송.
  여기서는 OdinLink 대신 tbv + libtbvcoll 을 쓴다(`odl_ar2.py` 자리에 같은 인터페이스의 libtbvcoll 래퍼).
- 베이스 이미지: `kyuz0/vllm-therock-gfx1151:rocm10.0.0-torch2.11.0-vllm0.30.0`.
- 원본 드라이버: [hellas-ai/thunderbolt-ibverbs](https://github.com/hellas-ai/thunderbolt-ibverbs).

## 다음 로드맵 (2026-10-25 지정)

원래 4단계는 기본 형태로 모두 도달했다. 이어서 이 순서로 진행한다.

| # | 단계 | 내용 |
|---|---|---|
| 1 | **GLM 성능 튜닝** | GLM-5.3-Flash TP=2 (현재 eager·추측 디코딩 끔 9.6~10.4 tok/s). PIECEWISE CUDA 그래프, MTP/DFlash2, reasoning 파서, 반복 시 감속(10.2 → 9.6) 원인 |
| 2 | **halogen flash server 로 Qwen 3.8 Flash Next Q8 돌리기** | vLLM 외 두 번째 엔진 |
| 3 | **halogen server 를 우리 하드웨어에 맞게 튜닝** | 2×ZBook, gfx1151, TB 2레일 |
| 4 | **TB 처리량 최대화** | 원래 1단계의 남은 레버: RX zero-copy, credit, kernel-bypass |
| 5 | **다시 LLM 돌려보기** | 4 의 개선을 실제 추론으로 재검증 |

그 밖에: 출력 오염 결함이 6.17 커널에서도 있었는지 확인.
