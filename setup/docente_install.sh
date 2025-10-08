#!/usr/bin/env bash
# docente_install.sh
# VM docente: IP fija LAN (sin WAN), DHCP+DNS (dnsmasq), firewall (nftables),
# servicios Docker (DVWA, Juice Shop, MailHog) con auto-arranque.

set -euo pipefail

### ---- Parámetros (override por env) ----
IFACE="${IFACE:-eth0}"
DOCENTE_IP="${DOCENTE_IP:-192.168.50.10}"
NET_CIDR="${NET_CIDR:-192.168.50.0/24}"
NET_MASK="${NET_MASK:-255.255.255.0}"
DHCP_RANGE_START="${DHCP_RANGE_START:-192.168.50.100}"
DHCP_RANGE_END="${DHCP_RANGE_END:-192.168.50.200}"
LEASE_TIME="${LEASE_TIME:-12h}"
LAB_HOSTS="${LAB_HOSTS:-dvwa.lab juiceshop.lab mail.lab}"

DVWA_IMAGE="${DVWA_IMAGE:-vulnerables/web-dvwa}"
DVWA_PORT="${DVWA_PORT:-80}"
JUICE_IMAGE="${JUICE_IMAGE:-bkimminich/juice-shop}"
JUICE_PORT="${JUICE_PORT:-3000}"
MAIL_IMAGE="${MAIL_IMAGE:-mailhog/mailhog}"
MAIL_UI_PORT="${MAIL_UI_PORT:-8025}"
MAIL_SMTP_PORT="${MAIL_SMTP_PORT:-1025}"

### ---- Rutas ----
IFACES_DIR="/etc/network/interfaces.d"
IF_CFG="${IFACES_DIR}/${IFACE}.cfg"
DNSMASQ_CONF="/etc/dnsmasq.d/lab.conf"
NFT_CONF="/etc/nftables.conf"

### ---- Helpers ----
enable_service(){ systemctl enable --now "$1" 2>/dev/null || systemctl start "$1" || true; }
iface_exists(){ ip link show "$1" >/dev/null 2>&1; }

### ---- Pre-chequeos ----
[ "$(id -u)" -eq 0 ] || { echo "Ejecutá como root."; exit 1; }
iface_exists "$IFACE" || { echo "No existe interfaz $IFACE"; exit 1; }

### ---- Paquetes ----
export DEBIAN_FRONTEND=noninteractive
# evitar colisiones con timers de apt (no imprescindible, pero ayuda en algunas distros)
systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl kill --kill-who=all apt-daily.service apt-daily-upgrade.service 2>/dev/null || true

apt-get update -y
apt-get install -y --no-install-recommends dnsmasq nftables docker.io
enable_service dnsmasq
enable_service nftables
enable_service docker

### ---- IP fija ----
mkdir -p "$IFACES_DIR" 2>/dev/null || true
cat > "$IF_CFG" <<EOF
auto ${IFACE}
iface ${IFACE} inet static
  address ${DOCENTE_IP}
  netmask ${NET_MASK}
EOF
ifdown "$IFACE" 2>/dev/null || true
ifup "$IFACE" || ip addr add "${DOCENTE_IP}/24" dev "$IFACE" 2>/dev/null || true
ip link set "$IFACE" up

### ---- dnsmasq: DHCP + DNS ----
ADDRESSES=""
for h in ${LAB_HOSTS}; do
  ADDRESSES="${ADDRESSES}address=/${h}/${DOCENTE_IP}\n"
done
cat > "$DNSMASQ_CONF" <<EOF
interface=${IFACE}
bind-interfaces
domain-needed
bogus-priv
no-resolv
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${LEASE_TIME}
dhcp-option=3,${DOCENTE_IP}
dhcp-option=6,${DOCENTE_IP}
$(echo -e "${ADDRESSES}")
EOF
systemctl restart dnsmasq

### ---- Alinear *tables a nft y reiniciar Docker ----
if iptables -V | grep -qi legacy; then
  update-alternatives --set iptables   /usr/sbin/iptables-nft || true
  update-alternatives --set ip6tables  /usr/sbin/ip6tables-nft || true
  update-alternatives --set arptables  /usr/sbin/arptables-nft || true
  update-alternatives --set ebtables   /usr/sbin/ebtables-nft || true
fi
modprobe nf_tables nfnetlink nf_nat xt_MASQUERADE br_netfilter overlay 2>/dev/null || true
systemctl restart docker

### ---- nftables: SOLO nuestra tabla (no flush global) ----
cat > "$NFT_CONF" <<EOF
table inet lab {
  set lan_subnet { type ipv4_addr; flags interval; elements = { ${NET_CIDR} } }
  # permitir loopback y subredes docker por defecto (172.16.0.0/12)
  chain input  { type filter hook input  priority 0; policy accept; }
  chain forward{ type filter hook forward priority 0; policy drop; }
  chain output {
    type filter hook output priority 0; policy accept;
    ip daddr 127.0.0.0/8 accept
    ip daddr @lan_subnet accept
    ip daddr 172.16.0.0/12 accept
    ip daddr != @lan_subnet drop
  }
}
EOF
# aplicar nuestra tabla sin borrar las de Docker
nft delete table inet lab 2>/dev/null || true
nft -f "$NFT_CONF"
systemctl restart nftables

### ---- Verificar puertos libres antes de correr contenedores ----
for P in "$DVWA_PORT" "$JUICE_PORT" "$MAIL_UI_PORT" "$MAIL_SMTP_PORT"; do
  if ss -tulpn | grep -qE ":${P}\b"; then
    echo "ERROR: Puerto ${P} en uso. Cerrá el proceso o cambia el puerto y reintenta."
    exit 1
  fi
done

### ---- Docker: run (sin ocultar errores) ----
docker rm -f dvwa-demo juiceshop-demo mailhog-demo 2>/dev/null || true

# pulls opcionales (no fallar si no hay red)
timeout 25s docker pull "$DVWA_IMAGE"  >/dev/null 2>&1 || true
timeout 25s docker pull "$JUICE_IMAGE" >/dev/null 2>&1 || true
timeout 25s docker pull "$MAIL_IMAGE"  >/dev/null 2>&1 || true

docker run -d --name dvwa-demo      --restart unless-stopped -p ${DVWA_PORT}:80          "$DVWA_IMAGE"
docker run -d --name juiceshop-demo --restart unless-stopped -p ${JUICE_PORT}:3000       "$JUICE_IMAGE"
docker run -d --name mailhog-demo   --restart unless-stopped -p ${MAIL_UI_PORT}:8025 -p ${MAIL_SMTP_PORT}:1025 "$MAIL_IMAGE"

enable_service docker

### ---- Salida / checks ----
echo
echo "[OK] Gateway listo en ${DOCENTE_IP} (${IFACE})"
echo "Subred: ${NET_CIDR} | DHCP: ${DHCP_RANGE_START}..${DHCP_RANGE_END} | DNS/GW: ${DOCENTE_IP}"
echo "Hosts lab: ${LAB_HOSTS}"
echo
echo "Servicios:"
echo " - DVWA        : http://${DOCENTE_IP}:${DVWA_PORT}"
echo " - Juice Shop  : http://${DOCENTE_IP}:${JUICE_PORT}"
echo " - MailHog UI  : http://${DOCENTE_IP}:${MAIL_UI_PORT}  (SMTP en ${MAIL_SMTP_PORT})"
echo
echo "Comandos útiles:"
echo "  docker ps"
echo "  journalctl -u docker -b --no-pager | tail -n 80"
echo "  nft list ruleset | sed -n '1,160p'"
