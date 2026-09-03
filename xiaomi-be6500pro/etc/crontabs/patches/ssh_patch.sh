#!/bin/sh
[ -e "/tmp/ssh_patch.log" ] && return 0

SSH_EN=$(nvram get ssh_en)
if [ "$SSH_EN" != "1" ]; then
  nvram set ssh_en=1
  nvram commit
fi

if grep -q '= "release"' /etc/init.d/dropbear; then
  sed -i 's/= "release"/= "XXXXXX"/g' /etc/init.d/dropbear
fi

cp /data/ssh/dropbear_rsa_host_key /etc/dropbear/

/etc/init.d/dropbear enable
/etc/init.d/dropbear restart

# Was /data/ssh/autorized_keys: the misspelling made this a silent no-op, so no
# authorized_keys was ever installed and key auth depended on whatever happened
# to already be in ramfs. /etc is ramfs, so this must run on every boot.
cp /data/ssh/authorized_keys /etc/dropbear/authorized_keys
chmod 600 /etc/dropbear/authorized_keys

echo "ssh enabled" >/tmp/ssh_patch.log
