#!/bin/bash
# Verify all prerequisites are met

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

errors=0
warnings=0

check_command() {
    local cmd=$1
    local name=$2
    if command -v "$cmd" &> /dev/null; then
        version=$($cmd --version 2>&1 | head -1)
        echo -e "${GREEN}✓${NC} $name: $version"
    else
        echo -e "${RED}✗${NC} $name: not found"
        errors=$((errors + 1))
    fi
}

check_file() {
    local file=$1
    local name=$2
    if [[ -f "$file" ]]; then
        echo -e "${GREEN}✓${NC} $name: $file"
    else
        echo -e "${RED}✗${NC} $name: not found at $file"
        errors=$((errors + 1))
    fi
}

check_service() {
    local service=$1
    if systemctl is-active --quiet "$service"; then
        echo -e "${GREEN}✓${NC} Service $service: running"
    else
        echo -e "${YELLOW}!${NC} Service $service: not running (will configure in stage 02)"
        warnings=$((warnings + 1))
    fi
}

echo "=== Prerequisites Check ==="
echo ""

echo "--- Required Tools ---"
check_command podman "Podman"
check_command oc "OpenShift CLI"
check_command openssl "OpenSSL"
check_command jq "jq"
check_command virsh "libvirt (virsh)"
check_command virt-install "virt-install"

# Source cluster vars for file paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh" 2>/dev/null || true

echo ""
echo "--- Files ---"
check_file "${SSH_PUB_KEY:-${HOME}/.ssh/id_rsa.pub}" "SSH public key"
check_file "${PULL_SECRET_FILE:-${HOME}/.pull-secret.json}" "Pull secret"

if [[ -f "${PULL_SECRET_FILE:-${HOME}/.pull-secret.json}" ]]; then
    if jq . "${PULL_SECRET_FILE:-${HOME}/.pull-secret.json}" > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Pull secret: valid JSON"
    else
        echo -e "${RED}✗${NC} Pull secret: invalid JSON"
        errors=$((errors + 1))
    fi
fi

echo ""
echo "--- Services ---"
check_service libvirtd

echo ""
echo "--- System Resources ---"
cpu_cores=$(nproc)
total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
total_mem_gb=$((total_mem_kb / 1024 / 1024))
available_disk=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')

echo "CPU cores: $cpu_cores (need 8+, recommend 16+)"
if [[ $cpu_cores -lt 8 ]]; then
    echo -e "${RED}✗${NC} Insufficient CPU cores"
    errors=$((errors + 1))
elif [[ $cpu_cores -lt 16 ]]; then
    echo -e "${YELLOW}!${NC} CPU cores adequate but not recommended"
    warnings=$((warnings + 1))
else
    echo -e "${GREEN}✓${NC} CPU cores sufficient"
fi

echo "Memory: ${total_mem_gb}GB (need 32+, recommend 64+)"
if [[ $total_mem_gb -lt 32 ]]; then
    echo -e "${RED}✗${NC} Insufficient memory"
    errors=$((errors + 1))
elif [[ $total_mem_gb -lt 64 ]]; then
    echo -e "${YELLOW}!${NC} Memory adequate but not recommended"
    warnings=$((warnings + 1))
else
    echo -e "${GREEN}✓${NC} Memory sufficient"
fi

pool_parent=$(dirname "${LIBVIRT_POOL_PATH:-/var/lib/libvirt/images/ocp4}")
pool_disk=$(df -BG "$pool_parent" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G')
echo "Available disk on ${pool_parent}: ${pool_disk}GB (need 50+, VM disks are thin-provisioned)"
if [[ $pool_disk -lt 50 ]]; then
    echo -e "${RED}✗${NC} Insufficient disk space for libvirt pool"
    errors=$((errors + 1))
else
    echo -e "${GREEN}✓${NC} Disk space sufficient"
fi

echo ""
echo "--- libvirt Access ---"
if groups | grep -q libvirt; then
    echo -e "${GREEN}✓${NC} User in libvirt group"
else
    echo -e "${YELLOW}!${NC} User not in libvirt group (run: sudo usermod -aG libvirt \$USER)"
    warnings=$((warnings + 1))
fi

if virsh list --all &> /dev/null; then
    echo -e "${GREEN}✓${NC} Can access libvirt"
else
    echo -e "${RED}✗${NC} Cannot access libvirt"
    errors=$((errors + 1))
fi

echo ""
echo "=== Summary ==="
if [[ $errors -eq 0 && $warnings -eq 0 ]]; then
    echo -e "${GREEN}All prerequisites met!${NC}"
elif [[ $errors -eq 0 ]]; then
    echo -e "${YELLOW}$warnings warning(s), $errors error(s)${NC}"
    echo "Warnings are non-blocking but should be addressed."
else
    echo -e "${RED}$errors error(s), $warnings warning(s)${NC}"
    echo "Fix errors before proceeding."
    exit 1
fi
