#!/usr/bin/env bash
# 한 케이블 단방향 ib_write_bw(B→A 쓰기) 를 돌리는 동안 양쪽 스레드별 CPU 상위를 표본한다.
#   cpu_during.sh <크기> <qp> [장치=usb4_rdma0] [초=8]
set -uo pipefail
S=$1 Q=$2 DEV=${3:-usb4_rdma0} D=${4:-8}
B=parks-zbook@10.99.0.2; E=$(cd "$(dirname "$0")" && pwd); OUT=$E/raw/cpu; mkdir -p "$OUT"; T="s${S}_q${Q}_$DEV"
pkill -x ib_write_bw 2>/dev/null; ssh -o BatchMode=yes "$B" 'pkill -x ib_write_bw' 2>/dev/null; sleep 0.5
ib_write_bw -d $DEV -x 1 -p 18790 -s $S -q $Q -D $D -F --report_gbits -u 20 > "$OUT/$T.srv" 2>&1 &
sleep 1.5
ssh -o BatchMode=yes "$B" "ib_write_bw -d $DEV -x 1 -p 18790 -s $S -q $Q -D $D -F --report_gbits -u 20 10.99.0.1 > /tmp/cpuc 2>&1" &
sleep $((D / 2))
top -H -b -n 2 -d 1 -w 200 | awk '/^top -/{n++} n==2' | sed -n '1,4p;8,22p' > "$OUT/$T.topA"
ssh -o BatchMode=yes "$B" "top -H -b -n 2 -d 1 -w 200 | awk '/^top -/{n++} n==2' | sed -n '1,4p;8,22p'" > "$OUT/$T.topB"
wait
echo "== $T BW $(grep -E "^[[:space:]]*$S[[:space:]]" "$OUT/$T.srv" | tail -1 | awk '{print $4}') Gb/s"
echo "-- A(수신)"; sed -n '3p;6,16p' "$OUT/$T.topA" | cut -c1-110
echo "-- B(송신)"; sed -n '3p;6,16p' "$OUT/$T.topB" | cut -c1-110
