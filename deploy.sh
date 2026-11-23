#!/usr/bin/env bash
# Sets up one of my chatgamelab instances, or brings it back to its file.
# Usage: ./deploy.sh --help. Written for bash 3.2 (macOS).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
app_repo="flocko-motion/chatgamelab"

help() {
  cat <<'HELP'
Sets up one of my chatgamelab instances, or brings it back to its file.

  ./deploy.sh [<instance>] [options]

Takes the newest release on the instance's release_channel, fetches
chatgamelab at that tag into .cache/ and runs its deploy/setup.sh with the
instance file. A new box installs that release; a box that runs a version
keeps it (its admin upgrades from the app). Safe to run again.

<instance>             a domain (dev.cgl.fmnoel.de) or an instance file
                       (instances/dev.cgl.fmnoel.de.yml); none: pick from a list

Options:
  --admin <email>      the address that becomes admin at its first sign-in,
                       while the instance has no admin (first setup)
  --backup-key <file>  the private SSH key for the SFTP backup target;
                       copied to the box
  --basic-auth         set a new site password (basic_auth_user in the
                       instance file): asked for, saved in the keychain
  --key <file>         the SSH key to reach the box as root with
                       (default: your ssh config and agent)
  --ref v<version>     set up from this release instead of the newest one
  -h, --help           this text

The site password (when the instance file names basic_auth_user) comes from
the macOS keychain, item "chatgamelab basic auth <domain>"; the first run asks
for it and saves it there.

Needs macOS, git, ssh, curl, jq and ansible.
HELP
}

die() { printf '%s\n' "$@" >&2; exit 1; }

# A top-level scalar of the instance file: comment, quotes and spaces off.
instance_value() {
  sed -n "s/^$1:[[:space:]]*//p" "$instance" | head -1 \
    | sed -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}
usage() { help >&2; exit 2; }

for arg in "$@"; do
  case "$arg" in -h|--help) help; exit 0 ;; esac
done

if [ $# -ge 1 ] && [ "${1#-}" = "$1" ]; then
  domain="$1"; shift
else
  # No instance named: pick one of instances/*.yml.
  names=()
  for f in "$here"/instances/*.yml; do
    [ -f "$f" ] && names+=("$(basename "$f" .yml)")
  done
  [ ${#names[@]} -gt 0 ] || die "no instance files in instances/"
  echo "Which instance?"
  PS3="number: "
  select domain in "${names[@]}"; do
    [ -n "${domain:-}" ] && break
    echo "pick one of 1-${#names[@]}"
  done
  [ -n "${domain:-}" ] || die "no instance picked"
fi
ref=""
pass=()
new_password=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) [ $# -ge 2 ] || usage; ref="$2"; shift 2 ;;
    --admin|--backup-key) [ $# -ge 2 ] || usage; pass+=("$1" "$2"); shift 2 ;;
    --basic-auth) new_password=1; shift ;;
    --key)
      [ $# -ge 2 ] || usage
      [ -f "$2" ] || die "no such key file: $2"
      # ansible's ssh connection reads it; setup.sh passes the environment on.
      export ANSIBLE_PRIVATE_KEY_FILE="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
      # Only this key: the agent's keys first would use up the box's MaxAuthTries.
      export ANSIBLE_SSH_EXTRA_ARGS="-o IdentitiesOnly=yes"
      shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

for tool in git ssh ssh-keyscan curl jq; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is missing (apt install $tool | brew install $tool)"
done

# The instance by domain or by its file: dev.cgl.fmnoel.de,
# instances/dev.cgl.fmnoel.de.yml and a path elsewhere all work.
case "$domain" in
  *.yml|*/*)
    [ -f "$domain" ] || die "no such file: $domain"
    instance="$(cd "$(dirname "$domain")" && pwd)/$(basename "$domain")"
    domain="$(basename "$domain" .yml)"
    ;;
  *)
    instance="$here/instances/$domain.yml"
    [ -f "$instance" ] || die "no instance file for $domain: instances/$domain.yml" \
      "instances: $(cd "$here/instances" && ls *.yml 2>/dev/null | sed 's/\.yml$//' | tr '\n' ' ')"
    ;;
esac

# ------------------------------------------------------------ the release

# The newest release on the instance's channel that carries an artifact, from
# the app's release index. A release sorts after its own prereleases.
if [ -z "$ref" ]; then
  channel="$(instance_value release_channel)"
  case "$channel" in
    stable|prerelease) ;;
    *) die "instances/$domain.yml: release_channel must be stable or prerelease" ;;
  esac
  index="https://github.com/$app_repo/releases/download/schemaf-index/releases.json"
  # The download URL is cached for minutes; a query string reads it fresh.
  version="$(curl -fsSL -H "Cache-Control: no-cache" "$index?t=$(date +%s)" | jq -r --arg ch "$channel" '
      .[] | select($ch == "prerelease" or (.version | contains("-") | not)) | .version' \
    | awk '{ k = $0; if (index(k, "-")) sub(/-/, ".a.", k); else k = k ".z"; print k "\t" $0 }' \
    | sort -V | tail -1 | cut -f2)"
  [ -n "$version" ] || die "no release on the $channel channel in $index"
  ref="v$version"
fi
echo ">> chatgamelab $ref"

checkout="$here/.cache/chatgamelab-$ref"
if [ ! -d "$checkout" ]; then
  mkdir -p "$here/.cache"
  git clone --quiet --depth 1 --branch "$ref" "https://github.com/$app_repo.git" "$checkout"
fi

# ------------------------------------------------------------ the host key

# ansible checks host keys strictly; trust on first use happens here, with the
# fingerprints shown for checking against the provider's console.
mkdir -p ~/.ssh
touch ~/.ssh/known_hosts
if ! ssh-keygen -F "$domain" >/dev/null 2>&1; then
  echo ">> $domain is not in ~/.ssh/known_hosts yet. Its key fingerprints:"
  echo
  ssh-keyscan "$domain" 2>/dev/null | ssh-keygen -lf - | sed 's/^/     /'
  echo
  printf 'Trust and record this host key? [y/N] '
  read -r confirm
  case "$confirm" in
    y|Y) ssh-keyscan -H "$domain" 2>/dev/null >> ~/.ssh/known_hosts ;;
    *) die "Aborted. Check the fingerprint with the provider, then run again." ;;
  esac
fi

# ------------------------------------------------------------ the site password

# From the keychain; asked for (and saved there) on the first run or with
# --basic-auth. setup.sh reads it from a file only this user can read.
basic_auth_user="$(instance_value basic_auth_user)"
keychain_item="chatgamelab basic auth $domain"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"
if [ -n "$basic_auth_user" ]; then
  password=""
  [ -n "$new_password" ] || password="$(security find-generic-password -s "$keychain_item" -a "$basic_auth_user" -w 2>/dev/null || true)"
  if [ -z "$password" ]; then
    # security asks for the password (twice) and stores it; read it back.
    echo ">> the site password for $domain (user $basic_auth_user), kept in the keychain as \"$keychain_item\":" >&2
    security add-generic-password -U -s "$keychain_item" -a "$basic_auth_user" -w \
      || die "the password was not saved"
    password="$(security find-generic-password -s "$keychain_item" -a "$basic_auth_user" -w)"
    [ -n "$password" ] || die "an empty password protects nothing"
  fi
  printf '%s' "$password" > "$work/basic-auth"
  pass+=(--basic-auth-file "$work/basic-auth")
fi

# ------------------------------------------------------------ the setup

"$checkout/deploy/setup.sh" "$instance" ${pass[@]+"${pass[@]}"}
