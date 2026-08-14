#!/usr/bin/env bash
# =============================================================================
# collect-ue-diagnostics.sh
# Structured srsUE attach evidence. Never TCP-probes ZMQ (that deadlocks IQ).
#
# Usage (from repo root, with kubeconfig):
#   ./scripts/collect-ue-diagnostics.sh
#   ./scripts/collect-ue-diagnostics.sh --no-file
#   KUBECONFIG=/path/to/kubeconfig ./scripts/collect-ue-diagnostics.sh -o /tmp/ue.txt
#
# MongoDB subscriber count is included (needs exec into 5g-core/mongodb-0).
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAN_NS="${RAN_NS:-ran}"
CORE_NS="${CORE_NS:-5g-core}"
UE_IMSI="${UE_IMSI:-001010000000001}"
WRITE_FILE=true
OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-file) WRITE_FILE=false; shift ;;
    -o|--output) OUT="$2"; WRITE_FILE=true; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--no-file] [-o FILE]"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "${KUBECONFIG:-}" && -f "${ROOT}/kubeconfig" ]]; then
  export KUBECONFIG="${ROOT}/kubeconfig"
fi

if $WRITE_FILE && [[ -z "$OUT" ]]; then
  OUT="${ROOT}/docs/UE_ATTACH_CAPTURE-$(date -u +%Y-%m-%dT%H%M%SZ).txt"
fi

kc() { kubectl "$@"; }

section() {
  echo
  echo "======== $* ========"
}

dump() {
  section "timeline"
  echo "--- srsUE wait / attach ---"
  kc logs -n "${RAN_NS}" deployment/ocudu-du -c srsue --tail=500 2>/dev/null \
    | grep -Ei 'waiting for DU ZMQ|DU ZMQ listening|startup banner|utc=|wait=|Attaching|Switching on|starting srsue' \
    || echo "(no timeline matches in srsUE logs)"
  echo "--- DU F1 / scheduler ---"
  kc logs -n "${RAN_NS}" deployment/ocudu-du -c ocudu-du --tail=2000 2>/dev/null \
    | grep -E 'F1 Setup: Procedure completed|Cell scheduling was activated' \
    || echo "(no F1/SCHED completion lines)"

  section "srsUE (tail 500, then filtered)"
  kc logs -n "${RAN_NS}" deployment/ocudu-du -c srsue --tail=500 2>/dev/null || true
  echo "--- srsUE grep PHY|RRC|NAS|PRACH|MIB|SIB|cell|sync|zmq|error ---"
  kc logs -n "${RAN_NS}" deployment/ocudu-du -c srsue --tail=500 2>/dev/null \
    | grep -Ei 'PHY|RRC|NAS|PRACH|MIB|SIB|cell|sync|zmq|error' \
    || echo "(no matches)"

  section "DU (filtered; no F1 JSON)"
  kc logs -n "${RAN_NS}" deployment/ocudu-du -c ocudu-du --tail=4000 2>/dev/null \
    | grep -Ei 'SCHED|zmq|PRACH|Cell scheduling|F1 Setup|Waiting for data' \
    || echo "(no matches)"

  section "CU (NGAP / NAS / Registration / UE)"
  kc logs -n "${RAN_NS}" deployment/ocudu-cu --tail=2000 2>/dev/null \
    | grep -Ei 'NGAP|NAS|Registration|UE' \
    || echo "(no matches)"

  section "AMF (imsi / Registration / gNB-N2)"
  kc logs -n "${CORE_NS}" deployment/amf --tail=2000 2>/dev/null \
    | grep -Ei 'imsi|Registration|gNB-N2' \
    || echo "(no matches)"

  section "ZMQ sockets (read-only; no TCP connect to 2000/2001)"
  kc exec -n "${RAN_NS}" deploy/ocudu-du -c ocudu-du -- sh -c '
    echo "---- ss -tnp 2000/2001 ----"
    ss -tnp 2>/dev/null | grep -E ":2000|:2001" || echo "(no ss matches)"
    echo "---- /proc/net/tcp 07D0/07D1 (2000/2001) ----"
    grep -E ":07D0|:07D1" /proc/net/tcp || true
  ' 2>/dev/null || echo "(exec failed)"

  section "config ue.conf"
  kc exec -n "${RAN_NS}" deploy/ocudu-du -c srsue -- cat /mnt/srsran/configs/ue.conf 2>/dev/null || echo "(exec failed)"

  section "config du.yml ru_sdr / cell_cfg"
  kc exec -n "${RAN_NS}" deploy/ocudu-du -c ocudu-du -- sh -c '
    awk "
      /^ru_sdr:/ {p=1}
      /^cell_cfg:/ {p=1}
      /^[a-z]/ && !/^ru_sdr:/ && !/^cell_cfg:/ {p=0}
      p
    " /mnt/ocudu/configs/du.yml
  ' 2>/dev/null || echo "(exec failed)"

  section "subscriber MongoDB"
  echo "IMSI=${UE_IMSI}"
  kc exec -n "${CORE_NS}" mongodb-0 -c mongodb -- \
    mongosh "mongodb://localhost:27017/open5gs?directConnection=true" --quiet --eval \
    "db.subscribers.countDocuments({imsi:\"${UE_IMSI}\"})" \
    2>/dev/null || echo "(mongodb exec failed — run this with a kubeconfig that can exec in ${CORE_NS})"

  section "images"
  kc get pod -n "${RAN_NS}" -l app=ocudu-du -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .status.containerStatuses[*]}{.name}{" "}{.image}{" "}{.imageID}{"\n"}{end}{end}' 2>/dev/null || true
  echo
  kc get deploy -n "${RAN_NS}" ocudu-du ocudu-cu -o wide 2>/dev/null || true

  section "pcap emptyDir (empty files mean no RRC/NAS captured)"
  kc exec -n "${RAN_NS}" deploy/ocudu-du -c srsue -- sh -c 'ls -l /mnt/srsran/logs 2>/dev/null || true' 2>/dev/null || true
}

BODY="$(dump)"
printf '%s\n' "$BODY"

if $WRITE_FILE; then
  printf '%s\n' "$BODY" > "$OUT"
  echo "Wrote ${OUT}" >&2
fi
