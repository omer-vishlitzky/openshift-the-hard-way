#!/bin/bash
# Build worker ignition config
# Workers fetch their real config from the Machine Config Server

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh"

mkdir -p "${IGNITION_DIR}"

OUTPUT_FILE="${IGNITION_DIR}/worker.ign"

echo "=== Building Worker Ignition ==="
echo ""

# Encode the root CA
ROOT_CA_B64=$(base64 -w0 "${PKI_DIR}/root-ca.crt")

# Get SSH key
SSH_KEY=$(cat "${SSH_PUB_KEY}")

# Build the ignition config
cat > "${OUTPUT_FILE}" <<EOF
{
  "ignition": {
    "version": "3.2.0",
    "config": {
      "merge": [
        {
          "source": "https://api-int.${CLUSTER_DOMAIN}:22623/config/worker"
        }
      ]
    },
    "security": {
      "tls": {
        "certificateAuthorities": [
          {
            "source": "data:text/plain;charset=utf-8;base64,${ROOT_CA_B64}"
          }
        ]
      }
    }
  },
  "passwd": {
    "users": [
      {
        "name": "core",
        "sshAuthorizedKeys": [
          "${SSH_KEY}"
        ]
      }
    ]
  }
}
EOF

# Validate JSON
if jq . "${OUTPUT_FILE}" > /dev/null 2>&1; then
    echo "Worker ignition built successfully"
    echo "Output: ${OUTPUT_FILE}"
    echo "Size: $(du -h "${OUTPUT_FILE}" | cut -f1)"
    echo ""
    echo "This ignition will fetch config from:"
    echo "  https://api-int.${CLUSTER_DOMAIN}:22623/config/worker"
else
    echo "ERROR: Generated invalid JSON!"
    exit 1
fi
