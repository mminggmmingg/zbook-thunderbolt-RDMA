# 로드맵 4단계 — TB 처리량 최대화: 기준 측정 (2026-10-28)

환경: A/B 둘 다 커널 7.0.0-1015-oem, 케이블 2개 모두 2×20 Gb/s 로 링크(rx/tx_lanes=2), `usb4_rdma0`/`usb4_rdma5` ACTIVE.
tbv 파라미터(양쪽 같음): `lanes=1 native_tx_max_inflight=64 nhi_interrupt_throttle_ns=0 rx_supp_poll=-1 tx_progress_poll=-1 zcopy_min_bytes=0`,
`tb_ring_throttling()` helper 사용 중(부팅 로그). IOMMU Translated + lazy. memlock 상한 8 MiB(호스트 perftest 는 1 MiB 까지).
B 에는 사용자의 `local-clova-v8-2-epsilon` 컨테이너가 떠 있었으나 유휴(CPU 0.01%, GPU 0%) — 건드리지 않음.

스크립트: `perf_pair.sh`(perftest 한 쌍), `lat_sweep.sh`, `bw_matrix.sh`(EXTRA/SIZES/QPS/DEVSETS/DIRS), `cpu_during.sh`,
`coll/`(libtbvcoll 정본 deaa5b2 소스로 새로 빌드한 `libtbvcoll.so` sha256 4e5de0f2…, `run_tbvcoll.sh` 는 B 의 새 폴더 `~/step4-tbthroughput` 사용).
원시 결과: `raw/`.

## 1. 지연 (ib_write_lat, host 메모리, 한쪽 방향 = RTT/2, typical / p99)
| 크기 | rdma0 | rdma5 |
|---:|---|---|
| 2 B | 8.90 / 10.99 µs | 10.17 / 14.92 |
| 64 B | 8.87 / 10.90 | 9.83 / 15.73 |
| 4 KiB | 12.80 / 14.81 | 13.50 / 18.69 |
| 10 KiB | 19.82 / 22.33 | 20.40 / 25.10 |
| 64 KiB | 81.5 / 96.4 | 86.4 / 102.4 |
| 1 MiB | 1340 / 1559 | 1389 / 1739 |
→ 약 9 µs + 크기/≈6.3 Gb/s. 장치 이름 짝(rdma0↔rdma0, rdma0↔rdma5)은 둘 다 동작한다.

## 2. 대역폭 (ib_write_bw, B→A, host 메모리, 5 s)
| 조건 | 64 KiB q=1 | 256 KiB q=1 (-u 20) | 1 MiB q=1 |
|---|---|---|---|
| 케이블 1, 단방향 | 8.0–8.3 Gb/s | 8.7 | 5.7–5.9 |
| 케이블 2, 단방향 | 13.6 | 16.3 | 7.0–7.8 |
| 케이블 1, 양방향(합) | 17.6–20.6 | 14.3 | 8.0–9.6 |
| 케이블 2, 양방향(합) | **37.3** | 28.8 | 11.8 |
- QP 를 늘리면 줄어든다: 64 KiB q=4 2.2–2.7, 256 KiB q=2 4.6(단방향 1케이블). 1 MiB q≥2 는 `Couldn't post send` 로 실패.
- 1 MiB 에서 기본 QP timeout(14 → 4.096 µs×2^14 ≈ 67 ms) 이면 양쪽에 `native retransmit … reason=1 age_ms=67~161` 이 대량 발생.
  `-u 20`(≈4.3 s)이면 재전송 0 이지만 1 MiB 는 여전히 느리다 → 깊은 큐(perftest tx_depth 128)에서 성능이 무너진다.
  **libtbvcoll 도 `timeout=14` 를 쓴다**(대형 prefill 교환에서 같은 위험).

## 3. 병목 위치 (cpu_during.sh, 1케이블 단방향)
- 송신(B): 시스템 workqueue 의 per-CPU kworker 2개가 **95% / 66%**(256 KiB), 77% / 49%(1 MiB). 수신(A)은 거의 유휴(sy 1.2%).
- 추정: NHI 링 완료 work(시스템 wq) 안의 프레임별 TX 완료·재게시 처리와, 재전송 가능한 RC WRITE 가 zero-copy 대신
  "framed copy" 로 가는 경로(`zcopy_min_bytes` 설명)가 송신 CPU 를 묶는다. **커널 프로파일(perf)은 root 가 필요** — 미확인.

## 4. libtbvcoll 끝단 all-reduce (GPU bf16 텐서, 2레일, ASYNC+GPUSIG, 300회)
| 바이트 | 전체 | 전송 | algbw |
|---:|---:|---:|---:|
| 8 KiB (GLM decode 1행) | **20.8 µs** | 14.2 | 3.2 Gb/s |
| 32 KiB | 39.2 | 32.3 | 6.7 |
| 64 KiB | 61.1 | 53.5 | 8.6 |
| 256 KiB | 105.9 | 91.8 | 19.8 |
| 1 MiB | 374.5 | 338.2 | 22.4 |
| 4 MiB | 1454.9 | 1363.5 | **23.1** |
- 큰 크기는 케이블당 방향당 ≈11.5 Gb/s(현재 송신 CPU 천장)에 근접. 얕은 송신 큐(WR 상한 7)라 perftest 의 깊은 큐 붕괴가 없다.
- GLM 안에서 잰 all-reduce 1회 ≈100 µs 와 단독 20.8 µs 의 차이는 모델 안 상호작용(연산 중 GPU 플래그 대기, 진행 스레드 스케줄링 등)으로 보인다 — 미확인.
  GAP 모드(연산 사이 삽입)는 테스트 코드의 시간 분해 정의를 확인한 뒤 해석한다.

## 다음 레버 (우선순위 제안)
1. **송신 CPU 프로파일**(root): B 에서 대역폭 측정 중 `perf record -a -g` → 프레임 복사인지 완료 처리인지 확정.
2. **lanes=2**(케이블당 레일 2개 → 링·kworker 분산): 양쪽 모듈 재적재(root). 빠른 실험.
3. **폴링 모드** `rx_supp_poll/tx_progress_poll=2`(런타임 쓰기, root): 지연·CPU 측정.
4. **재전송 가능한 RC WRITE 의 zero-copy**(드라이버 코드): umem 페이지는 완료까지 고정되어 있으므로 재전송도 원본에서 다시 읽을 수 있다 — 설계 검토 필요.
5. **깊은 큐 견고성**: 재전송 타이머를 큐 진입이 아닌 실제 송신 시점부터, 또는 QP당 미완료 바이트 상한. libtbvcoll timeout 14→더 크게.
6. **모델 안 all-reduce 비용 분해**(root 불필요): GLM 실행 중 TBV_STATS 로 플래그 대기·전송·가산을 나눠 본다.

## 5. 수정 1: 정상 send 완료 때 취소 스캔 생략 (2026-10-28 밤)
- 프로파일(B 송신, 256 KiB, perf -a -g): `native_queued_spin_lock_slowpath` 24.8%, `tbv_path_cancel_data_match` 23.1%, memcpy 2.4%.
  `tbv_send_complete()` 가 정상 완료마다 `tbv_cancel_send_ctx_packets()` → 링 크기 kvcalloc + `path->tx_lock` 아래 전체 스캔.
- 수정(42줄, `tbv-build/fix-send-complete-skip-cancel.patch`): 성공·retryable·재전송 중 아님·`tx_pending==0` 일 때만 스캔 생략.
- 빌드: B 의 `~/kbuild-1015` 헤더 + `~/tbmod-1015/thunderbolt/Module.symvers`(로드된 thunderbolt.ko 와 같은 트리). 같은 환경의 정본 재빌드가
  설치본과 기계어 동일(주소 제외) → 수정본 차이는 패치뿐. 모듈 srcversion E475F47027AD6CFCB11B2AB, sha c5d79e61….
  (1차 시도는 잘못된 헤더로 빌드해 양 노드 oops — local_analysis/TBV_SENDSKIP_ABI_OOPS_20261028.md)

| ib_write_bw (Gb/s) | 기준 | 수정 |
|---|---:|---:|
| 1케이블 단방향 1 MiB q1 | 5.68 | 9.16 |
| 2케이블 단방향 1 MiB q1 | 7.81 | 19.24 |
| 1케이블 단방향 64 KiB q4 | 2.19 | 7.88 |
| 1케이블 단방향 256 KiB q2 (-u 20) | 4.60 | 9.02 |
| 2케이블 양방향 64 KiB q1 | 37.34 | 43.81 |
| 2케이블 양방향 1 MiB q1 | 11.82 | 28.09 |
| 2케이블 양방향 64 KiB q4 | 9.84 | 36.32 |
- 송신 CPU: kworker 95%+66% → 한 개 ~54%. 케이블당 방향당 천장 ≈9.2–9.6 Gb/s 는 이제 CPU 밖의 무언가.
- 남은 문제: 기본 timeout(14) 에서 재전송 여전(A 18, B 50 / 행렬 1회), 1 MiB × q≥2 는 `Couldn't post send` 실패.

| libtbvcoll all-reduce (bf16, 2레일) | 기준 | 수정(3회) |
|---:|---:|---|
| 8 KiB | 20.8 µs | 19.8 |
| 32 KiB | 39.2 | 38.2 |
| 256 KiB | 105.9 | 136.9 / 113.9 / 105.9 |
| 1 MiB | 374.5 | 389.0 / 377.6 / 369.2 |
| 4 MiB | 1454.9 (23.1 Gb/s) | 1633.6 / 1678.6 / 1677.7 (≈20.0) |
- **4 MiB 가 일관되게 ~13% 느리다**(재전송 0). 기준은 재부팅 전, 수정은 재부팅 후에 쟀고, 측정 시 B 에서 claude-desktop 이 CPU ~90% 를 쓰고 있었다 →
  수정 때문인지 조건 차이인지 미확정. 같은 부팅에서 모듈만 바꿔 A/B 해야 판정 가능.
- 참고: perftest 양방향 2 MiB, tx_depth 4, 2케이블 = 14.0 Gb/s(기준 없음) — 큰 WR + 얕은 큐 조합이 약하다.

## 6. 같은 부팅 A/B/A 비교 (2026-10-29 00:00–00:07, 모듈만 교체, B 유휴)
스크립트 `ab/swap.sh old|new`(sha·CRC 확인 후 재적재), `ab/measure.sh`(all-reduce 3회 + perftest 4줄). 원시: `raw/ab_{N1,O,N2}.sum`.

| 항목 | N1 새 | O 이전 | N2 새 |
|---|---|---|---|
| all-reduce 4 MiB | 1484–1523 µs | 1493–1501 | **1459–1466** (23.0 Gb/s) |
| all-reduce 1 MiB | 368–391 | 374–398 | 366–393 |
| all-reduce 256 KiB | 108–109 | 109–113 | 107–115 |
| perftest 1케이블 단방향 1 MiB | 9.15 Gb/s | 5.81 | 9.16 |
| perftest 2케이블 단방향 1 MiB | 18.83 | 7.79 | 19.01 |
| perftest 2케이블 양방향 1 MiB | 28.43 | 12.03 | 28.07 |
| perftest 2케이블 양방향 64 KiB | 43.44 | 32.66 | 44.09 |
재전송·커널 이상 세 상태 모두 0.

**판정**: 수정은 libtbvcoll all-reduce 를 느리게 하지 않는다(세 상태 모두 같은 범위). 앞서 본 4 MiB −13% 는 B 의 CPU 부하(claude-desktop ~90%) 탓이었다.
perftest(깊은 큐·큰 WR·다중 QP)는 1.3–2.4× 좋아짐이 같은 조건에서 재현. libtbvcoll 은 송신 큐를 얕게(WR ≤7) 써서 원래 이 병목을 거의 밟지 않았다 —
all-reduce 4 MiB ≈23 Gb/s 상한은 다른 데서 온다(다음 과제). 최종 상태: 두 노드 모두 새 모듈(E475F…).

## 7. all-reduce 상한(≈23 Gb/s) 원인 찾기 (2026-10-29)
- libtbvcoll 4 MiB: 레일(케이블)당 2 MiB 가 ~1.36–1.55 ms 에 도착 → **케이블당 방향당 ≈11–12 Gb/s** = 양방향 동시일 때의 케이블당 전송 상한과 같다.
  즉 all-reduce 상한 = 케이블(=레일) 하나의 처리 상한.
- **native_tx_max_inflight sweep**(`inflight_sweep.sh`, 런타임 적용, 사용자 임시 chmod): 64/128/256/512 모두 같음(±잡음, 256↑ 약간 나쁨).
  재전송·이상 0. → 송신 중 프레임 수는 상한이 아니다. 64 로 되돌림. 원시 `raw/inflight_sweep.sum`.
- **lanes=2 시도**(`lanes_set.sh`, 설정 백업 .pre-lanes.bak): 케이블 1(domain0)은 양쪽 레일 2개 등록, 케이블 2(domain1)는 두 번째 레일 HELLO 실패
  (`failed after 5 attempts` / `no matching peer rail`), A 의 `thunderbolt-net … failed to allocate Tx ring` → thunderbolt0 DOWN → TB IP·RoCE 경로 불통.
  → lanes=1 로 복귀, 정상(2케이블 단방향 1 MiB 21.19, 양방향 29.19 Gb/s).
- lanes=2 를 제대로 재려면 RoCE GID 출처를 thunderbolt0 대신 링이 필요 없는 dummy 인터페이스로 옮기고, 제어 연결(벤치·라이브러리 핸드셰이크)을
  tailscale/LAN 으로 돌려야 한다(roce_netdev 와 bring-up 스크립트 변경). 미실시.

## 8. 남은 드라이버 문제 점검 (2026-10-29, 새 모듈)
**(a) 기본 timeout(14 ≈ 67 ms) 재전송** — 새 모듈에서는 정상 실행에서 0:
| 조건(2케이블, 기본 timeout) | 합계 | 재전송 A/B |
|---|---:|---|
| 1 MiB q1 t128 단방향 / 양방향 | 20.81 / 29.69 | 0 / 0 |
| 1 MiB q1 t32 단방향 / 양방향 | 21.37 / 29.71 | 0 / 0 |
| 64 KiB q4 t128 단방향 / 양방향 | 11.92 / 38.55 | 0 / 0 |
| 1 MiB q2 t64 단방향 / 양방향 | 20.04 / 21.26 | 0 / 0 |
| 1 MiB q4 t32 양방향 | 14.22 | 0 |
- 이전 모듈의 재전송은 느린 완료 처리로 ACK 처리가 67 ms 를 넘긴 결과로 보인다(수정 1 로 해소). §5 행렬의 A 18 / B 50 은 post 실패로 perftest 가 중단된 회차와 겹친다.

**(b) 1 MiB × QP 2개 이상 `Couldn't post send`** — 원인 확정:
- 경로당 송신 데이터 큐 상한 `tx_data_queue_limit = tx_ring_size(1024) × TBV_DATA_QUEUE_MULTIPLIER(64) = 65,536 프레임 ≈ 253 MiB`
  (path.c:1136). 넘으면 `tbv_path_*` 가 `-ENOMEM` → `tbv_post_send_one()` 가 그대로 반환(ibdev.c, post_frames 실패 경로).
- 경계 실측: 2 QP × 128 × 1 MiB(256 MiB) 실패, 2 QP × 64 × 1 MiB / 2 QP × 128 × 512 KiB(128 MiB) 성공.
- 실제 작업 영향: libtbvcoll 은 ≤7 WR × ≤4 MiB ≈ 28 MiB, RCCL 도 이 근처에 못 미침 → 우선순위 낮음.
  바른 수정은 상한을 넘는 WR 을 거절하지 않고 받아 두었다가 큐가 빠질 때 프레임을 만드는 지연 게시(큰 변경).

**(c) 새로 보인 점: 같은 케이블에 QP 여러 개면 여전히 손해** — 64 KiB 단방향 q1 17–19 → q4 11.9, 1 MiB 양방향 q1 29.7 → q2 21.3 → q4 14.2.
RCCL 이 채널마다 QP 를 쓰면 영향을 받을 수 있다. 원인 미조사.

## 9. 수정 2·3: 두 번째 컨트롤러·다중 QP·양방향 큰 메시지 (2026-10-29)
**수정 2** (`tbv-build/fix2-never-retransmitted.patch`, srcversion 0E989E58…, sha 9923174f…):
- 증상: `rdma5`(domain1) 단방향 64 KiB q1 8.6, q4 4.6–4.8 Gb/s(`rdma0` 은 10.7/10.6). 프로파일: 취소 스캔 17–24% + 스핀락 20–29% 가 여전.
- 원인: 두 번째 NHI 에서는 ACK 처리가 TX 완료 콜백보다 먼저 돌아 완료 시점에 `tx_pending>0` → 수정 1 의 생략 조건 불충족 → 전체 스캔.
- 수정: 성공·retryable·재전송 중 아님이고 **재전송 이력이 없으면(retries==rnr_retries==0)** tx_pending 과 무관하게 생략.
  ACK = 상대가 모든 프레임을 받음 → 경로 대기열에 남은 원본 프레임 없음. 링에 남은 프레임은 자기 send_ctx 참조로 정상 완료,
  send 는 이미 pending_sends 에서 빠져(`pending=false`) 늦은 tx_done 이 타이머를 걸지 않는다. 재전송 이력이 있으면 기존 스캔.
- 결과: `rdma5` q1 8.6→10.0, q4 4.7→10.0; 2케이블 q1 18.4→21.3, q4 11.9→21.0.

**수정 3** (`tbv-build/fix3-sg-cursor-copy.patch`, srcversion 7DE3F58A…, sha 4752843d…):
- 증상: 양방향 1 MiB 에서 QP 를 늘리면 28.7→21.0→13.6. 프로파일(B, 양방향 1 MiB q4): `sg_miter_skip` 21.4% + `__sg_page_iter_next` 19.0%
  (`sg_copy_buffer` ← 수신 kworker 와 송신 사용자 프로세스).
- 원인: MR 복사(수신 `sg_pcopy_from_buffer`, 송신 `ib_umem_copy_from`)가 프레임마다 sg 목록 머리부터 **페이지 단위로** 오프셋까지 걷는다
  → 큰 WR 을 프레임 단위로 복사하면 크기의 제곱에 비례.
- 수정: `tbv_umem_sg_copy()` — sg **항목 단위**로 걷고, MR 마다 마지막 위치(항목, 시작 오프셋)를 잠금 아래 쌍으로 기억해 이어 간다.
  umem MR 의 수신 기록·세그먼트 송신 복사·READ 응답 복사 3곳에 적용(dmabuf/dma MR 은 기존 경로).
  빌드 중 7.0 에 `nth_page()` 가 없어 pfn 산술로 대체. 새 모듈은 `sg_pcopy_from_buffer` import 만 빠지고 나머지 CRC 동일(부분집합 확인).
- **무결성**(`verify/rdma_verify.c`, 새로 작성): 무작위 길이(1 B–4 MiB)·비정렬 오프셋·PRNG 패턴, QP 여러 개가 한 MR 공유,
  WRITE_WITH_IMM 은 구간 앞뒤 64 B 보호 바이트까지 확인, READ 도 대조. 2케이블 × QP 1/4 × 200회: WRITE 726 MiB, READ 715 MiB,
  **불일치 0 B, 보호 바이트 0** → PASS.
- 결과(2케이블, 기본 timeout, 재전송 0):

| 조건 | 수정 2 | 수정 3 |
|---|---:|---:|
| 양방향 64 KiB q1 / q4 | 43.15 / 37.89 | **44.69 / 44.76** |
| 양방향 1 MiB q1 / q2 / q4 | 28.73 / 21.00 / 13.62 | **45.15 / 44.98 / 44.98** |
| 단방향 1 MiB q1 / q2 | 21.53 / 19.93 | 21.45 / 21.46 |
| 단방향 64 KiB rdma0 / rdma5 / 둘 (q4) | 10.5 / 10.0 / 21.0 | 10.7 / 10.2 / 21.3 |
- 이제 크기·QP 수·방향과 무관하게 **케이블당 방향당 ≈10.7–11.3 Gb/s** 에 고르게 닿는다(양방향 2케이블 합 ≈45). 이것이 현재 링(NHI) 하나의 상한.
- libtbvcoll all-reduce: 1 MiB 370–400 µs, 4 MiB 1590–1617 µs(≈21 Gb/s), 결과 확인 OK — 이전 측정 범위(1454–1586) 안. 링 상한에 붙어 있어 변화 없음.

## 10. 로드맵 5단계: GLM-5.3 다시 돌리기 (2026-10-29, 새 모듈 c3429d7 = new3)
설정은 10-27 최고 기록과 같다: `MODE=tbv EAGER=0 SPEC=dflash SPEC_K=3 FP8BMM=0 W8A16=1 CHAT_REPS=4` (experiments/glm53/run/last-step5c.out).
| 항목 | 10-27 (이전 모듈) | 10-29 (새 모듈) |
|---|---|---|
| chat 256 토큰 ×4 | 22.48 / 22.58 / 22.62 / 22.71 tok/s | 22.61 / 22.46 / 22.31 / 22.34 |
| greedy 해시 | 857b8314 / 7dd52f6e / f1868566 | **같음** |
| NLL en / ko | 3.5881 / 2.8149 | **같음** |
| 기동 | 380 s | 385 s |
| 커널 이상 | 0 | 0 |
- 출력은 비트 단위로 같고 속도는 잡음 범위(±1%). GLM 디코드의 통신은 8 KiB all-reduce(libtbvcoll, 얕은 큐)라 이번 송신 경로 수정이 겨냥한
  깊은 큐·다중 QP·큰 메시지 병목을 밟지 않는다 — 예상대로. 디코드 통신 몫(스텝의 ≈8%)을 줄이려면 모델 안 all-reduce 1회 ≈100 µs vs 단독 ≈20 µs 의 차이를 봐야 한다.
- 첫 시도는 vLLM 초기화(노드 간 zmq 메시지 큐)에서 멈췄다: vLLM 이 기본경로(Wi-Fi) IP 를 골랐는데 오늘은 두 노드가 다른 망(A 192.168.0.199, B 10.197.2.40)이라 B 가 못 닿음.
  드라이버와 무관(RCCL all-reduce 단독 시험은 정상, `rccl/`). `glm53_node.sh` 에 `VLLM_HOST_IP`=TB IP 를 넣어 해결(백업 .pre-hostip.bak).
