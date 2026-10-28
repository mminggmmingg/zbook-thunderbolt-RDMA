#!/usr/bin/env bash
# 송신(B) CPU 프로파일: A=서버(수신), B=클라이언트(송신) ib_write_bw 를 돌리는 동안 B 에서 perf record -a -g.
# B 에 perf_event_paranoid=-1, kptr_restrict=0 이 필요(사용자가 임시 설정). 결과는 raw/prof/ 로 가져온다.
#   profile_tx.sh <크기> [qp=1] [장치=usb4_rdma0] [라벨=base]
set -uo pipefail
S=$1 Q=${2:-1} DEV=${3:-usb4_rdma0} LABEL=${4:-base}
B=parks-zbook@10.99.0.2; BD=/home/parks-zbook/step4-tbthroughput
E=$(cd "$(dirname "$0")" && pwd); OUT=$E/raw/prof; mkdir -p "$OUT"; T="${LABEL}_s${S}_q${Q}_$DEV"
pkill -x ib_write_bw 2>/dev/null; ssh -o BatchMode=yes "$B" "pkill -x ib_write_bw; mkdir -p $BD" 2>/dev/null; sleep 0.5
ib_write_bw -d $DEV -x 1 -p 18791 -s $S -q $Q -D 14 -F --report_gbits -u 20 > "$OUT/$T.srv" 2>&1 &
sleep 1.5
ssh -o BatchMode=yes "$B" "ib_write_bw -d $DEV -x 1 -p 18791 -s $S -q $Q -D 14 -F --report_gbits -u 20 10.99.0.1 > $BD/$T.cli 2>&1 &
  sleep 4; perf record -a -g -F 1999 -o $BD/$T.data -- sleep 6 > $BD/$T.rec.log 2>&1; wait
  perf report -i $BD/$T.data --no-children --sort sym --stdio -g none --percent-limit 0.5 2>/dev/null | grep -vE '^#|^$' | head -45 > $BD/$T.sym
  perf report -i $BD/$T.data --no-children --sort comm,dso --stdio -g none --percent-limit 1 2>/dev/null | grep -vE '^#|^$' | head -20 > $BD/$T.comm
  perf report -i $BD/$T.data --children --sort sym --stdio -g none --percent-limit 3 2>/dev/null | grep -vE '^#|^$' | head -40 > $BD/$T.children"
wait
scp -q "$B:$BD/$T.sym" "$B:$BD/$T.comm" "$B:$BD/$T.children" "$B:$BD/$T.cli" "$OUT/" 2>/dev/null
echo "== $T BW $(grep -E "^[[:space:]]*$S[[:space:]]" "$OUT/$T.srv" | tail -1 | awk '{print $4}') Gb/s"
echo "-- comm,dso (self ≥1%)"; head -14 "$OUT/$T.comm"
echo "-- 심볼 self 상위"; head -30 "$OUT/$T.sym"
