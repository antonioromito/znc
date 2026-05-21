#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
IMAGE_NAME="${ZNC_IMAGE:-znc-bouncer:latest}"
CONTAINER_NAME="${ZNC_CONTAINER_NAME:-znc-bouncer}"
ZNC_PORT="${ZNC_PORT:-8443}"
ZNC_NETWORK="${ZNC_NETWORK:-host}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run ZNC in Podman (official Dockerfile + znc-docker submodule).

Host layout (set ZNC_PODMAN_ROOT, e.g. /opt/znc):

  data/   -> /znc-data   (znc.conf, users/, znc.pem — never baked into the image)

Options:
  --build   Build image (needs: git submodule update --init docker)
  --down    Stop and remove container
  --logs    Follow container logs
  -h        Show help

Environment:
  ZNC_PODMAN_ROOT     deployment directory on host
  ZNC_NETWORK=host|pasta   (default: host — best for outbound IRC)
  ZNC_PASTA_OPTS=...       pasta-only IPv6/outbound options
  ZNC_PORT=6697            published port when not using host network
EOF
}

resolve_podman_network() {
    PODMAN_NET_ARGS=()
    case "$ZNC_NETWORK" in
        host)
            PODMAN_NET_ARGS=(--network host)
            ;;
        pasta)
            if [[ -n "${ZNC_PASTA_OPTS:-}" ]]; then
                PODMAN_NET_ARGS=(--network "pasta:${ZNC_PASTA_OPTS}")
            else
                local v6
                v6="$(ip -6 -br addr show scope global 2>/dev/null | awk '{print $3}' | cut -d/ -f1 | head -1 || true)"
                if [[ -n "$v6" ]]; then
                    PODMAN_NET_ARGS=(--network "pasta:-o,${v6}")
                else
                    PODMAN_NET_ARGS=(--network pasta)
                fi
            fi
            ;;
        *)
            echo "ERROR: ZNC_NETWORK must be 'host' or 'pasta' (got: $ZNC_NETWORK)" >&2
            exit 1
            ;;
    esac
}

resolve_host_root() {
    if [[ -n "${ZNC_PODMAN_ROOT:-}" ]]; then
        printf '%s' "${ZNC_PODMAN_ROOT%/}"
        return
    fi
    printf '%s/deploy/state' "$REPO_ROOT"
}

ensure_submodule() {
    if [[ ! -f "$REPO_ROOT/docker/slim/entrypoint.sh" ]]; then
        echo "Initializing docker submodule (znc-docker)..."
        git -C "$REPO_ROOT" submodule update --init docker
    fi
}

check_datadir() {
    local hr="$1"
    mkdir -p "$hr/data"
    if [[ ! -f "$hr/data/configs/znc.conf" ]]; then
        echo "WARN: $hr/data/configs/znc.conf not found." >&2
        echo "  Create config once (interactive):" >&2
        echo "    ZNC_PODMAN_ROOT=$hr $0 --makeconf" >&2
        echo "  Or: podman run --rm -it -v $hr/data:/znc-data --network host $IMAGE_NAME znc --makeconf" >&2
    fi
}

ensure_volume_permissions() {
    local hr="$1"
    if ! touch "$hr/data/.volume_write_test" 2>/dev/null; then
        echo "ERROR: cannot write to $hr/data as $(id -un) (uid=$(id -u))." >&2
        exit 1
    fi
    rm -f "$hr/data/.volume_write_test"
}

cmd_up() {
    local hr
    hr="$(resolve_host_root)"
    mkdir -p "$hr/data"
    check_datadir "$hr"
    ensure_volume_permissions "$hr"

    podman rm -f "$CONTAINER_NAME" 2>/dev/null || true

    local -a publish_args
    resolve_podman_network
    publish_args=()
    if [[ "$ZNC_NETWORK" != host ]]; then
        publish_args=(-p "0.0.0.0:${ZNC_PORT}:${ZNC_PORT}")
    fi

    echo "Using host root: $hr (network $ZNC_NETWORK, data -> /znc-data)"
    # Leading "--foreground" satisfies docker entrypoint 00-try-sh (args must start with '-').
    podman run -d --name "$CONTAINER_NAME" \
        "${PODMAN_NET_ARGS[@]}" \
        "${publish_args[@]}" \
        -v "$hr/data:/znc-data:Z" \
        --userns=keep-id:uid="$(id -u)",gid="$(id -g)" \
        --user "$(id -u):$(id -g)" \
        "$IMAGE_NAME" \
        --foreground

    echo ""
    echo "Container started."
    echo "  podman ps --filter name=$CONTAINER_NAME"
    echo "  $0 --logs"
    echo "  $0 --down"
}

cmd_down() {
    podman rm -f "$CONTAINER_NAME" 2>/dev/null || true
    echo "Container $CONTAINER_NAME removed."
}

cmd_build() {
    ensure_submodule
    podman build -t "$IMAGE_NAME" -f "$REPO_ROOT/Dockerfile" "$REPO_ROOT"
}

cmd_logs() {
    podman logs -f "$CONTAINER_NAME"
}

cmd_makeconf() {
    ensure_submodule
    local hr
    hr="$(resolve_host_root)"
    mkdir -p "$hr/data"
    resolve_podman_network
    echo "Interactive ZNC setup -> $hr/data/configs/znc.conf"
    podman run --rm -it \
        "${PODMAN_NET_ARGS[@]}" \
        -v "$hr/data:/znc-data:Z" \
        --userns=keep-id:uid="$(id -u)",gid="$(id -g)" \
        --user "$(id -u):$(id -g)" \
        -e TERM="${TERM:-xterm-256color}" \
        "$IMAGE_NAME" \
        znc --makeconf
}

ACTION="up"
BUILD=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build) BUILD=true; shift ;;
        --down)  ACTION="down"; shift ;;
        --logs)  ACTION="logs"; shift ;;
        --makeconf) ACTION="makeconf"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

case "$ACTION" in
    down) cmd_down ;;
    logs) cmd_logs ;;
    makeconf) cmd_makeconf ;;
    *)
        $BUILD && cmd_build
        cmd_up
        ;;
esac
