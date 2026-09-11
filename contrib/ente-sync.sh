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

die() { printf '%s\n' "$*" >&2; exit 1; }

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

printf 'Exporting from Ente into RAM (%s)...\n' "$STAGE" >&2
ente account update --app auth --email "$EMAIL" --dir "$STAGE" >/dev/null
ente export >/dev/null

# Ente decides its own filename, so take whatever landed and verify it is
# actually a list of otpauth:// URIs before handing it to the importer.
EXPORTED="$(find "$STAGE" -type f -size +0 | head -1 || true)"
[ -n "$EXPORTED" ] || die "Ente produced no export file. Check: ente account list"

grep -q '^otpauth://' "$EXPORTED" || die "Export does not look like otpauth:// URIs; refusing to import"
COUNT="$(grep -c '^otpauth://' "$EXPORTED")"
printf 'Found %s entries. Importing into OTPClient...\n' "$COUNT" >&2

# otpclient-cli reports duplicate counts and skips them, so re-running this is
# safe and idempotent for tokens that already exist.
otpclient-cli --import --type freeotpplus_plain --file "$EXPORTED"

printf 'Done. Staging dir shredded.\n' >&2
