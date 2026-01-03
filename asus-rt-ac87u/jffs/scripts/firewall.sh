#!/bin/sh

TUN_INTERFACE="tun0"
LAN_INTERFACE="br0"
MARK="0x2"
ROUTE_TABLE="252"

# Local ranges to exclude from VPN
LOCAL_V4_RANGE="172.16.0.0/12,192.168.0.0/16"

# Disable strict reverse path filtering
sysctl -w net.ipv4.conf.all.rp_filter=0
sysctl -w net.ipv4.conf.br0.rp_filter=0
sysctl -w net.ipv4.conf.default.rp_filter=0

echo "Cleaning up old rules..."
# --- A. Clean up Old Rules (IPv4 only) ---

# Remove Mangle (Marking) rules
iptables -t mangle -D PREROUTING -i $LAN_INTERFACE -p tcp -m multiport --dports 80,443,8080 -j MARK --set-mark $MARK 2>/dev/null
iptables -t mangle -D PREROUTING -i $LAN_INTERFACE -d $LOCAL_V4_RANGE -j RETURN 2>/dev/null
iptables -t mangle -D PREROUTING -i $LAN_INTERFACE -p tcp --dport 22 -j ACCEPT 2>/dev/null
iptables -t mangle -D PREROUTING -i $LAN_INTERFACE -p tcp --dport 16756 -j ACCEPT 2>/dev/null

# Remove NAT rules
iptables -t nat -D POSTROUTING -o $TUN_INTERFACE -j SNAT --to-source 172.16.250.1 2>/dev/null

# Remove IP Rules
ip rule del fwmark $MARK 2>/dev/null
iptables -D FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null

# Remove Routes
ip route del default dev $TUN_INTERFACE table $ROUTE_TABLE 2>/dev/null

# Remove Filter (Forward) bypasses
iptables -D FORWARD -i $LAN_INTERFACE -o $TUN_INTERFACE -j ACCEPT 2>/dev/null
iptables -D FORWARD -i $LAN_INTERFACE -o wg0 -j ACCEPT 2>/dev/null

# --- B. Set up New Rules (IPv4 only) ---
echo "Setting up Split Tunnel Rules..."

iptables -I FORWARD 1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# 1. Mark Traffic
# Bypass local traffic
iptables -t mangle -A PREROUTING -i $LAN_INTERFACE -d $LOCAL_V4_RANGE -j RETURN

# Bypass Router Management Ports
iptables -t mangle -A PREROUTING -i $LAN_INTERFACE -p tcp --dport 22 -j ACCEPT
iptables -t mangle -A PREROUTING -i $LAN_INTERFACE -p tcp --dport 16756 -j ACCEPT

# MARK HTTP/HTTPS Traffic for VPN
iptables -t mangle -A PREROUTING -i $LAN_INTERFACE -p tcp -m multiport --dports 80,443,8080 -j MARK --set-mark $MARK

# 2. Set Routing
# Use Table 252 for Marked Traffic
ip rule add fwmark $MARK lookup $ROUTE_TABLE

# Route Marked Traffic via TUN
ip route add default dev $TUN_INTERFACE table $ROUTE_TABLE

# 3. Allow Forwarding (Firewall)
# Allow traffic entering TUN (VPN) to be forwarded to LAN/WAN
iptables -I FORWARD 1 -i $LAN_INTERFACE -o $TUN_INTERFACE -j ACCEPT
# Allow returning traffic from TUN to LAN (Established connections)
iptables -I FORWARD 2 -o $LAN_INTERFACE -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# 4. WireGuard Routes (Optional)
if ip link show wg0 &> /dev/null; then
    iptables -I FORWARD 3 -i $LAN_INTERFACE -o wg0 -j ACCEPT
    ip route add 10.69.101.0/24 dev wg0 scope link
    ip route add 10.88.101.0/24 dev wg0 scope link
    ip route add 192.168.33.0/24 dev wg0 scope link
fi

# 5. Masquerade
# Masquerade traffic going out of TUN so kernel knows where to return packets
iptables -t nat -A POSTROUTING -o $TUN_INTERFACE -j SNAT --to-source 172.16.250.1

echo "Rules applied successfully."
