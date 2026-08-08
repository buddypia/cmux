#!/usr/bin/env bash
# Report how much of the kernel's pipe buffer pool is in use and which processes
# are holding it.
#
# macOS allocates pipe buffers from a fixed pool. When it runs dry every new
# pipe gets a 2 KB buffer instead of the usual 16-64 KB, and anything that
# writes more than that into a pipe nobody is draining deadlocks. xcodebuild is
# the usual casualty: its compiler probe writes ~20 KB and hangs with no output
# at `ExecuteExternalTool ... clang -v -E -dM`. reload.sh refuses to start in
# that state and points here.
#
# Long-lived processes are what drain the pool, so the fix is to quit whatever
# tops this list (or reboot).
set -euo pipefail

capacity="$(python3 -c '
import os
r, w = os.pipe()
os.set_blocking(w, False)
n = 0
try:
    while True:
        try:
            n += os.write(w, b"x" * 1024)
        except BlockingIOError:
            break
finally:
    os.close(r)
    os.close(w)
print(n)
')"

echo "New pipes on this machine get: ${capacity} bytes"
if (( capacity >= 16384 )); then
  echo "Healthy. xcodebuild's ~20 KB compiler probe will not deadlock."
else
  echo "DEGRADED. Expected 16384-65536. xcodebuild will hang at the compiler probe."
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
