#!/bin/bash
set -e
TARGET_DIR="/var/www/html"
if [ -z "$(ls -A $TARGET_DIR)" ]; then
    echo "-> Web directory is leeg. Kopiëren van de standaard Plongo-site..."
    cp -r /usr/src/default-site/* $TARGET_DIR
fi
exec "$@"
