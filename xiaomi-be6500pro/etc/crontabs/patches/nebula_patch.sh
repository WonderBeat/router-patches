#!/bin/sh
# Nebula mesh patch for Xiaomi BE6500Pro.
# Mirrors singbox_patch.sh structure. Downloads nebula (linux-arm-7, matching our
# 32-bit ARM userspace) into /tmp/nebula and runs it as a procd service.
#
# Config + certs + keys are deployed by distro_update.sh to /data/nebula:
#   ca.crt          -> CA certificate ("Gladiators")
#   xiaomi.crt      -> node cert  (name=xiaomi, ip=10.88.101.93/24)
#   xiaomi.key      -> X25519 private key for that cert
#   config.yaml     -> nebula config (pki points at the three files above)
#
# Nebula deliberately runs on the plain WAN path. Its lighthouses are reached
# directly, NOT through sing-box, so nothing here should mark or reroute its
# traffic.

# Paths for this outer script. The PROG/CONF defined inside the quoted heredoc
# below belong to the generated init.d only and are not visible here.
# Persistent: at ~24MB this was re-downloaded and re-extracted into tmpfs on
# every boot, which also made the mesh depend on GitHub at boot time.
NEBULA_BIN=/data/other_vol/nebula/nebula
DATA_DIR="/data/nebula"
CONF="${DATA_DIR}/config.yaml"
INIT_SCRIPT=/etc/init.d/nebula

# Single source of truth for the version; injected into the generated init.d
# below so a bump here is enough to roll out a new build.
VERSION="v1.11.0"

# busybox pgrep matches the process NAME only, so the old "nebula -config"
# pattern never matched and the running-check was always false. Match the
# full command line via ps, consistent with the other patch scripts.
nebula_running() {
  ps w | grep -v grep | grep -q "${NEBULA_BIN} -config"
}

# nebula prints "Version: 1.11.0" while VERSION is tagged "v1.11.0", so the
# leading v is stripped before comparing.
installed_version() {
  [ -x "$NEBULA_BIN" ] || return 1
  "$NEBULA_BIN" -version 2>/dev/null | head -n1 | awk '{print $NF}'
}

report_status() {
  if nebula_running; then
    echo "[nebula] running $("$NEBULA_BIN" -version 2>/dev/null | head -n1)"
  else
    echo "[nebula] NOT running after start"
    logread 2>/dev/null | grep -i nebula | tail -5
  fi
}

# Emit the init.d script. The shebang and VERSION are echoed so the version
# stays defined in one place; the rest is a quoted heredoc so nothing else is
# expanded by this outer shell.
generate_init() {
  {
    echo '#!/bin/sh /etc/rc.common'
    echo "VERSION=\"$VERSION\""
    cat <<'EOF'
START=98
USE_PROCD=1

# BIN_DIR is persistent (/data is only 1.6M free, other_vol has room); DL_DIR is
# the tmpfs scratch for the tarball so 12MB of download never lands on flash.
BIN_DIR=/data/other_vol/nebula
PROG=${BIN_DIR}/nebula
DL_DIR=/tmp/nebula-dl
DATADIR=/data/nebula
CONF=${DATADIR}/config.yaml
# arm64, not arm-7: this CPU is aarch64 with the AES and PMULL extensions, and
# Go's 32-bit ARM build has no assembly path for them, so AES-GCM falls back to
# software on the exact work that saturates the CPU during a mesh transfer.
# (sing-box runs the arm-7 build for unrelated reasons; the two are independent.)
# download_binary refuses to install a binary that does not execute and report
# the expected version, so a wrong-arch download cannot take the mesh down.
TAR_URL="https://github.com/slackhq/nebula/releases/download/${VERSION}/nebula-linux-arm64.tar.gz"
VER_FILE=${BIN_DIR}/version.txt
# Which release artifact the installed binary came from. Recorded separately
# because an arch switch does not change the reported version.
ARCH_FILE=${BIN_DIR}/arch.txt
LOCKFILE="/tmp/$(basename "$0").lock"

remove_lock() {
    rm -f "$LOCKFILE"
}

wait_for_tmp() {
    while [ ! -d /tmp ]; do
        sleep 1
    done
    mkdir -p "$BIN_DIR"
}

wait_for_network() {
    . /lib/functions/network.sh
    network_flush_cache
    network_get_ipaddr ip wan
    while [ -z "$ip" ]; do
        sleep 2
        network_flush_cache
        network_get_ipaddr ip wan
    done
}

# nebula reports "Version: 1.11.0" but VERSION is the git tag "v1.11.0".
normalize_version() {
    echo "$1" | sed 's/^v//'
}

download_binary() {
    mkdir -p "$BIN_DIR" "$DL_DIR"
    local_version=""
    [ -x "$PROG" ] && local_version=$("$PROG" -version 2>/dev/null | head -n1 | awk '{print $NF}')
    want=$(normalize_version "$VERSION")

    # The installed build is identified by version AND arch. Version alone is not
    # enough: switching the download from arm-7 to arm64 keeps the same version,
    # so a version-only check silently kept running the old 32-bit binary.
    want_arch=$(echo "$TAR_URL" | sed 's#.*/nebula-linux-##; s#\.tar\.gz$##')
    have_arch=$(cat "$ARCH_FILE" 2>/dev/null)

    if [ "$local_version" = "$want" ] && [ "$have_arch" = "$want_arch" ]; then
        echo "[nebula] nebula ${local_version} (up to date)"
        return 0
    fi
    if [ "$local_version" = "$want" ] && [ "$have_arch" != "$want_arch" ]; then
        echo "[nebula] same version but arch ${have_arch:-unknown} -> ${want_arch}, reinstalling..."
    fi
    if [ -n "$local_version" ]; then
        echo "[nebula] upgrading ${local_version} -> ${want}..."
    else
        echo "[nebula] Binary not found, downloading ${VERSION}..."
    fi

    # Unpack beside PROG, not in the tmpfs scratch: the install below is a
    # rename, and a cross-device mv would open the running binary with O_TRUNC
    # (ETXTBSY). The tarball itself stays in tmpfs.
    UNPACK="${BIN_DIR}/unpack"
    TAR_FILE="${DL_DIR}/nebula.tar.gz"

    # Abort on a stalled transfer rather than a short fixed deadline, which a
    # router uplink may not meet.
    if command -v curl >/dev/null 2>&1; then
        curl -L --speed-limit 10240 --speed-time 30 --retry 3 --retry-all-errors \
            --connect-timeout 10 --max-time 600 -o "$TAR_FILE" "$TAR_URL" || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$TAR_FILE" "$TAR_URL" || return 1
    else
        echo "[nebula] Neither curl nor wget found!"
        return 1
    fi

    rm -rf "$UNPACK"
    mkdir -p "$UNPACK"
    if ! tar -xzf "$TAR_FILE" -C "$UNPACK" nebula; then
        echo "[nebula] extract failed"
        rm -rf "$TAR_FILE" "$UNPACK"
        return 1
    fi
    rm -f "$TAR_FILE"
    chmod +x "${UNPACK}/nebula"

    # Only replace a working binary once the new one proves it executes and
    # reports the expected version; a truncated or wrong-arch download would
    # otherwise take the mesh down until someone noticed.
    new_version=$("${UNPACK}/nebula" -version 2>/dev/null | head -n1 | awk '{print $NF}')
    if [ "$new_version" != "$want" ]; then
        echo "[nebula] downloaded binary reports '${new_version:-nothing}', expected ${want}; keeping current"
        rm -rf "$UNPACK"
        return 1
    fi

    # rename() over a running binary is safe: the running process keeps the old
    # inode, so this never yields ETXTBSY.
    mv -f "${UNPACK}/nebula" "$PROG"
    rm -rf "$UNPACK"
    chmod +x "$PROG"
    echo "$VERSION" > "$VER_FILE"
    echo "$want_arch" > "$ARCH_FILE"
    echo "[nebula] Installed nebula ${VERSION}"
}

start_service() {
    wait_for_tmp
    wait_for_network

    # Note: this export does NOT reach nebula. procd spawns the daemon from the
    # instance definition below, so only `procd_set_param env` is inherited.
    # It is kept only for anything start_service itself runs.
    export GOMAXPROCS=3

    # config.yaml asks for 4MB socket buffers, but setsockopt is silently clamped
    # to net.core.*mem_max (208KB by default), so the request is a no-op without
    # this. Raised only to what nebula actually asks for; SO_RCVBUFFORCE is not
    # used since a plain sysctl is visible and revertible.
    for knob in rmem_max wmem_max; do
        cur=$(sysctl -n "net.core.$knob" 2>/dev/null || echo 0)
        [ "$cur" -lt 4194304 ] && sysctl -w "net.core.$knob=4194304" >/dev/null 2>&1
    done

    # Certs and config are deployed separately by distro_update.sh; starting
    # without them would just crash-loop under procd respawn. Both are
    # required, so this checks each one.
    if [ ! -f "${DATADIR}/ca.crt" ] || [ ! -f "$CONF" ]; then
        echo "[nebula] missing config/certs under $DATADIR, not starting"
        return 0
    fi

    # A lock left behind by a killed/rebooted run would otherwise block the
    # service from ever starting again, so verify the owning pid is alive.
    if [ -e "$LOCKFILE" ]; then
        oldpid=$(cat "$LOCKFILE" 2>/dev/null)
        # A bare kill -0 trusts any live pid, and after a reboot that number is
        # usually held by an unrelated process: that wedged this script into
        # reporting "already running" every run while the daemon stayed down.
        if [ -n "$oldpid" ] && grep -qs nebula "/proc/$oldpid/cmdline"; then
            echo "Error: Another instance of this script is already running (pid $oldpid)." >&2
            return 1
        fi
        echo "[nebula] removing stale lock $LOCKFILE"
        rm -f "$LOCKFILE"
    fi
    trap remove_lock EXIT INT TERM HUP
    echo $$ > "$LOCKFILE"

    # A failed download must not take the mesh down. If a usable binary is
    # already present, run it rather than leaving the service stopped.
    if ! download_binary; then
        if [ -x "$PROG" ]; then
            echo "[nebula] download failed; continuing with the installed binary"
        else
            echo "[nebula] Failed to download binary and none installed!"
            return 1
        fi
    fi

    procd_open_instance
    # 3 of 4 cores. Measured under a real mesh transfer, nebula sat at 170% CPU
    # against the previous 200% cap, i.e. saturated, with a full core idle.
    # One core is deliberately left for sing-box, which carries all LAN internet
    # traffic and matters more than backup throughput.
    procd_set_param env GOMAXPROCS=3
    procd_set_param command ${PROG} -config ${CONF}
    procd_set_param limits core="unlimited"
    procd_set_param limits nofile="1000000 50000"
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance

    ver=$("$PROG" -version 2>/dev/null | awk '{print $NF}')
    echo "[nebula] Started (${ver:-unknown})"
}

stop_service() {
    pid=$(ps w | grep "$PROG -config" | grep -v grep | awk '{print $1}')
    [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
}

service_triggers() {
    procd_add_reload_trigger "nebula"
}
EOF
  } >"$1"
}

NEW_INIT=/tmp/nebula-init.new
generate_init "$NEW_INIT" || {
  echo "[nebula] failed to generate init script"
  exit 1
}

# Refresh the installed init.d whenever it drifts from what this script
# generates. The previous version bailed out early if the file merely existed,
# so edits here (including version bumps) never reached the router.
if ! cmp -s "$NEW_INIT" "$INIT_SCRIPT"; then
  echo "[nebula] updating $INIT_SCRIPT"
  cat "$NEW_INIT" >"$INIT_SCRIPT"
  chmod +x "$INIT_SCRIPT"
fi
rm -f "$NEW_INIT"

"$INIT_SCRIPT" enable

# A running daemon on the wrong version has to be restarted to pick up the new
# binary; procd would otherwise keep the old process alive indefinitely.
# The arch is checked alongside the version for the same reason download_binary
# does: an arm-7 -> arm64 switch keeps the version identical, so a version-only
# comparison leaves the old 32-bit process running forever.
current=$(installed_version)
want=$(echo "$VERSION" | sed 's/^v//')
want_arch=$(grep -m1 '^TAR_URL=' "$INIT_SCRIPT" | sed 's#.*/nebula-linux-##; s#\.tar\.gz.*##')
have_arch=$(cat /tmp/nebula/arch.txt 2>/dev/null)
if nebula_running && [ "$current" = "$want" ] && [ "$have_arch" != "$want_arch" ]; then
  echo "[nebula] running ${current} but arch ${have_arch:-unknown} != ${want_arch}; restarting to reinstall"
  "$INIT_SCRIPT" restart
elif nebula_running && [ "$current" != "$want" ]; then
  echo "[nebula] running ${current:-unknown}, want ${want}; restarting"
  "$INIT_SCRIPT" restart
elif ! nebula_running; then
  "$INIT_SCRIPT" start
fi

report_status

exit 0
