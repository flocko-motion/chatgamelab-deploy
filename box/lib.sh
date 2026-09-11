# Sourced by every phase two script. Not executable, and holds no side effects
# beyond reading the box's own configuration.

set -euo pipefail

# Written by ansible from group_vars, so there is one definition of where
# things live and box/ carries no paths of its own.
: "${BOX_ENV:=/var/lib/cgl/box.env}"
[ -r "$BOX_ENV" ] || { echo "cannot read $BOX_ENV — has ground setup run?" >&2; exit 1; }
# shellcheck disable=SC1090
. "$BOX_ENV"

ENV_CONFIG="$RUNTIME_HOME/env.config"
ENV_SECRET="$RUNTIME_HOME/env.secret"
COMPOSE_FILE="$DEPLOY_CLONE/compose.yml"

say()  { printf '   %s\n' "$*"; }
step() { printf '>> %s\n' "$*"; }
die()  { printf '%s\n' "$@" >&2; exit 1; }

# The three images a deploy consists of, named as podman tags them for a local
# build.
IMAGE_NAMES="chatgamelab-db chatgamelab-backend chatgamelab-web"

image_ref() { printf 'localhost/%s:%s' "$1" "$2"; }

# One value out of the secret half of the environment.
secret_get() { # key
  [ -r "$ENV_SECRET" ] || return 1
  sed -n "s/^$1=//p" "$ENV_SECRET" | head -1
}

# Replace one key in the secret half, leaving the rest as it is. Written
# through a temp file in the same directory so a reader never sees a partial
# file, and with a umask that keeps the mode even if the file is recreated.
secret_set() { # key value
  local key="$1" value="$2" tmp
  tmp="$(mktemp "$ENV_SECRET.XXXXXX")"
  chmod 600 "$tmp"
  if [ -f "$ENV_SECRET" ]; then
    grep -v "^$key=" "$ENV_SECRET" > "$tmp" || true
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$ENV_SECRET"
}

# docker compose, speaking to podman's Docker-API socket. No daemon is
# involved: podman.socket is a per-user systemd socket unit, so this whole
# stack runs in RUNTIME_USER's own user namespace.
compose() {
  DOCKER_HOST="unix:///run/user/$(id -u)/podman/podman.sock" \
  docker compose \
    --file "$COMPOSE_FILE" \
    --env-file "$ENV_CONFIG" \
    --env-file "$ENV_SECRET" \
    "$@"
}
