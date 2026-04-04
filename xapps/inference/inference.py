"""
xapp-inference — xapps/inference/inference.py
==============================================
Polls the Redis Stream `xapp:messages` for entries with status=0
(encrypted input ready), runs the FHE server-side inference, writes the
encrypted result back, and advances the entry to status=1.

The split-key design mirrors the original xapp_inference.py:
  - xapp-kpi generates and holds the client key; it sent serialized eval keys
    embedded inside the encrypted_input payload (concrete-ml ≥ 1.x includes
    the eval key as part of quantize_encrypt_serialize).
  - xapp-inference only needs the server.zip and the evaluation keys.

In concrete-ml the evaluation keys are regenerated from the client key on
every fresh client instance, but for a single-process deployment they are
stable.  Here we load a FHEModelClient solely to generate the eval keys once
at startup (same pattern as the original xapp_inference.py).

Environment variables:
  REDIS_HOST    Redis host                 (default: ric-dbaas)
  REDIS_PORT    Redis port                 (default: 6379)
  MODEL_PATH    FHE model directory        (default: /tmp/fhe_model)
  STREAM_KEY    Redis stream name          (default: xapp:messages)
  POLL_INTERVAL Seconds between polls      (default: 1)
  KEY_DIR       Shared volume for FHE keys (default: None = in-memory)
"""

import base64
import logging
import os
import sys
import time
from typing import cast

import redis
from concrete.ml.deployment import FHEModelClient, FHEModelServer

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
REDIS_HOST    = os.environ.get("REDIS_HOST",         "ric-dbaas")
REDIS_PORT    = int(os.environ.get("REDIS_PORT",     "6379"))
MODEL_PATH    = os.environ.get("MODEL_PATH",         "/tmp/fhe_model")
STREAM_KEY    = os.environ.get("STREAM_KEY",         "xapp:messages")
POLL_INTERVAL = float(os.environ.get("POLL_INTERVAL","1"))
KEY_DIR       = os.environ.get("KEY_DIR",             None)  # shared volume for FHE keys

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [xapp-inference] %(levelname)s %(message)s",
)
log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def b64enc(b: bytes) -> str:
    return base64.b64encode(b).decode()

def b64dec(s: str | bytes) -> bytes:
    if isinstance(s, bytes):
        s = s.decode()
    return base64.b64decode(s)


def redis_connect() -> redis.Redis:
    while True:
        try:
            r = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=False)
            r.ping()
            log.info("Connected to Redis at %s:%d", REDIS_HOST, REDIS_PORT)
            return r
        except redis.exceptions.ConnectionError as exc:
            log.warning("Redis not ready (%s). Retrying in 3s…", exc)
            time.sleep(3)


# ---------------------------------------------------------------------------
# Main polling loop
# ---------------------------------------------------------------------------

def main() -> None:
    log.info("Loading FHE model from %s", MODEL_PATH)
    try:
        fhe_client = FHEModelClient(MODEL_PATH, key_dir=KEY_DIR)
        eval_keys  = cast(bytes, fhe_client.get_serialized_evaluation_keys())

        fhe_server = FHEModelServer(MODEL_PATH)
        fhe_server.load()
    except Exception as exc:
        log.error("Cannot load FHE model: %s", exc)
        sys.exit(1)

    log.info("FHE server loaded. Eval-key size: %d bytes", len(eval_keys))

    r = redis_connect()

    log.info("Polling stream %s for status=0 entries…", STREAM_KEY)
    while True:
        try:
            entries = r.xrange(STREAM_KEY, count=100)
            processed = 0
            for entry_id, fields in entries:
                status = fields.get(b"status", b"").decode()
                if status != "0":
                    continue

                enc_input_b64 = fields.get(b"encrypted_input", b"")
                if not enc_input_b64:
                    continue

                try:
                    enc_input  = b64dec(enc_input_b64)
                    enc_output = fhe_server.run(enc_input, eval_keys)
                    enc_out_bytes = (
                        b"".join(bytes(x) for x in enc_output)
                        if isinstance(enc_output, tuple)
                        else bytes(enc_output)
                    )

                    # Update entry: delete + re-add with new fields
                    all_fields = dict(fields)
                    all_fields[b"encrypted_prediction_result"] = b64enc(enc_out_bytes).encode()
                    all_fields[b"status"] = b"1"
                    new_fields = {
                        k.decode() if isinstance(k, bytes) else k:
                        v.decode() if isinstance(v, bytes) else v
                        for k, v in all_fields.items()
                    }
                    r.xdel(STREAM_KEY, entry_id)
                    r.xadd(STREAM_KEY, new_fields)

                    log.info("Inference done for entry %s → status=1", entry_id)
                    processed += 1

                except Exception as exc:
                    log.error("Inference error for entry %s: %s", entry_id, exc)

            if processed == 0:
                time.sleep(POLL_INTERVAL)

        except Exception as exc:
            log.error("Stream poll error: %s", exc)
            time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
