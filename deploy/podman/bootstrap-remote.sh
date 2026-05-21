#!/usr/bin/env bash
# One-shot remote bootstrap: rsync tree, create host data/, build & start Podman.
# Does not require git on the server.
#
# Usage (from repo root):
#   ./deploy/podman/bootstrap-remote.sh
#   ./deploy/podman/bootstrap-remote.sh --check-port

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ZNC_PORT="${ZNC_PORT:-8443}"
CHECK_PORT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-port) CHECK_PORT=true; shift ;;
    -h|--help)
      sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -f "$SCRIPT_DIR/deploy.secrets.local" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/deploy.secrets.local"
  set +a
fi

PASSWORD="${DEPLOY_SSH_PASSWORD:-}"
SERVER="${DEPLOY_SERVER:-}"
SSH_USER="${DEPLOY_SSH_USER:-root}"
PODMAN_ROOT="${ZNC_PODMAN_ROOT:-/opt/znc}"
PODMAN_USER="${DEPLOY_PODMAN_USER:-centos}"

[[ -n "$PASSWORD" ]] || { echo "ERROR: DEPLOY_SSH_PASSWORD not set" >&2; exit 1; }
[[ -n "$SERVER" ]] || { echo "ERROR: DEPLOY_SERVER not set" >&2; exit 1; }

command -v sshpass rsync &>/dev/null || { echo "ERROR: need sshpass and rsync" >&2; exit 1; }

git -C "$REPO_ROOT" submodule update --init docker

SSH=(sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=20)
RSYNC_SSH="sshpass -p $PASSWORD ssh -o StrictHostKeyChecking=no -o ConnectTimeout=20"

echo "== SSH test ${SSH_USER}@${SERVER} =="
"${SSH[@]}" "${SSH_USER}@${SERVER}" "echo OK on \$(hostname)"

echo "== Prepare ${PODMAN_ROOT} on server =="
"${SSH[@]}" "${SSH_USER}@${SERVER}" bash -s -- "$PODMAN_ROOT" "$PODMAN_USER" <<'PREP'
set -euo pipefail
ROOT="$1"
USER="$2"
mkdir -p "$ROOT/data"
chown -R "$USER:$USER" "$ROOT"
PREP

echo "== Rsync sources to ${SERVER}:${PODMAN_ROOT} =="
rsync -az --delete \
  --exclude '.git' \
  --exclude 'build/' \
  --exclude 'deploy/state/data/*' \
  --exclude 'deploy/podman/deploy.secrets.local' \
  -e "$RSYNC_SSH" \
  "$REPO_ROOT/" "${SSH_USER}@${SERVER}:${PODMAN_ROOT}/"

echo "== Open firewall port ${ZNC_PORT}/tcp (firewalld, if active) =="
"${SSH[@]}" "${SSH_USER}@${SERVER}" bash -s -- "$ZNC_PORT" <<'FW' || true
set -euo pipefail
PORT="$1"
if systemctl is-active firewalld &>/dev/null; then
  firewall-cmd --permanent --add-port="${PORT}/tcp" 2>/dev/null || true
  firewall-cmd --reload 2>/dev/null || true
fi
FW

echo "== Podman build & start as ${PODMAN_USER} =="
"${SSH[@]}" "${SSH_USER}@${SERVER}" \
  "su - '$PODMAN_USER' -c 'cd \"$PODMAN_ROOT\" && export ZNC_PODMAN_ROOT=\"$PODMAN_ROOT\" ZNC_PORT=\"$ZNC_PORT\" && ./deploy/podman/run.sh --down'" || true
"${SSH[@]}" "${SSH_USER}@${SERVER}" \
  "su - '$PODMAN_USER' -c 'cd \"$PODMAN_ROOT\" && export ZNC_PODMAN_ROOT=\"$PODMAN_ROOT\" ZNC_PORT=\"$ZNC_PORT\" && ./deploy/podman/run.sh --build'"

if $CHECK_PORT; then
  echo "== Port check ${SERVER}:${ZNC_PORT} =="
  command -v nc &>/dev/null && nc -zv -w 8 "$SERVER" "$ZNC_PORT" 2>&1 || true
fi

echo ""
echo "Bootstrap done."
echo "  If no config yet, on laptop:"
echo "    ZNC_PODMAN_ROOT=$PODMAN_ROOT ./deploy/podman/run.sh --makeconf"
echo "  Or SSH and run the same on server after copying secrets workflow."
echo "  IRC client -> ${SERVER}:<ListenPort from znc.conf> (often ${ZNC_PORT} with SSL)"
