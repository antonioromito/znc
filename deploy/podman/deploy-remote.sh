#!/usr/bin/env bash
# Remote Podman deploy: SSH, git pull, podman run.sh (ZNC).
#
# Set DEPLOY_SERVER, ZNC_PODMAN_ROOT, DEPLOY_PODMAN_USER via deploy.secrets.local
#
# Usage (from repo root):
#   ./deploy/podman/deploy-remote.sh [branch]
#   ./deploy/podman/deploy-remote.sh [branch] --no-build
#   ./deploy/podman/deploy-remote.sh --down [branch]
#   ./deploy/podman/deploy-remote.sh --status
#   ./deploy/podman/deploy-remote.sh --logs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

_die() {
  echo "ERROR: $*" >&2
  echo "Set variables in deploy/podman/deploy.secrets.local" >&2
  exit 1
}

_load_secrets() {
  if [[ -n "${DEPLOY_SSH_PASSWORD:-}" ]]; then
    return
  fi
  if [[ -f "$SCRIPT_DIR/deploy.secrets.local" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/deploy.secrets.local"
    set +a
  fi
}

_load_secrets
PASSWORD="${DEPLOY_SSH_PASSWORD:-}"

[[ -n "$PASSWORD" ]] || _die "DEPLOY_SSH_PASSWORD is not set."

SERVER="${DEPLOY_SERVER:-}"
SSH_USER="${DEPLOY_SSH_USER:-root}"
REPO_URL="${DEPLOY_REPO_URL:-}"
PODMAN_ROOT="${ZNC_PODMAN_ROOT:-${DEPLOY_PODMAN_ROOT:-}}"
PODMAN_USER="${DEPLOY_PODMAN_USER:-}"
BRANCH="${DEPLOY_BRANCH:-master}"
DO_BUILD=true
ACTION="deploy"

[[ -n "$SERVER" ]] || _die "DEPLOY_SERVER is not set."
[[ -n "$PODMAN_ROOT" ]] || _die "ZNC_PODMAN_ROOT (or DEPLOY_PODMAN_ROOT) is not set."
[[ -n "$PODMAN_USER" ]] || _die "DEPLOY_PODMAN_USER is not set."

if [[ -z "$REPO_URL" ]]; then
  REPO_URL="$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null || true)"
fi
[[ -n "$REPO_URL" ]] || _die "DEPLOY_REPO_URL is not set and git remote.origin.url is missing."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) DO_BUILD=false; shift ;;
    --down) ACTION="down"; shift ;;
    --status) ACTION="status"; shift ;;
    --logs) ACTION="logs"; shift ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) BRANCH="$1"; shift ;;
  esac
done

command -v sshpass &>/dev/null || _die "sshpass required (dnf install sshpass)."

SSH=(sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 "${SSH_USER}@${SERVER}")

echo "Testing SSH to ${SSH_USER}@${SERVER}..."
"${SSH[@]}" "echo OK" || _die "Cannot connect to ${SERVER}"

if [[ "$ACTION" == "logs" ]]; then
  exec sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no -t "${SSH_USER}@${SERVER}" \
    "su - '$PODMAN_USER' -c 'podman logs -f znc-bouncer'"
fi

if [[ "$ACTION" == "status" ]]; then
  "${SSH[@]}" "su - '$PODMAN_USER' -c 'podman ps -a --filter name=znc-bouncer'"
  exit 0
fi

echo "Remote deploy: server=${SERVER} root=${PODMAN_ROOT} user=${PODMAN_USER} branch=${BRANCH}"

"${SSH[@]}" bash -s -- "$PODMAN_ROOT" "$PODMAN_USER" "$BRANCH" "$REPO_URL" "$ACTION" "$DO_BUILD" <<'REMOTE'
set -euo pipefail
PODMAN_ROOT="$1"
PODMAN_USER="$2"
BRANCH="$3"
REPO_URL="$4"
ACTION="$5"
DO_BUILD="$6"

git config --global --add safe.directory "$PODMAN_ROOT" 2>/dev/null || true

if [[ ! -d "$PODMAN_ROOT/.git" ]]; then
  echo "== Initial clone into $PODMAN_ROOT =="
  PRESERVE=$(mktemp -d)
  if [[ -d "$PODMAN_ROOT/data" ]]; then
    cp -a "$PODMAN_ROOT/data" "$PRESERVE/"
  fi
  rm -rf "$PODMAN_ROOT"
  git clone --branch "$BRANCH" --recurse-submodules -- "$REPO_URL" "$PODMAN_ROOT"
  if [[ -d "$PRESERVE/data" ]]; then
    cp -a "$PRESERVE/data" "$PODMAN_ROOT/"
  fi
  rm -rf "$PRESERVE"
else
  cd "$PODMAN_ROOT"
  git remote set-url origin "$REPO_URL" 2>/dev/null || true
  git fetch origin
  git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH" "origin/$BRANCH"
  git reset --hard "origin/$BRANCH"
  git submodule update --init --recursive docker
fi

chown -R "$PODMAN_USER:$PODMAN_USER" "$PODMAN_ROOT"
mkdir -p "$PODMAN_ROOT/data"
chown -R "$PODMAN_USER:$PODMAN_USER" "$PODMAN_ROOT/data"

cd "$PODMAN_ROOT"
echo "HEAD: $(git rev-parse --short HEAD) $(git log -1 --format='%s')"

_run_podman() {
  su - "$PODMAN_USER" -c "cd '$PODMAN_ROOT' && export ZNC_PODMAN_ROOT='$PODMAN_ROOT' ZNC_PORT='${ZNC_PORT:-8443}' && $1"
}

case "$ACTION" in
  down)
    _run_podman "./deploy/podman/run.sh --down"
    ;;
  deploy)
    _run_podman "./deploy/podman/run.sh --down" || true
    if [[ "$DO_BUILD" == "true" ]]; then
      _run_podman "./deploy/podman/run.sh --build"
    fi
    _run_podman "./deploy/podman/run.sh"
    su - "$PODMAN_USER" -c "podman ps --filter name=znc-bouncer"
    ;;
esac
REMOTE

echo ""
echo "Data dir on host: ${PODMAN_ROOT}/data/ (configs/znc.conf, users/, znc.pem)"
echo "First-time config: ./deploy/podman/run.sh --makeconf  (or deploy-remote after SSH)"
echo "Done. Logs: ./deploy/podman/deploy-remote.sh --logs"
