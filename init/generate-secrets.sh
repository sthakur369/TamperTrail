#!/bin/sh
# Runs once on first boot to generate a unique DB password.
# Stored in a shared volume so both Postgres and the server can read it.

PASSWORD_FILE="/secrets/db_password"

if [ -f "$PASSWORD_FILE" ]; then
    echo "[init] DB password already exists — skipping."
else
    echo "[init] First boot — generating unique DB password..."
    # Generate a 32-char URL-safe random password
    DB_PASSWORD=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 32)
    echo -n "$DB_PASSWORD" > "$PASSWORD_FILE"
    chmod 644 "$PASSWORD_FILE"
    echo "[init] DB password generated and saved."
fi
