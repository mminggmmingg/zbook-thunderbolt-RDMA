# engine2n 측정 기록

## 2026-10-29 — 빌드, 대리 모델(Qwen3.6-35B-A3B Q4_K_M, qwen35moe)로 TP 경로 점검 (A 단독, B 꺼짐)
- 빌드: llama.cpp e09a78a, `build_llama.sh` → `llama.cpp/build-rocm/bin/`, GGML_HIP=ON gfx1151, GGML_RPC_RDMA=ON(libibverbs v61). 호스트 /opt/rocm/lib 로 실행됨.
  (첫 시도는 예전 호스트 configure 가 남긴 `build-hip` 캐시 경로 불일치로 실패 → 새 폴더 `build-rocm`, 원 폴더는 그대로 둠)
- 대리 모델을 쓴 이유: qwen35moe 는 qwen4exp 와 같은 TP 분할 규칙(Q-gate fused QKV, GDN head)을 공유, 이미 디스크에 있음(20.4 GB).
- RPC 장치 이름은 `--rpc` 순서대로 `RPC0`, `RPC1`(예전 `RPC0[host:port]` 표기는 안 먹음).

| 실행 | 구성 | pp512 t/s | tg128 t/s | 기록 |
|---|---|---:|---:|---|
| 1노드 | ROCm0, -sm none(기본) | 1410.4 ± 44.3 | 51.10 ± 0.09 | runs/1node-Qwen3.6-35B-A3B-Q4_K_M-1029-1225 |
| A 단독 TP | rpc-server 2개(같은 GPU), -sm tensor, fa on, localhost TCP | 987.8 ± 29.2 | 35.82 ± 0.77 | runs/tp-Qwen3.6-35B-A3B-Q4_K_M-local-rdma-1029-1226 |

- A 단독 TP 는 같은 GPU 를 둘이 나눠 쓰고 AR 이 localhost TCP 라 속도 비교 대상이 아니다. 경로가 돈다는 것만 본다.
  rpc-server 로그: 50052 = rank 0, 50053 = rank 1, `[comm_init] ... joined pairwise comm` (테스트마다 컨텍스트 1번씩).

### 정합성 (perplexity, eval/ppl_text.txt = llama.cpp 문서 3개 이어붙임, -c 512, 40 청크, fa on)
| 구성 | PPL |
|---|---|
| 1노드 | 3.9158 ± 0.0903 |
| A 단독 TP | 3.9146 ± 0.0903 (차이 −0.03%) |
→ qwen35moe TP 경로 수치 일치(합 순서 차이 수준). 기록: runs/ppl-Qwen3.6-35B-A3B-Q4_K_M-{1node,tplocal}-*/ppl.log

## 2026-10-29 오후 — B 켜고 2노드 (대리 모델 Qwen3.6-35B-A3B Q4_K_M)
### T3: tbv SEND 경로 (perftest, usb4_rdma0, tbv new3 = c3429d7)
| 시험 | 결과 |
|---|---|
| ib_send_lat 8 B | 단방향 평균 10.0 µs, p99 12.5 |
| ib_send_lat 10 KiB | 20.1 µs, p99 24.2 |
| ib_send_bw 256 KiB | 1033 MB/s |
기록: runs/t3-send/

### T4: 2노드 TP
- 구성 확정: `--rpc 10.99.0.2:50052,127.0.0.1:50052` (B = rank 0). A 서버를 10.99.0.1 로 등록하면 클라이언트↔A 서버가 tbv **루프백** RDMA 로
  협상되고 tbv 는 같은 노드 안 QP 를 못 이어 `transport retry counter exceeded` 로 죽음.
- TCP(thunderbolt_net) 기준: **pp512 755.8 ± 8.2, tg128 24.91 ± 0.20 t/s** (1노드 51.10) → 토큰당 TP 부대비용 ≈ 30 ms(40층 × 2 AR ≈ 80회 → 회당 ≈ 375 µs, RPC 포함).
  기록: runs/tp-Qwen3.6-35B-A3B-Q4_K_M-2node-tcp-*
- RDMA: 클라이언트→B 링크에서 `RNR retry counter exceeded`(status 13)로 중단.
  - 재현 도구 `tbthroughput/verify/send_rnr.c`(llama.cpp 와 같은 QP 설정, 수신 측이 늦게 다시 게시):
    | S | 수신 게시 R | 지연 | 결과 |
    |---|---|---|---|
    | 256 KiB | 24 | 0 | PASS 1074 MB/s |
    | 256 KiB | 24 | 200 µs | #1065 에서 RNR_RETRY_EXC |
    | 256 KiB | 4 | 2 ms | #364 에서 RNR_RETRY_EXC |
    | 2 KiB / 4 KiB (1프레임) | 4 | 200 µs | PASS |
    | 16 KiB (여러 프레임) | 4 | 200 µs | QP 오류(post_send ECANCELED) |
  - 원인(코드 + 재현으로 판단): `tbv_qp_timeout_reap_tx()` 의 RNR 대기 분기가 `tx_pending == 0` 일 때만 재시도하고 아니면 -EAGAIN(=RNR_RETRY_EXC)로 끝냄.
    여러 프레임 SEND 는 RNR NAK 가 올 때 뒤 프레임이 아직 링에 있어 이 길로 빠진다. rnr_retry=7(무한)인데도 실패.
  - 수정 fix4(`experiments/step4-tbthroughput/tbv-build/fix4-rnr-wait-tx-drain.patch`, +14줄): 재시도 가능·무한/잔여 횟수 있음·QP 정상이면
    프레임이 빠질 때까지 다시 기다림. B 에서 정본 트리로 빌드, srcversion C8A6733DE6C7ADEFE716E4F, sha c81f49da…, CRC 부분집합 확인.
    배치: 두 노드 `~/tbv-deploy-sendskip5/`, `~/tbv-ab/swap.sh new4`. **설치·검증 대기.**
- 통신 링크(rpc-server 끼리)가 TCP 로 떨어진 이유: llama.cpp RDMA 연결 하나가 (24+1)×256 KiB ≈ 6.25 MiB 를 고정하는데 memlock 이 8 MiB(soft=hard).
  B 서버는 클라이언트 연결을 이미 가져 두 번째 등록 실패 → TCP. → llama.cpp 에 `GGML_RDMA_RX_DEPTH`(기본 24) 추가, 스크립트는 12 로 실행.

## 2026-10-29 13:00 — tbv new4 설치 후 (두 노드 srcversion C8A6733DE6C7ADEFE716E4F)
- send_rnr 재실행: 이전 실패 사례 전부 PASS(256 KiB R=24 D=200 µs / R=4 D=2 ms / R=2 D=500 µs, 16 KiB R=4), 지연 0 일 때 1145 MB/s(전 1074, 퇴행 없음). runs/rnr-new4/send_rnr.txt
- rdma_verify 4 QP × 100회, 두 케이블: 불일치 0 → PASS. runs/rnr-new4/rdma_verify.txt
- 2노드 TP, **모든 노드 간 링크 RDMA**(클라이언트→B, A 서버↔B 서버 통신; GGML_RDMA_RX_DEPTH=12):

| 구성 | pp512 | tg128 | tg256 | PPL |
|---|---:|---:|---:|---|
| 1노드 | 1410.4 | 51.10 | — | 3.9158 |
| 2노드 TP TCP | 755.8 | 24.91 | — | — |
| 2노드 TP RDMA | 831.3 ± 40.7 | 31.99 ± 2.88 | 36.10 ± 1.56 | 3.9146 (A 단독 TP 와 동일) |

### AR 단계별 시간 (GGML_RPC_COMM_PROF, tg256, 2000회 평균, µs, 메시지 8 KiB = hidden 2048 × f32)
| 노드 | gap(이전 AR 끝→다음 AR 시작) | sync(GPU 부분그래프 완료 대기) | d2h | net(교환+상대 기다림) | h2d+add 발행 | 합 |
|---|---:|---:|---:|---:|---:|---:|
| A (rank 1) | 44–46 | 163–165 | 14 | 72–111 | 22–23 | ≈320–360 |
| B (rank 0) | 75–78 | 143–144 | 18 | 61–104 | 16 | ≈315–355 |
- 토큰당 ≈84 AR (27.7 ms / ≈330 µs).
- **계산 몫(gap+sync ≈ 209 µs/부분그래프)이 1노드의 부분그래프당 ≈233 µs(19.6 ms / 84)보다 10% 남짓만 작다** →
  이 모델(활성 3B, batch 1)은 디코드가 대역폭보다 커널 발행·동기화 지연에 묶여 있어, 행렬을 반으로 나눠도 시간이 반으로 줄지 않는다.
- **통신 몫 ≈ 110–150 µs/AR**(d2h + net + h2d) × 84 ≈ 9–12 ms/토큰. net 에는 전송(8 KiB 단방향 ≈ 20 µs × 2)과 두 노드 도착 시각 차이가 섞여 있다.

## 2026-10-29 13:15 — T5 1차: 통신 경로 개선 (llama.cpp 우리 수정, 대리 모델, tg256 기준)
| 단계 | 바꾼 것 | tg256 t/s | AR 1회 평균(A) | 비고 |
|---|---|---:|---|---|
| 0 | 원본 경로 | 36.1 ± 1.6 | gap 45 sync 164 d2h 14 net 72–111 h2d 22 | |
| 1 | pinned host 버퍼 + 비동기 D2H/H2D, 작은 교환은 양쪽 동시 송신 | 28.7–30.8 | d2h 0, h2d 3 / B gap 125–170 | 복사는 사라졌는데 B 가 늦게 도착 |
| 2 | RDMA 전송 **보내기 묶음**(send_data 를 모아 flush 때 SEND 1번, 받기는 바이트 스트림) | 41.3 ± 1.3 | B wait-for-cmd 75 µs 그대로 | 명령 1개 = SEND 3번 → 1번 |
| 3 | 수신 링을 작은 조각·깊게(`GGML_RDMA_CHUNK=65536 GGML_RDMA_RX_DEPTH=48`) | **39.8 ± 2.9 (5회)** | gap 42 sync 164 net 35 h2d 4 (A·B 비슷), B wait-for-cmd 75→12 µs | |
- 서버 명령별 시간(`GGML_RPC_COMM_PROF`): AR 마다 GRAPH_RECOMPUTE 1회(그래프 캐시, 발행 7–12 µs) + COMM_ALLREDUCE 1회.
- 단계 3 근거: 클라이언트는 토큰 안에서 기다리지 않고 명령(토큰당 ≈168개)을 앞서 보낸다 → B 의 수신 슬롯 12개가 늘 차서 RNR → 크레딧 대기·재전송으로
  명령마다 ≈75 µs 늦게 도착. 슬롯 48개로 늘리자 12 µs.
- 같은 조건 1노드: pp512 1377 ± 22, tg256 51.07 ± 0.09. TP(단계 3) pp512 598 ± 103 — 64 KiB 조각 때문에 prefill 의 큰 교환이 느려짐(미해결).
- **남은 몫은 계산**: AR 당 gap+sync ≈ 206 µs. 통신이 0 이어도 1/(84 × 206 µs) ≈ 58 t/s → 이 모델에서 TP 상한은 1노드(51)보다 ≈13% 위.
  배치 1 디코드의 부분그래프가 작은 커널 여러 개라 행렬을 반으로 나눠도 GPU 시간이 반으로 줄지 않는다(1노드 부분그래프당 ≈233 µs).

## 2026-10-29 13:20 — prefill 회복: 송신 겹치기 + 큰 교환 전이중
- 전송: 송신 슬롯 링(`GGML_RDMA_TX_SLOTS`, 기본 4). flush 는 post 만 하고, 슬롯을 다시 채울 때만 완료를 기다림.
- 교환: 크기와 상관없이 양쪽이 64 KiB 조각으로 보내고 받기를 번갈아 함. RDMA 는 최대 4조각 앞서 보냄, TCP 는 1조각.
  (기존: 64 KiB 넘으면 rank 0 이 다 보낸 뒤 받고 rank 1 은 반대 → 직렬)
- **주의: 아래 측정 중 B 에서 사용자 프로그램이 돌고 있었다(부하 평균 5.5).** B 의 sync 가 165 → 450 µs 로 늘어 디코드 수치는 무효.
  prefill 은 B 가 바쁜 상태에서도:

| TX_SLOTS | pp512 | tg256 (무효) |
|---|---:|---:|
| 4 | **989.7 ± 16.2** (5회) | 21.1 |
| 2 | 920.7 ± 33.6 | 22.3 |
| 1 | 805.0 ± 46.0 | 21.4 |
- 이전 비교값: T5 전 831, 64 KiB 조각만 바꿨을 때 598, 1노드 1377.
- 정합성: A 단독 TP(TCP, 조각 교환 경로) PPL 3.9146 — 이전과 같음. 2노드 RDMA 경로의 PPL 과 디코드 재측정은 B 가 빈 뒤에.

## 2026-10-29 13:46 — B 유휴 상태에서 재측정 (부하 평균 1.0, top 비어 있음)
| 구성 | pp512 | tg256 | AR 1회(A): gap / sync / net / h2d |
|---|---:|---:|---|
| 1노드 | 1377 ± 22 | 51.07 ± 0.09 | — |
| TP, TX_SLOTS=4 (기본) | **1050.2 ± 16.4** | **49.98 ± 0.57** | 37 / 166 / 37 / 4 |
| TP, TX_SLOTS=2 | 1043.4 ± 19.5 | 49.64 ± 1.24 | 40 / 168 / 42 / 5 |
| TP, TX_SLOTS=1 (≈ 이전 단계 3) | 901.8 ± 65.9 | 46.35 ± 2.18 | 37 / 164 / 33 / 8 |
- 2노드 RDMA PPL 3.9146(변화 없음).
- 앞의 단계별 수치(36.1 → 28.7 → 41.3 → 39.8)는 B 에 사용자 작업이 돌던 시간과 겹쳤을 수 있다(언제부터였는지 모름). 같은 조건 비교를 위해
  T5 출발점(원래 경로 + RX 깊이 env + 계측만)을 `llama.cpp-t5base` 워크트리로 따로 빌드해 다시 잰다.
- 같은 조건(B 유휴, 연달아 측정) **T5 출발점**(`llama.cpp-t5base`, 원래 경로 + RX 깊이 12 + 계측): pp512 **688.8 ± 34.2**, tg256 **24.44 ± 2.33**.
  AR 1회: A gap 41 / sync 170 / d2h 14 / net 312 / h2d 19, **B gap 257** / sync 166 / d2h 16 / net 99 / h2d 17 → B 가 명령을 늦게 받아(명령당 SEND 3번 + 수신 12칸 RNR) A 가 기다림.
  출발점 수치는 RNR 상황에 따라 흔들린다(앞서 같은 경로로 32.0, 36.1 도 나왔다).
- **T5 결과(같은 조건 A/B): tg256 24.4 → 50.0 t/s (×2.0), pp512 689 → 1050 (×1.5).** 1노드 대비 디코드 98%, prefill 76%.
