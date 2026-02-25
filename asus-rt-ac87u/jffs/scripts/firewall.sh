#!/bin/sh

# CONFIGURATION
TUN_INTERFACE="tun0"
LAN_INTERFACE="br0"
WG_INTERFACE="wg0"
MARK="0x2"
ROUTE_TABLE="252"

# Local ranges to exclude from VPN (Router IP, Sing-Box internal)
LOCAL_V4_RANGE="172.16.0.0/12,192.168.0.0/16,10.69.101.0/24,10.88.101.0/24"

echo "Applying Complete Firewall Rules with Isolated Chain and WG Access..."

# 1. SYSTEM TUNING (Fixes "Network unreachable" and kernel drops)
# Disable Reverse Path Filtering on all interfaces to prevent asymmetric routing drops
sysctl -w net.ipv4.conf.all.rp_filter=0
sysctl -w net.ipv4.conf.br0.rp_filter=0
sysctl -w net.ipv4.conf.default.rp_filter=0
sysctl -w net.ipv4.conf.tun0.rp_filter=0 2>/dev/null
sysctl -w net.ipv4.conf.wg0.rp_filter=0 2>/dev/null

# 2. CLEANUP OLD RULES
# --- Clean up Old Rules (IPv4 only) ---

# Remove old Custom Mangle chain if it exists
iptables -t mangle -D PREROUTING -j VPN-MANGLE 2>/dev/null
iptables -t mangle -F VPN-MANGLE 2>/dev/null
iptables -t mangle -X VPN-MANGLE 2>/dev/null

# Clean up old specific marking rules (to avoid duplicates)
iptables -t mangle -D PREROUTING -i $LAN_INTERFACE -d $LOCAL_V4_RANGE -j RETURN 2>/dev/null
iptables -t mangle -D PREROUTING -i $LAN_INTERFACE -p tcp --dport 22 -j ACCEPT 2>/dev/null
iptables -t mangle -D PREROUTING -i $LAN_INTERFACE -p tcp --dport 16756 -j ACCEPT 2>/dev/null
iptables -t mangle -D PREROUTING -i $LAN_INTERFACE -p tcp -m multiport --dports 80,443,8080 -j MARK --set-mark $MARK 2>/dev/null

# Clean up old NAT rules
iptables -t nat -D POSTROUTING -o $TUN_INTERFACE -j SNAT --to-source 172.16.250.1 2>/dev/null

# Clean up old IP Rules
ip rule del fwmark $MARK 2>/dev/null

# Clean up old Routes
ip route flush table $ROUTE_TABLE 2>/dev/null

# Clean up old Filter (Forward) bypasses
iptables -D FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
iptables -D FORWARD -i $LAN_INTERFACE -o $TUN_INTERFACE -j ACCEPT 2>/dev/null
iptables -D FORWARD -i $LAN_INTERFACE -o $WG_INTERFACE -j ACCEPT 2>/dev/null
iptables -D FORWARD -i $WG_INTERFACE -o $LAN_INTERFACE -j ACCEPT 2>/dev/null
iptables -D FORWARD -o $LAN_INTERFACE -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
iptables -t nat -D POSTROUTING -o $WG_INTERFACE -j MASQUERADE 2>/dev/null
iptables -t nat -D POSTROUTING -s 10.69.101.0/24 -o $LAN_INTERFACE -j MASQUERADE 2>/dev/null
iptables -t nat -D POSTROUTING -s 10.88.101.0/24 -o $LAN_INTERFACE -j MASQUERADE 2>/dev/null

# Clean up old Input rules
iptables -D INPUT -i $WG_INTERFACE -j ACCEPT 2>/dev/null
iptables -D INPUT -i $WG_INTERFACE -p tcp --dport 80 -j ACCEPT 2>/dev/null
iptables -D INPUT -i $WG_INTERFACE -p tcp --dport 443 -j ACCEPT 2>/dev/null
iptables -D INPUT -i $WG_INTERFACE -p tcp --dport 22 -j ACCEPT 2>/dev/null

# 3. SETUP NEW RULES (IPv4 only)

# --- A. SETUP MANGLE (MARKING) CHAIN ---
# Create a custom chain to ensure our logic runs first
iptables -t mangle -N VPN-MANGLE
# Jump ALL traffic in PREROUTING to our custom chain (Priority 1)
iptables -t mangle -I PREROUTING 1 -j VPN-MANGLE

# --- B. SET UP RULES INSIDE VPN-MANGLE ---
# 1. Bypass Local Traffic (Do not mark)
iptables -t mangle -A VPN-MANGLE -i $LAN_INTERFACE -d $LOCAL_V4_RANGE -j RETURN

# 2. Bypass Router Management Ports (Do not mark)
iptables -t mangle -A VPN-MANGLE -i $LAN_INTERFACE -p tcp --dport 22 -j ACCEPT
iptables -t mangle -A VPN-MANGLE -i $LAN_INTERFACE -p tcp --dport 16756 -j ACCEPT

# 3. MARK HTTP/HTTPS Traffic (Send to Sing-Box)
iptables -t mangle -A VPN-MANGLE -i $LAN_INTERFACE -p tcp --dport 80 -j MARK --set-mark $MARK
iptables -t mangle -A VPN-MANGLE -i $LAN_INTERFACE -p tcp --dport 443 -j MARK --set-mark $MARK
iptables -t mangle -A VPN-MANGLE -i $LAN_INTERFACE -p tcp --dport 8080 -j MARK --set-mark $MARK

# --- C. SETUP ROUTING ---
# Use Table 252 for Marked Traffic
ip rule add fwmark $MARK lookup $ROUTE_TABLE
# Route Marked Traffic via TUN
ip route add default dev $TUN_INTERFACE table $ROUTE_TABLE

# --- D. SETUP FILTER (FORWARD) CHAIN ---
# 1. Fix MTU (Clamp MSS to prevent fragmentation)
iptables -I FORWARD 1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# 2. Allow LAN -> Sing-Box (VPN)
iptables -I FORWARD 2 -i $LAN_INTERFACE -o $TUN_INTERFACE -j ACCEPT

# 3. Allow LAN -> WireGuard (Static Routes)
iptables -I FORWARD 3 -i $LAN_INTERFACE -o $WG_INTERFACE -j ACCEPT

# 4. Allow WireGuard -> LAN (Access Router UI/Services)
iptables -I FORWARD 4 -i $WG_INTERFACE -o $LAN_INTERFACE -j ACCEPT

# 5. Allow Returning Traffic (Established connections)
iptables -I FORWARD 5 -o $LAN_INTERFACE -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# --- E. SETUP FILTER (INPUT) CHAIN ---
# Allow WireGuard Full Access to Router Services (Web UI, SSH, All ports)
# This fixes "Connection refused" from WG node
iptables -I INPUT 1 -i $WG_INTERFACE -j ACCEPT

# --- F. SETUP WIREGUARD ROUTES ---
# Ensure static routes for WireGuard exist
if ip link show $WG_INTERFACE >/dev/null 2>&1; then
	ip route add 10.69.101.0/24 dev $WG_INTERFACE scope link 2>/dev/null
	ip route add 10.88.101.0/24 dev $WG_INTERFACE scope link 2>/dev/null
fi

# --- G. SETUP NAT ---
# Masquerade traffic going out of TUN so kernel knows where to return packets
iptables -t nat -A POSTROUTING -o $TUN_INTERFACE -j SNAT --to-source 172.16.250.1
iptables -t nat -A POSTROUTING -o $WG_INTERFACE -j MASQUERADE
iptables -t nat -A POSTROUTING -s 10.69.101.0/24 -o $LAN_INTERFACE -j MASQUERADE
iptables -t nat -A POSTROUTING -s 10.88.101.0/24 -o $LAN_INTERFACE -j MASQUERADE

echo "Rules applied successfully."
