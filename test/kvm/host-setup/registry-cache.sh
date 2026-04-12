#!/usr/bin/env bash
#
# registry-cache.sh — pull-through container-registry cache on the libvirt host
#
# Runs a `registry:2` container that acts as a pull-through cache in front of
# quay.io, listening on 192.168.125.1:5000 (the libvirt gateway the VMs can
# reach). First install iteration populates the cache; subsequent iterations
# hit LAN speed (~GbE) instead of WAN for all already-pulled layers.
#
# Why TLS with a self-signed cert (instead of plain HTTP):
#   CRI-O on the cluster nodes can pull from an insecure registry, but wiring
#   that requires a registries.conf MachineConfig — extra plumbing. A
#   self-signed TLS cert is 5 lines of openssl and gets inlined into
#   install-config.yaml's `additionalTrustBundle` cleanly.
#
# Idempotent — safe to re-run. Generates the cert if missing, starts the
# container if not running, prints the cert path at the end so you can
# confirm build-iso.sh will pick it up.
#
# Usage:
#   ./host-setup/registry-cache.sh          # set up + start
#   ./host-setup/registry-cache.sh status   # show state
#   ./host-setup/registry-cache.sh logs     # tail the registry log
#   ./host-setup/registry-cache.sh stop     # stop + remove the container (keeps cache volume)
#   ./host-setup/registry-cache.sh purge    # stop + remove + wipe cache volume
#
# Cache volume: /var/lib/tna-cache (persists across `stop` + `start` cycles)

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CONTAINER_NAME="tna-cache"
LISTEN_IP="192.168.125.1"
LISTEN_PORT="5000"
UPSTREAM="https://quay.io"
CACHE_DIR="/var/lib/tna-cache"
CERT_DIR="${HERE}"
CERT_PEM="${CERT_DIR}/registry-cert.pem"
CERT_KEY="${CERT_DIR}/registry-key.pem"

cmd="${1:-up}"

need_docker() {
  if ! sudo docker info >/dev/null 2>&1; then
    echo "FATAL: docker daemon not reachable. Run: sudo systemctl start docker" >&2
    exit 1
  fi
}

gen_cert() {
  if [ -s "$CERT_PEM" ] && [ -s "$CERT_KEY" ]; then
    echo "  cert already exists at $CERT_PEM"
    return 0
  fi
  echo "  generating self-signed cert for IP ${LISTEN_IP}"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$CERT_KEY" -out "$CERT_PEM" \
    -subj "/CN=tna-mirror" \
    -addext "subjectAltName=IP:${LISTEN_IP}" \
    >/dev/null 2>&1
  chmod 644 "$CERT_PEM"
  chmod 600 "$CERT_KEY"
  echo "  wrote $CERT_PEM and $CERT_KEY"
}

start_container() {
  need_docker
  gen_cert

  # Cache dir on the host
  sudo mkdir -p "$CACHE_DIR"
  sudo chown -R 1000:1000 "$CACHE_DIR" 2>/dev/null || true  # registry image runs as uid 1000

  # Already running?
  if sudo docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    state=$(sudo docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME")
    if [ "$state" = "running" ]; then
      echo "  container $CONTAINER_NAME already running"
      return 0
    fi
    echo "  container $CONTAINER_NAME in state '$state' — removing and recreating"
    sudo docker rm -f "$CONTAINER_NAME" >/dev/null
  fi

  echo "=== starting $CONTAINER_NAME (${LISTEN_IP}:${LISTEN_PORT} → ${UPSTREAM}) ==="
  sudo docker run -d \
    --name "$CONTAINER_NAME" \
    --restart=always \
    -p "${LISTEN_IP}:${LISTEN_PORT}:5000" \
    -v "${CACHE_DIR}:/var/lib/registry" \
    -v "${CERT_PEM}:/certs/tls.crt:ro" \
    -v "${CERT_KEY}:/certs/tls.key:ro" \
    -e "REGISTRY_PROXY_REMOTEURL=${UPSTREAM}" \
    -e "REGISTRY_HTTP_TLS_CERTIFICATE=/certs/tls.crt" \
    -e "REGISTRY_HTTP_TLS_KEY=/certs/tls.key" \
    -e "REGISTRY_STORAGE_DELETE_ENABLED=true" \
    docker.io/library/registry:2 >/dev/null

  # Wait for healthy
  for i in 1 2 3 4 5 6 7 8; do
    if curl -sk "https://${LISTEN_IP}:${LISTEN_PORT}/v2/" >/dev/null 2>&1; then
      echo "  registry is up"
      return 0
    fi
    sleep 1
  done
  echo "  registry started but /v2/ not responding yet — check: sudo docker logs $CONTAINER_NAME" >&2
  return 1
}

case "$cmd" in
  up|start)
    start_container
    echo
    echo "=== registry cache summary ==="
    echo "  endpoint : https://${LISTEN_IP}:${LISTEN_PORT}"
    echo "  upstream : ${UPSTREAM}"
    echo "  cache dir: ${CACHE_DIR}"
    echo "  cert pem : ${CERT_PEM}"
    echo
    echo "Next: regenerate the agent ISO with the mirror wired in."
    echo "  build-iso.sh will automatically inline the cert + imageContentSources"
    echo "  when ${CERT_PEM} exists."
    ;;

  status)
    need_docker
    if ! sudo docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
      echo "$CONTAINER_NAME: not present"
      exit 1
    fi
    state=$(sudo docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME")
    echo "$CONTAINER_NAME: $state"
    if [ "$state" = "running" ]; then
      if curl -sk "https://${LISTEN_IP}:${LISTEN_PORT}/v2/" >/dev/null; then
        echo "  /v2/ endpoint: OK"
      else
        echo "  /v2/ endpoint: NOT RESPONDING"
      fi
      size=$(sudo du -sh "$CACHE_DIR" 2>/dev/null | awk '{print $1}')
      echo "  cache size: ${size:-unknown}"
    fi
    ;;

  logs)
    need_docker
    exec sudo docker logs -f "$CONTAINER_NAME"
    ;;

  stop)
    need_docker
    sudo docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    echo "$CONTAINER_NAME removed (cache volume at $CACHE_DIR preserved)"
    ;;

  purge)
    need_docker
    sudo docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    sudo rm -rf "$CACHE_DIR"
    rm -f "$CERT_PEM" "$CERT_KEY"
    echo "$CONTAINER_NAME removed, $CACHE_DIR wiped, cert files deleted"
    ;;

  *)
    echo "Usage: $0 {up|status|logs|stop|purge}" >&2
    exit 2
    ;;
esac
