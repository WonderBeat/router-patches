#!/bin/sh
# ExecStartPre for sing-box.service: make sure a usable pinned binary exists.
#
# Contract: exit 0 whenever a working binary is present, even if the download
# failed. Returning non-zero here would stop systemd from starting a sing-box
# that was perfectly fine, turning a GitHub hiccup into an outage.

VERSION="1.13.19"
# Our own fork build, same binary the asus and xiaomi run: upstream parses
# fragment/record_fragment and then silently ignores them for REALITY, and the
# fallback config here sets exactly those. Upstream would look fine and fail.
# Cortex-A7 is 32-bit and we only publish a GOARM=5 arm build (its OpenWrt
# target list covers arm_cortex-a7). Go reports "linux/arm" for any GOARM, so
# ARCH below is what the binary self-reports, not the asset name.
ARCH="arm"
ASSET="sing-box-${VERSION}-linux-armv5"
DIR="/opt/sing-box"
PROG="$DIR/sing-box"
TAR_URL="https://github.com/WonderBeat/sing-box-extended/releases/download/reality-fragment-${VERSION}/${ASSET}.tar.gz"

installed_version() { [ -x "$PROG" ] && "$PROG" version 2>/dev/null | head -n1 | awk '{print $NF}'; }
installed_arch()    { [ -x "$PROG" ] && "$PROG" version 2>/dev/null | sed -n 's|.*linux/||p' | head -n1; }

mkdir -p "$DIR"

if [ "$(installed_version)" = "$VERSION" ] && [ "$(installed_arch)" = "$ARCH" ]; then
  exit 0
fi

echo "[sing-box] fetching v${VERSION} ${ARCH}"
# Staged on the SD card, not /tmp: /tmp is a ~243MB RAM-backed tmpfs on a 484MB box
# and this tarball is ~27MB before extraction.
TAR="$DIR/sing-box.tar.gz"
UNPACK="$DIR/unpack"

if ! curl -L --speed-limit 10240 --speed-time 30 --retry 3 --retry-all-errors \
     --connect-timeout 10 --max-time 900 -o "$TAR" "$TAR_URL"; then
  echo "[sing-box] download failed"
  [ -x "$PROG" ] && { echo "[sing-box] continuing with installed binary"; exit 0; }
  exit 1
fi

rm -rf "$UNPACK"; mkdir -p "$UNPACK"
# Extract everything and locate the binary rather than hardcoding the archive's
# top-level directory, which differs between upstream and our release assets.
if ! tar -xzf "$TAR" -C "$UNPACK"; then
  echo "[sing-box] extract failed"
  rm -rf "$TAR" "$UNPACK"
  [ -x "$PROG" ] && exit 0
  exit 1
fi
rm -f "$TAR"
NEW_BIN=$(find "$UNPACK" -type f -name sing-box | head -n1)
if [ -z "$NEW_BIN" ]; then
  echo "[sing-box] archive contained no sing-box binary"
  rm -rf "$UNPACK"
  [ -x "$PROG" ] && exit 0
  exit 1
fi
chmod +x "$NEW_BIN"

# Only replace a working binary once the new one proves it runs and reports what
# was asked for; a truncated or wrong-arch download must not take the box down.
new_version=$("$NEW_BIN" version 2>/dev/null | head -n1 | awk '{print $NF}')
new_arch=$("$NEW_BIN" version 2>/dev/null | sed -n 's|.*linux/||p' | head -n1)
if [ "$new_version" != "$VERSION" ] || [ "$new_arch" != "$ARCH" ]; then
  echo "[sing-box] downloaded binary reports '${new_version:-nothing}/${new_arch:-nothing}', want ${VERSION}/${ARCH}"
  rm -rf "$UNPACK"
  [ -x "$PROG" ] && exit 0
  exit 1
fi

# rename() over a running binary is safe: the running process keeps the old inode.
mv -f "$NEW_BIN" "$PROG"
rm -rf "$UNPACK"
chmod +x "$PROG"
echo "[sing-box] installed v${VERSION} ${ARCH}"
exit 0
