#!/bin/sh
# Extract both server.zip and client.zip into /tmp/fhe_model before starting.
# inference.py uses FHEModelServer (from server.zip) for inference and
# FHEModelClient (from client.zip) to generate evaluation keys.
# The /model volume is read-only, so we extract to a writable tmpfs location.
set -e

MODEL_DIR="${MODEL_PATH:-/tmp/fhe_model}"
SERVER_ZIP="/model/server.zip"
CLIENT_ZIP="/model/client.zip"

if [ ! -d "$MODEL_DIR" ]; then
    echo "[xapp-inference] Extracting model zips → $MODEL_DIR"
    mkdir -p "$MODEL_DIR"
    unzip -q "$SERVER_ZIP" -d "$MODEL_DIR"
    # client.zip may contain overlapping files; allow overwrite (-o)
    unzip -q -o "$CLIENT_ZIP" -d "$MODEL_DIR"
    echo "[xapp-inference] Extraction complete. Contents:"
    ls "$MODEL_DIR"
else
    echo "[xapp-inference] FHE model directory already exists at $MODEL_DIR"
fi

exec "$@"
