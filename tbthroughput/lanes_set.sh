#!/usr/bin/env bash
# tbv 의 lanes(케이블당 레일 수) 를 바꾸고 재적재(재부팅 없음). 설정 원본은 처음 한 번 .pre-lanes.bak 로 보존.
# 되돌리기 = lanes_set.sh 1.  양 노드에서 같은 값으로 실행한다.
#   sudo bash ~/tbv-ab/lanes_set.sh 2
set -euo pipefail
N=${1:?사용법: sudo bash $0 <1|2>}
[ "$(id -u)" = 0 ] || { echo "sudo 로 실행"; exit 1; }
case "$N" in 1|2) ;; *) echo "1 또는 2 만"; exit 2 ;; esac
C=/etc/modprobe.d/thunderbolt_ibverbs.conf
[ -f $C.pre-lanes.bak ] || cp -a $C $C.pre-lanes.bak
grep -q 'lanes=[0-9]' $C || { echo "$C 에 lanes= 가 없음 — 중단"; exit 1; }
sed -i -E "s/lanes=[0-9]+/lanes=$N/" $C
grep -o 'lanes=[0-9]*' $C
systemctl stop tbv-multirail || true
[ -d /sys/module/thunderbolt_ibverbs ] && rmmod thunderbolt_ibverbs
systemctl reset-failed tbv-multirail || true
systemctl start tbv-multirail || true
sleep 3
echo "로드 lanes=$(cat /sys/module/thunderbolt_ibverbs/parameters/lanes 2>/dev/null) srcversion=$(cat /sys/module/thunderbolt_ibverbs/srcversion 2>/dev/null)"
ibv_devices 2>/dev/null | grep usb4 || echo "usb4_rdma 장치 없음"
for d in /sys/class/infiniband/usb4_rdma*; do [ -e "$d" ] && echo "$(basename $d) $(cat $d/ports/1/state) gid1=$(cat $d/ports/1/gids/1)"; done
ip -br addr show thunderbolt0 2>/dev/null
journalctl -u tbv-multirail -n 4 --no-pager | tail -4
