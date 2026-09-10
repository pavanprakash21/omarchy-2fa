#!/usr/bin/env bash
# Stands in for: otpclient-cli --show -i <issuer> -a <account> -m --output=json
# Field names match upstream src/cli/get-data.c's show_token() -- see Cli.js.
cat <<'JSON'
{"type": "TOTP", "account": "pavan@smaply.com", "issuer": "GitHub", "current": "482913", "validity_seconds": 21, "next": "118204"}
JSON
exit 0
