#!/usr/bin/env bash
# ./deploy.sh <server> <commit> [--reset-db <admin-email>] [--force-rebuild]
#                             [--restore <dump.sql.gz>]
#
# Deploys one commit of chatgamelab to one v-server. <commit> is anything git
# can resolve — a branch, a tag, a short or full SHA — and it is resolved here,
# on your machine, to an immutable SHA before anything is asked of the box. A
# branch name never travels, so `./deploy.sh cgl-dev development` twice in a
# day deploys two different commits and says which.
#
# The box builds the images itself, from source, as an unprivileged user under
# rootless podman. That is what makes any commit deployable rather than only
# the ones CI published, and it is why a deploy takes minutes. Images are
# tagged by SHA, so a commit built once comes back up in seconds.
#
# --reset-db destroys the database and names the address that gets back in.
# Both halves are one decision deliberately: the admin bootstrap only grants
# anything while no admin exists (server/db/user_roles.go:55), so a reset is
# the one moment the address can act, and requiring it here makes locking
# yourself out unreachable rather than merely discouraged.
#
# Safe to re-run. Ground setup is idempotent and is skipped when nothing in
# ansible/ has changed since the box last recorded it.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Written for bash 3.2, which is what macOS still ships as /bin/bash — so no
# associative arrays, no mapfile, no ${var,,}. Likewise every external call
# below sticks to what BSD and GNU userlands both answer to: no `grep -oP`, no
# `sed -i`, no `sha256sum`, no `timeout`, no `sort -V`.

die() { printf '%s\n' "$@" >&2; exit 1; }

usage() {
  cat >&2 <<'USAGE'
usage: ./deploy.sh <server> <commit> [--reset-db <admin-email>] [--force-rebuild]
                   [--restore <dump.sql.gz>]

  <server>   the domain of an instance (e.g. cgl.fmnoel.de), which is also
             its ansible/host_vars/<server>.yml and its inventory line
  <commit>   a branch, tag, or commit SHA in the chatgamelab repository
  --reset-db destroys the database and makes <admin-email> its first admin
  --force-rebuild
             build the images again even though this commit has been built
             here before — for when the recipe moved rather than the source
  --restore <dump.sql.gz>
             replace the database with a dump, loading it before the backend
             starts so its own migrations carry it forward

examples:
  ./deploy.sh cgl.fmnoel.de development
  ./deploy.sh cgl.fmnoel.de v1.56.0
  ./deploy.sh cgl.fmnoel.de 68b1744
  ./deploy.sh cgl.fmnoel.de engineV2 --reset-db you@example.com
USAGE
  exit 2
}

# ---------------------------------------------------------------- local tools

# Collected and reported in one block rather than failing on the first miss:
# being told about four missing tools at once costs one trip to the package
# manager instead of four.
sha256() { # reads stdin, prints the hex digest
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else shasum -a 256 | cut -d' ' -f1; fi
}

# stat -c is GNU, stat -f is BSD; both userlands answer to one of them.
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

require_tools() {
  local missing="" apt_pkgs="" brew_pkgs=""
  # tool:apt-package:brew-package
  for spec in \
    git:git:git \
    ssh:openssh-client:openssh \
    ssh-keygen:openssh-client:openssh \
    ssh-keyscan:openssh-client:openssh \
    curl:curl:curl \
    ansible-playbook:ansible:ansible \
    ansible-galaxy:ansible:ansible \
    gh:gh:gh
  do
    local tool="${spec%%:*}" rest="${spec#*:}"
    local apt_pkg="${rest%%:*}" brew_pkg="${rest#*:}"
    command -v "$tool" >/dev/null 2>&1 && continue
    missing="$missing $tool"
    case " $apt_pkgs " in *" $apt_pkg "*) ;; *) apt_pkgs="$apt_pkgs $apt_pkg" ;; esac
    case " $brew_pkgs " in *" $brew_pkg "*) ;; *) brew_pkgs="$brew_pkgs $brew_pkg" ;; esac
  done
  # One of the two digest tools has to be there. Both userlands ship one, under
  # different names, so this only ever fires on something unusual.
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    missing="$missing sha256sum"
    apt_pkgs="$apt_pkgs coreutils"
    brew_pkgs="$brew_pkgs coreutils"
  fi
  [ -z "$missing" ] && return 0

  echo "Missing:$missing" >&2
  echo >&2
  echo "Install with one of:" >&2
  echo >&2
  echo "  Debian/Ubuntu:  sudo apt install$apt_pkgs" >&2
  echo "  macOS:          brew install$brew_pkgs" >&2
  echo >&2
  echo "On macOS, brew itself comes from https://brew.sh." >&2
  exit 1
}

require_tools

# ---------------------------------------------------------------- arguments

server=""; commit=""; reset_db=0; admin_email=""; force_rebuild=0; restore_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reset-db)
      shift
      [ $# -gt 0 ] || die "--reset-db needs the address that becomes admin."
      admin_email="$1"; reset_db=1
      ;;
    --force-rebuild) force_rebuild=1 ;;
    --restore)
      shift
      [ $# -gt 0 ] || die "--restore needs the dump to load."
      restore_file="$1"
      ;;
    -h|--help) usage ;;
    -*) die "Unknown option: $1" "" "$(usage 2>&1)" ;;
    *)
      if   [ -z "$server" ]; then server="$1"
      elif [ -z "$commit" ]; then commit="$1"
      else die "Unexpected argument: $1"
      fi
      ;;
  esac
  shift
done
[ -n "$server" ] && [ -n "$commit" ] || usage

# One empties the database and names who gets into what replaces it; the other
# brings a database that already has its own admins. Asking for both says two
# incompatible things about the same volume.
if [ "$reset_db" -eq 1 ] && [ -n "$restore_file" ]; then
  die "--reset-db and --restore both replace the database, differently." \
      "" \
      "A restored dump carries its own accounts, so it needs no bootstrap" \
      "address. Drop --reset-db."
fi

if [ -n "$restore_file" ]; then
  [ -r "$restore_file" ] || die "cannot read $restore_file"
  case "$restore_file" in
    *.gz)
      gzip -t "$restore_file" 2>/dev/null || die "$restore_file is named .gz and does not decompress."
      ;;
  esac
fi

# Checked here because a typo costs the database: --reset-db destroys it and
# this address is the only way back into what replaces it.
if [ "$reset_db" -eq 1 ]; then
  case "$admin_email" in
    *[[:space:]]*|*@*@*|@*|*@|"") die "That doesn't look like an address: '$admin_email'" ;;
    *@*.*) ;;
    *) die "That doesn't look like an address: '$admin_email'" ;;
  esac
fi

# ------------------------------------------------------------ configuration

# One scalar out of a YAML file, with surrounding quotes stripped. Enough for
# these files, which hold flat `key: value` lines and nothing else — and it is
# `sed -n s//p` rather than `grep -oP` because BSD grep has no PCRE.
yaml_get() { # key file
  sed -n "s/^$1:[[:space:]]*//p" "$2" | head -1 \
    | sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

vars_file="$repo_root/ansible/host_vars/$server.yml"
if [ ! -f "$vars_file" ]; then
  echo "No such server: $server" >&2
  echo >&2
  echo "An instance is a host_vars file named after its domain, plus a line in" >&2
  echo "ansible/inventory.ini. These exist:" >&2
  for f in "$repo_root"/ansible/host_vars/*.yml; do
    [ -f "$f" ] || continue
    echo "  $(basename "$f" .yml)" >&2
  done
  exit 1
fi

inventory="$repo_root/ansible/inventory.ini"
grep -q "^$server[[:space:]]" "$inventory" \
  || die "$server has a host_vars file and no line in ansible/inventory.ini, so" \
         "ansible does not know it exists."

# The domain the instance serves, the host this script reaches, and the name
# ansible knows it by are one string deliberately: one v-server per instance
# with DNS already pointing at it, which certbot requires regardless.
host="$server"
domain="$server"
# All three checked, so a half-filled file fails here with the reason rather
# than at sign-in with a redirect_uri mismatch or an audience the backend
# refuses. The values are public — the client id is served to every visitor in
# /env.js — so they belong in this file once you have them.
for key in auth0_domain auth0_audience auth0_client_id; do
  value="$(yaml_get "$key" "$vars_file")"
  case "$value" in
    PUT_THE_*|"")
      die "$key is still unset in ansible/host_vars/$server.yml." \
          "" \
          "All three Auth0 values come from that instance's own account: a" \
          "Single Page Application, and an API whose identifier is the" \
          "audience. The application's URL lists want the callback paths," \
          "not the bare origin:" \
          "" \
          "  Allowed Callback URLs   https://$domain/auth/login/auth0/callback" \
          "  Allowed Logout URLs     https://$domain/auth/logout/auth0/callback" \
          "  Allowed Web Origins     https://$domain" \
          "" \
          "The file itself carries the rest of the reasoning."
      ;;
  esac
done

all_vars="$repo_root/ansible/group_vars/all.yml"
app_repo="$(yaml_get app_repo "$all_vars")"
runtime_user="$(yaml_get runtime_user "$all_vars")"
runtime_home="$(yaml_get runtime_home "$all_vars")"
hook_secret_path="$(yaml_get hook_secret_path "$all_vars" | sed "s#{{ runtime_home }}#$runtime_home#")"
hook_secret_name="$(yaml_get hook_secret_name "$all_vars")"
hook_path_val="$(yaml_get hook_path "$all_vars")"
app_repo_slug="$(yaml_get app_repo_slug "$all_vars")"
track_branch="$(yaml_get track_branch "$vars_file")"
update_interval="$(yaml_get update_interval "$all_vars")"
# Per-host, defaulting to the safer of the two (see group_vars).
image_source="$(yaml_get image_source "$vars_file")"
[ -n "$image_source" ] || image_source="$(yaml_get image_source "$all_vars")"
image_registry="$(yaml_get image_registry "$all_vars")"
# Read rather than assumed, since group_vars is where the path is decided and
# it is not under runtime_home.
deploy_base="$(yaml_get deploy_base "$all_vars")"
deploy_clone_remote="$(yaml_get deploy_clone "$all_vars" | sed "s#{{ deploy_base }}#$deploy_base#")"

echo ">> https://$domain"

# ------------------------------------------------------- resolving the commit

# Resolved against a mirror this script keeps, rather than against a working
# clone next door: a mirror is never mid-rebase, never on a stale branch, and
# never has a commit that only exists locally. What it resolves is therefore
# what the box will be able to fetch.
mirror="$repo_root/.cache/chatgamelab.git"
echo ">> resolving $commit"
if [ -d "$mirror" ]; then
  git --git-dir="$mirror" fetch --quiet --prune --prune-tags --tags origin '+refs/heads/*:refs/heads/*'
else
  mkdir -p "$repo_root/.cache"
  echo "   first run — mirroring $app_repo (~100 MB)"
  git clone --quiet --mirror "$app_repo" "$mirror"
fi

sha="$(git --git-dir="$mirror" rev-parse --verify --quiet "${commit}^{commit}" || true)"
if [ -z "$sha" ]; then
  echo "   '$commit' resolves to nothing in $app_repo." >&2
  echo >&2
  echo "   Branches and tags carrying recent work:" >&2
  git --git-dir="$mirror" for-each-ref --sort=-committerdate --count=12 \
    --format='     %(refname:short)  %(committerdate:short)' refs/heads refs/tags >&2
  exit 1
fi

# A commit no ref can reach is a commit the box cannot fetch, so it is refused
# here with the reason rather than several minutes later as a git failure on
# the far side.
if ! git --git-dir="$mirror" for-each-ref --contains "$sha" --count=1 \
     refs/heads refs/tags | grep -q .; then
  die "$sha is in the mirror but no branch or tag reaches it, so the box cannot fetch it." \
      "Push it to a branch first."
fi

short="$(git --git-dir="$mirror" rev-parse --short=7 "$sha")"

# A pulling instance runs what CI published, and CI publishes one image per
# release — so the ref has to be a release tag, and the image tag is that
# version. Refused here with the reason rather than as a registry 404 later.
image_tag=""
if [ "$image_source" = "registry" ]; then
  exact="$(git --git-dir="$mirror" describe --tags --exact-match "$sha" 2>/dev/null || true)"
  case "$exact" in
    v[0-9]*.[0-9]*.[0-9]*) image_tag="${exact#v}" ;;
    *)
      die "$server pulls its images, so it can only deploy a published release." \
          "" \
          "'$commit' resolves to $short, which carries no vX.Y.Z tag. Name a" \
          "release tag instead:" \
          "" \
          "  $(git --git-dir="$mirror" tag -l 'v[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname | awk '!/-/' | head -5 | tr '\n' ' ')" \
          "" \
          "Deploying an arbitrary commit needs image_source: build, and a box" \
          "with the memory to compile on."
      ;;
  esac
fi
reached_by="$(git --git-dir="$mirror" for-each-ref --contains "$sha" --count=3 \
  --format='%(refname:short)' refs/heads refs/tags | tr '\n' ' ')"
subject="$(git --git-dir="$mirror" log -1 --format=%s "$sha")"
echo "   $short — $subject"
echo "   reached by: $reached_by"

# The migration high-water mark of the tree being deployed. Compared on the box
# against the schema version the live database carries, because the app runs
# migrations forward only (server/db/init.go:298) and has no down path: moving
# to an older commit leaves the schema ahead of the code, which fails at query
# time rather than at startup.
# Leading zeros stripped: the filenames are 001_.. to 031_.., and a value like
# 031 survives `test -ge` intact but means 25 in any arithmetic context. Both
# this and box/cgl-build emit a plain integer so the two can never disagree.
target_migration="$(git --git-dir="$mirror" ls-tree --name-only "$sha" server/db/migrations/ \
  | sed -n 's#.*/0*\([0-9]\{1,\}\)_.*\.sql$#\1#p' | sort -n | tail -1)"
[ -n "$target_migration" ] || target_migration=0
echo "   migrations: up to $target_migration"

# ------------------------------------------------------------ reaching the box

# host_key_checking stays on in ansible.cfg, deliberately, so an untrusted host
# key fails the connection outright instead of prompting mid-play. The
# trust-on-first-use step happens here instead, with the fingerprints shown for
# you to check against your provider's console.
mkdir -p ~/.ssh
touch ~/.ssh/known_hosts
if ! ssh-keygen -F "$host" >/dev/null 2>&1; then
  echo ">> $host is not in ~/.ssh/known_hosts yet. Its key fingerprints:"
  echo
  ssh-keyscan -H "$host" 2>/dev/null | ssh-keygen -lf - | sed 's/^/     /'
  echo
  printf 'Trust and record this host key? [y/N] '
  read -r confirm
  case "$confirm" in
    y|Y) ssh-keyscan -H "$host" 2>/dev/null >> ~/.ssh/known_hosts ;;
    *) die "Aborted. Verify the fingerprint with your provider — its console usually" \
           "shows it — then re-run." ;;
  esac
fi

ssh_opts="-o BatchMode=yes -o ConnectTimeout=10"

# Every call below that pipes nothing in gets -n as well. ssh reads stdin by
# default and forwards it to the remote command, so one of these swallowing a
# script's own input is how an answer typed for a later prompt disappeared and
# `read` then hit EOF — which under set -e ends the run with no message at all.
# -n is per-call rather than in ssh_opts, because the calls that push a secret
# or a dump do need stdin.

# Authentication is by key throughout, held in your ssh-agent; nothing here can
# fall back to a password. Asked as its own question because inside a play the
# two causes — a key the agent is not holding, and a key the box never knew —
# arrive identically as "Permission denied (publickey)", several tasks in, with
# the agent never mentioned.
ssh_works() { ssh -n $ssh_opts "$1@$host" true 2>/dev/null; }

explain_ssh_failure() { # user
  local user="$1" agent=0
  ssh-add -l >/dev/null 2>&1 || agent=$?   # 0 holding keys, 1 empty, 2 unreachable
  echo >&2
  echo "Cannot authenticate to $user@$host, and there is no password to fall back to." >&2
  echo >&2
  case "$agent" in
    2)
      if [ -n "${SSH_AUTH_SOCK:-}" ]; then
        echo "Nothing is answering \$SSH_AUTH_SOCK:" >&2
        echo "  $SSH_AUTH_SOCK" >&2
        echo "a value that outlived the agent that set it. Start one, or point this" >&2
        echo "shell at the agent you do have:" >&2
      else
        echo "\$SSH_AUTH_SOCK is unset, so this shell has no agent at all:" >&2
      fi
      echo >&2
      echo "  eval \"\$(ssh-agent -s)\" && ssh-add" >&2
      ;;
    1)
      echo "Your agent is running and holding nothing:" >&2
      echo >&2
      echo "  ssh-add" >&2
      ;;
    *)
      echo "Your agent is holding:" >&2
      ssh-add -l | sed 's/^/    /' >&2
      echo >&2
      echo "and $host accepts none of them as $user." >&2
      ;;
  esac
  echo >&2
  echo "'ssh-add -l' shows what you are offering." >&2
}

# ---------------------------------------------------- preconditions on the box

# One round trip, because each of these is a sentence the box can answer in the
# same breath, and reporting them together beats a failing task twelve steps
# into a play.
check_box() { # user
  local blob
  blob="$(ssh -n $ssh_opts "$1@$host" '
    . /etc/os-release 2>/dev/null || true
    echo "os_id=${ID:-unknown}"
    echo "os_version=${VERSION_ID:-unknown}"
    echo "os_name=${PRETTY_NAME:-unknown}"
    echo "arch=$(uname -m)"
    echo "mem_mb=$(awk "/MemTotal/{print int(\$2/1024)}" /proc/meminfo 2>/dev/null || echo 0)"
    echo "disk_gb=$(df -Pk / | awk "NR==2{print int(\$4/1048576)}")"
    command -v systemctl >/dev/null 2>&1 && echo "systemd=yes" || echo "systemd=no"
  ' 2>/dev/null)" || return 1
  printf '%s\n' "$blob"
}

field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

require_box_supported() { # blob
  local blob="$1" os_id os_version os_name mem_mb disk_gb systemd
  os_id="$(field "$blob" os_id)"
  os_version="$(field "$blob" os_version)"
  os_name="$(field "$blob" os_name)"
  mem_mb="$(field "$blob" mem_mb)"
  disk_gb="$(field "$blob" disk_gb)"
  systemd="$(field "$blob" systemd)"

  echo "   $os_name, $(field "$blob" arch), ${mem_mb} MB RAM, ${disk_gb} GB free on /"

  if [ "$os_id" != "debian" ]; then
    die "This expects Debian and the box reports '$os_id' ($os_name)." \
        "" \
        "The roles are Debian-shaped throughout: apt, /etc/ssh/sshd_config.d," \
        "unattended-upgrades, and Debian's own podman package. Porting them to" \
        "another distribution is real work rather than a variable to flip."
  fi

  # 13 is the floor because that is where Debian's podman becomes 5.x, and
  # rootless Quadlet plus pasta networking are what this deployment is built
  # on. Bookworm's podman is 4.x and would need a different story entirely.
  case "$os_version" in
    1[3-9]|[2-9][0-9]) ;;
    12|11|10|9|8)
      die "Debian $os_version is too old — this needs Debian 13 (trixie) or newer." \
          "" \
          "Debian $os_version ships podman 4.x. This deployment runs the stack" \
          "rootless under podman 5.x, for Quadlet units and pasta networking." \
          "Reinstall the box with Debian 13."
      ;;
    *)
      die "Cannot read a Debian version from the box (got '$os_version')."
      ;;
  esac
  if [ "$os_version" -gt 13 ] 2>/dev/null; then
    echo "   note: Debian $os_version is newer than the 13 this was written against"
  fi

  [ "$systemd" = "yes" ] || die "No systemctl on the box; this deployment is systemd-shaped throughout."

  # Measured rather than guessed: a full three-image rebuild peaked at 1636 MB
  # of total system use, stack included, and never touched swap. So a building
  # box wants ~1.9 GB, and one that only pulls needs enough to run the stack,
  # which idles at 751 MB.
  if [ "$image_source" = "build" ]; then
    if [ "$mem_mb" -lt 1700 ]; then
      die "${mem_mb} MB of RAM, and building here peaks around 1.7 GB." \
          "" \
          "Either give this instance a bigger box, or set image_source:" \
          "registry in ansible/host_vars/$server.yml so it pulls what CI" \
          "published instead of compiling." \
          "" \
          "The floor is the measured peak (1636 MB for a full three-image" \
          "rebuild, stack included) rather than a guess, so a box under it" \
          "will not finish a build however long it is given."
    fi
    if [ "$mem_mb" -lt 2600 ]; then
      echo "   note: ${mem_mb} MB leaves the build about $((mem_mb - 1700)) MB spare — swap will be used"
    fi
  elif [ "$mem_mb" -lt 1200 ]; then
    die "${mem_mb} MB of RAM, and the stack alone idles around 750 MB."
  fi
  if [ "$disk_gb" -lt 15 ]; then
    die "${disk_gb} GB free on /, which the image store and build cache will" \
        "exhaust. Free some space or resize the box."
  fi
}

# ------------------------------------------------------------- ground setup

# The hash of everything under ansible/. The box records what it last converged
# to, so the sweep runs when this repo's ground definition has changed and is
# skipped when it has not — which is what keeps `./deploy.sh <server> <commit>`
# a fast loop while still leaving the box in a defined state. Sorted before
# hashing because find's order is filesystem order, not a promise.
ground_hash="$(
  cd "$repo_root" && find ansible -type f \
    | LC_ALL=C sort \
    | while IFS= read -r f; do printf '%s ' "$f"; sha256 < "$f"; done \
    | sha256
)"

echo ">> ssh"
setup_needed=0
if ssh_works "$runtime_user"; then
  echo "   $runtime_user@$host — key accepted"
  box="$(check_box "$runtime_user")" || die "Reached $runtime_user@$host and then could not read its state."
  require_box_supported "$box"
  recorded="$(ssh -n $ssh_opts "$runtime_user@$host" "cat '$runtime_home/.ground-hash' 2>/dev/null" || true)"
  if [ "$recorded" = "$ground_hash" ]; then
    echo ">> ground setup — unchanged since this box last converged, skipping"
  else
    echo ">> ground setup — ansible/ has changed since this box last converged"
    setup_needed=1
  fi
else
  echo "   $runtime_user@$host — no (the box has not been set up yet, or has drifted)"
  setup_needed=1
fi

if [ "$setup_needed" -eq 1 ] || [ "${FORCE_SETUP:-0}" = "1" ]; then
  # Ground setup creates the unprivileged users, so it is the one phase that
  # needs root — and the only one.
  if ! ssh_works root; then
    explain_ssh_failure root
    echo >&2
    echo "Ground setup creates $runtime_user, so this phase needs root. Install your" >&2
    echo "public key for root through your provider's console, then re-run." >&2
    exit 1
  fi
  echo "   root@$host — key accepted"
  box="$(check_box root)" || die "Reached root@$host and then could not read its state."
  require_box_supported "$box"

  echo ">> ground setup"
  ( cd "$repo_root/ansible" \
    && ansible-galaxy collection install -r requirements.yml \
    && ansible-playbook setup-server.yml --limit "$server" -e "ground_hash=$ground_hash" )

  ssh_works "$runtime_user" || die "Ground setup finished and $runtime_user@$host still refuses the key."
fi

# ------------------------------------------------------- the box's own copy

# Brought up to date here, before anything runs out of it. Everything below
# invokes a script from that clone — the backup check, phase two — so updating
# it later means those run the previous commit's code, which is how a fix to
# box/ appeared to have no effect at all.
#
# The box runs its own copy of this repository, so it can redeploy with no
# laptop in the loop and both the manual and the automatic path execute the
# same code. Which copy is decided here: the commit you are running from. That
# makes "the phase two that runs" the phase two you are looking at — provided
# you pushed it, which is checked rather than assumed.
self_sha="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
[ -n "$self_sha" ] || die "$repo_root is not a git repository, so there is no phase two for the box to check out."
git -C "$repo_root" fetch --quiet origin 2>/dev/null || true
if ! git -C "$repo_root" for-each-ref --contains "$self_sha" --count=1 refs/remotes/origin | grep -q .; then
  die "The commit you are deploying from ($(git -C "$repo_root" rev-parse --short HEAD)) is not on origin," \
      "and the box checks this repository out from there." \
      "" \
      "  git push" \
      "" \
      "Phase two lives on the box deliberately, which is what makes a push the" \
      "price of changing it."
fi
if ! git -C "$repo_root" diff --quiet || ! git -C "$repo_root" diff --cached --quiet; then
  echo "   note: your working tree has uncommitted changes, and the box will run $(git -C "$repo_root" rev-parse --short HEAD)"
fi

# Brought to that commit from here, rather than by the script inside it: a bug
# in a self-checkout cannot be fixed by the checkout it broke, and a box wedged
# that way needed someone to log in and clean up before anything could deploy
# again. Done from this side, the next deploy repairs it.
#
# reset --hard because the clone is machine-managed and nobody edits it, so
# local drift is to be discarded rather than protected.
echo ">> bringing the box's clone to $(git -C "$repo_root" rev-parse --short HEAD)"
ssh -n $ssh_opts "$runtime_user@$host" \
  "git -C '$deploy_clone_remote' fetch --quiet origin \
   && git -C '$deploy_clone_remote' reset --quiet --hard '$self_sha'" \
  || die "Could not bring $deploy_clone_remote to $self_sha." \
         "" \
         "If the clone is missing entirely, re-run with FORCE_SETUP=1 to make" \
         "ground setup recreate it."

# Checked from here, where the answer can name the release and the workflow,
# rather than as a pull failure on the box. Anonymous, because the packages are
# public — which is also why the box needs no registry credential.
if [ -n "$image_tag" ]; then
  echo ">> checking the registry holds $image_tag"
  registry_host="${image_registry%%/*}"
  registry_path="${image_registry#*/}"
  for image in db backend web; do
    repo="$registry_path/chatgamelab-$image"
    token="$(curl -fsS "https://$registry_host/token?scope=repository:$repo:pull&service=$registry_host" \
      | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
    code="$(curl -sS -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer $token" \
      -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
      "https://$registry_host/v2/$repo/manifests/$image_tag")"
    case "$code" in
      200) echo "   chatgamelab-$image:$image_tag — present" ;;
      *)   die "   chatgamelab-$image:$image_tag — the registry answered $code" \
               "" \
               "That release has no published image. CI builds them on a push to" \
               "main, so a tag created by hand has none. Check the run:" \
               "" \
               "  gh run list --workflow=docker-image.yml --repo $app_repo_slug" ;;
    esac
  done
fi

remote_restore=""
if [ -n "$restore_file" ]; then
  remote_restore="/var/tmp/cgl-restore-$$.$(basename "$restore_file")"
  echo ">> sending the dump ($(du -h "$restore_file" | cut -f1))"
  # Landed rather than streamed straight into psql: a transfer that fails
  # part-way then costs the transfer again rather than the database, and phase
  # two can check the file before it drops anything.
  ssh $ssh_opts "$runtime_user@$host" "umask 077 && cat > '$remote_restore'" < "$restore_file" \
    || die "could not send the dump to the box."
fi

# --------------------------------------------------------- backup destination

# Reported every run, and changed only when you say so. The one genuine secret
# in this deployment — the SSH key the database container uploads dumps with —
# is given here interactively and lives on the box from then on, so it stays in
# your password manager and never in this repository.
echo ">> backups"
backup_state=0
ssh -n $ssh_opts "$runtime_user@$host" "'$deploy_clone_remote/box/cgl-secrets' check" || backup_state=$?
case "$backup_state" in
  0) backup_prompt="Replace the backup destination? [y/N] " ;;   # configured and working
  *) backup_prompt="Set the backup destination now? [y/N] " ;;   # absent, or broken
esac
printf '   %s' "$backup_prompt"
read -r answer || die "" "No answer on stdin, so nothing was changed." \
                        "Run this from a terminal, or pipe an answer in."
case "$answer" in
  y|Y)
    # Offered back, so correcting one value costs one value rather than five.
    current="$(ssh -n $ssh_opts "$runtime_user@$host" "'$deploy_clone_remote/box/cgl-secrets' show" 2>/dev/null || true)"
    cur() { printf '%s\n' "$current" | sed -n "s/^$1=//p" | head -1; }

    ask() { # prompt current-value fallback -> answer on stdout
      local prompt="$1" cur="$2" fallback="${3:-}" shown answer
      shown="${cur:-$fallback}"
      if [ -n "$shown" ]; then printf '   %s [%s]: ' "$prompt" "$shown" >&2
      else printf '   %s: ' "$prompt" >&2; fi
      read -r answer
      printf '%s' "${answer:-$shown}"
    }

    b_host="$(ask 'SFTP host'   "$(cur BACKUP_SSH_HOST)")"
    b_port="$(ask 'SFTP port'   "$(cur BACKUP_SSH_PORT)" 22)"
    b_user="$(ask 'SFTP user'   "$(cur BACKUP_SSH_USER)")"
    b_path="$(ask 'remote path' "$(cur BACKUP_PATH)" backups)"

    have_key="$(cur HAS_KEY)"
    if [ -n "$have_key" ]; then
      printf '   private key file [keep the one on the box, %s]: ' "$have_key"
    else
      printf '   private key file: '
    fi
    read -r b_key

    [ -n "$b_host" ] && [ -n "$b_user" ] \
      || die "host and user are both needed; nothing has been changed."
    [ -n "$b_key" ] || [ -n "$have_key" ] \
      || die "there is no key on the box to keep, so one is needed here."

    # read does no expansion, so a path typed with a ~ arrives literally.
    case "$b_key" in
      "~") b_key="$HOME" ;;
      "~/"*) b_key="$HOME/${b_key#\~/}" ;;
    esac
    if [ -n "$b_key" ]; then
      [ -r "$b_key" ] || die "cannot read $b_key; nothing has been changed."
    fi

    # ssh refuses a private key others can read, and says so in a banner that
    # looks like a different problem entirely — so it is caught here, where the
    # answer is one keystroke. scp brings a loose mode across, which is how a
    # key copied from another host usually arrives.
    if [ -n "$b_key" ] && [ "$(( 8#$(file_mode "$b_key") & 8#77 ))" -ne 0 ]; then
      echo "   $b_key is mode $(file_mode "$b_key"), which ssh refuses —"
      echo "   and which lets anyone on this machine read it."
      printf '   chmod 600 it? [Y/n] '
      read -r fix_mode
      case "$fix_mode" in
        n|N) die "left as it is, and what follows would refuse it." ;;
        *) chmod 600 "$b_key"; echo "   now mode $(file_mode "$b_key")" ;;
      esac
    fi

    [ -z "$b_key" ] || ssh-keygen -y -f "$b_key" >/dev/null 2>&1 \
      || die "ssh cannot read $b_key as a private key." \
             "" \
             "If it is passphrase-protected, the database container cannot use" \
             "it unattended — make an unencrypted key for this and register its" \
             "public half on the destination."

    # base64 because an env file has no multi-line values, and -w0 is GNU-only.
    # Left empty when the answer was blank: cgl-secrets writes the key only
    # when it is given one, so the box keeps what it already holds.
    key_b64=""
    [ -z "$b_key" ] || key_b64="$(base64 -w0 < "$b_key" 2>/dev/null || base64 < "$b_key" | tr -d '\n')"
    # Piped straight over ssh rather than written anywhere here: the key never
    # touches this machine's disk outside the file it already lives in.
    {
      printf 'BACKUP_ENABLED=true\n'
      printf 'BACKUP_SSH_HOST=%s\n' "$b_host"
      printf 'BACKUP_SSH_PORT=%s\n' "${b_port:-22}"
      printf 'BACKUP_SSH_USER=%s\n' "$b_user"
      printf 'BACKUP_PATH=%s\n' "${b_path:-backups}"
      [ -z "$key_b64" ] || printf 'BACKUP_SSH_KEY_B64=%s\n' "$key_b64"
    } | ssh $ssh_opts "$runtime_user@$host" "umask 077 && cat > '$runtime_home/secrets.env'"
    ssh -n $ssh_opts "$runtime_user@$host" "'$deploy_clone_remote/box/cgl-secrets' install" \
      || die "The box refused the backup destination; nothing has been deployed."
    ;;
  *) : ;;
esac

# ------------------------------------------------------------- the trigger

# Nobody ever needs to read this secret — it exists only so the box can tell
# CI's trigger from anyone else's — so it is minted fresh on every run and both
# ends are set here. No prompt, nothing in a password manager, and rotation for
# free.
#
# GitHub first, and the box only once that has landed: a run where gh cannot
# write the secret then leaves the working pair intact, rather than
# half-replaced with every trigger rejected until someone notices.
rotate_hook_secret() {
  local secret
  secret="$(openssl rand -hex 32)"
  # printf on both ends, not a here-string, so the two are the same bytes
  # rather than differing by the newline <<< appends — the listener strips what
  # it reads, but an HMAC key is the wrong place to rely on that. A pipe rather
  # than --body keeps the value out of the process list.
  if ! printf '%s' "$secret" | gh secret set "$hook_secret_name" --repo "$app_repo_slug" >/dev/null; then
    echo "   couldn't set $hook_secret_name on $app_repo_slug — the box is untouched" >&2
    echo "   too, so whatever pair was working still is. Check 'gh auth status'" >&2
    echo "   and that you have admin there." >&2
    return 1
  fi
  if ! printf '%s' "$secret" | ssh $ssh_opts "$runtime_user@$host" "umask 077 && cat > '$hook_secret_path'"; then
    echo "   set on GitHub but not on the box, which now disagree — triggers will" >&2
    echo "   be rejected until a re-run sets both." >&2
    return 1
  fi
  echo "   $hook_secret_name rotated, both ends set"

  # The endpoint's address, written beside the secret rather than hardcoded in
  # the workflow. A domain that moves would otherwise leave CI posting at a
  # name that no longer resolves — which is exactly what happened when this
  # instance became dev.cgl.fmnoel.de, and the workflow went on triggering
  # cgl.fmnoel.de into a NXDOMAIN for hours while the timer quietly covered it.
  if ! gh variable set CGL_DEPLOY_HOOK_URL --repo "$app_repo_slug" \
       --body "https://$domain$hook_path_val" >/dev/null 2>&1; then
    echo "   couldn't set CGL_DEPLOY_HOOK_URL on $app_repo_slug — CI will post" >&2
    echo "   wherever it was last told to. Check 'gh auth status'." >&2
    return 1
  fi
  echo "   CGL_DEPLOY_HOOK_URL set to https://$domain$hook_path_val"
}

# Only for an instance that follows a branch. The secret and the URL are single
# values on one shared application repository, so a branchless instance rotating
# them would point CI's trigger at itself and silently break the instance that
# does use it.
if [ -n "$track_branch" ]; then
  echo ">> the deploy trigger"
  # Reported rather than fatal: a dead trigger costs a deploy its promptness and
  # nothing else, since the timer goes on converging on $track_branch regardless.
  rotate_hook_secret || echo "   the trigger may be dead; the ${update_interval:-15min} timer still converges"
else
  echo ">> no deploy trigger — this instance follows no branch"
fi

# ------------------------------------------------------------------- phase two

echo ">> phase two on the box"
set -- "$deploy_clone_remote/box/cgl-deploy" \
  --deploy-sha "$self_sha" \
  --app-sha "$sha" \
  --target-migration "$target_migration"
[ "$reset_db" -eq 1 ] && set -- "$@" --reset-db "$admin_email"
[ "$force_rebuild" -eq 1 ] && set -- "$@" --force-rebuild
[ -n "$image_tag" ] && set -- "$@" --image-tag "$image_tag"
[ -n "$remote_restore" ] && set -- "$@" --restore "$remote_restore"

# -t so the box's progress arrives as it happens rather than in one lump at the
# end: a build is minutes long and watching it is the point.
ssh -t -o ConnectTimeout=10 "$runtime_user@$host" "$(printf '%q ' "$@")"

# ------------------------------------------------------------------- probing

# The nginx role re-templates the vhost that certbot edits in place, so the TLS
# directives are gone until certbot's own task reinstalls them in the same
# play. Probe rather than trust that it did: getting this wrong takes https
# down for the whole box, silently, and only a visitor would find out.
echo ">> probing https://$domain/"
probe() { # url expected-status [method] [body]
  local url="$1" want="$2" method="${3:-GET}" body="${4:-}" status
  local -a data=()
  # A POST with no body carries no Content-Length, which the listener answers
  # 411 before anything looks at it — so a probe meaning to reach past that has
  # to send something.
  [ -n "$body" ] && data=(--data-binary "$body")
  status="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -X "$method" "${data[@]+"${data[@]}"}" "$url" 2>/dev/null || echo 000)"
  case "|$want|" in
    *"|$status|"*) echo "   $url — $status" ;;
    *) echo "   $url — answered $status, expected ${want//|/ or }" >&2; return 1 ;;
  esac
}

probe_failed=0
probe "https://$domain/" 200 || probe_failed=1
probe "https://$domain/env.js" 200 || probe_failed=1
# A real body, deliberately unsigned, so 403 is the pass: nginx reaches the
# listener and the listener read the body and refused it. A 404 or a 502 would
# mean CI posting its triggers into the void.
[ -z "$track_branch" ] \
  || probe "https://$domain$hook_path_val" 403 POST '{"probe":true}' || probe_failed=1
if [ "$probe_failed" -ne 0 ]; then
  echo >&2
  echo "The stack came up and the box is not serving as expected. Two usual causes:" >&2
  echo "certbot having failed to reinstall the TLS directives the vhost template" >&2
  echo "overwrote ('nginx -T' and 'certbot certificates' on the box), or nginx" >&2
  echo "unable to reach the web container ('systemctl --user status' as $runtime_user)." >&2
  exit 1
fi

echo
echo ">> $short is live at https://$domain/"
