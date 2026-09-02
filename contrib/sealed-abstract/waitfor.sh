#!/bin/bash
# Wait for a build, and ALWAYS come back.
#
#   waitfor.sh <deadline_s> <pid> <log> <marker_regex>
#
# WHY THIS EXISTS. A waiter that polls a log for a marker hangs forever when
# the process that writes the log is killed: the marker never arrives, the
# loop never ends, and the session loses track of what is running. That
# happened twice. This waiter ends on the FIRST of three conditions and always
# says which one, so silence is never a possible outcome:
#
#   0  the marker appeared
#   2  the process is gone (crashed, killed, or finished without the marker)
#   3  the deadline passed
#
# It prints the tail of the log whatever happens, so a return is never empty.
set -u
DEADLINE=${1:?deadline in seconds}
PID=${2:?pid to watch}
LOG=${3:?log file}
MARKER=${4:?marker regex}

start=$(date +%s)
reason=""
while :; do
    if [ -f "$LOG" ] && grep -qE "$MARKER" "$LOG" 2>/dev/null; then
        reason="MARKER"; code=0; break
    fi
    if ! kill -0 "$PID" 2>/dev/null; then
        reason="PROCESS-GONE"; code=2; break
    fi
    elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -ge "$DEADLINE" ]; then
        reason="DEADLINE"; code=3; break
    fi
    # Never sleep past the deadline: a fixed poll interval overshot a 6 s
    # deadline by 5 s in the test.
    left=$(( DEADLINE - elapsed ))
    sleep $(( left < 5 ? left : 5 ))
done

elapsed=$(( $(date +%s) - start ))
echo "WAITFOR $reason after ${elapsed}s (deadline ${DEADLINE}s, pid $PID)"
if [ -f "$LOG" ]; then
    echo "--- last 12 lines of $(basename "$LOG") ---"
    tail -12 "$LOG" | cut -c1-140
else
    echo "--- no log at $LOG ---"
fi
exit $code
