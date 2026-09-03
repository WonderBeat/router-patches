#!/bin/sh
# Two jobs in one script:
#   no args  -> cheap sentinel, runs every minute, reloads ONLY if the plumbing
#               is actually gone.
#   force    -> full rebuild, runs hourly.
#
# Why the sentinel exists: restarting sing-box tears down tun0, which drops
# "default dev tun0" from table vpn. The ip rule (fwmark 0x2 -> vpn) survives, so
# marked packets fall through to main and the whole LAN silently bypasses the
# tunnel - pages that only work through the proxy (youtube here) just stop, with
# nothing in any log. A restart done outside singbox_patch (init.d directly, or
# by hand) reapplies nothing, so before this the damage lasted until the next
# hourly rebuild.
FIREWALL=/data/userdisk/appdata/firewall.sh

if [ "$1" != force ]; then
	marks=$(iptables -w 2 -t mangle -S PREROUTING 2>/dev/null | grep -c "MARK --set-xmark 0x2")
	route=$(ip route show table vpn 2>/dev/null | grep -c "dev tun0")
	[ "$marks" -ge 1 ] && [ "$route" -ge 1 ] && exit 0
	logger -t firewall_patch "plumbing missing (marks=$marks route=$route), reapplying"
fi

"$FIREWALL" reload
