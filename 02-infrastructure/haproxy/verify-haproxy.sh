#!/bin/bash
# Verify HAProxy configuration

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../config/cluster-vars.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

errors=0

echo "=== HAProxy Verification ==="
echo ""

# Check if HAProxy is running
echo "--- Service Status ---"
if systemctl is-active --quiet haproxy; then
    echo -e "${GREEN}✓${NC} HAProxy is running"
else
    echo -e "${RED}✗${NC} HAProxy is not running"
    errors=$((errors + 1))
fi

# Check ports are listening
echo ""
echo "--- Port Bindings ---"
for port in 6443 22623 80 443 9000; do
    if ss -tlnp | grep -q ":${port} "; then
        echo -e "${GREEN}✓${NC} Port ${port} is listening"
    else
        echo -e "${RED}✗${NC} Port ${port} is not listening"
        errors=$((errors + 1))
    fi
done

# Check stats page
echo ""
echo "--- Stats Page ---"
if curl -s http://localhost:9000/stats | grep -q "HAProxy"; then
    echo -e "${GREEN}✓${NC} Stats page accessible at http://localhost:9000/stats"
else
    echo -e "${YELLOW}!${NC} Stats page not accessible"
fi

# Check backend status
echo ""
echo "--- Backend Status ---"
echo "(Note: Backends will show DOWN until nodes are running)"

# Quick check of HAProxy config
echo ""
echo "--- Configuration Check ---"
if haproxy -c -f /etc/haproxy/haproxy.cfg 2>&1; then
    echo -e "${GREEN}✓${NC} Configuration syntax valid"
else
    echo -e "${RED}✗${NC} Configuration syntax error"
    errors=$((errors + 1))
fi

echo ""
echo "=== Summary ==="
if [[ $errors -eq 0 ]]; then
    echo -e "${GREEN}HAProxy is configured correctly${NC}"
    echo ""
    echo "Backends will be DOWN until nodes boot - this is expected."
    echo "Check http://localhost:9000/stats to monitor backend health."
else
    echo -e "${RED}${errors} error(s) found${NC}"
    exit 1
fi
