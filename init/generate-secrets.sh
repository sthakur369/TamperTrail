#!/bin/sh
set -e
PASSWORD_FILE="/secrets/db_password"
if [ -f "$PASSWORD_FILE" ]; then
  echo "[init] DB password already exists — skipping."
else
  echo "[init] First boot — generating unique DB password..."
  DB_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
  umask 077
  mkdir -p "$(dirname "$PASSWORD_FILE")"
  printf '%s' "$DB_PASSWORD" > "$PASSWORD_FILE"
  chmod 644 "$PASSWORD_FILE"
  echo "[init] DB password generated and saved."
fi