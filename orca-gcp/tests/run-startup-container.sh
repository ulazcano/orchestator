#!/usr/bin/env bash
# run-startup-container.sh - corre startup-in-container.sh dentro de ubuntu:24.04 (docker o podman).
# Requiere red (apt, GitHub Releases, NodeSource, claude.ai). No toca GCP ni Tailscale reales.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
IMAGE="${IMAGE:-ubuntu:24.04}"

RUNTIME=""
for r in docker podman; do
  if command -v "$r" >/dev/null 2>&1; then RUNTIME="$r"; break; fi
done
[[ -n "$RUNTIME" ]] || { echo "Ni docker ni podman disponibles." >&2; exit 2; }

# Si el daemon requiere sudo (típico en sandboxes), úsalo.
if ! "$RUNTIME" info >/dev/null 2>&1; then
  if sudo -n "$RUNTIME" info >/dev/null 2>&1; then RUNTIME="sudo $RUNTIME"; else echo "El daemon de $RUNTIME no responde." >&2; exit 2; fi
fi

# shellcheck disable=SC2086  # RUNTIME puede ser "sudo docker"
exec $RUNTIME run --rm \
  -e ORCA_VERSION="${ORCA_VERSION:-1.4.255}" \
  -e ORCA_TEST_SKIP_CLAUDE="${ORCA_TEST_SKIP_CLAUDE:-0}" \
  -v "${ROOT}:/opt/orca-gcp:ro" \
  "$IMAGE" bash /opt/orca-gcp/tests/startup-in-container.sh
