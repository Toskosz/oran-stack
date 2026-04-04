#!/bin/sh
# Extract the FHE client model (client.zip) into /tmp/fhe_model before starting.
# The /model volume is read-only, so we extract to a writable tmpfs location.
set -e

MODEL_DIR="${MODEL_PATH:-/tmp/fhe_model}"
CLIENT_ZIP="/model/client.zip"

if [ ! -d "$MODEL_DIR" ]; then
    echo "[xapp-kpi] Extracting $CLIENT_ZIP → $MODEL_DIR"
    mkdir -p "$MODEL_DIR"
    unzip -q "$CLIENT_ZIP" -d "$MODEL_DIR"
    echo "[xapp-kpi] Extraction complete. Contents:"
    ls "$MODEL_DIR"
else
    echo "[xapp-kpi] FHE model directory already exists at $MODEL_DIR"
fi

exec "$@"
