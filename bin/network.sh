#!/usr/bin/env bash

echo "===== NETWORK MONITOR DEMO ====="
echo "Time: $(date)"
echo

echo "Network interfaces (ip addr):"
ip addr show 2>/dev/null || echo "ip command not found"

echo
echo "Raw /proc/net/dev:"
cat /proc/net/dev

echo
echo "===== END NETWORK MONITOR DEMO ====="

