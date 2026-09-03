#!/bin/sh

LOCKFILE="/tmp/firewall_patch.lock"

for i in $(seq 1 10); do
  # wg0 is intentionally not required here: sing-box owns the wg endpoint and it
  # may come up after tun0.
  if ip link show tun0 >/dev/null 2>&1; then
    echo "Interface tun0 is available after $i tries"
    break
  fi
  sleep 4
done

reload() {
    # Stale lock from a killed run must not block reloads forever.
    if [ -e "$LOCKFILE" ]; then
        oldpid=$(cat "$LOCKFILE" 2>/dev/null)
        # A bare kill -0 trusts any live pid, and after a reboot that number is
        # usually held by an unrelated process: that wedged this script into
        # reporting "already running" every run while the daemon stayed down.
        if [ -n "$oldpid" ] && grep -qs firewall "/proc/$oldpid/cmdline"; then
            echo "firewall reload already running (pid $oldpid)"
            return 0
        fi
        rm -f "$LOCKFILE"
    fi
    echo $$ > "$LOCKFILE"
    trap 'rm -f "$LOCKFILE"' EXIT INT TERM HUP

    # TCP timestamps off: the timestamp option is a DPI fingerprint (and leaks
    # uptime). This was set by hand here long ago and only lived in the running
    # kernel — /etc/sysctl.conf still says 1, so a reboot silently re-enabled it.
    # Applied from the repo now, on both routers.
    sysctl -w net.ipv4.tcp_timestamps=0 >/dev/null 2>&1

    TUN_INTERFACE="tun0"
    if ! ip link show "$TUN_INTERFACE" >/dev/null 2>&1; then
        echo "Error: $TUN_INTERFACE does not exist"
        return 1
    fi

    # Applying rules while sing-box is down would blackhole marked traffic.
    if ! ps w | grep -v grep | grep -q "/tmp/sing-box/sing-box run"; then
        echo "[sing-box] is not running"
        return 1
    fi

    WAN_INTERFACE="eth0.1"
    LAN_INTERFACE="br-lan"
    MARK="0x2"
    ROUTE_TABLE="252"

    # LAN and router-internal ranges bypass the VPN mark.
    #
    # The overlay prefixes are listed here so that traffic to the wireguard and
    # nebula meshes is never marked in the first place. Without this, a LAN
    # client talking to an overlay host on a redirected port (tcp/443, udp/6000,
    # ...) would be marked and routed into tun0, because the mark rule matches
    # on port alone and ignores the destination.
    #
    # 192.168.11.0/24 is a wg peer prefix but is already covered by the
    # 192.168.0.0/16 entry.
    WG_PREFIXES="10.77.101.0/24,10.69.101.0/24"
    NEBULA_PREFIX="10.88.101.0/24"
    LOCAL_V4_RANGE="172.16.0.0/12,192.168.0.0/16,${WG_PREFIXES},${NEBULA_PREFIX}"
    LOCAL_V6_RANGE="fc00::/7"

    # Explicit rule priorities. These are pinned rather than left to the
    # kernel's auto-assignment so the relative order is guaranteed: overlay
    # lookups must be consulted BEFORE the VPN mark rule, otherwise a marked
    # packet is sent to tun0 no matter what its destination is.
    WG_PRIO="31000"
    NEBULA_PRIO="31001"
    VPN_PRIO="31500"

    # --- custom chain for FORWARD rules (idempotent) ---
    iptables -N SINGBOX_FWD 2>/dev/null
    ip6tables -N SINGBOX_FWD 2>/dev/null
    iptables -F SINGBOX_FWD
    ip6tables -F SINGBOX_FWD
    # ensure jump exists at top of FORWARD
    iptables -D FORWARD -j SINGBOX_FWD 2>/dev/null
    ip6tables -D FORWARD -j SINGBOX_FWD 2>/dev/null
    iptables -I FORWARD 1 -j SINGBOX_FWD
    ip6tables -I FORWARD 1 -j SINGBOX_FWD

    # MSS clamp is intentionally not applied: tun0 MTU 1420 leaves enough room,
    # and clamping broke PMTU discovery for LAN clients.
    iptables -A SINGBOX_FWD -i $LAN_INTERFACE -o $TUN_INTERFACE -j ACCEPT
    iptables -A SINGBOX_FWD -i $LAN_INTERFACE -o wg0 -j ACCEPT
    # Same treatment for nebula. The catch-all `-i $LAN_INTERFACE -j ACCEPT`
    # below already covers it, but being explicit keeps the two overlays
    # symmetric and survives any future tightening of that catch-all.
    iptables -A SINGBOX_FWD -i $LAN_INTERFACE -o nebula -j ACCEPT
    iptables -A SINGBOX_FWD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -A SINGBOX_FWD -i $LAN_INTERFACE -j ACCEPT
    ip6tables -A SINGBOX_FWD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    ip6tables -A SINGBOX_FWD -i $LAN_INTERFACE -j ACCEPT

    # --- nat (delete-before-add) ---
    iptables -t nat -D POSTROUTING -o wg0 -j MASQUERADE 2>/dev/null
    iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
    # Nebula needs the same masquerade, and for a stricter reason than wg0.
    # A forwarded LAN packet keeps its 192.168.33.x source, but nebula is a
    # cryptographically addressed overlay: it only carries traffic sourced from
    # this node's own overlay address (10.88.101.93), and no peer has a route
    # back to the LAN prefix. Without this rule the router itself could reach
    # overlay hosts while every LAN client silently failed to connect.
    #
    # Masquerade is correct here rather than the "no SNAT" reasoning applied to
    # tun0 above: that note is about preserving full-cone NAT for internet-bound
    # UDP, whereas the overlay is a closed mesh where NAT is the only way LAN
    # clients can be represented at all.
    iptables -t nat -D POSTROUTING -o nebula -j MASQUERADE 2>/dev/null
    iptables -t nat -A POSTROUTING -o nebula -j MASQUERADE

    # Clean up an earlier attempt that "reserved" the router's nebula source
    # port by remapping NATed traffic away from it. Testing showed the rule
    # never matched a packet and made no difference: with a single nebula
    # instance running, the handshake succeeded or failed identically with and
    # without it. Moving the router off the port every other node uses is the
    # whole fix, so the rule is removed rather than kept "just in case".
    # The delete is retained so routers that already ran the old script drop it.
    #
    # The old script recorded the reserved port in /tmp, which does not survive a
    # reboot, so the marker cannot be relied on to find the rule. Delete by
    # matching the rule's own distinctive shape (--to-ports 20000-29999 in
    # POSTROUTING) instead, which also catches ports no longer in any config.
    iptables -t nat -S POSTROUTING 2>/dev/null \
        | grep -- '--to-ports 20000-29999' \
        | sed 's/^-A /-D /' \
        | while read -r rule; do
            iptables -t nat $rule 2>/dev/null
        done
    rm -f /tmp/nebula-reserved-port
    # NOTE: do NOT SNAT tun0 traffic. Collapsing all LAN clients onto the single
    # 172.16.255.1/30 address forces symmetric UDP port remapping (e.g. 6969->41750),
    # which breaks full-cone NAT that games/P2P require. sing-box (system
    # stack) is endpoint-independent by default and the return path works via the main
    # table + RELATED,ESTABLISHED accept, so no tun SNAT is needed.
    iptables -t nat -D POSTROUTING -o $TUN_INTERFACE -j SNAT --to-source 172.16.255.1 2>/dev/null

    # Remove every rule at a given priority. `ip rule del priority N` deletes
    # only one rule per call, and WG_PRIO intentionally holds one rule per
    # overlay prefix, so a single delete would leak duplicates on each reload.
    # $2 selects the family ("-4" or "-6"), defaulting to IPv4.
    #
    # The loop is bounded: if a delete ever silently failed to remove the rule
    # it matched, an unbounded loop would spin forever inside a cron job on the
    # router. Ten is far above the handful of prefixes we ever install.
    flush_rule_prio() {
        fam="${2:--4}"
        i=0
        while [ "$i" -lt 10 ]; do
            ip "$fam" rule show | grep -q "^$1:" || break
            ip "$fam" rule del priority "$1" 2>/dev/null || break
            i=$((i+1))
        done
    }

    # --- policy routing (delete-before-add) ---
    echo "Setting up policy and routes..."
    # The VPN rule gets an explicit priority so the overlay rules below can be
    # placed ahead of it deterministically. Both the old auto-assigned rule and
    # any rule at the pinned priority are removed first, so upgrading from the
    # previous layout does not leave a duplicate behind.
    ip rule del fwmark $MARK 2>/dev/null
    flush_rule_prio $VPN_PRIO
    ip rule add fwmark $MARK lookup $ROUTE_TABLE priority $VPN_PRIO
    ip -6 rule del fwmark $MARK 2>/dev/null
    flush_rule_prio $VPN_PRIO -6
    ip -6 rule add fwmark $MARK lookup $ROUTE_TABLE priority $VPN_PRIO
    ip route del default dev $TUN_INTERFACE table $ROUTE_TABLE 2>/dev/null
    ip route add default dev $TUN_INTERFACE table $ROUTE_TABLE
    ip -6 route del default dev $TUN_INTERFACE table $ROUTE_TABLE 2>/dev/null
    ip -6 route add default dev $TUN_INTERFACE table $ROUTE_TABLE

    # No explicit wg0 scope-link routes here: sing-box owns the wg endpoint and
    # installs its own routes, so adding them manually caused conflicting entries.
    #
    # Where sing-box puts those peer allowed_ips routes is not stable. It has
    # been observed both ways on this router:
    #   - in its own auto-numbered table (e.g. 290928627) with NO ip rule
    #     pointing at it, so the table was never consulted and AWG traffic fell
    #     through to main and left via the WAN (handshakes still worked because
    #     they ride the vless outbound, while data packets went nowhere);
    #   - directly in main, where unmarked traffic finds them fine.
    # Handle both: discover the table, and fall back to main.
    #
    # This rule is placed at WG_PRIO, ahead of the VPN mark rule, so overlay
    # traffic reaches wg0 even when the port-based mangle rules have marked it.
    # A `to <prefix>` selector is used rather than a bare lookup so the rule
    # only diverts overlay-bound traffic and cannot capture anything else.
    # Marked traffic is the case that matters: without a rule ahead of the VPN
    # rule, a marked packet is sent to tun0 before main is ever consulted.
    flush_rule_prio $WG_PRIO
    # The table number is chosen by sing-box and changes between runs, so it is
    # discovered rather than hardcoded. `table [0-9][0-9]*` requires at least
    # one digit: `table [0-9]*` also matches the "table local" host route the
    # kernel adds for the wg address, yielding an empty table name.
    #
    # The "local" table is excluded for the same reason: it holds only the
    # router's own address, never the peer prefixes.
    WG_TABLE=$(ip -4 route show table all 2>/dev/null \
        | grep " dev wg0 " | grep -v " table local " \
        | grep -o "table [0-9][0-9]*" | awk '{print $2}' | head -1)
    # No numbered table means sing-box put the routes straight into main.
    if [ -z "$WG_TABLE" ] && ip -4 route show table main 2>/dev/null | grep -q " dev wg0"; then
        WG_TABLE=main
    fi
    if [ -n "$WG_TABLE" ]; then
        # A default route in that table would send *all* matching traffic into
        # wg, so only wire it up when the table holds specific prefixes.
        # main always has a default (the WAN), but the `to <prefix>` selectors
        # keep the lookup scoped to the overlays, so it cannot swallow anything.
        # The old code refused this table whenever it held a default route. The
        # endpoint carries 0.0.0.0/0 in allowed_ips, so that refusal was
        # permanent and left main with no route to 10.77.101.0/24 at all:
        # inbound amnezia ssh reached dropbear and the reply was dropped, which
        # is why this box looked dead on 10.77.101.125 while its peer handshook
        # every 100s. Every rule below is `to <prefix>`, so a default route in
        # the table can never be reached for anything outside those prefixes.
        #
        # One rule per prefix keeps the diversion tightly scoped. A lookup that
        # finds no route falls through to the next rule, so listing a prefix the
        # tunnel does not currently carry is harmless.
        for p in $(echo "$WG_PREFIXES" | tr ',' ' '); do
            ip rule add to "$p" lookup "$WG_TABLE" priority $WG_PRIO
        done
        echo "wg0 routes: ${WG_PREFIXES} -> table $WG_TABLE"
    else
        # Not fatal: wg0 may simply not be up yet.
        echo "wg0 route table not found, skipping wg policy rule"
    fi

    # Nebula owns its own tun device and installs a scope-link route for its
    # /24 into the main table, so unmarked traffic already finds it. The
    # problem is only the mark: a marked packet is diverted to tun0 before main
    # is ever consulted. Sending nebula-bound traffic to main ahead of the VPN
    # rule restores the intended path without duplicating nebula's route.
    flush_rule_prio $NEBULA_PRIO
    if ip link show nebula >/dev/null 2>&1; then
        ip rule add to "$NEBULA_PREFIX" lookup main priority $NEBULA_PRIO
        echo "nebula routes: ${NEBULA_PREFIX} -> main"
    else
        echo "nebula interface not up, skipping nebula policy rule"
    fi

    # --- mangle PREROUTING (flush and rebuild) ---
    #
    # Flush, then append in order. This chain is used by nothing else on the box
    # (verified live: 11 unique rules, all ours), so flushing is safe, and it is
    # the only way to guarantee ordering - which is load-bearing here, because
    # every RETURN must precede the MARK rules or local and overlay traffic gets
    # diverted into tun0.
    #
    # This replaces per-rule delete-before-add, which had two failure modes:
    #   - a comma list in -d expands to one rule PER address on add, but a single
    #     -D with the same list does not remove them all, so three overlay
    #     prefixes leaked on every reload. The live table reached 12137 rules of
    #     which 11 were unique, and this chain is walked for every packet.
    #   - draining those with a -D loop is O(n^2) (each -D rescans the table) and
    #     took minutes on this CPU, while re-appending the survivors after the
    #     MARK rules silently inverted the ordering above.
    # A flush is O(1) and self-heals a table any earlier version bloated.
    iptables -t mangle -F PREROUTING
    ip6tables -t mangle -F PREROUTING 2>/dev/null

    iptables -t mangle -A PREROUTING -i $LAN_INTERFACE -p tcp --dport 22 -j RETURN
    iptables -t mangle -A PREROUTING -i $LAN_INTERFACE -p tcp --dport 16756 -j RETURN
    # One rule per CIDR; never a comma-separated -d (see above).
    for cidr in $(echo "$LOCAL_V4_RANGE" | tr ',' ' '); do
        iptables -t mangle -A PREROUTING -i $LAN_INTERFACE -d "$cidr" -j RETURN
    done
    ip6tables -t mangle -A PREROUTING -i $LAN_INTERFACE -d $LOCAL_V6_RANGE -j RETURN

    # Hosts that run their own sing-box and must reach their proxy servers
    # untouched. Intercepting them breaks REALITY: the handshake to <node>:443 is
    # accepted by this box's tun, sniffed and re-routed by SNI, so the cover
    # domain can be dialled instead of the actual node and the connection just
    # times out. It also pushes their durev traffic through this box's detour,
    # which durev is required not to use.
    # 192.168.33.92 = asus RT-AC87U while it is relocated onto this LAN.
    PROXY_HOSTS="192.168.33.92"
    for h in $PROXY_HOSTS; do
        iptables -t mangle -A PREROUTING -i $LAN_INTERFACE -s "$h" -j RETURN
    done

    # 6969 stays in both lists: LAN clients using it (including their nebula) are
    # proxied, which external peers depend on. The router's own nebula is
    # unaffected because these all match -i $LAN_INTERFACE, and locally generated
    # packets never traverse PREROUTING. What did break the router's nebula was
    # NAT, not marking; see the port reservation above.
    TCP_DPORTS="80,443,8080,6443,6969,32243,2022"
    UDP_DPORTS="443,6000,6443,6969,8080,32243,2022"
    iptables -t mangle -A PREROUTING -i $LAN_INTERFACE -p tcp -m multiport --dports $TCP_DPORTS -j MARK --set-mark $MARK
    ip6tables -t mangle -A PREROUTING -i $LAN_INTERFACE -p tcp -m multiport --dports $TCP_DPORTS -j MARK --set-mark $MARK
    iptables -t mangle -A PREROUTING -i $LAN_INTERFACE -p udp -m multiport --dports $UDP_DPORTS -j MARK --set-mark $MARK
    ip6tables -t mangle -A PREROUTING -i $LAN_INTERFACE -p udp -m multiport --dports $UDP_DPORTS -j MARK --set-mark $MARK

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
