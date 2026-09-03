crontab -l >/tmp/current_crontab && if ! grep -q 'singbox_patch.sh' /tmp/current_crontab; then
	echo '*/1 * * * * /etc/crontabs/patches/singbox_patch.sh >/dev/null 2>&1' >>/tmp/current_crontab
	echo '13 */1 * * * /etc/crontabs/patches/firewall_patch.sh force >/dev/null 2>&1' >>/tmp/current_crontab
	echo '*/1 * * * * /etc/crontabs/patches/firewall_patch.sh >/dev/null 2>&1' >>/tmp/current_crontab
	echo '*/10 * * * * /etc/crontabs/patches/ssh_patch.sh >/dev/null 2>&1' >>/tmp/current_crontab
	echo '0 */2 * * * /etc/crontabs/patches/distro_update.sh >/dev/null 2>&1' >>/tmp/current_crontab
	echo '0 */6 * * * /etc/crontabs/patches/update-durev-vless.sh >/tmp/update_net.log 2>&1; /etc/crontabs/patches/log-remote.sh /tmp/update_net.log' >>/tmp/current_crontab
	crontab /tmp/current_crontab
fi

# Existing installs kept the old line that discarded updater output, which hid
# the non-zero exits the updater now reports on validation/rollback failure.
if grep -q 'update-durev-vless.sh >/dev/null' /tmp/current_crontab; then
	sed -i 's#^0 \*/6 \* \* \* /etc/crontabs/patches/update-durev-vless.sh >/dev/null 2>&1$#0 */6 * * * /etc/crontabs/patches/update-durev-vless.sh >/tmp/update_net.log 2>\&1; /etc/crontabs/patches/log-remote.sh /tmp/update_net.log#' /tmp/current_crontab
	crontab /tmp/current_crontab
fi

if ! grep -q 'nebula_patch.sh' /tmp/current_crontab; then
	echo '*/1 * * * * /etc/crontabs/patches/nebula_patch.sh >/dev/null 2>&1' >>/tmp/current_crontab
	crontab /tmp/current_crontab
fi

if ! grep -q 'rule-sets.sh' /tmp/current_crontab; then
	echo '41 4 * * * /etc/crontabs/patches/rule-sets.sh >/dev/null 2>&1' >>/tmp/current_crontab
	crontab /tmp/current_crontab
fi

# Was */1: a full rule rebuild every minute is pointless churn. Boot and every
# sing-box restart already reapply the rules (singbox_patch calls firewall.sh
# reload when it starts the daemon), so hourly only covers the rare case of the
# firmware flushing our chains behind our back.
if grep -q '^\*/1 \* \* \* \* /etc/crontabs/patches/firewall_patch.sh' /tmp/current_crontab; then
	sed -i 's#^\*/1 \* \* \* \* /etc/crontabs/patches/firewall_patch.sh#13 */1 * * * /etc/crontabs/patches/firewall_patch.sh force#' /tmp/current_crontab
	crontab /tmp/current_crontab
fi

# The hourly job is the unconditional rebuild, so it must pass 'force'; without
# it the hourly run is just another sentinel and the rules are never rebuilt
# while the plumbing happens to look present.
if grep -q '^13 \*/1 \* \* \* /etc/crontabs/patches/firewall_patch.sh >' /tmp/current_crontab; then
	sed -i 's#^13 \*/1 \* \* \* /etc/crontabs/patches/firewall_patch.sh >#13 */1 * * * /etc/crontabs/patches/firewall_patch.sh force >#' /tmp/current_crontab
	crontab /tmp/current_crontab
fi

# The hourly rebuild alone leaves up to an hour of silent tunnel bypass after any
# restart, so pair it with the per-minute sentinel (cheap: two greps, exits
# immediately when the marks and the tun0 route are both present).
if ! grep -q '^\*/1 \* \* \* \* /etc/crontabs/patches/firewall_patch.sh >' /tmp/current_crontab; then
	echo '*/1 * * * * /etc/crontabs/patches/firewall_patch.sh >/dev/null 2>&1' >>/tmp/current_crontab
	crontab /tmp/current_crontab
fi

# Every block above is "grep, else append", so a line whose text later changes
# (adding 'force') gets appended again on the next run and cron then runs it
# twice. Collapse duplicates instead of making each block smarter.
if [ "$(sort /tmp/current_crontab | uniq -d | grep -c .)" -gt 0 ]; then
	awk '!seen[$0]++' /tmp/current_crontab >/tmp/current_crontab.dedup
	mv /tmp/current_crontab.dedup /tmp/current_crontab
	crontab /tmp/current_crontab
fi

if ! grep -q 'log-cap.sh' /tmp/current_crontab; then
	echo '*/10 * * * * /etc/crontabs/patches/log-cap.sh >/dev/null 2>&1' >>/tmp/current_crontab
	crontab /tmp/current_crontab
fi

# Existing installs refreshed every 30m, which the upstream lists never warrant.
if grep -q '^\*/30 \* \* \* \* /etc/crontabs/patches/rule-sets.sh' /tmp/current_crontab; then
	sed -i 's#^\*/30 \* \* \* \* /etc/crontabs/patches/rule-sets.sh#41 4 * * * /etc/crontabs/patches/rule-sets.sh#' /tmp/current_crontab
	crontab /tmp/current_crontab
fi

# dnsmasq must try sing-box first and the public server only as a fallback.
# Without strictorder dnsmasq prefers whichever upstream answers fastest, so
# client queries could silently bypass sing-box's DNS - losing the hijack and
# any DNS-based routing - while still looking healthy.
if [ "$(uci -q get dhcp.@dnsmasq[0].strictorder)" != "1" ]; then
	uci set dhcp.@dnsmasq[0].strictorder='1'
	uci commit dhcp
	/etc/init.d/dnsmasq reload >/dev/null 2>&1
fi
