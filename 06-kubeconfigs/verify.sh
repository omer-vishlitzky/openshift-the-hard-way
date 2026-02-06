#!/bin/bash
# Verify kubeconfigs

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh"

KUBECONFIG_DIR="${ASSETS_DIR}/kubeconfigs"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

errors=0

echo "=== Kubeconfig Verification ==="
echo "Directory: ${KUBECONFIG_DIR}"
echo ""

check_kubeconfig() {
    local name=$1
    local expected_server=$2
    local expected_user=$3

    local file="${KUBECONFIG_DIR}/${name}.kubeconfig"

    if [[ ! -f "${file}" ]]; then
        echo -e "${RED}✗${NC} ${name}.kubeconfig - NOT FOUND"
        errors=$((errors + 1))
        return
    fi

    # Check it's valid YAML
    if ! kubectl config view --kubeconfig="${file}" &>/dev/null; then
        echo -e "${RED}✗${NC} ${name}.kubeconfig - INVALID YAML"
        errors=$((errors + 1))
        return
    fi

    # Check server URL
    local server=$(kubectl config view --kubeconfig="${file}" -o jsonpath='{.clusters[0].cluster.server}')
    if [[ "${server}" != "${expected_server}" ]]; then
        echo -e "${RED}✗${NC} ${name}.kubeconfig - server mismatch: got '${server}', expected '${expected_server}'"
        errors=$((errors + 1))
        return
    fi

    # Check user
    local user=$(kubectl config view --kubeconfig="${file}" -o jsonpath='{.users[0].name}')
    if [[ "${user}" != "${expected_user}" ]]; then
        echo -e "${RED}✗${NC} ${name}.kubeconfig - user mismatch: got '${user}', expected '${expected_user}'"
        errors=$((errors + 1))
        return
    fi

    # Check embedded certificates
    local has_cert=$(kubectl config view --kubeconfig="${file}" --raw -o jsonpath='{.users[0].user.client-certificate-data}')
    if [[ -z "${has_cert}" ]]; then
        echo -e "${RED}✗${NC} ${name}.kubeconfig - missing embedded certificate"
        errors=$((errors + 1))
        return
    fi

    echo -e "${GREEN}✓${NC} ${name}.kubeconfig (server: ${server}, user: ${user})"
}

echo "--- Kubeconfig Files ---"
check_kubeconfig "admin" "${API_URL}" "admin"
check_kubeconfig "kube-controller-manager" "${API_INT_URL}" "system:kube-controller-manager"
check_kubeconfig "kube-scheduler" "${API_INT_URL}" "system:kube-scheduler"
check_kubeconfig "kubelet-bootstrap" "${API_INT_URL}" "system:bootstrapper"
check_kubeconfig "localhost" "https://localhost:6443" "admin"
check_kubeconfig "localhost-recovery" "https://localhost:6443" "admin"
check_kubeconfig "lb-int" "${API_INT_URL}" "admin"
check_kubeconfig "lb-ext" "${API_URL}" "admin"

echo ""
echo "=== Summary ==="
if [[ $errors -eq 0 ]]; then
    echo -e "${GREEN}All kubeconfig verification passed!${NC}"
else
    echo -e "${RED}${errors} error(s) found${NC}"
    exit 1
fi
