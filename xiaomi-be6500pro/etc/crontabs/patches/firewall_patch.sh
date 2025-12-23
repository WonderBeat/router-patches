#!/bin/sh
set -x

[ -e "/tmp/firewall_patch.log" ] && exit 0

cat >/data/userdisk/appdata/firewall.sh <<'EOF'
#!/bin/sh

reload() {

    TUN_INTERFACE="tun0"
    if ! ip link show "$TUN_INTERFACE" &> /dev/null; then
        echo "Error: tun_interface does not exist"
        exit 1
    fi

    WAN_INTERFACE="eth0.1" 
    LAN_INTERFACE="br-lan"
    MARK="0x2"
    ROUTE_TABLE="252" 

    LOCAL_V4_RANGE="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
    LOCAL_V6_RANGE="fc00::/7"

    # 1. Clean up only our specific Forwarding bypass
    iptables -D FORWARD -i $LAN_INTERFACE -o $TUN_INTERFACE -j ACCEPT 2>/dev/null
    ip rule del fwmark $MARK 2>/dev/null
    ip -6 rule del fwmark $MARK 2>/dev/null
    iptables -t mangle -D PREROUTING -i $LAN_INTERFACE -p tcp -m multiport --dports 80,443,8080 -j MARK --set-mark $MARK 2>/dev/null
    iptables -t mangle -D PREROUTING -i $LAN_INTERFACE -d $LOCAL_V4_RANGE -j RETURN 2>/dev/null
    iptables -t mangle -D PREROUTING -i $LAN_INTERFACE -p tcp --dport 16756 -j ACCEPT 2>/dev/null
    iptables -t mangle -D PREROUTING -i $LAN_INTERFACE -p tcp --dport 22 -j ACCEPT 2>/dev/null
    iptables -t nat -D POSTROUTING -o $TUN_INTERFACE -j SNAT --to-source 172.16.250.1 2>/dev/null
    iptables -D FORWARD -i $LAN_INTERFACE -j ACCEPT 2>/dev/null
    iptables -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null

    # 2. Add the specific bypass at the TOP of the Forward chain
    # This prevents the packet from hitting the "zone_lan_dest_REJECT" rule
    iptables -I FORWARD 1 -i $LAN_INTERFACE -o $TUN_INTERFACE -j ACCEPT

    # --- 3. Set up Policy and Routing ---
    echo "Setting up policy and routes..."
    ip rule add fwmark $MARK lookup $ROUTE_TABLE
    ip -6 rule add fwmark $MARK lookup $ROUTE_TABLE
    ip route add default dev $TUN_INTERFACE table $ROUTE_TABLE
    ip -6 route add default dev $TUN_INTERFACE table $ROUTE_TABLE

    # --- 4. Rules in the mangle table (to mark traffic) ---
    # Bypass proxy for specific ports (e.g., router management)
    iptables -t mangle -A PREROUTING -i $LAN_INTERFACE -p tcp --dport 22 -j ACCEPT
    iptables -t mangle -A PREROUTING -i $LAN_INTERFACE -p tcp --dport 16756 -j ACCEPT

    # Do not mark traffic destined for the local network
    iptables -t mangle -A PREROUTING -i $LAN_INTERFACE -d $LOCAL_V4_RANGE -j RETURN
    ip6tables -t mangle -A PREROUTING -i $LAN_INTERFACE -d $LOCAL_V6_RANGE -j RETURN

    iptables -t mangle -A PREROUTING -i $LAN_INTERFACE -p tcp -m multiport --dports 80,443,8080 -j MARK --set-mark $MARK
    ip6tables -t mangle -A PREROUTING -i $LAN_INTERFACE -p tcp -m multiport --dports 80,443,8080 -j MARK --set-mark $MARK
    # =================================================================


    # --- 4b. Rules in the filter table (to allow traffic to be forwarded) ---
    # Allow established and related connections to pass through
    iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    ip6tables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

    # Allow all traffic from the LAN interface to be forwarded
    iptables -A FORWARD -i $LAN_INTERFACE -j ACCEPT
    ip6tables -A FORWARD -i $LAN_INTERFACE -j ACCEPT

    # --- 4c. THE CRUCIAL SNAT RULE ---
    # Masquerade traffic going into the TUN interface so the kernel accepts it.
    iptables -t nat -A POSTROUTING -o $TUN_INTERFACE -j SNAT --to-source 172.16.250.1

    iptables-save > /tmp/after-update.txt
    echo "Rules applied successfully."
    return 0
}

case "$1" in
    reload)
        reload
        ;;
    *)
        echo "plugin_firewall: not support cmd: $1"
        ;;
esac
EOF

chmod +x /data/userdisk/appdata/firewall.sh

if /data/userdisk/appdata/firewall.sh reload; then
  echo "firewall enabled" >/tmp/firewall_patch.log
else
  echo "firewall reload failed; not creating /tmp/firewall_patch.log" >&2
  exit 1
fi
