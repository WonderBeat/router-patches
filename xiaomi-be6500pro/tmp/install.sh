crontab -l >/tmp/current_crontab && if ! grep -q 'singbox_patch.sh' /tmp/current_crontab; then
  echo '*/1 * * * * /etc/crontabs/patches/singbox_patch.sh >/dev/null 2>&1' >>/tmp/current_crontab
  echo '*/1 * * * * /etc/crontabs/patches/firewall_patch.sh >/dev/null 2>&1' >>/tmp/current_crontab
  crontab /tmp/current_crontab
fi
