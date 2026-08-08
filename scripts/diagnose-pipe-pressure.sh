#!/usr/bin/env bash
# Report how much of the kernel's pipe buffer pool is in use and which processes
# are holding it.
#
# macOS allocates pipe buffers from a fixed pool. When it runs dry every new
# pipe gets a small buffer instead of the usual 16-64 KB, and anything that
# writes more than that into a pipe nobody is draining deadlocks. A build is the
# usual casualty: its compiler probe writes ~20 KB and hangs with no output at
# `ExecuteExternalTool ... clang -v -E -dM`. reload.sh refuses to start in that
# state and points here.
#
# The reading that matters is the one taken under load. A pipe measured at rest
# can come back a healthy 65536 on a machine where the same pipe collapses to
# 512 the moment a build allocates its own -- the build is what tips the pool
# over. So this reports both, and trusts the second.
#
# Long-lived processes are what drain the pool, so the fix is to quit whatever
# tops this list (or reboot).
set -euo pipefail

# Held open while the reading is taken: enough to show whether the pool has room
# for a build's own pipes, far fewer than a real build creates.
HEADROOM_PROBES=96
MINIMUM_BYTES=32768

measure() {
  python3 -c '
import os
import sys

held = []
try:
    for _ in range(int(sys.argv[1])):
        held.append(os.pipe())
    read_fd, write_fd = os.pipe()
    os.set_blocking(write_fd, False)
    capacity = 0
    try:
        while True:
            try:
                capacity += os.write(write_fd, b"x" * 1024)
            except BlockingIOError:
                break
    finally:
        os.close(read_fd)
        os.close(write_fd)
    print(capacity)
finally:
    for read_fd, write_fd in held:
        os.close(read_fd)
        os.close(write_fd)
' "$1"
}

at_rest="$(measure 0)"
under_load="$(measure "$HEADROOM_PROBES")"

echo "Pipe capacity at rest:                 ${at_rest} bytes"
echo "Pipe capacity with ${HEADROOM_PROBES} pipes in use:     ${under_load} bytes"
if (( under_load >= MINIMUM_BYTES )); then
  echo "Healthy. A build's ~20 KB compiler probe will not deadlock."
else
  echo "DEGRADED. Expected >= ${MINIMUM_BYTES}. A build will hang at the compiler probe."
  if (( at_rest >= MINIMUM_BYTES )); then
    echo "  (At rest it looks fine, which is why a single reading is not enough.)"
  fi
fi
echo ""
echo "Live pipes, counted once each and grouped by the process holding them:"
echo ""

# Descendants inherit a pipe's file descriptors, so the same pipe shows up under
# many processes. Count each pipe object once, against whichever process lsof
# lists first, and sum the buffer sizes to get the pool usage.
snapshot="$(lsof -n 2>/dev/null | awk '
  $5 == "PIPE" && $6 ~ /^0x/ && !seen[$6]++ {
    count[$1]++
    bytes[$1] += $7
    total_count++
    total_bytes += $7
  }
  END {
    for (name in count) {
      printf "%7d pipes %8.1f MB  %s\n", count[name], bytes[name] / 1048576, name
    }
    printf "TOTAL %d pipes %.1f MB\n", total_count, total_bytes / 1048576 > "/dev/stderr"
  }
' 2>/tmp/cmux-pipe-total.$$)"

# `head` closing the pipe early would raise SIGPIPE under `set -o pipefail`, so
# rank into a variable rather than streaming into it.
ranked="$(printf '%s\n' "$snapshot" | sort -rn)"
printf '%s\n' "$ranked" | awk 'NR <= 15'
echo ""
cat "/tmp/cmux-pipe-total.$$"
rm -f "/tmp/cmux-pipe-total.$$"
