#!/bin/bash
# Docker variant of the e2e deb test.
#
# Runs e2e_deb_test.sh as root inside a pristine ubuntu:24.04 container
# (same package ABI as this system: Linux Mint 22.x is based on Ubuntu 24.04
# "noble"), so no sudo is required on the host.
#
# Usage: ./e2e_deb_test_docker.sh [path/to/yacreader_*.deb]
#        (defaults to the newest .deb in ./dist/)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEB="${1:-}"

if [ -z "$DEB" ]; then
    DEB="$(ls -t "$SCRIPT_DIR"/dist/yacreader_*.deb 2>/dev/null | head -n 1 || true)"
fi
if [ -z "$DEB" ] || [ ! -f "$DEB" ]; then
    echo "ERROR: no .deb found (looked at: ${DEB:-$SCRIPT_DIR/dist})"
    exit 1
fi
DEB="$(cd "$(dirname "$DEB")" && pwd)/$(basename "$DEB")"
echo "Testing: $DEB"

# Get deps list from the built package so the container resolves them the same
# way apt would on the host.
DEB_NAME="$(dpkg-deb -f "$DEB" Package)"

echo "Pulling ubuntu:24.04 image..."
docker pull -q ubuntu:24.04 >/dev/null

docker run --rm \
    -v "$DEB:/tmp/incoming.deb:ro" \
    -v "$SCRIPT_DIR/e2e_deb_test.sh:/usr/local/bin/e2e_deb_test.sh:ro" \
    ubuntu:24.04 \
    bash -e -c '
        set -o pipefail
        apt-get update -qq >/dev/null
        echo ">>> installing package + dependencies..."
        apt-get install -y -qq /tmp/incoming.deb >/dev/null
        echo ">>> running e2e test..."
        e2e_deb_test.sh /tmp/incoming.deb
    '
