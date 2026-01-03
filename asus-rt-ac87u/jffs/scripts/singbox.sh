#!/bin/sh

set -e

[ -e "/tmp/singbox.lock" ] && exit 0

# Prevent concurrent execution
LOCKFILE="/tmp/sing-concurrent.lock"

if [ -f "$LOCKFILE" ]; then
  echo "Script is already running. If this is an error, remove $LOCKFILE"
  exit 1
fi

touch "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT

TMPDIR=/tmp/sing-box
PROG=${TMPDIR}/sing-box
CONF=/jffs/config/sing-box/config.json
VERSION="1.12.14"
IPK_URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box_${VERSION}_openwrt_arm_cortex-a9.ipk"
VER_FILE=${TMPDIR}/version.txt

modprobe tun

curl -L https://curl.se/ca/cacert.pem -o /tmp/cacert.pem

export SSL_CERT_FILE=/tmp/cacert.pem

wait_for_tmp() {
  while [ ! -d /tmp ]; do
    sleep 1
  done
  mkdir -p "$TMPDIR"
}

download_binary() {
  mkdir -p "$TMPDIR"
  local_version=""
  [ -x "$PROG" ] && local_version=$("$PROG" version 2>/dev/null | head -n1 | awk '{print $NF}')

  if [ ! -x "$PROG" ]; then
    echo "[sing-box] Binary not found, downloading ${VERSION}..."
  else
    echo "[sing-box] sing-box v${local_version:-unknown} (up to date)"
    return 0
  fi
  IPK_FILE=/tmp/install.ipk

  curl -L -o "$IPK_FILE" "$IPK_URL" || return 1
  mkdir -p /tmp/sing-box-extract

  tar -xzf $IPK_FILE -C /tmp/sing-box-extract
  tar -xzf /tmp/sing-box-extract/data.tar.gz -C /tmp/sing-box-extract/
  mv /tmp/sing-box-extract/usr/bin/sing-box $PROG
  rm $IPK_FILE
  rm -rf /tmp/sing-box-extract

  chmod +x "$PROG"
  echo "[sing-box] Installed sing-box"
}

start_service() {
  wait_for_tmp
  download_binary || {
    echo "[sing-box] Failed to download binary!"
    return 1
  }

  ${PROG} run -c ${CONF} -D ${TMPDIR} &

  ver=$("$PROG" version 2>/dev/null | head -n1 | awk '{print $NF}')
  echo "[sing-box] Started (v${ver:-unknown})"
}

start_service

sleep 4
for i in $(seq 1 30); do
  if ip link show tun0 >/dev/null 2>&1 && ip link show wg0 >/dev/null 2>&1; then
    echo "Interfaces tun0 and wg0 are available"
    break
  fi
  sleep 4
done
/jffs/scripts/firewall.sh
echo "singbox enabled" >/tmp/singbox_patch.log

touch /tmp/singbox.lock
