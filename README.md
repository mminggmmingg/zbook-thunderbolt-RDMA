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
| [`tbthroughput/`](tbthroughput/) | 로드맵 4단계(TB 처리량) 측정 도구와 기록 — perftest 행렬, 송신 CPU 프로파일, 같은 부팅 A/B 모듈 교체 |
| [`engine2n/`](engine2n/) | 로드맵 2단계 — 자체 2노드 TP 엔진(llama.cpp `--split-mode tensor` + tbv RDMA), 우리 llama.cpp 패치·실행기·측정 기록 |

## 구성

| | 노드 A | 노드 B |
|---|---|---|
| 기기 | HP ZBook Ultra G1a 14 (Ryzen AI MAX+ PRO 395, Radeon 8060S gfx1151, 128 GB) | 같음 |
| OS | Ubuntu 26.04.1, 커널 7.0.0-1015-oem | 같음 |
| 메모리 | BIOS VRAM 4 GiB, GTT 112 GiB (`ttm.pages_limit=29360128`) | 같음 |
| 링크 | Thunderbolt 케이블 2개 → RDMA 레일 `usb4_rdma0`, `usb4_rdma5` + 제어용 IP `thunderbolt0` 10.99.0.1 / 10.99.0.2 | |

## 로드맵 진행 상황 (2026-10-27)

진행 순서는 2 → 3 → 1 → 4.

| 단계 | 상태 | 결과 |
|---|---|---|
| **2. LLM TP 벤치마크** | ✅ 완료 | RCCL all-reduce 를 tbv 위에서 실행한 뒤, 자체 all-reduce(libtbvcoll)로 NCCL 보다 빠르게 |
| **3. 실제 LLM 추론** | ✅ 도달 | GLM-5.3-Flash(177.7 GiB, 한 대에 안 들어감)를 vLLM serve(OpenAI API)로 두 대에서 실행, 출력 정상 |
| **1. TB 처리량** | 🔶 상당 부분 | 67 MiB/s 에서 시작 → 2레일 합산 약 20 Gb/s. RX zero-copy·kernel-bypass 는 보류 |
| **4. 링크 2개로 분산 추론** | ✅ 동작 | GLM-5.3 이 두 레일 위에서 22.5~22.7 tok/s(TCP 대비 +21%). RCCL·libtbvcoll 모두 2레일 |

최종 목표 중 **vLLM 외 엔진(llama.cpp, diffusion 등)** 연결은 아직 시작하지 않았다.

## 결과

### Qwen2.5-7B-Instruct, vLLM TP=2 (출력 해시 NCCL 과 동일)

| batch | NCCL (tok/s) | libtbvcoll (tok/s) |
|---|---|---|
| 8 | 175.7 | 194.6 ~ 200.2 |
| 32 | 421 ~ 444 | 626 ~ 639 |
| 128 | 749 ~ 887 | 1174 ~ 1182 |

### GLM-5.3-Flash Uncensored AWQ (W4A16), vLLM TP=2 — 튜닝 결과 (2026-10-27)

랭크당 가중치 82.75 GiB, KV 4 GiB, 최대 문맥 32K. 측정은 `glm53/run/probe.py`: 같은 채팅 요청(256 토큰, 프롬프트 46 토큰) 4회의
tok/s(프롬프트 포함), greedy 완성 3개의 출력 해시, 고정 텍스트 2개의 프롬프트 NLL. 모든 실행에서 양 노드 커널 이상 0.

| 단계 (누적) | 채팅 tok/s | 출력 |
|---|---|---|
| eager, 추측 디코딩 끔 | 9.6 ~ 10.2 | 기준 해시 |
| + PIECEWISE CUDA 그래프 | 11.9 ~ 12.1 | 해시 동일. eager 의 반복 감속(10.2 → 9.6)도 사라짐 |
| + MTP 추측 디코딩 k=3 | 19.0 ~ 19.7 | 해시 동일 |
| + DFlash2 drafter k=3 (MTP 대신) | 20.9 ~ 21.3 | 해시 동일 |
| + `VLLM_ROCM_USE_AITER_FP8BMM=0` | 21.8 ~ 22.3 | 수치 변경(해시 달라짐), NLL ±1% 이내 |
| **+ `VSH_W8A16=1` (최종)** | **22.5 ~ 22.7 (≈2.2×)** | NLL 영 3.59 / 한 2.81 (기준 3.62 / 2.79) |

**전송별 비교** (DFlash2 k=3 + 그래프, 같은 설정): RCCL over TCP 17.3 ~ 17.4 tok/s, **tbv + libtbvcoll 20.9 ~ 21.3 (+21%)**.
eager 때(+15%)보다 차이가 커졌다 — 계산이 줄수록 스텝에서 통신이 차지하는 몫이 커진다.

**reasoning 파서**(`REASONING=1`, glm47 reasoning·tool 파서): 생각 과정은 `reasoning` 필드, 답변은 `content` 로 나뉜다.
기본 강도(max)에서 770 토큰 중 생각 2,454자 / 답변 351자, `content` 에 `<think>` 없음, 22.2 tok/s — 속도·NLL 영향 없음.
`chat_template_kwargs: {"reasoning_effort": "low"}` 면 생각을 거의 건너뛰고 바로 답한다.

CUDA 그래프에서도 TP all-reduce 는 그래프 밖에서 eager 로 돈다(참고 스택의 `vsh-cg-eager-collectives`). 그래서 libtbvcoll 훅이 그대로 쓰인다.

**시도했지만 이득이 없던 것**

| 시도 | 결과 |
|---|---|
| 추측 길이 MTP k=2 / k=4, DFlash2 k=7 | 17.8 / 14.5~14.9 / 14.1~15.1 tok/s — k=3 이 최적 |
| 적응형 추측 길이(`VSH_ADAPTIVE_K=ema`, k ∈ {1,2,3}) | 22.3~22.5 — 차이 없음(참고 스택과 같은 결론) |
| libtbvcoll 진행 스레드 CPU 고정(`TBV_CPU=30`) | 22.4~22.7, 전송 97.7 → 101.5 µs — 차이 없음 |
| iGPU 클럭 상한(참고 스택의 2100 MHz) | 하드웨어 설정은 건드리지 않기로 해서 적용 안 함 |

**8행 검증 그래프에서 greedy 출력이 달라짐(미해결).** MTP k=4 와 DFlash2 k=7 은 drafter·k 가 다른데도 똑같은 3개의 다른 출력을
냈고, TCP 로 돌려도 같았다 — 전송(tbv·libtbvcoll)과 drafter 는 원인이 아니다. 둘 다 본 모델이 8행 그래프로 검증하고, 정상인
k=2·3 은 4행 그래프를 쓴다. 배치 형상에 따른 커널 수치 차이로 보이며(vLLM 은 배치 불변성을 보장하지 않음), 최종 설정 k=3 은 해당 없음.

**통신이 차지하는 몫.** libtbvcoll 구간 측정(`TBV_STATS_EVERY`)으로 디코드 all-reduce 한 번의 전송(피어 대기 포함)은 평균 ≈100 µs,
스텝(≈109 ms)당 ≈85 회 → **통신 ≈8~9 ms(≈8%)**. 작은 메시지의 고정비(≈115 µs, tbv 커널 경로의 인터럽트·softirq)와 같은 범위라,
더 줄이려면 드라이버 쪽(로드맵 4단계)이 필요하다. torch 프로파일러의 GPU 시간은 ROCm 에서 깨져(8 KiB 복사 커널이 8.7 ms 로 기록) 쓰지 않았다.

### 다른 시스템과 비교 (GLM-5.3-Flash, 약 4비트, 1명 사용 디코드, 2026-10-27 조사)

| 시스템 | 메모리 대역폭(대당) | 양자화 / 엔진 | 보고된 디코드 tok/s |
|---|---|---|---|
| **이 저장소: 2× Strix Halo(ZBook) + TB** | ≈256 GB/s ×2 | AWQ W4A16(≈4.7 bpw), vLLM, DFlash2 k=3 | **22.5 ~ 22.7**(생각 포함 채팅) |
| 2× Strix Halo, [참고 스택](https://github.com/davidcanar/vllm-strix-halo) | ≈256 GB/s ×2 | AWQ W4A16, vLLM, DFlash2 k=3 | 산문 19.6~19.9 / JSON 23~27 / 도구 25~29 |
| 2× DGX Spark, [독립 측정](https://dev.classmethod.jp/en/articles/dgx-spark-2node-glm-5-3-flash-nvfp4-vllm/) | 273 GB/s ×2 | NVFP4, vLLM, 추측 없음 → MTP k=3 | 14.6 → 26.5 |
| 2× DGX Spark, [커뮤니티 자체 보고](https://github.com/tonyd2wild/GLM-5.3-Flash-NVFP4-DFlash2-2x-DGX-Spark) | 273 GB/s ×2 | NVFP4, DFlash2 k=7 | 산문 28.4 / 코드 51.9 |
| Mac Studio M3 Ultra 256 GB ([oMLX](https://omlx.ai/benchmarks/performance/f4uqqpai), [rapid-mlx](https://rapidmlx.com/models/glm-5.3-flash)) | ≈819 GB/s | MLX 4비트 | 27.8 ~ 39.6 |
| 1× RTX 3090/5090 + RAM 오프로드 ([strata-glm](https://github.com/sergqwer/strata-glm)) | — | NVFP4, Strata 기반 엔진 | 15 ~ 20 (llama.cpp 2.4~2.9) |

비슷한 대역폭의 2× DGX Spark 와 같은 범위다. 50~60 tok/s 대 수치는 대부분 코드·구조화 출력(추측 채택률이 높음)과 k=7 에서 나왔고,
Mac 은 한 대의 대역폭이 약 3배다. 프롬프트·양자화·k 가 서로 달라 직접 비교는 대략적이다(우리 측정은 채팅 프롬프트 하나, 채택 2.46 토큰/스텝).

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
3. DFlash2 drafter: `incoai/GLM-5.3-Flash-DFlash2`(2.18 GiB, CC BY-NC-ND 4.0)를 양 노드 모델 폴더 옆에 둔다.
4. 실행 (A 에서, 양 노드 컨테이너를 띄우고 시험 요청 후 종료). 최종 설정:
   ```
   MODE=tbv EAGER=0 SPEC=dflash SPEC_K=3 FP8BMM=0 W8A16=1 glm53/run/run_tp2.sh
   ```
   손잡이: `MODE=tcp`(비교 기준선), `EAGER=1`(그래프 끔), `SPEC=none|mtp|dflash`, `REASONING=1`(생각 과정 분리 파서),
   `PROF=1`(torch 프로파일러), `TBV_STATS_EVERY=N`(libtbvcoll 구간 시간), `CHAT_REPS`, `CHAT_FIRST`.
   `TBV_STATS_EVERY` 는 이 저장소의 `glm53/image/odl_ar2.py` 가 들어간 이미지가 필요하다 — `build-tbv-image.sh` 로 다시 빌드하거나,
   `ODLPY=1` 로 그 파일을 마운트한다(B 에는 `~/glm53-run/odl_ar2.py` 로 복사해 둔다).
   양 노드 커널 로그에 tbv/TB 이상이 찍히면 즉시 두 컨테이너를 정리하고, 컨테이너 안에 시간 제한이 있다.
   (호스트 쪽 timeout 만 쓰면 B 컨테이너가 멈춘 QP 를 붙잡고 남아, 케이블 재연결 때 커널 손상까지 간 적이 있다.)

경로·IP·사용자명은 이 두 대 기준으로 스크립트에 들어 있다.

## 참고

- 참고 스택: [davidcanar/vllm-strix-halo](https://github.com/davidcanar/vllm-strix-halo) (Apache-2.0) @ `fe5ac10` — gfx1151 용 vLLM 패치와 OdinLink 전송.
  여기서는 OdinLink 대신 tbv + libtbvcoll 을 쓴다(`odl_ar2.py` 자리에 같은 인터페이스의 libtbvcoll 래퍼).
- 베이스 이미지: `kyuz0/vllm-therock-gfx1151:rocm10.0.0-torch2.11.0-vllm0.30.0`.
- 원본 드라이버: [hellas-ai/thunderbolt-ibverbs](https://github.com/hellas-ai/thunderbolt-ibverbs).

## 다음 로드맵 (2026-10-25 지정, 2026-10-28 갱신)

원래 4단계는 기본 형태로 모두 도달했다. 이어서 이 순서로 진행한다.

| # | 단계 | 내용 |
|---|---|---|
| 1 | **GLM 성능 튜닝** — ✅ 완료(2026-10-27) | 9.6~10.2 → **22.5~22.7 tok/s**(그래프 + DFlash2 k=3 + FP8 BMM 끔 + int8 linear). 위 "튜닝 결과" 참고. reasoning 파서 확인 완료 |
| 2 | **2노드 엔진(자체, TP)** — 🔶 진행 중 | halogen 바이너리 분석 대신 자체 엔진으로 전환(2026-10-29). 원칙: 다중 노드는 TP 만. llama.cpp `e09a78a` 의 `--split-mode tensor` + RPC 서버 2개, 서버 사이 all-reduce 를 tbv RDMA 로. tbv 수정 `9a35117`(여러 프레임 SEND 의 RNR 대기) + llama.cpp 전송·all-reduce 패치. 대리 모델 Qwen3.6-35B-A3B Q4_K_M 2노드: 디코드 24.4 → **50.0 tok/s**(1노드 51.1), prefill 689 → 1050(1노드 1377), PPL 1노드와 0.03% 차. 남은 몫은 부분그래프 계산(배치 1). AR 뒤 발행 겹치기(`GGML_RPC_COMM_OVERLAP`) +4%. **Qwen3.8-Flash-Next UD-IQ4_XS: 1노드 17.5 → 2노드 TP 22.4 tok/s(+28%)**, prefill 471 → 416, PPL 2.1682 / 2.1709(+0.12%). 임계 경로는 B(부분그래프 A 보다 22% 느림, BIOS 차이 추정). 다음 순서(2026-10-29 지정): 분할 비율 조정 → 케이블 2개 → qwen4exp 커널 → Q8_0. 분할: 전문가 FFN 이 256/384 로 번갈아 갈리던 것을 320/320 으로(+2%). GPU 활용: 서버 HIP 그래프가 전체 어텐션 층마다 GPU 를 ≈620 µs 멈춰 끔(21.1 → 21.8 tok/s), 서버 실행 순서를 바꾼 모드 3 은 정확하지만 펌웨어가 CPU 우선으로 바뀌어 GPU 클럭이 2.85 → 2.1 GHz 로 떨어져 느림 — 기본은 모드 2 + 그래프 끔으로 **23.1–24.1 tok/s**. 케이블 2개(b)는 prefill 통신이 케이블이 아니라 노드별 처리에 묶여 이득 없음. 1노드 디코드는 TB DMA 활동이 있을 때만 ≈21–25% 빨라짐. 두 노드 모두 디코드가 ≈22% 느려지는 상태가 있음(원인 미확정, 'B 는 BIOS 탓' 추정 철회). 기록: [`engine2n/`](engine2n/) |
| 3 | **2노드 halogen 을 우리 하드웨어에 맞게 튜닝** | 2×ZBook, gfx1151, TB 2레일 |
| 4 | **TB 처리량 최대화** — ✅ 송신 경로 정리 완료(2026-10-29) | 송신 프로파일로 찾은 병목 3개를 tbv 에서 고침: 정상 완료마다 링 전체 취소 스캔(`4110684`), 두 번째 컨트롤러에서 그 생략이 안 되던 경우(`4c5512b`), MR 복사가 프레임마다 sg 목록을 처음부터 페이지 단위로 걷던 것(`c3429d7`). 2케이블 양방향 1 MiB 1/4 QP 12.0·13.6 → **45.2·45.0 Gb/s**, 단방향 1 MiB 7.8 → 21.5. 이제 크기·QP·방향과 무관하게 케이블당 방향당 ≈11 Gb/s(링 하나의 상한). 무결성 시험(`verify/rdma_verify.c`) 불일치 0. libtbvcoll all-reduce 는 원래 그 상한에 붙어 있어 그대로(4 MiB ≈21–23 Gb/s). 상한을 더 올리려면 케이블당 링 2개(lanes=2, thunderbolt0 링 충돌로 보류). 기록: [`tbthroughput/NOTES.md`](tbthroughput/NOTES.md) |
| 5 | **다시 LLM 돌려보기** — ✅ GLM 재실행(2026-10-29) | 새 tbv(`c3429d7`)로 GLM-5.3 같은 설정: 22.31–22.61 tok/s(이전 22.48–22.71), greedy 해시·NLL 비트 동일. 디코드 통신은 8 KiB all-reduce(얕은 큐)라 4단계 수정이 겨냥한 병목을 밟지 않아 변화 없음 — 예상대로. 다음 레버는 모델 안 all-reduce 1회 ≈100 µs vs 단독 ≈20 µs 의 차이. 두 노드가 다른 망일 때 vLLM 초기화가 멈추던 것은 `VLLM_HOST_IP`=TB IP 로 해결 |

5단계 다음에는 Strata·Gufo·halogen 의 장점을 합쳐 CPU·GPU·NPU 를 함께 쓰는 자체 LLM 엔진을 만든다(구상 단계).
NPU 쪽은 전원·클럭 설정을 바꿔야 하는 부분이 있어, 하드웨어 설정을 건드리지 않는 범위에서 검토한다.

### 2단계 진행 (2026-10-28)

- 이미지 `ghcr.io/peonist-ai/halogen-flash-server:0.18.17` 을 받아 실행하지 않고 내용만 확인했다. 서버 `flash_serve`(32.5 MB, 대부분 GPU 커널)는
  HIP·hipBLASLt 만 링크하고 NCCL·RDMA·노드 간 통신 코드가 없다 — 2노드 경로는 새로 붙여야 한다.
- halogen 자체 체크포인트를 받아 크기·sha256 을 확인했다: `qwen38-flash-next-v2.hgn` 62.1 GiB(가중치 평균 4.16 bit) +
  n-gram 표 `qwen38-flash-next-ngram.hgn` 47.7 GiB(메모리에 상주하지 않고 필요할 때 읽음). 이 조합은 한 대에 들어가므로 기준선으로 쓴다.
  2노드가 필요한 Q8_0 GGUF(≈188 GB)는 아직 받지 않았다.
- 다음: GPU 호출(HIP API) 기록 → REA 로 layer 루프·가중치 로더·`.hgn` 형식·KV 관리 분석 → 두 노드 분할 방식 결정.

#### halogen 1노드 기준 측정 (노드 A, 2026-10-28)

기본 설정 그대로(4 slots, ctx 262144, MTP 켬, NPU 끔, 컨테이너 권한 상승 없음), Docker 로 A 한 대에서 실행.

| 항목 | 결과 |
|---|---|
| 기동 | 요청을 받기까지 **26 s**(모델 파일이 page cache 에 있던 상태. 디스크에서 읽는 기동은 미측정) |
| 메모리 | 엔진이 쥔 양 **89.0 GiB** = 가중치 62.1 + KV pool 14.4 + 작업용 12.5. n-gram 표 47.7 GiB 는 상주하지 않음 |
| 우리 chat 프롬프트(256 토큰, greedy, 4회) | 엔진 디코드 **53.8~59.0 tok/s**, 프롬프트 포함 벽시계 53.7~55.9 tok/s. 4회 출력 동일 |
| halogen 자체 bench(10개 프롬프트, 256 토큰, greedy) | MTP 평균 **59.6 tok/s**(50.7~69.7). MTP 없이 36.8~37.7 tok/s. 두 방식 출력 byte-identical |
| 정지 후 | GTT 27.2 → 0.08 GiB, 전부 회수 |

- 4비트 v2 는 한 대에 여유 있게 들어간다. 2노드가 필요한 것은 Q8_0(≈188 GB) 같은 큰 체크포인트나 긴 context·많은 동시 요청이다.
- 한계: 256 토큰 제한 때문에 서버가 생각(thinking) 블록을 첫 토큰에서 닫았다. 긴 생각·긴 입력·동시 요청은 측정하지 않았다.
- GLM-5.3(2노드 22.5~22.7 tok/s)과는 모델이 달라 직접 비교하지 않는다.

halogen 은 소스 비공개(바이너리 배포)다. 라이선스는 리버스 엔지니어링을 금지하지 않고 자기 사본 수정을 허용하지만,
수정한 이미지나 거기서 나온 커널·소스의 배포는 금지한다 — 2노드 halogen 결과물은 비공개로 둔다.

그 밖에: 출력 오염 결함이 6.17 커널에서도 있었는지 확인.
