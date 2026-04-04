# Blockers — Pre-Flight Issues

Issues that will prevent a successful first `docker compose up` of the xApp
pipeline. All items are in the `oran-stack/` repo. The `oai-anomaly-detection`
repo requires no changes.

---

## B-1 — `go.sum` missing from `xapps/rc/`

**File**: `xapps/rc/go.mod` / `xapps/rc/Dockerfile`

The Dockerfile runs `go mod download` during the build stage. Go modules
require a `go.sum` lockfile alongside `go.mod`. Without it the build fails:

```
verifying github.com/go-redis/redis/v8@v8.11.5: checksum mismatch
```

**Fix**: Run `go mod tidy` inside `xapps/rc/` and commit the generated `go.sum`.

---

## B-2 — `concrete-ml==1.5.0` incompatible with Python 3.11

**Files**: `xapps/kpi/Dockerfile`, `xapps/inference/Dockerfile`

Both Dockerfiles use `python:3.11-slim`. PyPI metadata for `concrete-ml==1.5.0`
declares `requires_python: "<3.11,>=3.8.1"`. pip will refuse to install it:

```
ERROR: Package 'concrete-ml' requires a different Python: 3.11.x not in '<3.11,>=3.8.1'
```

Both image builds fail entirely.

**Fix**: Change base image to `python:3.10-slim` in both Dockerfiles.

---

## B-3 — ADS sidecars cannot resolve `xapp-kpi` by hostname

**File**: `docker-compose.xapps.yml` (both `ads-slice1` and `ads-slice2`)

Both ADS containers use `network_mode: service:5g-core-upf[2]`, which means
they inherit the UPF container's network namespace and have no independent
network interface. Docker's embedded DNS only resolves service names within
the same Compose project's networks. `xapp-kpi` lives on `ric-network`
(172.22.x.x) — a different bridge. The name `xapp-kpi` will not resolve from
inside the UPF namespace and `ads.py` will loop forever on connection attempts.

**Fix**: Change `KPI_HOST: "xapp-kpi"` → `KPI_HOST: "172.22.0.220"` in both
ADS service `environment:` blocks.

---

## B-4 — Inverted `depends_on` on `xapp-kpi`

**File**: `docker-compose.xapps.yml`

`xapp-kpi` declares `depends_on: - xapp-inference`. This is backwards: the
two services are peers connected only via Redis and neither needs to wait for
the other. In practice it means `xapp-kpi` (the TCP server that ADS connects
to) will not start until after `xapp-inference` has started, delaying the
ADS connection window unnecessarily. If `xapp-inference` fails to build (B-2),
`xapp-kpi` never starts at all.

**Fix**: Remove `depends_on: - xapp-inference` from the `xapp-kpi` service.

---

## B-5 — FHE key mismatch: no shared key directory between `xapp-kpi` and `xapp-inference`

**Files**: `docker-compose.xapps.yml`, `xapps/kpi/kpi.py`, `xapps/inference/inference.py`

`FHEModelClient(path)` called without a `key_dir` argument generates **new
random keys on every startup**. `xapp-kpi` encrypts inputs with key set A.
`xapp-inference` instantiates its own `FHEModelClient` and generates eval keys
from key set B. The two key sets do not match — decryption in `xapp-kpi` will
produce garbage or raise an exception for every inference result.

```python
# current (broken) — fresh keys per container restart
FHEModelClient(MODEL_PATH)

# required — deterministic keys from a shared persistent volume
FHEModelClient(MODEL_PATH, key_dir="/keys")
```

**Fix**:
1. Add a named volume `xapp-keys` to `docker-compose.xapps.yml`.
2. Mount it at `/keys` in both `xapp-kpi` and `xapp-inference`.
3. Pass `key_dir="/keys"` to `FHEModelClient(...)` in both `kpi.py` and
   `inference.py`.

---

## B-6 — `MODEL_PATH` default in `kpi.py` diverges from Dockerfile `ENV`

**Files**: `xapps/kpi/kpi.py` (line 54), `xapps/kpi/Dockerfile`

The Dockerfile sets `ENV MODEL_PATH=/tmp/fhe_model` and `entrypoint.sh`
extracts `client.zip` there. But the Python fallback default is:

```python
MODEL_PATH = os.environ.get("MODEL_PATH", "/model/fhe_model")
```

If the env var is ever unset or cleared (e.g. `docker run` without `-e`), the
process tries to load from `/model/fhe_model` which does not exist, and exits.

**Fix**: Align the Python default with the Dockerfile:

```python
MODEL_PATH = os.environ.get("MODEL_PATH", "/tmp/fhe_model")
```

---

## B-7 — `smf2` and `upf2` not in `entrypoint.sh` config list

**File**: `entrypoint.sh` (repo root, line 19)

The entrypoint processes a hardcoded list of NF config files:

```bash
declare -a configs=("nrf" "scp" "sepp1" "amf" "smf" "upf" "ausf" "udm" "pcf" "nssf" "bsf" "udr" "mme" "sgwc" "sgwu" "hss" "pcrf")
```

`smf2` and `upf2` are new files added for multi-slice support (WP1). They are
not in this list, so `envsubst` is never run on them. The `${SMF2_SUBNET4}`
and `${SMF2_SUBNET6}` tokens in `configs/smf2.yaml` and `configs/upf2.yaml`
remain as literal strings, and Open5GS rejects the YAML on startup.

**Fix**: Add `"smf2"` and `"upf2"` to the `configs` array in `entrypoint.sh`.

---

## B-8 — `pandas==2.2.2` conflicts with `concrete-ml==1.5.0`

**File**: `xapps/kpi/Dockerfile`

`concrete-ml==1.5.0` pins `pandas==2.0.3` as a dependency. The Dockerfile
explicitly installs `pandas==2.2.2`. pip will abort the build with a
dependency conflict error.

**Fix**: Remove the explicit `pandas==2.2.2` line from `xapps/kpi/Dockerfile`
and let concrete-ml pull in its required version transitively.

---

## B-9 — Unused `5g-core-network: external` crashes standalone xApp bring-up

**File**: `docker-compose.xapps.yml`

```yaml
5g-core-network:
  external: true
  name: 5g-core-network
```

No xApp service (`xapp-kpi`, `xapp-inference`, `xapp-rc`) is attached to this
network. The declaration serves no purpose but causes `docker compose up` to
fail with:

```
network 5g-core-network declared as external, but could not be found
```

if the 5G core is not already running (e.g. during isolated xApp development
or CI).

**Fix**: Remove the `5g-core-network` stanza from `docker-compose.xapps.yml`.
