#!/bin/sh

[ -e "/tmp/singbox_patch.log" ] && return 0

cat <<'EOF' >/etc/init.d/sing-box
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1

TMPDIR=/tmp/sing-box
PROG=${TMPDIR}/sing-box
CONF=/data/sing-box/config.json
VERSION="1.12.13"
IPK_URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box_${VERSION}_openwrt_aarch64_generic.ipk"
VER_FILE=${TMPDIR}/version.txt

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
    [ -x "$PROG" ] && local_version=$("$PROG" version 2>/dev/null | head -n1 | awk '{print $NF}')

    if [ ! -x "$PROG" ]; then
        echo "[sing-box] Binary not found, downloading ${VERSION}..."
    else
        echo "[sing-box] sing-box v${local_version:-unknown} (up to date)"
        return 0
    fi
    IPK_FILE=/tmp/install.ipk

    if command -v curl >/dev/null 2>&1; then
        curl -L -o "$IPK_FILE" "$IPK_URL" || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$IPK_FILE" "$IPK_URL" || return 1
    else
        echo "[sing-box] Neither curl nor wget found!"
        return 1
    fi
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
    wait_for_network
    download_binary || { echo "[sing-box] Failed to download binary!"; return 1; }

    procd_open_instance
    procd_set_param command ${PROG} run -c ${CONF} -D ${TMPDIR}
    procd_set_param limits core="unlimited"
    procd_set_param limits nofile="1000000 1000000"
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance

    ver=$("$PROG" version 2>/dev/null | head -n1 | awk '{print $NF}')
    echo "[sing-box] Started (v${ver:-unknown})"
}

stop_service() {
    pid=$(ps w | grep "$PROG run -c" | grep -v grep | awk '{print $1}')
    [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
}

service_triggers() {
    procd_add_reload_trigger "sing-box"
}
EOF

chmod +x /etc/init.d/sing-box
/etc/init.d/sing-box enable
/etc/init.d/sing-box start
echo "singbox enabled" >/tmp/singbox_patch.log
