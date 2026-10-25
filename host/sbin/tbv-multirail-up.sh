#!/usr/bin/env bash
# tbv 멀티레일 부팅 bring-up v3(피어 없으면 즉시 종료). systemd oneshot 이 호출. 검증된 수동 시퀀스를 인코딩:
#   thunderbolt_net(패치) 로드 → netdev down(ring 양보) → tbv lanes=1 로드 → thunderbolt0 up+IP.
# 노드 IP 는 /etc/tbv-multirail.conf 의 TB0_IP (+선택 TB1_IP).
#
# v1 대비 변경(2026-10-20 리부팅 실측 기반):
#  (a) flock — udev 핸들러(tbv-netdev-up.sh)와 직렬화. ring 양보용 link down 과 경쟁 금지.
#  (b) nmcli managed=no 를 netdev 등장 **이후**로 이동(v1 은 장치가 없을 때 호출해 항상 실패했다).
#  (c) 종료코드 — v1 은 항상 exit 0 이라 systemd Restart=on-failure 가 영구 미발화였다.
#      netdev 자체가 없으면(피어 전원off 등) exit 0 + 로그(udev 가 나중에 처리), netdev 은 있는데
#      IP/ib_device 가 안 섰으면 exit 1 로 재시도를 유발한다.
set +e
. /etc/tbv-multirail.conf 2>/dev/null
LOG(){ logger -t tbv-multirail "$*"; echo "tbv-multirail: $*"; }
exec 9>/run/tbv-bringup.lock; flock -w 120 9

modprobe ib_uverbs
# 패치 thunderbolt_net 로드(이미 udev 가 올렸으면 no-op) → netdev 생성
modprobe thunderbolt_net
# XDomain 피어(상대 PC)가 없으면 thunderbolt_net 이 netdev 를 만들 수 없다 → 기다리지 않고 바로 끝낸다.
# (v2 는 피어 없이도 30s 를 기다려 multi-user.target·graphical.target 을 통째로 밀었다, 2026-10-24 실측 30.3s)
has_xdomain(){ grep -qs '^DEVTYPE=thunderbolt_xdomain$' /sys/bus/thunderbolt/devices/*/uevent; }
if ! has_xdomain; then
  LOG "XDomain 피어 없음 — udev tbv-netdev@ 가 등장 시 처리. 종료 0"
  modprobe thunderbolt_ibverbs   # 서비스 광고를 먼저 해 둬야 핫플러그 때 tbv 가 바인드된다
  exit 0
fi
# 피어는 있음: netdev 등장 대기(0.2s 간격, 최대 10s)
for i in $(seq 1 50); do ip link show thunderbolt0 >/dev/null 2>&1 && break; sleep 0.2; done
if ! ip link show thunderbolt0 >/dev/null 2>&1; then
  LOG "thunderbolt0 netdev 없음(피어 미연결?) — udev tbv-netdev@ 가 등장 시 처리. 종료 0"
  modprobe thunderbolt_ibverbs
  exit 0
fi
# NetworkManager 가 netdev 을 멋대로 올려 ring 을 잡는 레이스 방지(장치 등장 후에 호출해야 먹는다)
if command -v nmcli >/dev/null 2>&1; then
  nmcli dev set thunderbolt0 managed no 2>/dev/null
  nmcli dev set thunderbolt1 managed no 2>/dev/null
fi
# tbv 로드 전에 netdev down (ring 양보 순서 보장)
ip link set thunderbolt0 down 2>/dev/null
ip link set thunderbolt1 down 2>/dev/null
sleep 1
# tbv 로드 — 옵션(lanes=1 등)은 /etc/modprobe.d/thunderbolt_ibverbs.conf
modprobe thunderbolt_ibverbs
sleep 3
# netdev up + IP (tbv lanes=1 이후라 ring 여유)
for pair in "thunderbolt0:${TB0_IP:-}" "thunderbolt1:${TB1_IP:-}"; do
  IF="${pair%%:*}"; IP="${pair#*:}"
  [ -n "$IP" ] || continue
  ip link show "$IF" >/dev/null 2>&1 || continue
  ip addr flush dev "$IF" 2>/dev/null
  ip addr add "$IP/24" dev "$IF" 2>/dev/null
  ip link set "$IF" up
done
# ibv 디바이스 등록 대기(deferred registration 이 netdev UP 에 발화)
for i in $(seq 1 20); do ibv_devices 2>/dev/null | grep -q usb4_rdma && break; sleep 1; done
N=$(ibv_devices 2>/dev/null | grep -c usb4_rdma)
GID=$(cat /sys/class/infiniband/usb4_rdma*/ports/1/gids/1 2>/dev/null \
      | grep -v '^0000:0000:0000:0000:0000:0000:0000:0000$' | head -1)
LOG "done: $N usb4_rdma devices; $(ip -br addr show thunderbolt0 2>/dev/null); gid1=${GID:-EMPTY}"

# --- 성공 판정(v1 에는 없었다) ---
RC=0
if [ -n "${TB0_IP:-}" ] && ! ip -4 addr show thunderbolt0 2>/dev/null | grep -q "inet $TB0_IP/24"; then
  LOG "FAIL: thunderbolt0 에 $TB0_IP/24 미적용"; RC=1
fi
[ "$N" -ge 1 ] || { LOG "FAIL: usb4_rdma ib_device 0 개"; RC=1; }
[ "$N" -ge 2 ] || LOG "WARN: usb4_rdma $N 개(2번째 케이블 미연결/미인증일 수 있음)"
[ -n "$GID" ] || { LOG "FAIL: RoCE gid[1] 비어 있음 — RTR EINVAL 이 된다"; RC=1; }
exit $RC
