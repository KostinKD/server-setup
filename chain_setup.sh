#!/usr/bin/env bash
# Keenetic -> AWG (MSK) -> AWG (Sweden), based on AYastrebov/docker-amneziawg.
# Run on clean Ubuntu 24.04 VPS as root. Does not install router rules.
set -Eeuo pipefail
umask 077
BASE=/opt/awg-chain
IMAGE=ghcr.io/ayastrebov/docker-amneziawg:latest
MSK_PORT=51820
SE_PORT=51821
MSK_SUBNET=10.70.0.0
SE_SUBNET=10.80.0.0
TABLE=55111

log(){ printf '\n[awg-chain] %s\n' "$*"; }
die(){ printf '[awg-chain] ERROR: %s\n' "$*" >&2; exit 1; }
usage(){ cat <<'EOF'
Usage:
  sudo bash awg-chain.sh sweden --public-ip SWEDEN_PUBLIC_IP
  sudo bash awg-chain.sh msk-init --public-ip MSK_PUBLIC_IP
  sudo bash awg-chain.sh msk-finish --upstream /path/to/peer_msk.conf
  sudo bash awg-chain.sh status

Run sweden FIRST. Copy /opt/awg-chain/config/peer_msk/peer_msk.conf
securely from Sweden to the Moscow VPS, then run msk-finish there.
From Moscow, copy /opt/awg-chain/config/peer_keenetic/peer_keenetic.conf
securely to your computer for import into Keenetic.

WARNING: The MSK kill switch works only for forwarded traffic arriving on
wg0. DNS-based split routing on Keenetic can still fail open if VPN drops.
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
 [[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 ]] || die "Expected Ubuntu 24.04; got ${PRETTY_NAME:-unknown}."
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
    container_name: amneziawg
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
