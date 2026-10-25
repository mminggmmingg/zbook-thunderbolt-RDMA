# host/ — 양 노드에 설치된 tbv bring-up 파일 (두 노드 동일, 2026-10-25 기준)

| 파일 | 설치 위치 | 역할 |
|---|---|---|
| `sbin/tbv-multirail-up.sh` (v3) | `/usr/local/sbin/` | 부팅 bring-up: thunderbolt_net → netdev down → tbv 로드 → thunderbolt0 IP. **XDomain 피어가 없으면 즉시 종료**(v2 는 30초 대기로 부팅 지연) |
| `sbin/tbv-netdev-up.sh` | `/usr/local/sbin/` | 피어 리부팅/핫플러그로 netdev 이 재생성될 때 IP·RoCE GID 재적용 |
| `systemd/tbv-multirail.service` | `/etc/systemd/system/` | 위 bring-up 을 oneshot 으로 실행 |
| `systemd/tbv-netdev@.service`, `udev/99-tbv-netdev.rules` | `/etc/systemd/system/`, `/etc/udev/rules.d/` | netdev 생성 이벤트 → tbv-netdev-up.sh |
| `etc/thunderbolt_ibverbs.conf` | `/etc/modprobe.d/` | tbv 모듈 옵션(lanes=1, roce_netdev=thunderbolt0 …) |
| `etc/tbv-multirail.conf.example` | `/etc/tbv-multirail.conf` | 노드별 `TB0_IP` |

커널 쪽(패치된 thunderbolt.ko, thunderbolt_net.ko, thunderbolt_ibverbs.ko, provider)은 `../tbv` 서브모듈에서 빌드한다.
