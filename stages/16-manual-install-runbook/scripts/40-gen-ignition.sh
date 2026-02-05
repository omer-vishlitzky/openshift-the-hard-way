#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../config/cluster-vars.sh
source "${ROOT_DIR}/config/cluster-vars.sh"

export CLUSTER_DOMAIN
export BOOTSTRAP
export MASTER0
export MASTER1
export MASTER2
export WORKER0
export WORKER1
export SSH_PUB_KEY

python3 "${ROOT_DIR}/scripts/40-gen-ignition.py"
