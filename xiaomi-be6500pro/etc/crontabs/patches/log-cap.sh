#!/bin/sh
# Cap every log this box writes. /tmp is ramfs and /var is a symlink into it, so
# any log here is resident RAM: /tmp is a 431MB tmpfs and nothing rotates it.
# Runs from cron, so it covers sing-box, nebula, the updaters and anything added
# later without per-tool wiring.
#
# Truncate in place rather than rotate: a daemon holding the file open keeps its
# fd valid across a truncate, while mv/unlink would leave it writing to an
# unlinked inode and the log would silently stop.
MAX=${1:-131072}

for f in /tmp/*.log /tmp/*/*.log; do
  [ -f "$f" ] || continue
  size=$(wc -c <"$f" 2>/dev/null) || continue
  case "$size" in
    ''|*[!0-9]*) continue ;;
  esac
  [ "$size" -gt "$MAX" ] || continue
  : >"$f"
  logger -t log-cap "truncated $f (was ${size}B)"
done
