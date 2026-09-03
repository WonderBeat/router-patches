#!/bin/sh

LOCKFILE="/tmp/firewall.lock"

# CONFIGURATION
TUN_INTERFACE="tun0"
LAN_INTERFACE="br0"
LAN_CIDR="192.168.11.0/24"
# No WG_INTERFACE any more: the wireguard endpoint runs system:false inside
# sing-box, so it creates no kernel interface and installs no routes. Everything
# bound for the wg overlay has to travel through tun0 and be routed by sing-box.
NEBULA_INTERFACE="nebula"
WG_PREFIXES="10.69.101.0/24 10.77.101.0/24"
MARK="0x2"
ROUTE_TABLE="252"
SINGBOX_BIN="/tmp/sing-box/sing-box"

# Local ranges to exclude from VPN (Router IP, Sing-Box internal).
# The wg prefixes are deliberately NOT here: with the endpoint in userspace the
# kernel has no path to them, so they must be marked into tun0 and handed to the
# wg outbound by a route rule in the sing-box config. Nebula keeps its exclusion
# because it still owns a real interface.
LOCAL_V4_RANGE="172.16.0.0/12,192.168.0.0/16,10.88.101.0/24"

singbox_running() {
  ps w | grep -v grep | grep -q "$SINGBOX_BIN run"
}

for i in $(seq 1 5); do
  if ip link show $TUN_INTERFACE >/dev/null 2>&1; then
    echo "Interface $TUN_INTERFACE is available after $i tries"
    break
  fi
  sleep 3
done

if ! ip link show $TUN_INTERFACE >/dev/null 2>&1; then
  echo "[sing-box] interfaces are down"
  exit 1
fi

if ! singbox_running; then
  echo "[sing-box] is not running"
  exit 1
fi

# Stale lock from a killed run must not block the script forever.
if [ -e "$LOCKFILE" ]; then
  oldpid=$(cat "$LOCKFILE" 2>/dev/null)
  # A bare kill -0 trusts any live pid, and after a reboot that number is
  # usually held by an unrelated process: that wedged this script into
  # reporting "already running" every run while the daemon stayed down.
  if [ -n "$oldpid" ] && grep -qs firewall "/proc/$oldpid/cmdline"; then
    echo "firewall.sh already running (pid $oldpid)"
    exit 0
  fi
  rm -f "$LOCKFILE"
fi
trap 'rm -f "$LOCKFILE"' EXIT INT TERM HUP
echo $$ >"$LOCKFILE"

echo "Applying Complete Firewall Rules with Isolated Chain and WG Access..."

# 1. SYSTEM TUNING (Fixes "Network unreachable" and kernel drops)
# Disable Reverse Path Filtering on all interfaces to prevent asymmetric routing drops
sysctl -w net.ipv4.conf.all.rp_filter=0
sysctl -w net.ipv4.conf.$LAN_INTERFACE.rp_filter=0
sysctl -w net.ipv4.conf.default.rp_filter=0
sysctl -w net.ipv4.conf.$TUN_INTERFACE.rp_filter=0 2>/dev/null

# TCP timestamps off: the timestamp option is a DPI fingerprint (and leaks
# uptime). It was set by hand on the xiaomi long ago and only lived in the
# running kernel, so every reboot silently turned it back on. Kept here so
# both routers get it from the repo instead of from memory.
sysctl -w net.ipv4.tcp_timestamps=0 >/dev/null 2>&1

iptables -t mangle -D PREROUTING -i $LAN_INTERFACE -d $LOCAL_V4_RANGE -j RETURN 2>/dev/null
iptables -t mangle -A PREROUTING -i $LAN_INTERFACE -d $LOCAL_V4_RANGE -j RETURN
iptables -t mangle -D PREROUTING -i $LAN_INTERFACE -p tcp -m multiport --dports 80,443,8080 -j MARK --set-mark $MARK 2>/dev/null
iptables -t mangle -A PREROUTING -i $LAN_INTERFACE -p tcp -m multiport --dports 80,443,8080 -j MARK --set-mark $MARK

# UDP too, or QUIC walks straight past sing-box: Chrome and Android prefer
# HTTP/3 on udp/443 for Google properties, so a LAN client looked completely
# un-proxied while the TCP rule above showed traffic. The xiaomi has always
# marked both; this closes the same hole here.
iptables -t mangle -D PREROUTING -i $LAN_INTERFACE -p udp -m multiport --dports 443,6000,6443,6969,8080,32243,2022 -j MARK --set-mark $MARK 2>/dev/null
iptables -t mangle -A PREROUTING -i $LAN_INTERFACE -p udp -m multiport --dports 443,6000,6443,6969,8080,32243,2022 -j MARK --set-mark $MARK

# The wg overlay, all protocols and ports. The port-based rules above cannot
# carry it (overlay traffic is not limited to web ports), and there is no kernel
# route to it any more, so without these two rules LAN clients lose the wg peers
# entirely. Marked here, they reach tun0 and the sing-box route rule sends them
# to the wg outbound.
for p in $WG_PREFIXES; do
  iptables -t mangle -D PREROUTING -i $LAN_INTERFACE -d "$p" -j MARK --set-mark $MARK 2>/dev/null
  iptables -t mangle -A PREROUTING -i $LAN_INTERFACE -d "$p" -j MARK --set-mark $MARK
done

# Drop any route for our own LAN that does not point at the LAN bridge.
#
# While this box sits behind the xiaomi, that router advertises DHCP option 121
# (classless static routes) including "192.168.11.0/24 via 192.168.33.1" to every
# LAN client. This box is one of those clients but it OWNS that subnet, so the
# learned route shadowed its own connected route: replies to its own LAN clients
# went out the WAN instead of br0. Symptoms were a phone that could browse (NAT
# was fine) but could not reach 192.168.11.1:16756, and 100% loss pinging a LAN
# client from here. It is re-learned on every DHCP renew, so a one-shot delete is
# not enough - this runs at boot and hourly with the rest of this script.
ip route show "$LAN_CIDR" 2>/dev/null | grep -v "dev $LAN_INTERFACE" | while read -r route; do
  ip route del $route 2>/dev/null && logger -t firewall "removed bogus route for own LAN: $route"
done

ip rule del fwmark $MARK 2>/dev/null
ip rule add fwmark $MARK lookup $ROUTE_TABLE
ip route flush table $ROUTE_TABLE 2>/dev/null
# No wg route in this table any more. The wg prefixes used to be pinned to wg0
# here so marked overlay traffic reached the kernel tunnel; with the endpoint in
# userspace they must instead follow the table's default into tun0, where
# sing-box routes them to the wg outbound. Adding a route for them here would
# send them nowhere.
#
# Nebula is different: it still owns a real interface, and sending its /24 into
# tun0 blackholed every marked packet to the mesh once nebula owned the prefix.
if ip link show $NEBULA_INTERFACE >/dev/null 2>&1; then
  ip route add 10.88.101.0/24 dev $NEBULA_INTERFACE table $ROUTE_TABLE
fi
ip route add default dev $TUN_INTERFACE table $ROUTE_TABLE

iptables -N SINGBOX_FWD 2>/dev/null
iptables -F SINGBOX_FWD
iptables -D FORWARD -j SINGBOX_FWD 2>/dev/null
iptables -I FORWARD 1 -j SINGBOX_FWD

iptables -A SINGBOX_FWD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -A SINGBOX_FWD -i $LAN_INTERFACE -o $TUN_INTERFACE -j ACCEPT
iptables -A SINGBOX_FWD -i $LAN_INTERFACE -o $NEBULA_INTERFACE -j ACCEPT
iptables -A SINGBOX_FWD -i $NEBULA_INTERFACE -o $LAN_INTERFACE -j ACCEPT
iptables -A SINGBOX_FWD -o $LAN_INTERFACE -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Legacy wg0 rules are removed rather than re-added: nothing creates that
# interface now. Inbound over the tunnel arrives from sing-box on lo instead.
iptables -D INPUT -i wg0 -j ACCEPT 2>/dev/null
iptables -D INPUT -i $NEBULA_INTERFACE -j ACCEPT 2>/dev/null
iptables -I INPUT 1 -i $NEBULA_INTERFACE -j ACCEPT

# Nebula only carries traffic sourced from this node's overlay address, and no
# peer has a route back to the LAN, so LAN clients are only representable via NAT.
iptables -t nat -D POSTROUTING -o $NEBULA_INTERFACE -j MASQUERADE 2>/dev/null
iptables -t nat -A POSTROUTING -o $NEBULA_INTERFACE -j MASQUERADE

# Legacy rule cleanup (delete-only, no matching add on purpose).
# do NOT SNAT tun0 traffic: collapsing all LAN clients onto the single
# 172.16.250.1 address forces symmetric UDP port remapping (e.g. 6969->41750),
# which breaks full-cone NAT that games/P2P require. sing-box (system stack) is
# endpoint-independent by default and the return path works via the main table +
# RELATED,ESTABLISHED accept, so no tun SNAT is needed.
# wg0/LAN masquerade is likewise dropped: the wg peer routes the LAN prefix
# directly, so masquerading only hides client addresses from the far side.
iptables -t nat -D POSTROUTING -o $TUN_INTERFACE -j SNAT --to-source 172.16.250.1 2>/dev/null
iptables -t nat -D POSTROUTING -o wg0 -j MASQUERADE 2>/dev/null
iptables -t nat -D POSTROUTING -o wg0 -s 192.168.11.0/24 -j MASQUERADE 2>/dev/null
iptables -t nat -D POSTROUTING -s 10.69.101.0/24 -o $LAN_INTERFACE -j MASQUERADE 2>/dev/null
iptables -t nat -D POSTROUTING -s 10.88.101.0/24 -o $LAN_INTERFACE -j MASQUERADE 2>/dev/null

echo "Rules applied successfully."
