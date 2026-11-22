#!/bin/bash
set -eu

case "${0##*/}" in
    t) signal=TERM ;;
    k) signal=KILL ;;
    *) exit 1 ;;
esac
pid=$(cat supervise/pid)
[[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ]
kill -"$signal" -- "-$pid"
