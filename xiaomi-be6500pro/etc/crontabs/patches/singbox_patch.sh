#!/bin/sh

# Paths for this outer script. The init.d file below is written from a quoted
# heredoc, so the PROG/CONF it defines exist only inside that generated file and
# are NOT visible here.
SINGBOX_BIN=/tmp/sing-box/sing-box
SINGBOX_LOG=/tmp/box.log
INIT_SCRIPT=/etc/init.d/sing-box

# Single source of truth for the version. It is injected into the generated
# init.d below rather than duplicated, so bumping it here is enough.
# Fork build: upstream's reality client parses fragment/record_fragment and then
# ignores them, so every reality handshake went out as one record and the ISP
# dropped it (all durev endpoints timed out). This build applies them.
VERSION="1.13.19"

# The arm64 build is worth pinning explicitly: measured against the armv7 build
# on this box it used 76% less CPU per byte (~1790 -> ~424 ticks/100MB), moved
# 71% more throughput, and dropped idle CPU by ~98%. The armv7 build lacks the
# ARMv8 AES/crypto assembly, so it software-emulates every cipher operation.
ARCH="arm64"

singbox_running() {
    ps w | grep -v grep | grep -q "$SINGBOX_BIN run"
}


installed_version() {
    [ -x "$SINGBOX_BIN" ] || return 1
    "$SINGBOX_BIN" version 2>/dev/null | head -n1 | awk '{print $NF}'
}

# Read the arch out of the binary itself rather than trusting a stamp file, so
# the restart gate below reflects what is actually installed.
installed_arch() {
    [ -x "$SINGBOX_BIN" ] || return 1
    "$SINGBOX_BIN" version 2>/dev/null | sed -n 's|.*linux/||p' | head -n1
}

report_status() {
    if singbox_running; then
        echo "[sing-box] running $("$SINGBOX_BIN" version 2>/dev/null | head -n1) ($(installed_arch))"
    else
        echo "[sing-box] NOT running after start; last log lines:"
        tail -5 "$SINGBOX_LOG" 2>/dev/null
    fi
}

# Emit the init.d script. The shebang and VERSION are echoed so the version
# stays defined in one place; the remainder is a quoted heredoc so nothing
# else gets expanded by this outer shell.
generate_init() {
    {
        echo '#!/bin/sh /etc/rc.common'
        echo "VERSION=\"$VERSION\""
        echo "ARCH=\"$ARCH\""
        cat <<'EOF'
START=99
USE_PROCD=1

TMPDIR=/tmp/sing-box
PROG=${TMPDIR}/sing-box
CONF=/data/sing-box/config.json
TAR_URL="https://github.com/WonderBeat/sing-box-extended/releases/download/reality-fragment-${VERSION}/sing-box-${VERSION}-linux-${ARCH}.tar.gz"
VER_FILE=${TMPDIR}/version.txt
# Records the arch of the installed binary. Without it the check below compares
# versions only, so switching ARCH at the same version looks "up to date" and
# the old-arch binary is kept forever.
ARCH_FILE=${TMPDIR}/arch.txt
LOCKFILE="/tmp/$(basename "$0").lock"

# Cleanup function to remove lock file
remove_lock() {
    rm -f "$LOCKFILE"
}

wait_for_tmp() {
    while [ ! -d /tmp ]; do
        sleep 1
    done
    mkdir -p "$TMPDIR"
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

download_binary() {
    mkdir -p "$TMPDIR"
    local_version=""
    local_arch=""
    [ -x "$PROG" ] && local_version=$("$PROG" version 2>/dev/null | head -n1 | awk '{print $NF}')
    # Prefer the arch reported by the binary; fall back to the stamp so an
    # install predating this file is treated as unknown and re-fetched.
    [ -x "$PROG" ] && local_arch=$("$PROG" version 2>/dev/null | sed -n 's|.*linux/||p' | head -n1)
    [ -z "$local_arch" ] && local_arch=$(cat "$ARCH_FILE" 2>/dev/null)

    # Compare against the pinned VERSION *and* ARCH rather than merely testing
    # for the file, otherwise neither a version bump nor an arch switch would
    # ever be picked up.
    if [ "$local_version" = "$VERSION" ] && [ "$local_arch" = "$ARCH" ]; then
        echo "[sing-box] sing-box v${local_version} ${local_arch} (up to date)"
        return 0
    fi
    if [ "$local_version" = "$VERSION" ] && [ -n "$local_version" ]; then
        echo "[sing-box] switching arch ${local_arch:-unknown} -> ${ARCH}..."
    elif [ -n "$local_version" ]; then
        echo "[sing-box] upgrading v${local_version} -> v${VERSION} (${ARCH})..."
    else
        echo "[sing-box] Binary not found, downloading ${VERSION} (${ARCH})..."
    fi
    TAR_FILE="${TMPDIR}/sing-box.tar.gz"
    # Unpack inside TMPDIR so the install is a same-filesystem rename rather
    # than a copy, and so a failed run leaves nothing behind in /tmp.
    UNPACK="${TMPDIR}/unpack"
    EXTRACT_DIR="${UNPACK}/sing-box-${VERSION}-linux-${ARCH}"

    # The tarball is ~27MB, which a router uplink will not finish inside a
    # short fixed deadline; abort on a stalled transfer instead.
    if command -v curl >/dev/null 2>&1; then
        curl -L --speed-limit 10240 --speed-time 30 --retry 3 --retry-all-errors \
            --connect-timeout 10 --max-time 600 -o "$TAR_FILE" "$TAR_URL" || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$TAR_FILE" "$TAR_URL" || return 1
    else
        echo "[sing-box] Neither curl nor wget found!"
        return 1
    fi

    rm -rf "$UNPACK"
    mkdir -p "$UNPACK"
    if ! tar -xzf "$TAR_FILE" -C "$UNPACK" "sing-box-${VERSION}-linux-${ARCH}/sing-box"; then
        echo "[sing-box] extract failed"
        rm -rf "$TAR_FILE" "$UNPACK"
        return 1
    fi
    rm -f "$TAR_FILE"
    chmod +x "${EXTRACT_DIR}/sing-box"

    # Only replace a working binary once the new one proves it executes and
    # reports the expected version; a truncated or wrong-arch download would
    # otherwise take the tunnel down until someone noticed.
    new_version=$("${EXTRACT_DIR}/sing-box" version 2>/dev/null | head -n1 | awk '{print $NF}')
    new_arch=$("${EXTRACT_DIR}/sing-box" version 2>/dev/null | sed -n 's|.*linux/||p' | head -n1)
    if [ "$new_version" != "$VERSION" ] || [ "$new_arch" != "$ARCH" ]; then
        echo "[sing-box] downloaded binary reports '${new_version:-nothing}/${new_arch:-nothing}', expected ${VERSION}/${ARCH}; keeping current"
        rm -rf "$UNPACK"
        return 1
    fi

    # rename() over a running binary is safe: the running process keeps the old
    # inode, so this never yields ETXTBSY.
    mv -f "${EXTRACT_DIR}/sing-box" "$PROG"
    rm -rf "$UNPACK"
    chmod +x "$PROG"
    # Stamp only after a validated install, so a crash mid-download cannot leave
    # a stamp claiming an arch that was never installed.
    echo "$VERSION" > "$VER_FILE"
    echo "$ARCH" > "$ARCH_FILE"
    echo "[sing-box] Installed sing-box v${VERSION} ${ARCH}"
}

start_service() {
    wait_for_tmp
    wait_for_network

    # A lock left behind by a killed/rebooted run would otherwise block the
    # service from ever starting again, so verify the owning pid is alive.
    if [ -e "$LOCKFILE" ]; then
        oldpid=$(cat "$LOCKFILE" 2>/dev/null)
        # A bare kill -0 trusts any live pid, and after a reboot that number is
        # usually held by an unrelated process: that wedged this script into
        # reporting "already running" every run while the daemon stayed down.
        if [ -n "$oldpid" ] && grep -qs singbox "/proc/$oldpid/cmdline"; then
            echo "Error: Another instance of this script is already running (pid $oldpid)." >&2
            return 1
        fi
        echo "[sing-box] removing stale lock $LOCKFILE"
        rm -f "$LOCKFILE"
    fi
    trap remove_lock EXIT INT TERM HUP
    echo $$ > "$LOCKFILE"

    # A failed download must not take the tunnel down. If a usable binary is
    # already present, run it rather than leaving the service stopped after the
    # restart that this upgrade path performs.
    if ! download_binary; then
        if [ -x "$PROG" ]; then
            echo "[sing-box] download failed; continuing with the installed binary"
        else
            echo "[sing-box] Failed to download binary and none installed!"
            return 1
        fi
    fi

    procd_open_instance
    procd_set_param command ${PROG} run -c ${CONF} -D ${TMPDIR}
    procd_set_param limits core="unlimited"
    procd_set_param limits nofile="1000000 1000000"
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance

    ver=$("$PROG" version 2>/dev/null | head -n1 | awk '{print $NF}')
    echo "[sing-box] Started (v${ver:-unknown} ${ARCH})"
}

stop_service() {
    pid=$(ps w | grep "$PROG run -c" | grep -v grep | awk '{print $1}')
    [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
}

service_triggers() {
    procd_add_reload_trigger "sing-box"
}
EOF
    } > "$1"
}

NEW_INIT=/tmp/sing-box-init.new
generate_init "$NEW_INIT" || { echo "[sing-box] failed to generate init script"; exit 1; }

# Refresh the installed init.d whenever it drifts from what this script
# generates. The previous version bailed out early if the file merely existed,
# so edits here (including version bumps) never reached the router.
if ! cmp -s "$NEW_INIT" "$INIT_SCRIPT"; then
    echo "[sing-box] updating $INIT_SCRIPT"
    cat "$NEW_INIT" > "$INIT_SCRIPT"
    chmod +x "$INIT_SCRIPT"
fi
rm -f "$NEW_INIT"

"$INIT_SCRIPT" enable

# A running daemon on the wrong version *or arch* has to be restarted to pick up
# the new binary; procd would otherwise keep the old process alive indefinitely.
# Checking the version alone was the bug that silently kept the armv7 process
# running after the init.d had already been updated to fetch arm64.
current=$(installed_version)
current_arch=$(installed_arch)
if singbox_running && { [ "$current" != "$VERSION" ] || [ "$current_arch" != "$ARCH" ]; }; then
    echo "[sing-box] running v${current:-unknown}/${current_arch:-unknown}, want v${VERSION}/${ARCH}; restarting"
    "$INIT_SCRIPT" restart
    sleep 5
    # A restart tears down tun0 and the rules bound to it, including
    # "default dev tun0" in table vpn - without which every marked packet falls
    # through to main and the LAN bypasses the tunnel silently. The per-minute
    # firewall_patch sentinel catches it, but reapply now to close even that gap.
    # sleep 5 above is for tun0 to exist; the sentinel covers it being slower.
    FIREWALL=/data/userdisk/appdata/firewall.sh
    [ -x "$FIREWALL" ] && "$FIREWALL" reload
else
    "$INIT_SCRIPT" start
fi

report_status

exit 0
