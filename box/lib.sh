# Sourced by every phase two script. Not executable, and holds no side effects
# beyond reading the box's own configuration.

set -euo pipefail

# Written by ansible from group_vars, so there is one definition of where
# things live and box/ carries no paths of its own.
: "${BOX_ENV:=/opt/chatgamelab/box.env}"
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

# Compose v2 against podman's Docker-API socket. No daemon and no Docker CLI
# are involved: Debian's docker-compose package depends on libc6 alone and
# ships a standalone /usr/bin/docker-compose, and podman.socket is a per-user
# systemd socket unit — so the whole stack runs in RUNTIME_USER's own user
# namespace.
#
# The standalone binary is what gets used, since `docker compose` with a space
# needs a `docker` CLI to dispatch the plugin and there deliberately is none.
if command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_BIN="docker-compose"
elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  COMPOSE_BIN="docker compose"
else
  echo "no compose v2 found — expected /usr/bin/docker-compose from the docker-compose package" >&2
  exit 1
fi

# Rootless podman reaches the user systemd through these two. Without the bus
# address it cannot create cgroups and falls back to --cgroup-manager=cgroupfs,
# which works and silently discards compose's mem_limit — and says so in three
# warnings on every command. A bare ssh command inherits neither, so they are
# set here rather than relied on.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
# Only when the socket is actually there. Pointing this at a path that does not
# exist is worse than leaving it unset: podman then falls back to the *system*
# bus, which needs polkit, and a build dies with "Interactive authentication
# required" instead of degrading to cgroupfs with a warning.
if [ -S "$XDG_RUNTIME_DIR/bus" ]; then
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
else
  unset DBUS_SESSION_BUS_ADDRESS
fi

compose() {
  DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock" \
  $COMPOSE_BIN \
    --file "$COMPOSE_FILE" \
    --env-file "$ENV_CONFIG" \
    --env-file "$ENV_SECRET" \
    "$@"
}

# The backup destination, as box/cgl-secrets stored it. Commands on stdin.
BACKUP_KEY="$RUNTIME_HOME/backup_key"
sftp_at() {
  local bhost bport buser
  bhost="$(secret_get BACKUP_SSH_HOST)"
  bport="$(secret_get BACKUP_SSH_PORT)"; bport="${bport:-22}"
  buser="$(secret_get BACKUP_SSH_USER)"
  [ -n "$bhost" ] && [ -n "$buser" ] || return 1
  sftp -b - -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=15 \
    -i "$BACKUP_KEY" -P "$bport" "$buser@$bhost" 2>&1
}

# One deploy at a time on this box, whoever started it — a hand-run from any
# machine, the webhook, or the timer. Without it two runs interleave: both drop
# the volume, both restore, and the box ends up serving whichever finished
# last with a database from the other.
#
# The lock file doubles as the record of who holds it, so a contender can say
# so rather than reporting a bare failure. Opened >> rather than >, rather than
# truncating the very content the contender wants to read.
DEPLOY_LOCK="$RUNTIME_HOME/.deploy.lock"

take_deploy_lock() { # what-is-being-deployed
  # cgl-update takes the lock before it builds and hands this process the open
  # descriptor, so taking it again here would deadlock against itself.
  [ "${CGL_DEPLOY_LOCKED:-0}" = "1" ] && return 0
  exec 9>>"$DEPLOY_LOCK"
  if ! flock -n 9; then
    echo "A deploy is already running on this box:" >&2
    sed 's/^/  /' "$DEPLOY_LOCK" >&2 2>/dev/null || true
    echo >&2
    echo "Wait for it to finish, or investigate if it looks stuck. Two at once" >&2
    echo "would both drop the volume and both restore." >&2
    exit 1
  fi
  : > "$DEPLOY_LOCK"
  printf 'started %s by %s (pid %s)\ndeploying %s\n' \
    "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$(id -un)" "$$" "$1" >&9
}
