> **폐기된 v0 (층 분할 = PP).** 사용자 원칙: 다중 노드는 TP 만 쓴다(2026-10-29). 현재 설계는 DESIGN.md(v1, TP).

# 자체 2노드 엔진 — Qwen3.8-Flash-Next 를 두 ZBook 에 나눠 돌리기 (설계 v0, 2026-10-29 밤)

목표: 한 대(GTT 112 GiB)에 안 들어가는 Qwen3.8-Flash-Next **Q8_0(≈188 GB)** 를 두 노드에 층 단위로 나눠, tbv(USB4 RDMA)로 잇는다.
1노드 실행(Q4)도 같은 엔진으로 유지. 이후 자체 CPU·GPU·NPU 엔진의 바탕.

출처 원칙: 공개 자료만 쓴다 — 공식 config/모델 카드, vLLM 레시피, llama.cpp(MIT) 소스, 우리 측정. 닫힌 바이너리 분석 결과는 쓰지 않는다.

## 1. 모델 (공개 자료로 확인)
공식 `Qwen/Qwen3.8-Flash-Next` config.json, vLLM 레시피(recipes.vllm.ai/Qwen/Qwen3.8-Flash-Next):
- 48층, hidden 2560, vocab 248,320, 문맥 262,144. 4층마다 3층 Gated DeltaNet(선형, 16 key·48 value head, dim 128, conv 4, 상태 fp32),
  1층 Qwen Sparse Attention(24 head, KV 2, head dim 256, partial rotary 0.25, θ 1e7; indexer budget 2048, compress 4, 4 head·dim 128).
- MoE 512 전문가·활성 10, 전문가 FFN 640 + 공유 전문가 640. 잔차는 4갈래 hyper-connection(low-rank 320).
- N-gram 임베딩(n=3, 기본 vocab 2천만, n-gram 당 8 head, 128 분할) — 51B 파라미터 표, PLE 로 한 층에 주입. MTP 1층.
- 총 125B(표 51B 포함), 토큰당 활성 ≈6B. BF16 335 GiB, FP8 173 GiB.
- vLLM: TP/TEP 지원, **"N-gram Embedding does not initially support pipeline parallelism"** — 층 분할(PP)은 미지원.

## 2. 바탕 선택: llama.cpp (ggml) + RPC
- llama.cpp 본선(확인 커밋 `e09a78a`, 2026-10-29)에 `qwen4exp` 가 있다(`src/models/qwen4exp.cpp` 1560줄: hyper-connection, QSA indexer, PLE n-gram).
  GGUF: unsloth `Qwen3.8-Flash-Next-GGUF` — UD-Q4_K_XL 111.3 GB, Q8_0 188.2 GB, MTP shared Q8_0 2.79 GB.
- **RPC 백엔드**(`ggml/src/ggml-rpc/`)가 원격 장치를 ggml 장치로 붙이고 층을 장치별로 나눈다(`--rpc HOST:PORT`, layer split).
  전송 계층이 분리돼 있고(`transport.h`: send_data/recv_data/flush + caps 협상), **Linux RDMA 전송이 이미 있다**
  (`transport.cpp`, `GGML_RPC_RDMA`, libibverbs 있으면 자동 ON): RC QP, SEND/RECV, 256 KiB 청크, 수신 24개 미리 게시(6 MiB, 기본 memlock 안),
  CQ 이벤트 채널로 유휴 시 잠듦, `GGML_RDMA_DEV`/`GGML_RDMA_GID` 또는 **TCP 소켓의 로컬 주소와 같은 GID 를 자동 선택**.
- tbv 호환성(코드 대조): CQ 알림 지원(`usb4_rdma_req_notify_cq`, 커널 comp_handler) ✓. `max_inline_data` 는 tbv 가 0 으로 돌려주고 llama.cpp 는
  생성 후 값을 다시 읽으므로 inline 을 안 쓸 뿐 ✓. RoCE v2 GID 는 thunderbolt0 IPv4(10.99.0.x) → RPC 를 10.99.0.x 로 붙이면 자동 매칭 ✓(실측 필요).
- 그 밖에 `RPC_CMD_COMM_INIT/ALLREDUCE` 가 있어 텐서 병렬 경로도 있다(나중에 libtbvcoll 로 대체 후보).
- 무게: 원격 층 가중치는 로드 때 RPC `SET_TENSOR` 로 B 에 보낸다 → **모델 파일은 A 에만 있으면 된다**(Q8 의 절반 ≈94 GB 를 tbv 로 한 번 전송,
  10 Gb/s 면 ≈80 s). rpc-server 의 로컬 캐시 옵션으로 두 번째부터 줄일 수 있다.

## 3. 2노드 구성
```
A (llama-server, 층 0..k-1 + 임베딩 + n-gram 표 + 출력·MTP)  ──RPC(RDMA over tbv, 10.99.0.x)──  B (rpc-server, GPU, 층 k..47)
```
- 나눔: 층당 크기가 거의 같으므로 ≈24/24 에서 시작(`-ts` 로 비율 조정). n-gram 표(≥4-bit, mmap)는 A 의 호스트 메모리/디스크.
- 토큰당 경계 전송: hyper-connection 잔차 4×2560(llama.cpp `n_embd_out_impl = hc_mult × n_embd`), RPC 명령 몇 번 왕복.
  우리 측정으로 tbv 왕복 ≈20 µs(8 KiB) — 토큰당 ≈30 ms 대비 무시 가능. prefill 은 큰 텐서라 대역폭(케이블당 ≈11 Gb/s/방향)이 중요.
- **이 구성은 층 분할, 즉 PP 방식이다.** vLLM 의 "n-gram 은 PP 미지원" 과 겹치는 지점:
  - (소스 확인) llama.cpp 는 한 그래프를 스케줄러가 장치별로 자르고, 경계를 넘는 텐서는 자동 복사한다. n-gram 표(`per_layer_tok_embd`)는 층 텐서가 아니고
    `TENSOR_READ_LAZY`(mmap 에서 필요한 행만 읽음)로 입력 쪽(A)에 놓이며, 조회는 토큰 임베딩과 같은 분할에서 한다(`qwen4exp.cpp:468-472`).
    주입 층(GDN 층 하나, conv 기록은 그 층의 recurrent 캐시)이 B 에 있으면 조회 결과가 A→B 로 한 번 더 넘어갈 뿐이다.
  - (추론) vLLM 제한은 단계 사이에 고정된 텐서(hidden/residual)만 넘기는 구현 때문으로 보인다 — vLLM 문서에 이유는 없다.
  - (미확인) 주입 층 번호는 GGUF 메타데이터(`PLE_LAYERS`)에 있다 → 받은 뒤 확인. 2노드 정합성은 E4 에서 1노드와 greedy 출력 비교로 판정.
- 한 요청 디코드는 A 다음 B 가 차례로 계산한다(동시 실행 없음). **2노드로 얻는 것은 메모리(Q8 수용)이고 디코드 속도는 오르지 않는다** —
  같은 양자화면 1노드 속도 − 경계 전송·RPC 비용. 속도를 올리려면 TP(층마다 all-reduce) 가 필요하고, 그건 E6 이후 과제.

## 4. 단계와 완료 기준
| 단계 | 내용 | 필요 | 완료 기준 |
|---|---|---|---|
| E1 | llama.cpp HIP(gfx1151)+RPC+RDMA 빌드 | **사용자 승인**(외부 코드 빌드 — 자동 권한 검사가 막음) | rpc-server·llama-server·llama-bench 생성, RDMA 전송 포함 확인 |
| E2 | GGUF 받기: UD-Q4_K_XL(111.3 GB) → A | **다운로드 승인** | sha/크기 확인 |
| E3 | A 1노드 Q4: llama-bench / server | — | tok/s·prefill, 출력 정상(halogen 1노드 54–60 tok/s 와 비교) |
| E4 | A+B 2노드 Q4(RPC, TCP 먼저 → RDMA) | **B 켜기** | 1노드와 같은 출력(greedy), 전송 경로가 RDMA 인지 로그 확인, tok/s |
| E5 | Q8_0(188.2 GB) 받기 → 2노드 Q8 | 다운로드 승인 | 한 대에 안 들어가는 Q8 실행, 품질(NLL/perplexity) |
| E6 | 우리 쪽 개선 | — | 2케이블(멀티레일) RDMA 전송, 지연(폴링/이벤트) 조정, 여러 요청 파이프라인, MTP 위치 |

## 5. 위험과 미확인
- RPC 의 토큰당 오버헤드(그래프 직렬화·왕복 수)가 생각보다 크면 디코드가 느려진다 → E4 에서 측정, 필요하면 그래프 캐시/명령 묶기.
- llama.cpp qwen4exp 의 ROCm(gfx1151) 커널 성능은 미측정. 1노드 성능이 halogen 보다 낮을 수 있다(전용 커널 대비).
- tbv 위 RDMA 전송은 실측 전. CQ 이벤트 경로, 256 KiB SEND 와 수신 미리 게시 깊이 24 가 tbv 크레딧과 맞는지 E4 에서 확인.
- 호스트 ROCm 7.2.1 에는 hipcc 가 없다 → `rocm/vllm-dev:rocm7.2.1` 컨테이너에서 빌드(같은 ROCm 7.2.1). 실행은 같은 컨테이너, 또는
  호스트 런타임(`/opt/rocm/lib`) 로 가능한지 E1 에서 확인. B 에 이미지가 없으면 바이너리만 옮기는 쪽을 먼저 본다.

## 6. llama.cpp RDMA 전송을 tbv 에 붙일 때 확인할 것 (코드 읽음, 실측 전)
- QP: RC, timeout 14(≈67 ms), retry 7, rnr_retry 7, min_rnr_timer 1. 송신 = 256 KiB **SEND**(signaled; inline 은 max_inline 이하일 때만 — tbv 는 0),
  수신 = 256 KiB × 24 미리 게시. 100 ms 동안 바쁜 폴링, 그 뒤 CQ 이벤트(`ibv_req_notify_cq`/`ibv_get_cq_event`).
- 오늘 새 tbv(c3429d7) 로 검증한 것은 WRITE·READ·WRITE_WITH_IMM(rdma_verify, perftest write, libtbvcoll, RCCL). **SEND 경로는 따로 안 봤다** →
  E4 전에 `ib_send_bw`/`ib_send_lat` 와 rdma_verify 에 SEND 를 더해 확인.
- 단일 장치·단일 QP 라 케이블 하나만 쓴다(≈11 Gb/s/방향). 2케이블은 E6 에서(장치 2개에 연결을 나누거나 청크를 번갈아 보내기).
