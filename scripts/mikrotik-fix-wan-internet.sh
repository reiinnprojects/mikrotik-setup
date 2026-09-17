#!/bin/bash
# Thin wrapper: WAN/DHCP/NAT steps only. See mikrotik-router-parity-fix.sh.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/mikrotik-router-parity-fix.sh" --wan-only "$@"
