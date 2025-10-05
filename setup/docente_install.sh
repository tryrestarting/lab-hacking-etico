#!/usr/bin/env bash
# Prepara la VM docente como gateway de laboratorio
# - IP fija LAN (sin WAN)
# - DHCP + DNS (dnsmasq) para nombres del lab
# - Firewall (nftables): sin salida fuera de la subred.

set -euo pipefail

IFACE="${IFACE:-eth0}"                # Interfaz bridged hacia el AP aislado
DOCENTE_IP="${DOCENTE_IP:-192.168.50.10}"
NET_CIDR="${NET_CIDR:-192.168.50.0/24}"
NET_MASK="${NET_MASK:-255.255.255.0}"
DHCP_RANGE_START="${DHCP_RANGE_START:-192.168.50.100}"
DHCP_RANGE_END="${DHCP_RANGE_END:-192.168.50.200}"
LEASE_TIME="${LEASE_TIME:-12h}"

# servicios de lab, resuelven a la IP del docente
LAB_HOSTS=${LAB_HOSTS:-"dvwa.lab juiceshop.lab mail.lab"}

DNSMASQ_CONF="/etc/dnsmasq.d/lab.conf"
IFACES_DIR="/etc/network/interfaces.d"
IF_CFG="${IFACES_DIR}/${IFACE}.cfg"
NFT_CONF="/etc/nftables.conf"

# Pre-chequeos
[ "$(id -u)" -eq 0 ] || { echo "Ejecutá como root."; exit 1; }
ip link show "$IFACE" >/dev/null 2>&1 || { echo "No existe interfaz $IFACE"; exit 1; }

# Paquetes
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y dnsmasq nftables

# IP fija en la interfaz
mkdir -p "$IFACES_DIR"
cat > "$IF_CFG" <<EOF
auto ${IFACE}
iface ${IFACE} inet static
  address ${DOCENTE_IP}
  netmask ${NET_MASK}
EOF
ifdown "$IFACE" 2>/dev/null || true
ifup "$IFACE"

# dnsmasq: DHCP+DNS local
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
dhcp-option=3,${DOCENTE_IP}   # gateway = VM docente
dhcp-option=6,${DOCENTE_IP}   # DNS = VM docente
$(echo -e "${ADDRESSES}")
EOF

systemctl enable --now dnsmasq
systemctl restart dnsmasq

# Firewall nftables: sin salida fuera de la subred
# Política: INPUT/OUTPUT permitidos por defecto, pero BLOQUEAMOS cualquier
# paquete cuyo destino no sea la subred del lab. FORWARD DROP por si acaso.
nft flush ruleset
cat > "$NFT_CONF" <<EOF
table inet lab {
  set lan_subnet {
    type ipv4_addr; flags interval;
    elements = { ${NET_CIDR} }
  }

  chain input {
    type filter hook input priority 0;
    policy accept;
  }

  chain forward {
    type filter hook forward priority 0;
    policy drop;
  }

  chain output {
    type filter hook output priority 0;
    policy accept;
    # Bloqueo de salida a destinos fuera del lab
    ip daddr != @lan_subnet drop
  }
}
EOF
systemctl enable --now nftables
systemctl restart nftables

# Info final
echo
echo "[OK] Gateway del laboratorio listo."
echo " Interfaz:   ${IFACE}"
echo " IP docente: ${DOCENTE_IP}"
echo " Subred:     ${NET_CIDR}"
echo " DHCP:       ${DHCP_RANGE_START}..${DHCP_RANGE_END} (DNS/GW=${DOCENTE_IP})"
echo " Hosts lab:  ${LAB_HOSTS}"
echo
echo "Comprobaciones sugeridas:"
echo "  - En un cliente: 'ip a', 'ip route', 'nslookup dvwa.lab ${DOCENTE_IP}', 'curl -I http://dvwa.lab'"
