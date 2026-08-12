#!/usr/bin/env bash
# =============================================================================
# render-nephio-packages.sh
# Render Helm charts into kpt blueprint packages under packages/blueprints/.
#
# Usage (from repo root):
#   ./scripts/render-nephio-packages.sh
#   ./scripts/render-nephio-packages.sh --values packages/values/lab-defaults.yaml
#   ./scripts/render-nephio-packages.sh --check
#
# Prerequisites: helm >= 3.12
# After chart edits, re-run this script and commit the updated packages.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALUES="${ROOT}/packages/values/lab-defaults.yaml"
COMMITTED_OUT="${ROOT}/packages/blueprints"
OUT="${COMMITTED_OUT}"
CHECK=false
TEMP_OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --values) VALUES="$2"; shift 2 ;;
    --check) CHECK=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--values PATH] [--check]"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if $CHECK; then
  TEMP_OUT="$(mktemp -d)"
  OUT="$TEMP_OUT"
  trap 'rm -rf "$TEMP_OUT"' EXIT
fi

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required" >&2
  exit 1
fi

write_kptfile() {
  local dir="$1"
  local name="$2"
  local desc="$3"
  cat > "${dir}/Kptfile" <<EOF
apiVersion: kpt.dev/v1
kind: Kptfile
metadata:
  name: ${name}
  annotations:
    config.kubernetes.io/local-config: "true"
info:
  description: ${desc}
EOF
}

render_shared_settings() {
  mkdir -p "${OUT}/ns-and-secrets"
  python3 - "$VALUES" "${ROOT}/ansible/inventories/group_vars/all/vars.yml" \
    "${OUT}/ns-and-secrets/settings.yaml" <<'PY'
import sys
from pathlib import Path

import yaml

values_path, ansible_path, output_path = map(Path, sys.argv[1:])
values = yaml.safe_load(values_path.read_text())
ansible = yaml.safe_load(ansible_path.read_text())

errors = []

def compare(label, left, right):
    if str(left) != str(right):
        errors.append(f"{label}: lab-defaults={left!r}, legacy={right!r}")

for key in ("mcc", "mnc", "tac"):
    compare(f"plmn.{key}", values["plmn"][key], ansible["plmn"][key])

compare("xapp.e2NodeId", values["xapp"]["e2NodeId"], ansible["xapp"]["e2_node_id"])

key_map = {
    "nadName": "nad_name",
    "amfIP": "amf_ip",
    "cuIP": "cu_ip",
    "duIP": "du_ip",
    "e2termIP": "e2term_ip",
}
for network, configured in values["secondaryNetworks"].items():
    legacy = ansible["secondary_networks"][network]
    for key, value in configured.items():
        compare(f"secondaryNetworks.{network}.{key}", value, legacy[key_map[key]])

image_suffixes = {
    "core": "oran-5gcore",
    "webui": "oran-webui",
    "ocudu": "oran-ocudu",
    "srsue": "oran-srsue",
}
for name, suffix in image_suffixes.items():
    compare(
        f"images.{name}.repository",
        values["images"][name]["repository"],
        f'{ansible["dockerhub_username"]}/{suffix}',
    )
    compare(
        f"images.{name}.tag",
        values["images"][name]["tag"],
        ansible["images"][name]["tag"],
    )
compare(
    "image.repository",
    values["image"]["repository"],
    f'{ansible["dockerhub_username"]}/oran-xapps',
)
compare("image.tag", values["image"]["tag"], ansible["images"]["xapps"]["tag"])

if errors:
    raise SystemExit("Nephio/legacy configuration drift:\n- " + "\n- ".join(errors))

data = {
    "E2_NODE_ID": str(values["xapp"]["e2NodeId"]),
    "UE_IMSI": str(values["ue"]["imsi"]),
    "UE_K": str(values["ue"]["k"]),
    "UE_OPC": str(values["ue"]["opc"]),
    "UE_APN": str(values["ue"]["apn"]),
}
documents = []
for namespace in ("oran-verify", "5g-core"):
    documents.append({
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": "oran-lab-settings",
            "namespace": namespace,
            "labels": {"oran.stack/managed-by": "nephio"},
        },
        "data": data,
    })
Path(output_path).write_text(yaml.safe_dump_all(documents, sort_keys=False))
PY
}

render_chart() {
  local name="$1"
  local chart="$2"
  local release="$3"
  local namespace="$4"
  shift 4
  local extra_args=("$@")

  local dest="${OUT}/${name}"
  mkdir -p "${dest}"
  echo "==> Rendering ${name} from ${chart}"

  # Pin .Values.namespace after --values so it wins over any shared file.
  # helm --namespace only sets .Release.Namespace; these charts use
  # .Values.namespace, so a leaked top-level namespace: in lab-defaults
  # would otherwise rewrite every package.
  helm template "${release}" "${ROOT}/${chart}" \
    --namespace "${namespace}" \
    --values "${VALUES}" \
    "${extra_args[@]}" \
    --set "namespace=${namespace}" \
    > "${dest}/resources.yaml"

  # Strip helm-managed labels that confuse Config Sync ownership if re-applied
  # via GitOps (keep app labels intact).
  if command -v sed >/dev/null 2>&1; then
    sed -i \
      -e '/app.kubernetes.io\/managed-by: Helm/d' \
      -e '/meta.helm.sh\/release-name:/d' \
      -e '/meta.helm.sh\/release-namespace:/d' \
      "${dest}/resources.yaml" || true
  fi
}

# --- Helm-backed NF packages -------------------------------------------------
render_chart "5g-core" "helm/5g-core" "5g-core" "5g-core"
write_kptfile "${OUT}/5g-core" "5g-core" \
  "Open5GS 5G SA core (NRF AMF SMF UPF + MongoDB + WebUI). Multus N2 AMF IP via setters in lab-defaults."

render_chart "near-rt-ric" "helm/near-rt-ric" "near-rt-ric" "near-rt-ric"
write_kptfile "${OUT}/near-rt-ric" "near-rt-ric" \
  "O-RAN SC Near-RT RIC platform (e2term e2mgr rtmgr submgr appmgr a1mediator dbaas)."

render_chart "ran" "helm/ran" "ran" "ran"
write_kptfile "${OUT}/ran" "ran" \
  "OCUDU CU/DU plus srsUE ZMQ sidecar (deployUE). Multus n2/f1c/e2 static IPs."

# xApp: merge simple-mon values file
render_chart "xapp-simple-mon" "helm/xapps/xapp" "r4-simple-mon" "ricxapp" \
  --values "${ROOT}/helm/xapps/xapp/values/simple-mon.yaml"
write_kptfile "${OUT}/xapp-simple-mon" "xapp-simple-mon" \
  "simple-mon KPM xApp (E2SM-KPM). e2NodeId must match e2mgr ranName."

# Monitoring needs the vendored kube-prometheus-stack dependency
if [[ ! -f "${ROOT}/helm/monitoring/charts/kube-prometheus-stack-59.1.0.tgz" ]] \
   && [[ ! -d "${ROOT}/helm/monitoring/charts/kube-prometheus-stack" ]]; then
  echo "==> Fetching monitoring chart dependencies"
  helm dependency update "${ROOT}/helm/monitoring"
fi
render_chart "monitoring" "helm/monitoring" "monitoring" "monitoring"
write_kptfile "${OUT}/monitoring" "monitoring" \
  "Prometheus + Grafana (kube-prometheus-stack) and O-RAN ServiceMonitors."

render_shared_settings

if $CHECK; then
  status=0
  for package in 5g-core near-rt-ric ran xapp-simple-mon monitoring; do
    diff -ru "${COMMITTED_OUT}/${package}" "${OUT}/${package}" || status=1
  done
  diff -u "${COMMITTED_OUT}/ns-and-secrets/settings.yaml" \
    "${OUT}/ns-and-secrets/settings.yaml" || status=1
  if (( status != 0 )); then
    echo "ERROR: Nephio blueprints are stale; run $0" >&2
    exit 1
  fi
  echo "==> Nephio render and configuration parity OK"
  exit 0
fi

echo "==> Render complete under ${OUT}"
echo "    Shared settings were synchronized from ${VALUES}."
echo "    Other hand-maintained package resources are not overwritten."
