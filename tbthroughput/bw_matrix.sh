#!/usr/bin/env bash
# 대역폭 행렬: 케이블 1개/2개 동시 × 단방향/양방향(-b) × QP 1/4 × 크기. ib_write_bw, host 메모리, 지속시간 D 초.
# 서버=A, 클라이언트=B (raw_bidi_ceiling.sh 와 같은 방향: B→A 쓰기). 한 줄 요약을 raw/<라벨>_bw.sum 에 남긴다.
#   bw_matrix.sh <라벨> [D=5]   환경변수: EXTRA(perftest 추가 인자), SIZES, QPS, DEVSETS(;로 구분), DIRS
set -uo pipefail
E=$(cd "$(dirname "$0")" && pwd); LABEL=$1; D=${2:-5}
B=parks-zbook@10.99.0.2; RAW=$E/raw/bw_$LABEL; mkdir -p "$RAW"; SUM=$E/raw/${LABEL}_bw.sum; : > "$SUM"
run() {  # run <장치들> <크기> <qp> <bidi 0|1>
  local devs="$1" S=$2 Q=$3 BI=$4 port=18720 tot=0 tag; local b=""; [ "$BI" = 1 ] && b="-b"
  pkill -x ib_write_bw 2>/dev/null; ssh -o BatchMode=yes "$B" 'pkill -x ib_write_bw' 2>/dev/null; sleep 0.5
  tag="$(echo $devs | tr ' ' '+')_s${S}_q${Q}_b${BI}"
  local p=$port; for d in $devs; do ib_write_bw -d $d -x 1 -p $p -s $S -q $Q $b -D $D -F --report_gbits ${EXTRA:-} > "$RAW/$tag.$d.srv" 2>&1 & p=$((p+1)); done
  sleep 1.5
  ssh -o BatchMode=yes "$B" "p=$port; for d in $devs; do ib_write_bw -d \$d -x 1 -p \$p -s $S -q $Q $b -D $D -F --report_gbits ${EXTRA:-} 10.99.0.1 > /tmp/bwc_\$d 2>&1 & p=\$((p+1)); done; wait; for d in $devs; do echo == \$d; cat /tmp/bwc_\$d; done" > "$RAW/$tag.cli" 2>&1
  wait
  local parts=""
  for d in $devs; do
    local v=$(grep -E "^[[:space:]]*$S[[:space:]]" "$RAW/$tag.$d.srv" | tail -1 | awk '{print $4}')
    parts="$parts $d=${v:-실패}"; [ -n "$v" ] && tot=$(python3 -c "print(f'{$tot+$v:.2f}')")
  done
  printf "%-26s s=%-8s q=%s %s 합계 %6s Gb/s |%s\n" "$(echo $devs | tr ' ' '+')" "$S" "$Q" "$([ $BI = 1 ] && echo 양방향 || echo 단방향)" "$tot" "$parts" | tee -a "$SUM"
}
IFS=';' read -ra DS <<< "${DEVSETS:-usb4_rdma0;usb4_rdma5;usb4_rdma0 usb4_rdma5}"
for BI in ${DIRS:-0 1}; do
  for devs in "${DS[@]}"; do
    for Q in ${QPS:-1 4}; do
      for S in ${SIZES:-65536 1048576}; do run "$devs" $S $Q $BI; done
    done
  done
done
