#!/usr/bin/env bash
# thunderbolt netdev 이 (재)생성될 때마다 고정 IP 재부여 + up. udev → systemd 템플릿이 호출.
# 왜 필요한가(2026-10-20 실측): 피어가 리부팅하면 XDomain 이 끊겨 살아있는 쪽의 thunderbolt0 netdev 이
#   파괴·재생성된다. 그 결과 IP 가 사라지고, 재등록된 ib_device 의 RoCE gid[1] 이 전부 0(ndev 없음) →
#   RTR EINVAL. one-shot 부팅 서비스는 자기 부팅 때만 돌아서 살아있는 노드를 복구하지 못한다.
set +e
IF="${1:?iface}"
. /etc/tbv-multirail.conf 2>/dev/null
LOG(){ logger -t tbv-netdev "$*"; }
case "$IF" in
  thunderbolt0) IP="${TB0_IP:-}";;
  thunderbolt1) IP="${TB1_IP:-}";;
  *) exit 0;;
esac
[ -n "$IP" ] || { LOG "$IF: conf 에 IP 없음 — skip"; exit 0; }
# 부팅 bring-up(tbv-multirail-up.sh)과 직렬화 — ring 양보용 link down 과 경쟁하면 안 된다
exec 9>/run/tbv-bringup.lock; flock -w 60 9
for i in $(seq 1 20); do ip link show "$IF" >/dev/null 2>&1 && break; sleep 0.5; done
ip link show "$IF" >/dev/null 2>&1 || { LOG "$IF: netdev 사라짐 — skip"; exit 0; }
command -v nmcli >/dev/null 2>&1 && nmcli dev set "$IF" managed no 2>/dev/null
ip addr flush dev "$IF" 2>/dev/null
ip addr add "$IP/24" dev "$IF" 2>/dev/null
ip link set "$IF" up
# RoCE GID 재populate 대기(ib_core netdev notifier 가 inet 이벤트로 채운다)
G=""
for i in $(seq 1 15); do
  G=$(cat /sys/class/infiniband/usb4_rdma*/ports/1/gids/1 2>/dev/null \
      | grep -v '^0000:0000:0000:0000:0000:0000:0000:0000$' | head -1)
  [ -n "$G" ] && break; sleep 1
done
LOG "$IF: $(ip -4 -br addr show "$IF" 2>/dev/null) gid1=${G:-EMPTY}"
exit 0
