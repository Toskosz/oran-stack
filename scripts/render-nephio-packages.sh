#!/usr/bin/env bash
# =============================================================================
# render-nephio-packages.sh
# Render Helm charts into kpt blueprint packages under packages/blueprints/.
#
# Usage (from repo root):
#   ./scripts/render-nephio-packages.sh
#   ./scripts/render-nephio-packages.sh --values packages/values/lab-defaults.yaml
#
# Prerequisites: helm >= 3.12
# After chart edits, re-run this script and commit the updated packages.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALUES="${ROOT}/packages/values/lab-defaults.yaml"
OUT="${ROOT}/packages/blueprints"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --values) VALUES="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--values PATH]"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

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

echo "==> Render complete under ${OUT}"
echo "    Hand-maintained packages (ns-and-secrets, mongodb-init, verify-*) are not overwritten."
