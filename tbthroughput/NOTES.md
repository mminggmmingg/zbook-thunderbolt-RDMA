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
