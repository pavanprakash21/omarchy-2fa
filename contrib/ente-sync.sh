#!/usr/bin/env bash
# Refresh the OTPClient database (and therefore the 2FA bar widget) from Ente
# Auth, which is the source of truth when you sync across phone and desktop.
#
# Run it deliberately after adding or removing a token in Ente. It is not a
# daemon and is not meant to be one: a background job holding your whole 2FA
# vault open on a timer is a worse trade than typing one command occasionally.
#
# The one real hazard here is Ente's export: it writes every secret in
# PLAINTEXT. So this script points Ente's export directory at a tmpfs
# (RAM-backed) staging dir, mode 0700, and shreds it on the way out --
# including if you Ctrl-C halfway through. Nothing unencrypted touches the SSD.
#
# Requires: ente CLI (AUR: ente-cli-bin), configured once with
#   ente account add          # choose "auth" as the app
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
umask 077

QUIET=0
for arg in "$@"; do
  case "$arg" in
    --quiet) QUIET=1 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }

# A scheduled run that fails silently is worse than no scheduled run: the
# vault quietly goes stale and the widget serves codes for tokens you have
# since changed. So when nobody is watching (--quiet, i.e. the systemd
# timer), surface failures on the desktop instead of only in the journal.
notify_failure() {
  [ "$QUIET" -eq 1 ] || return 0
  if command -v omarchy-notification-send >/dev/null; then
    omarchy-notification-send "2FA sync failed" "$1" -u critical 2>/dev/null || true
  elif command -v notify-send >/dev/null; then
    notify-send -u critical "2FA sync failed" "$1" 2>/dev/null || true
  fi
}

die() { printf '%s\n' "$*" >&2; notify_failure "$*"; exit 1; }

command -v ente >/dev/null || die "ente CLI not found. Install it with: yay -S ente-cli-bin"
command -v otpclient-cli >/dev/null || die "otpclient-cli not found. Install it with: yay -S otpclient"

# /dev/shm is RAM. If it is somehow missing, stop rather than silently falling
# back to disk -- writing 2FA secrets to an SSD is the thing this avoids.
[ -d /dev/shm ] || die "/dev/shm not available; refusing to stage plaintext secrets on disk"

STAGE="$(mktemp -d /dev/shm/ente-sync.XXXXXX)"
cleanup() {
  # shred each file, then drop the dir. Runs on success, failure and Ctrl-C.
  if [ -d "$STAGE" ]; then
    find "$STAGE" -type f -exec shred -u {} + 2>/dev/null || true
    rm -rf "$STAGE"
  fi
}
trap cleanup EXIT INT TERM

EMAIL="${ENTE_EMAIL:-}"
if [ -z "$EMAIL" ]; then
  EMAIL="$(ente account list 2>/dev/null | grep -oE '[[:alnum:]._%+-]+@[[:alnum:].-]+' | head -1 || true)"
fi
[ -n "$EMAIL" ] || die "Could not determine your Ente account. Set ENTE_EMAIL=you@example.com and retry."

say "Exporting from Ente into RAM ($STAGE)..."
ente account update --app auth --email "$EMAIL" --dir "$STAGE" >/dev/null
ente export >/dev/null

# Ente decides its own filename, so take whatever landed and verify it is
# actually a list of otpauth:// URIs before handing it to the importer.
EXPORTED="$(find "$STAGE" -type f -size +0 | head -1 || true)"
[ -n "$EXPORTED" ] || die "Ente produced no export file. Check: ente account list"

grep -q '^otpauth://' "$EXPORTED" || die "Export does not look like otpauth:// URIs; refusing to import"
COUNT="$(grep -c '^otpauth://' "$EXPORTED")"
say "Found $COUNT entries. Importing into OTPClient..."

# otpclient-cli reports duplicate counts and skips them, so re-running this is
# safe and idempotent for tokens that already exist.
if [ "$QUIET" -eq 1 ]; then
  otpclient-cli --import --type freeotpplus_plain --file "$EXPORTED" >/dev/null \
    || die "otpclient-cli import failed (is the OTPClient GUI open, or the keyring locked?)"
else
  otpclient-cli --import --type freeotpplus_plain --file "$EXPORTED"
fi

say "Done. Staging dir shredded."
