#!/bin/bash
# Build all ignition configs

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Building All Ignition Configs ==="
echo ""

echo "--- Building Bootstrap Ignition ---"
"${SCRIPT_DIR}/build-bootstrap.sh"
echo ""

echo "--- Building Master Ignition ---"
"${SCRIPT_DIR}/build-master.sh"
echo ""

echo "--- Building Worker Ignition ---"
"${SCRIPT_DIR}/build-worker.sh"
echo ""

echo "=== All Ignition Configs Built ==="
echo ""
echo "Files:"
ls -la "${IGNITION_DIR:-${SCRIPT_DIR}/../assets/ignition}"/*.ign 2>/dev/null || ls -la "$(dirname "${SCRIPT_DIR}")/assets/ignition"/*.ign
echo ""
echo "Serve these files for installation:"
echo "  cd ${IGNITION_DIR:-${SCRIPT_DIR}/../assets/ignition} && python3 -m http.server 8080"
