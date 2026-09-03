#!/bin/sh
# Install and supervise nebula on Asuswrt-Merlin.
#
# Ported from the xiaomi nebula_patch.sh, which relies on procd for respawn and
# so is not reusable here: this firmware has no procd, so the script is written to
# be safely re-run from cron every minute and starts the daemon only when it is
# not already running.
#
# Certs and config.yaml are deployed by distro_update.sh from the repo; this only
# fetches the binary (into tmpfs, so it re-downloads after each reboot).
# The binary lives on jffs, not in tmpfs: at ~24MB it was re-downloaded and
# re-extracted on every boot, which cost RAM on a 256MB box and made the mesh
# depend on GitHub being reachable at boot. jffs2 wear is a non-issue when the
# write happens once per version bump.
NEBULA_DIR=/jffs/nebula
PROG=${NEBULA_DIR}/nebula
# Download scratch stays in tmpfs so the 12MB tarball never touches flash and
# cannot survive a failed install.
DL_DIR=/tmp/nebula-dl
DATA_DIR=/jffs/config/nebula
CONF=${DATA_DIR}/config.yaml
VER_FILE=${NEBULA_DIR}/version.txt
ARCH_FILE=${NEBULA_DIR}/arch.txt
LOG=/tmp/nebula.log
LOGTAG=nebula
VERSION="v1.11.0"

# RT-AC87U is a dual-core Cortex-A9 (ARMv7), but only the armv5 build actually
# runs here: arm-7 and arm-6 both die with SIGILL (measured). They stay in the
# list, after arm-5, so a firmware with a newer userspace can still use them.
ARCH_CANDIDATES="arm-5 arm-6 arm-7"

LOCKFILE=/tmp/nebula_patch.lock

nebula_running() {
  ps w | grep -v grep | grep -q "${PROG} -config"
}

# Concurrent cron runs would race on the same tmpfs install; a lock whose owner
# is gone must not block forever.
if [ -e "$LOCKFILE" ]; then
  oldpid=$(cat "$LOCKFILE" 2>/dev/null)
  # A bare kill -0 trusts any live pid, and after a reboot that number is
  # usually held by an unrelated process: that wedged this script into
  # reporting "already running" every run while the daemon stayed down.
  if [ -n "$oldpid" ] && grep -qs nebula "/proc/$oldpid/cmdline"; then
    exit 0
  fi
  rm -f "$LOCKFILE"
fi
echo $$ >"$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT INT TERM HUP

# Nothing to supervise until the repo has delivered config and certs; starting
# without them would just fail every minute and fill the log.
for f in "$CONF" "${DATA_DIR}/ca.crt" "${DATA_DIR}/asus-router.crt" "${DATA_DIR}/asus-router.key"; do
  [ -f "$f" ] || {
    logger -t "$LOGTAG" "missing $f, not starting"
    exit 1
  }
done

# Fast path: already up, nothing to do. This is the usual cron outcome.
nebula_running && exit 0

normalize_version() { echo "$1" | sed 's/^v//'; }

install_binary() {
  mkdir -p "$NEBULA_DIR"
  have_ver=""
  [ -x "$PROG" ] && have_ver=$("$PROG" -version 2>/dev/null | head -n1 | awk '{print $NF}')
  have_arch=$(cat "$ARCH_FILE" 2>/dev/null)
  want=$(normalize_version "$VERSION")

  # Identify the install by version AND arch: a fallback to a different arch keeps
  # the same version, so a version-only check would keep a broken binary forever.
  if [ "$have_ver" = "$want" ] && [ -n "$have_arch" ] && [ -x "$PROG" ]; then
    return 0
  fi

  # A part-written 24MB binary on a full jffs would also break sing-box's
  # rule-sets, so refuse rather than fill the filesystem.
  avail=$(df -k "$NEBULA_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
  case "$avail" in
    ''|*[!0-9]*) : ;;
    *) [ "$avail" -lt 51200 ] && {
         logger -t "$LOGTAG" "only ${avail}K free on $NEBULA_DIR, need ~50M (unpack + install); not installing"
         return 1
       } ;;
  esac

  for arch in $ARCH_CANDIDATES; do
    url="https://github.com/slackhq/nebula/releases/download/${VERSION}/nebula-linux-${arch}.tar.gz"
    mkdir -p "$DL_DIR"
    tar_file="${DL_DIR}/nebula.tar.gz"
    # Unpack on jffs, not in the tmpfs scratch: the install below is a rename,
    # and a cross-device mv would open the running binary with O_TRUNC (ETXTBSY).
    unpack="${NEBULA_DIR}/unpack"

    # This firmware's curl predates --retry-all-errors and aborts on it.
    curl -sfL --http1.1 --connect-timeout 10 --max-time 600 \
      --speed-limit 1024 --speed-time 30 --retry 3 \
      -o "$tar_file" "$url" || continue

    rm -rf "$unpack"
    mkdir -p "$unpack"
    # The tarball ships 'nebula' at its root, which would collide with the
    # /tmp/nebula directory, so unpack into a subdir and rename into place.
    tar -xzf "$tar_file" -C "$unpack" nebula 2>/dev/null || {
      rm -rf "$DL_DIR" "$unpack"
      continue
    }
    chmod +x "${unpack}/nebula"

    # Only accept a build that actually executes on this CPU and reports the
    # expected version; a wrong-ABI download dies here instead of at boot.
    got=$("${unpack}/nebula" -version 2>/dev/null | head -n1 | awk '{print $NF}')
    if [ "$got" != "$want" ]; then
      logger -t "$LOGTAG" "nebula-linux-${arch} did not run (reported '${got:-nothing}'), trying next arch"
      rm -rf "$DL_DIR" "$unpack"
      continue
    fi

    mv -f "${unpack}/nebula" "$PROG"
    rm -rf "$DL_DIR" "$unpack"
    echo "$want" >"$VER_FILE"
    echo "$arch" >"$ARCH_FILE"
    logger -t "$LOGTAG" "installed nebula ${want} (${arch})"
    return 0
  done

  rm -rf "$DL_DIR" "${NEBULA_DIR}/unpack"
  logger -t "$LOGTAG" "no usable nebula build for this CPU"
  return 1
}

install_binary || exit 1

# config.yaml asks for 4MB socket buffers, but setsockopt is silently clamped to
# net.core.*mem_max, so the request is a no-op without raising these first.
for knob in rmem_max wmem_max; do
  cur=$(sysctl -n "net.core.$knob" 2>/dev/null || echo 0)
  case "$cur" in
    ''|*[!0-9]*) : ;;
    *) [ "$cur" -lt 4194304 ] && sysctl -w "net.core.$knob=4194304" >/dev/null 2>&1 ;;
  esac
done

# Dual-core box: leave a core for the datapath rather than letting Go spin up
# threads for every CPU it thinks it has.
GOMAXPROCS=2
export GOMAXPROCS

nohup "$PROG" -config "$CONF" >>"$LOG" 2>&1 &
sleep 2
if nebula_running; then
  logger -t "$LOGTAG" "started nebula (pid $(ps w | grep -v grep | grep "${PROG} -config" | awk '{print $1}' | head -n1))"
else
  logger -t "$LOGTAG" "nebula failed to stay up, see $LOG"
  exit 1
fi
exit 0
