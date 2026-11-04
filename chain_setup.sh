#!/usr/bin/env bash
# Keenetic -> AWG (MSK) -> AWG (Sweden), based on AYastrebov/docker-amneziawg.
# Fresh AWG 3.1 deployment, Ubuntu 24.04/26.04. Keeps prior deployment untouched.
set -Eeuo pipefail
umask 077
BASE=/opt/awg-chain31
IMAGE=ghcr.io/ayastrebov/docker-amneziawg:latest
CONTAINER=amneziawg31
MSK_PORT=51820
SE_PORT=51821
MSK_SUBNET=10.70.0.0
SE_SUBNET=10.80.0.0
TABLE=55111

log(){ printf '\n[awg-chain] %s\n' "$*"; }
die(){ printf '[awg-chain] ERROR: %s\n' "$*" >&2; exit 1; }
usage(){ cat <<'EOF'
Usage:
  sudo bash chain_setup_3_1.sh sweden --public-ip SWEDEN_PUBLIC_IP
  sudo bash chain_setup_3_1.sh msk-init --public-ip MSK_PUBLIC_IP
  sudo bash chain_setup_3_1.sh msk-finish --upstream /path/to/peer_msk.conf
  sudo bash chain_setup_3_1.sh status

Run sweden FIRST. Copy /opt/awg-chain31/config/peer_msk/peer_msk.conf
securely from Sweden to the Moscow VPS, then run msk-finish there.
From Moscow, copy /opt/awg-chain31/config/peer_keenetic/peer_keenetic.conf
securely to your computer for import into Keenetic.

WARNING: Fresh parallel installation in /opt/awg-chain31, NOT an in-place
upgrade. Existing /opt/awg-chain is preserved. Old Docker container must
be stopped separately to free ports, and peers need new configs.
The MSK kill switch protects forwarded traffic only; Keenetic domain routes
may fail open when VPN goes down.
EOF
}
[[ ${EUID} -eq 0 ]] || die 'Run as root using sudo.'
mode="${1:-}"; [[ -n "$mode" ]] || { usage; exit 2; }; shift || true
PUBLIC_IP='' UPSTREAM=''
while (($#)); do
 case "$1" in
 --public-ip) (($#>=2)) || die 'Missing --public-ip value'; PUBLIC_IP="$2"; shift 2;;
 --upstream) (($#>=2)) || die 'Missing --upstream value'; UPSTREAM="$2"; shift 2;;
 -h|--help) usage; exit 0;;
 *) die "Unknown argument: $1";;
 esac
done
validate_ip(){
 python3 - "$1" <<'PY'
import ipaddress,sys
try:
 ip=ipaddress.ip_address(sys.argv[1]); assert ip.version == 4 and ip.is_global
except (ValueError,AssertionError):
 raise SystemExit('Expected a globally routable public IPv4')
PY
}
require_host(){
 [[ -f /etc/os-release ]] || die 'Requires Ubuntu 24.04.'
 . /etc/os-release
 [[ "$ID" == ubuntu && ( "$VERSION_ID" == 24.04 || "$VERSION_ID" == 26.04 ) ]] || die "Expected Ubuntu 24.04/26.04; got ${PRETTY_NAME:-unknown}."
 [[ -e /dev/net/tun ]] || die '/dev/net/tun missing; VPS must expose TUN.'
 [[ $(uname -m) == x86_64 || $(uname -m) == aarch64 ]] || die 'Only x86_64/aarch64 supported.'
}
install_docker(){
 if docker compose version >/dev/null 2>&1; then log 'Docker Compose already installed'; return; fi
 log 'Installing Docker from official apt repository'
 apt-get update
 DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl python3
 install -m 0755 -d /etc/apt/keyrings
 curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
 chmod a+r /etc/apt/keyrings/docker.asc
 . /etc/os-release
 arch=$(dpkg --print-architecture)
 printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' "$arch" "${UBUNTU_CODENAME:-$VERSION_CODENAME}" > /etc/apt/sources.list.d/docker.list
 apt-get update
 DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
 systemctl enable --now docker
 docker compose version >/dev/null || die 'Docker Compose not available.'
}
write_compose(){
 local location="$1" ip="$2" port="$3" subnet="$4" peer="$5" tz="$6"
 mkdir -p "$BASE/config"
 chmod 700 "$BASE" "$BASE/config"
 cat > "$BASE/docker-compose.yml" <<EOF
services:
  amneziawg:
    image: ${IMAGE}
    container_name: ${CONTAINER}
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - PUID=0
      - PGID=0
      - TZ=${tz}
      - SERVERURL=${ip}
      - SERVERPORT=${port}
      - PEERS=${peer}
      - PEERDNS=1.1.1.1
      - INTERNAL_SUBNET=${subnet}
      - ALLOWEDIPS=0.0.0.0/0
      - IP6_SUBNET=off
      - AWG_VERSION=3.1
      - AWG_RANDOM_TRAILERS=on
      - AWG_DISABLE_COOKIES=off
      - AWG_S1=16
      - AWG_S2=16
      - AWG_S3=16
      - AWG_S4=16
      - AWG_CONTENT_PADDING=0
      - LOG_CONFS=false
      - PERSISTENTKEEPALIVE_PEERS=all
    volumes:
      - ./config:/config
    ports:
      - '${port}:51820/udp'
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    restart: unless-stopped
EOF
 echo "$location" > "$BASE/role"
 chmod 600 "$BASE/docker-compose.yml" "$BASE/role"
 cd "$BASE"
 docker compose config -q
 docker compose up -d
}
wait_file(){
 local file="$1"
 for _ in $(seq 1 40); do [[ -s "$file" ]] && return 0; sleep 2; done
 docker logs --tail 80 "$CONTAINER" || true
 die "Did not generate $file; inspect Docker logs."
}
fix_keenetic_i1(){
 local file="$1"
 # Keenetic has a 1000-byte limit per random tag in I1.
 # Splitting <r 1178> preserves identical on-wire bytes.
 python3 - "$file" <<'PYFIX'
from pathlib import Path
import sys, re
p=Path(sys.argv[1])
s=p.read_text()
s=re.sub(r'(<r 1178>)', '<r 1000><r 178>', s)
p.write_text(s)
PYFIX
 chmod 600 "$file"
}
check_awg31(){
 local file="$1"
 python3 - "$file" <<'PYCHECK'
from pathlib import Path
import sys,re
s=Path(sys.argv[1]).read_text()
iface=s.split('[Peer]',1)[0]
assert re.search(r'(?im)^RandomTrailers\s*=\s*on\s*$',iface), 'RandomTrailers missing'
for i in range(1,5):
 assert re.search(rf'(?m)^S{i}\s*=\s*16\s*$',iface), f'S{i} mismatch'
assert re.search(r'(?im)^HeaderProtectionKey\s*=',iface), 'HeaderProtectionKey missing'
PYCHECK
}
status(){
 [[ -f "$BASE/docker-compose.yml" ]] || die "No installation at $BASE"
 cd "$BASE"
 docker compose ps
 docker exec "$CONTAINER" awg show || true
 if [[ -f "$BASE/role" && $(cat "$BASE/role") == msk ]]; then
   docker exec "$CONTAINER" ip -4 rule show || true
   docker exec "$CONTAINER" ip -4 route show table "$TABLE" || true
   docker exec "$CONTAINER" iptables -S FORWARD || true
 fi
}
case "$mode" in
 sweden|msk-init)
   [[ -n "$PUBLIC_IP" ]] || die 'Provide --public-ip'
   command -v python3 >/dev/null || { apt-get update; apt-get install -y python3; }
   validate_ip "$PUBLIC_IP"
   require_host
   [[ ! -e "$BASE/role" && ! -e "$BASE/config/wg_confs/wg0.conf" ]] || die "Installation already exists at $BASE; refusing to overwrite keys."
   if docker container inspect amneziawg >/dev/null 2>&1; then
     [[ "$(docker inspect -f '{{.State.Running}}' amneziawg 2>/dev/null)" != true ]] || die 'Old AWG 2.0 container is running. Stop it manually before using same UDP ports; old files will be preserved.'
   fi
   install_docker
   if [[ "$mode" == sweden ]]; then
     log 'Configuring Sweden exit: UDP 51821'
     write_compose sweden "$PUBLIC_IP" "$SE_PORT" "$SE_SUBNET" msk Europe/Stockholm
     wait_file "$BASE/config/peer_msk/peer_msk.conf"
   check_awg31 "$BASE/config/peer_msk/peer_msk.conf"
     log "Ready: copy $BASE/config/peer_msk/peer_msk.conf securely to MSK."
   else
     log 'Configuring Moscow entry: UDP 51820'
     write_compose msk "$PUBLIC_IP" "$MSK_PORT" "$MSK_SUBNET" keenetic Europe/Moscow
     wait_file "$BASE/config/peer_keenetic/peer_keenetic.conf"
   fix_keenetic_i1 "$BASE/config/peer_keenetic/peer_keenetic.conf"
   check_awg31 "$BASE/config/peer_keenetic/peer_keenetic.conf"
     log "Ready: Keenetic config at $BASE/config/peer_keenetic/peer_keenetic.conf"
     log 'Next: msk-finish --upstream /path/to/peer_msk.conf'
   fi
   status
   ;;
 msk-finish)
   [[ -f "$BASE/role" && $(cat "$BASE/role") == msk ]] || die 'Run msk-init first, on MSK VPS.'
   [[ -n "$UPSTREAM" && -r "$UPSTREAM" ]] || die 'Provide a readable --upstream peer_msk.conf from Sweden.'
   [[ ! -e "$BASE/cascade-installed" ]] || die 'Cascade already installed; refusing to overwrite configurations.'
   [[ -f "$BASE/config/wg_confs/wg0.conf" ]] || die 'Generated wg0.conf missing.'
   command -v python3 >/dev/null || die 'python3 required.'
   check_awg31 "$UPSTREAM"
   log 'Stopping MSK container to modify generated config'
   cd "$BASE"; docker compose down
   mkdir -p "$BASE/backup"
   cp -a "$BASE/config/wg_confs/wg0.conf" "$BASE/backup/wg0.before-cascade.conf"
   cp "$UPSTREAM" "$BASE/config/wg_confs/wg1.conf"
   chmod 600 "$BASE/config/wg_confs/wg1.conf"
   cat > "$BASE/config/hub-rules.sh" <<'EOF'
#!/bin/sh
set -eu
# Runs inside container namespace, invoked by wg0 on start/stop.
mode="${1:?up|down}"
TABLE=55111
CIDR=10.70.0.0/24
# Idempotently remove our own rules (avoid clobbering Docker host firewall).
remove() {
  iptables -t nat -D POSTROUTING -s "$CIDR" -o wg1 -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -i wg1 -o wg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i wg0 -o wg1 -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i wg0 ! -o wg1 -j DROP 2>/dev/null || true
  ip rule del pref 1000 from "$CIDR" table "$TABLE" 2>/dev/null || true
  ip route del unreachable default table "$TABLE" metric 4278198272 2>/dev/null || true
}
case "$mode" in
 up)
  remove
  # Install the blackhole route before the policy rule. Linux will not fall
  # through to main table when wg1 is missing.
  ip route add unreachable default table "$TABLE" metric 4278198272
  ip rule add pref 1000 from "$CIDR" table "$TABLE"
  iptables -I FORWARD 1 -i wg0 ! -o wg1 -j DROP
  iptables -I FORWARD 1 -i wg0 -o wg1 -j ACCEPT
  iptables -I FORWARD 1 -i wg1 -o wg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -t nat -I POSTROUTING 1 -s "$CIDR" -o wg1 -j MASQUERADE
  ;;
 down) remove ;;
 *) echo 'Expected up or down' >&2; exit 2;;
esac
EOF
   chmod 700 "$BASE/config/hub-rules.sh"
   python3 - "$BASE/config/wg_confs/wg0.conf" "$BASE/config/wg_confs/wg1.conf" <<'PY'
import pathlib, re, sys
server=pathlib.Path(sys.argv[1]); client=pathlib.Path(sys.argv[2])
def rewrite(path, name):
    s=path.read_text()
    if '[Interface]' not in s or '[Peer]' not in s:
        raise SystemExit(f'Invalid AWG config: {path}')
    # Preserve keys, encryption/obfuscation params and all peers.
    parts=re.split(r'(?m)^\[Peer\]\s*$', s, maxsplit=1)
    if len(parts)!=2: raise SystemExit('Missing Peer')
    head, peers = parts
    head=re.sub(r'(?im)^(?:PostUp|PostDown|PreUp|PreDown|Table|DNS|MTU)\s*=.*(?:\n|$)', '', head)
    if name=='wg0':
        inject='PostUp = /config/hub-rules.sh up\nPreDown = /config/hub-rules.sh down\nMTU = 1280\n'
    else:
        inject='Table = 55111\nMTU = 1280\n'
    head=head.replace('[Interface]', '[Interface]\n'+inject, 1)
    path.write_text(head+'[Peer]'+peers)
rewrite(server,'wg0'); rewrite(client,'wg1')
if not re.search(r'(?im)^AllowedIPs\s*=\s*0\.0\.0\.0/0\s*$',client.read_text()):
    raise SystemExit('Upstream client must have AllowedIPs = 0.0.0.0/0')
PY
   # Preserve original peer file; server bridge requires wg1 via Sweden.
   check_awg31 "$BASE/config/wg_confs/wg1.conf"
   # Force the generated client to use a local-only IPv4 tunnel.
   chmod 600 "$BASE/config/wg_confs/wg0.conf" "$BASE/config/wg_confs/wg1.conf"
   log 'Starting MSK cascade'
   docker compose up -d
   sleep 5
   docker exec "$CONTAINER" ip rule show | grep '55111' || die 'Policy rule not installed; inspect container logs.'
   docker exec "$CONTAINER" ip route show table 55111 | grep 'unreachable default' || die 'Kill-switch fallback route missing.'
   docker exec "$CONTAINER" awg show wg1 >/dev/null || die 'wg1 missing; inspect Docker logs.'
   touch "$BASE/cascade-installed"
   log 'Cascade installed. Check handshake and end-to-end IP from a Keenetic client.'
   status
   ;;
 status) status;;
 help|-h|--help) usage;;
 *) usage; die "Unknown mode: $mode";;
esac
