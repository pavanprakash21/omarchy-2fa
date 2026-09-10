#!/usr/bin/env bash
# Stands in for: otpclient-cli --list --output=json
# Field names (issuer, account, group, type) match upstream
# src/cli/get-data.c's list_all_acc_iss() -- see Cli.js for the citation.
cat <<'JSON'
[
  {"issuer": "GitHub", "account": "pavan@smaply.com", "group": "Work", "type": "TOTP"},
  {"issuer": "AWS", "account": "root", "group": "", "type": "TOTP"},
  {"issuer": "Steam", "account": "pavan", "group": "Personal", "type": "HOTP"}
]
JSON
exit 0
