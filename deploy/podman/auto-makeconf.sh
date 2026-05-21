#!/usr/bin/env bash
# Non-interactive znc --makeconf. All credentials/IRC settings come from
# deploy.secrets.local (gitignored) — see deploy.secrets.local.example.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_die() {
    echo "ERROR: $*" >&2
    echo "Set values in deploy/podman/deploy.secrets.local (see .example)" >&2
    exit 1
}

if [[ -f "$SCRIPT_DIR/deploy.secrets.local" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/deploy.secrets.local"
    set +a
fi

[[ -n "${ZNC_ADMIN_USER:-}" ]] || _die "ZNC_ADMIN_USER is not set"
[[ -n "${ZNC_ADMIN_PASS:-}" ]] || _die "ZNC_ADMIN_PASS is not set"
[[ -n "${ZNC_IRC_NETWORK:-}" ]] || _die "ZNC_IRC_NETWORK is not set"
[[ -n "${ZNC_IRC_SERVER:-}" ]] || _die "ZNC_IRC_SERVER is not set"

ZNC_USER="$ZNC_ADMIN_USER"
ZNC_PASS="$ZNC_ADMIN_PASS"
ZNC_NICK="${ZNC_NICK:-$ZNC_ADMIN_USER}"
ZNC_PORT="${ZNC_PORT:-8443}"
ZNC_PODMAN_ROOT="${ZNC_PODMAN_ROOT:-/opt/znc}"
ZNC_IRC_SSL_ANS="${ZNC_IRC_SSL:-no}"
ZNC_IRC_PORT="${ZNC_IRC_PORT:-6667}"
ZNC_IRC_CHANNELS="${ZNC_IRC_CHANNELS:-}"
ZNC_REALNAME="${ZNC_REALNAME:-}"
ZNC_LISTEN_IPV6="${ZNC_LISTEN_IPV6:-no}"
IMAGE_NAME="${ZNC_IMAGE:-znc-bouncer:latest}"
CONTAINER_NAME="${ZNC_CONTAINER_NAME:-znc-bouncer}"

command -v expect &>/dev/null || _die "install expect (dnf install expect)"

if [[ -f "$ZNC_PODMAN_ROOT/data/configs/znc.conf" ]]; then
    echo "Config already exists: $ZNC_PODMAN_ROOT/data/configs/znc.conf"
    exit 0
fi

podman rm -f "$CONTAINER_NAME" 2>/dev/null || true
mkdir -p "$ZNC_PODMAN_ROOT/data/configs"

export ZNC_NO_LAUNCH_AFTER_MAKECONF=1
RUN_UID="$(id -u)"
RUN_GID="$(id -g)"

expect <<EOF
set timeout 120
log_user 1
spawn podman run --rm -it \
    --network host \
    -v ${ZNC_PODMAN_ROOT}/data:/znc-data:Z \
    --userns=keep-id:uid=${RUN_UID},gid=${RUN_GID} \
    --user ${RUN_UID}:${RUN_GID} \
    -e ZNC_NO_LAUNCH_AFTER_MAKECONF=1 \
    -e TERM=xterm \
    ${IMAGE_NAME} /opt/znc/bin/znc --makeconf --datadir /znc-data

expect {
    "alternate location" { send "/znc-data/configs/znc.conf\r"; exp_continue }
    "Listen on port" { send "${ZNC_PORT}\r"; exp_continue }
    "Listen using SSL" { send "yes\r"; exp_continue }
    "Listen using both IPv4 and IPv6" { send "${ZNC_LISTEN_IPV6}\r"; exp_continue }
    "Username" { send "${ZNC_USER}\r"; exp_continue }
    "Enter password" { send "${ZNC_PASS}\r"; exp_continue }
    "Confirm password" { send "${ZNC_PASS}\r"; exp_continue }
    "Nick" { send "${ZNC_NICK}\r"; exp_continue }
    "Alternate nick" { send "\r"; exp_continue }
    "Ident" { send "\r"; exp_continue }
    "Real name" { send "${ZNC_REALNAME}\r"; exp_continue }
    "Bind host" { send "\r"; exp_continue }
    "Set up a network?" { send "yes\r"; exp_continue }
    -re "Name.*libera" { send "${ZNC_IRC_NETWORK}\r"; exp_continue }
    "Server host" { send "${ZNC_IRC_SERVER}\r"; exp_continue }
    "Server uses SSL?" { send "${ZNC_IRC_SSL_ANS}\r"; exp_continue }
    "Server port" { send "${ZNC_IRC_PORT}\r"; exp_continue }
    "Server password" { send "\r"; exp_continue }
    "Initial channels" { send "${ZNC_IRC_CHANNELS}\r"; exp_continue }
    "Launch ZNC now?" { send "no\r"; exp_continue }
    eof
}
EOF

if [[ -f "$ZNC_PODMAN_ROOT/data/configs/znc.conf" ]]; then
    echo "OK: $ZNC_PODMAN_ROOT/data/configs/znc.conf"
else
    echo "ERROR: makeconf did not create znc.conf" >&2
    exit 1
fi
