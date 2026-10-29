# 자체 2노드 엔진 — Qwen3.8-Flash-Next, 텐서 병렬(TP) (설계 v1, 2026-10-29)

원칙: **다중 노드는 TP 만 쓴다**(사용자 결정 2026-10-29). 층 분할(PP)은 쓰지 않는다 — 이전 v0 는 `DESIGN_v0_pp.md` 에 기록으로만 남김.
목표: 두 GPU 가 매 층을 반씩 나눠 계산해 **디코드 속도를 1노드보다 올리고**, 한 대에 안 들어가는 Q8_0(188.2 GB)도 돌린다.
출처 원칙: 공개 자료만 — 공식 config/모델 카드, vLLM 레시피, llama.cpp(MIT) 소스, 우리 측정. 닫힌 바이너리 분석 결과는 쓰지 않는다.

## 1. 모델 (공개 자료로 확인)
- 48층(GDN 36 + QSA 12), hidden 2560, vocab 248,320. GDN: key head 16·value head 48, dim 128. QSA: 24 head, KV 2, head dim 256, indexer 4 head.
- MoE 512 전문가·활성 10, 전문가 FFN 640 + 공유 전문가 640. 4갈래 hyper-connection. N-gram 표 51B(PLE 로 GDN 층 하나에 주입). MTP 1층.
- 토큰당 활성 ≈6B. vLLM 레시피: TP/TEP 지원(PP 는 미지원).

## 2. 바탕: llama.cpp `--split-mode tensor` (소스 확인, e09a78a)
- `llm_arch_supports_sm_tensor()` 의 제외 목록에 qwen4exp 가 없다 → 허용. `llama-model.cpp:639-` 에 **qwen4exp 전용 분할 규칙**이 있다
  (Q-gate 가 붙은 fused QKV, GDN key/value head 차원). 전문가 FFN 은 up/gate 를 축 1, down 을 축 0 으로 나눔(전문가 내부 TP).
  분할 규칙이 없는 텐서는 양쪽에 복제(MIRRORED). TP 에는 flash attention 이 필수(`llama-context.cpp:4067`).
- 실행 구조(`ggml-backend-meta.cpp`): 한 그래프를 장치별 조각으로 나눠 동시에 계산, 부분합 지점마다 all-reduce.
  독립 가지의 AR 은 합쳐서 한 번에(`AllReduce(a)+AllReduce(b)==AllReduce(a+b)`, `:2160`) → 층당 대략 2번(어텐션 뒤, MoE+공유전문가 뒤).
- 2노드 AR 경로(`ggml-rpc.cpp:2227-2400`): **rpc-server 두 개가 서로 직접 연결**(COMM_INIT, world=2)하고 COMM_ALLREDUCE 마다
  GPU 동기화 → GPU→호스트 복사 → 상대와 send/recv → 호스트→GPU → 더하기. 32768 원소 이상만 bf16 로 줄여 보냄(디코드 크기는 f32).
  이 피어 연결도 같은 전송 계층을 쓰므로 RDMA(tbv) 로 붙을 수 있다(실측 필요).
- 같은 종류 장치끼리만 전용 AR 을 쓴다(`:1859`, 첫 장치의 reg 에서 comm_init 조회). 섞이면 일반 fallback(클라이언트 경유 복사).
  → **두 장치 모두 RPC 로** 맞춘다.

## 3. 구성
```
A: llama-server/bench (클라이언트, 입력 임베딩 + n-gram 표는 A CPU 에서 lazy mmap)
     ├─ RPC → rpc-server A (127.0.0.1:50052, rank 1, A GPU, 각 층의 절반)
     └─ RPC → rpc-server B (10.99.0.2:50052, rank 0, B GPU, 각 층의 절반)
              rpc-server A ⇄ rpc-server B : 층마다 all-reduce (tbv)
```
- 장치 지정: `--rpc 10.99.0.2:50052,127.0.0.1:50052 -sm tensor -dev RPC0/RPC1` (이름은 --rpc 순서대로 RPC0=B, RPC1=A). **B 를 rank 0 으로**:
  rank 1 이 rank 0 의 등록 주소 + 1000 포트(51052)로 붙으므로(`ggml-rpc.cpp:3019`) A 서버는 B:51052 로 나가 tbv RDMA 를 쓰고,
  클라이언트→A 서버는 localhost TCP 가 된다. (A 서버를 10.99.0.1 로 등록하면 클라이언트↔A 서버가 tbv 루프백 RDMA 로 협상되는데
  tbv 는 같은 노드 안 QP 연결을 못 해 `transport retry counter exceeded` 로 죽었다 — 2026-10-29 실측.)
- 모델 파일은 A 에만 둔다(가중치 조각은 로드 때 RPC 로 전송). Q8 이면 노드당 ≈(188−표 54)/2 ≈ 67 GB + 복제 텐서 + KV → GTT 112 GiB 안(추정).
  n-gram 표는 A 의 페이지 캐시로 필요한 행만 읽는다(디스크 읽기 지연은 실측).

## 4. 성능 예산 (추정 — 핵심은 AR 지연)
- 디코드는 메모리 대역폭에 묶임. TP=2 면 노드당 읽는 가중치가 반 → 계산 시간 ≈ 1노드의 절반.
- 대신 토큰당 AR ≈ 48층 × 2 ≈ 96회(+MTP). 한 번에 2560×f32 = 10 KiB.
  - AR 20 µs(우리 libtbvcoll 단독 측정 수준) → 토큰당 ≈2 ms → Q4 에서 **1노드의 약 1.6–1.8배** 가능.
  - AR 200 µs(복사·동기화·RPC 명령이 쌓인 경우) → 토큰당 ≈19 ms → 1노드보다 느림.
- 그러므로 **엔진 안 AR 지연을 20–30 µs 로 만드는 것이 이 프로젝트의 본체**. GLM 에서 본 "모델 안 AR 100 µs vs 단독 20 µs" 와 같은 문제다.

## 5. 단계와 완료 기준
| 단계 | 내용 | 필요 | 완료 기준 |
|---|---|---|---|
| T0 | llama.cpp 빌드(HIP gfx1151 + RPC + RDMA) | **빌드 승인** | rpc-server·llama-server·llama-bench 생성, RDMA 전송 포함 |
| T1 | Q4(111.3 GB) 받기 → A 1노드 기준(`-sm none`) | **다운로드 승인** | tok/s·prefill, greedy 기준 출력 저장 |
| T2 | A 혼자 TP 점검: rpc-server 2개를 A 에 띄우고 `-sm tensor` | — | qwen4exp TP 경로가 돌고 greedy 출력이 T1 과 같음(B 없이 정합성 먼저) |
| T3 | tbv SEND 경로 확인(`ib_send_bw/lat`, rdma_verify SEND) | **B 켜기** | 오류 0, 지연·대역폭 기록 |
| T4 | 2노드 TP Q4 기본 경로(TCP → RDMA) | — | T1 과 같은 출력, tok/s, 토큰당 AR 횟수·AR 1회 지연 측정 |
| T5 | **AR 교체**: rpc-server 의 COMM_ALLREDUCE 를 tbv 직접 경로로(미리 등록한 버퍼, WRITE_WITH_IMM, 불필요한 동기화·복사 제거) | — | AR 1회 ≤30 µs(엔진 안), 2노드 Q4 tok/s > 1노드 |
| T6 | Q8(188.2 GB) 받기 → 2노드 TP Q8 | 다운로드 승인 | 실행, perplexity/NLL |
| T7 | 다음 개선 | — | 2케이블 멀티레일, 클라이언트 명령 왕복 줄이기, MTP 추측 디코딩 |

## 6. 위험과 미확인
- qwen4exp 의 TP 분할 규칙이 hyper-connection·PLE·QSA indexer 를 모두 맞게 다루는지는 실행 전 미확인 → T2 에서 1노드 출력과 비교.
- flash attention 필수: gfx1151 HIP 에서 QSA(head dim 256, sparse indexer)와 함께 되는지 미확인.
- 클라이언트가 AR 마다 두 서버에 RPC 명령을 보내는 구조라, 명령 왕복이 AR 지연에 더해질 수 있다 → T4 에서 분리 측정. 크면 T5/T7 에서 서버 쪽으로 옮김.
- tbv 에서 llama.cpp RDMA 전송(256 KiB SEND, 수신 24개 미리 게시, CQ 이벤트)은 실측 전. 오늘 검증한 건 WRITE/READ 계열뿐 → T3.
- 호스트 ROCm 7.2.1 에 hipcc 없음 → `rocm/vllm-dev:rocm7.2.1` 컨테이너에서 빌드, 실행은 호스트 `/opt/rocm/lib` 로 먼저 시도.
- 대안(참고): vLLM 도 이 모델의 TP 를 지원하지만, 보유 이미지 v0.18.0 이 이 모델을 지원하는지, gfx1151 FP8 가 되는지 불확실하고 BF16/FP8 가중치(173–335 GB) 추가 다운로드가 필요하다.
