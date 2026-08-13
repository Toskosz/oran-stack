#!/usr/bin/env bash
# Deploy the O-RAN network functions through Porch and Config Sync.
#
# Normal path:
#   PackageVariants create Drafts; this script proposes and approves them in
#   dependency order, waiting for each package on the workload cluster.
#
# Recovery path:
#   A rebuilt cluster can rediscover old Published Porch revisions while the
#   oran-lab deployment branch contains no manifests. If 5g-core is absent and
#   there are no Drafts, this script pauses PackageVariant reconciliation,
#   clones fresh revisions from the configured upstream blueprints, publishes
#   them, then reapplies the variants. Git history is retained.
#
# Usage:
#   ./packages/examples/deploy-oran-lab.sh
#   ./packages/examples/deploy-oran-lab.sh --force-fresh
#
# Environment:
#   KUBECONFIG_MGMT  management kubeconfig (default: ./kubeconfig-mgmt)
#   KUBECONFIG_WL    workload kubeconfig (default: ./kubeconfig)
#   PACKAGE_TIMEOUT  seconds to wait per package (default: 900)
#   XAPP_LIFECYCLE_RETRIES attempts for route lifecycle stages (default: 36)
#   XAPP_LIFECYCLE_DELAY seconds between route lifecycle checks (default: 5)
#   XAPP_INDICATION_RETRIES attempts for the KPM indication gate (default: 10)
#   XAPP_INDICATION_DELAY seconds between KPM indication checks (default: 10)
#   E2_RECOVERY_ENABLED restart CU/DU once after E2 failure (default: true)
#   UE_ATTACH_REQUIRED fail when UE attach is unconfirmed (default: true)
#   HEARTBEAT_SECS     progress line interval during long waits (default: 30)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KUBECONFIG_MGMT="${KUBECONFIG_MGMT:-$ROOT/kubeconfig-mgmt}"
KUBECONFIG_WL="${KUBECONFIG_WL:-${KUBECONFIG:-$ROOT/kubeconfig}}"
PACKAGE_TIMEOUT="${PACKAGE_TIMEOUT:-900}"
HEARTBEAT_SECS="${HEARTBEAT_SECS:-30}"
XAPP_LIFECYCLE_RETRIES="${XAPP_LIFECYCLE_RETRIES:-36}"
XAPP_LIFECYCLE_DELAY="${XAPP_LIFECYCLE_DELAY:-5}"
XAPP_INDICATION_RETRIES="${XAPP_INDICATION_RETRIES:-10}"
XAPP_INDICATION_DELAY="${XAPP_INDICATION_DELAY:-10}"
E2_WAIT_RETRIES="${E2_WAIT_RETRIES:-30}"
E2_WAIT_DELAY="${E2_WAIT_DELAY:-10}"
E2_RECOVERY_ENABLED="${E2_RECOVERY_ENABLED:-true}"
UE_WAIT_RETRIES="${UE_WAIT_RETRIES:-36}"
UE_WAIT_DELAY="${UE_WAIT_DELAY:-10}"
UE_ATTACH_REQUIRED="${UE_ATTACH_REQUIRED:-true}"
VARIANTS="$ROOT/packages/variants/oran-lab-packagevariants.yaml"
PORCH_NAMESPACE="default"
DOWNSTREAM_REPO="oran-lab"
RUN_WORKSPACE="deploy-$(date -u +%Y%m%d%H%M%S)-$$"
FORCE_FRESH=false
VARIANTS_PAUSED=false
LOCK_ACQUIRED=false
DEPLOY_CHANGED=false
LAST_SOURCE_COMMIT=""
EXPECTED_SYNC_COMMIT=""

PACKAGES=(
  ns-and-secrets
  5g-core
  mongodb-init
  near-rt-ric
  ran
  verify-e2
  xapp-simple-mon
  xapp-lifecycle
  verify-ue
  monitoring
)
declare -A UPSTREAM_REPO
declare -A UPSTREAM_PACKAGE
declare -A UPSTREAM_WORKSPACE

usage() {
  cat <<'EOF'
Usage: deploy-oran-lab.sh [--force-fresh]

  --force-fresh  Publish fresh downstream revisions even if workloads exist.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force-fresh) FORCE_FRESH=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

for command in kubectl porchctl awk seq mktemp cp mkdir; do
  command -v "$command" >/dev/null || {
    echo "required command not found: $command" >&2
    exit 1
  }
done
for kubeconfig in "$KUBECONFIG_MGMT" "$KUBECONFIG_WL"; do
  [[ -r "$kubeconfig" ]] || {
    echo "kubeconfig is not readable: $kubeconfig" >&2
    exit 1
  }
done

# Line-buffer stdout/stderr when piped (Ansible/tee) so progress appears promptly.
# Must run before TEMP_ROOT / traps so a re-exec does not leak state.
if [[ "${ORAN_DEPLOY_STDBUF:-}" != "1" && ! -t 1 ]] && \
   command -v stdbuf >/dev/null 2>&1; then
  export ORAN_DEPLOY_STDBUF=1
  reexec_args=()
  $FORCE_FRESH && reexec_args+=(--force-fresh)
  exec stdbuf -oL -eL bash "$0" "${reexec_args[@]}"
fi

TEMP_ROOT="$(mktemp -d)"

kmgmt() {
  kubectl --kubeconfig="$KUBECONFIG_MGMT" "$@"
}

kwl() {
  kubectl --kubeconfig="$KUBECONFIG_WL" "$@"
}

porch() {
  porchctl "$@" --kubeconfig="$KUBECONFIG_MGMT"
}

# Progress goes to stderr so command substitutions (e.g. wait_for_revision)
# still capture only the PackageRevision name on stdout.
heartbeat() {
  local description="$1" deadline="$2"
  echo "==> still waiting: $description ($((deadline - SECONDS))s left)" >&2
}

dump_job() {
  local job="$1" namespace="$2"
  kwl get job "$job" -n "$namespace" -o wide >&2 || true
  kwl get pods -n "$namespace" -l "job-name=$job" -o wide >&2 || true
  kwl logs -n "$namespace" "job/$job" --tail=80 >&2 || true
}

job_condition() {
  local job="$1" namespace="$2" type="$3"
  kwl get job "$job" -n "$namespace" \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}' \
    2>/dev/null | grep -qx "${type}=True"
}

# Jobs that have Failed=True can never become Complete. Poll both conditions
# so a gate failure returns immediately instead of burning PACKAGE_TIMEOUT.
kwl_wait_job() {
  local description="$1" job="$2" namespace="$3"
  local deadline=$((SECONDS + PACKAGE_TIMEOUT))
  local next_hb=$((SECONDS + HEARTBEAT_SECS))
  echo "==> $description"
  while (( SECONDS < deadline )); do
    if job_condition "$job" "$namespace" Complete; then
      echo "==> $description: ready"
      return 0
    fi
    if job_condition "$job" "$namespace" Failed; then
      echo "ERROR: $description failed" >&2
      dump_job "$job" "$namespace"
      return 1
    fi
    if (( SECONDS >= next_hb )); then
      heartbeat "$description" "$deadline"
      next_hb=$((SECONDS + HEARTBEAT_SECS))
    fi
    sleep 2
  done
  echo "timed out waiting: $description" >&2
  dump_job "$job" "$namespace"
  return 1
}

# Chunk long kubectl waits so the log keeps moving instead of going quiet for
# PACKAGE_TIMEOUT seconds.
kwl_wait_condition() {
  local description="$1"
  shift
  local deadline=$((SECONDS + PACKAGE_TIMEOUT))
  local left chunk
  echo "==> $description"
  while (( SECONDS < deadline )); do
    left=$((deadline - SECONDS))
    chunk=$HEARTBEAT_SECS
    (( left < chunk )) && chunk=$left
    (( chunk < 1 )) && break
    if kwl wait "$@" --timeout="${chunk}s" >/dev/null 2>&1; then
      echo "==> $description: ready"
      return 0
    fi
    heartbeat "$description" "$deadline"
  done
  echo "timed out waiting: $description" >&2
  return 1
}

kwl_rollout_status() {
  local description="$1"
  shift
  local deadline=$((SECONDS + PACKAGE_TIMEOUT))
  local left chunk
  echo "==> $description"
  while (( SECONDS < deadline )); do
    left=$((deadline - SECONDS))
    chunk=$HEARTBEAT_SECS
    (( left < chunk )) && chunk=$left
    (( chunk < 1 )) && break
    if kwl rollout status "$@" --timeout="${chunk}s" >/dev/null 2>&1; then
      echo "==> $description: ready"
      return 0
    fi
    heartbeat "$description" "$deadline"
  done
  echo "timed out waiting: $description" >&2
  return 1
}

restore_variants_on_exit() {
  local rc=$?
  if $VARIANTS_PAUSED; then
    echo "==> Restoring PackageVariants before exit"
    if ! kmgmt apply -f "$VARIANTS" || \
       ! kmgmt wait --for=condition=Ready packagevariant --all \
         -n "$PORCH_NAMESPACE" --timeout=120s; then
      echo "failed to restore Ready PackageVariants" >&2
      rc=1
    fi
  fi
  if $LOCK_ACQUIRED; then
    kmgmt delete configmap oran-stack-nephio-deploy-lock \
      -n "$PORCH_NAMESPACE" --ignore-not-found >/dev/null || true
  fi
  rm -rf "$TEMP_ROOT"
  exit "$rc"
}
trap restore_variants_on_exit EXIT

revision_rows() {
  kmgmt get packagerevisions -n "$PORCH_NAMESPACE" -o jsonpath=\
'{range .items[*]}{.metadata.name}{"\t"}{.spec.repository}{"\t"}{.spec.packageName}{"\t"}{.spec.workspaceName}{"\t"}{.spec.lifecycle}{"\t"}{.spec.revision}{"\n"}{end}'
}

find_revision() {
  local repo="$1" package="$2" lifecycle_re="$3" workspace="${4:-}"
  revision_rows | awk -F '\t' \
    -v repo="$repo" -v package="$package" -v lifecycle_re="$lifecycle_re" -v workspace="$workspace" '
      $2 == repo && $3 == package && $5 ~ lifecycle_re &&
      (workspace == "" || $4 == workspace) && !found {
        found = 1
        name = $1
      }
      END { if (found) print name }
    '
}

find_latest_published() {
  local repo="$1" package="$2"
  revision_rows | awk -F '\t' -v repo="$repo" -v package="$package" '
    $2 == repo && $3 == package && $5 == "Published" {
      revision = $6 + 0
      if (!found || revision > max) {
        found = 1
        max = revision
        name = $1
      }
    }
    END { if (found) print name }
  '
}

variant_target_revision() {
  local package="$1" name lifecycle
  name="$(kmgmt get packagevariant "oran-lab-$package" -n "$PORCH_NAMESPACE" \
    -o jsonpath='{.status.downstreamTargets[0].name}')"
  [[ -n "$name" ]] || return 0
  lifecycle="$(kmgmt get packagerevision "$name" -n "$PORCH_NAMESPACE" \
    -o jsonpath='{.spec.lifecycle}' 2>/dev/null || true)"
  if [[ "$lifecycle" == "Draft" || "$lifecycle" == "Proposed" ]]; then
    printf '%s\n' "$name"
  fi
}

wait_for_revision() {
  local repo="$1" package="$2" lifecycle_re="$3" workspace="${4:-}"
  local deadline=$((SECONDS + PACKAGE_TIMEOUT)) name=""
  local next_hb=$((SECONDS + HEARTBEAT_SECS))
  local description="$repo/$package lifecycle=$lifecycle_re"
  [[ -n "$workspace" ]] && description+=" workspace=$workspace"
  echo "==> Waiting for PackageRevision $description" >&2
  while (( SECONDS < deadline )); do
    name="$(find_revision "$repo" "$package" "$lifecycle_re" "$workspace")"
    [[ -n "$name" ]] && { printf '%s\n' "$name"; return 0; }
    if (( SECONDS >= next_hb )); then
      heartbeat "$description" "$deadline"
      next_hb=$((SECONDS + HEARTBEAT_SECS))
    fi
    sleep 5
  done
  echo "timed out waiting for $description" >&2
  return 1
}

package_present() {
  local package="$1"
  case "$package" in
    ns-and-secrets)
      # workload-gitops also creates namespaces, so this package alone cannot
      # prove that the deployment Git branch contains package manifests. An
      # applied core workload proves the namespace package is already effective.
      package_present 5g-core
      ;;
    5g-core)        kwl get deployment amf -n 5g-core >/dev/null 2>&1 ;;
    mongodb-init)   kwl get job mongodb-init -n 5g-core >/dev/null 2>&1 ;;
    near-rt-ric)    kwl get deployment ric-e2term -n near-rt-ric >/dev/null 2>&1 ;;
    ran)            kwl get deployment ocudu-cu -n ran >/dev/null 2>&1 ;;
    verify-e2)      kwl get job verify-e2 -n oran-verify >/dev/null 2>&1 ;;
    xapp-simple-mon) kwl get deployment r4-simple-mon -n ricxapp >/dev/null 2>&1 ;;
    xapp-lifecycle) kwl get job xapp-lifecycle -n oran-verify >/dev/null 2>&1 ;;
    verify-ue)      kwl get job verify-ue -n oran-verify >/dev/null 2>&1 ;;
    monitoring)     kwl get deployment monitoring-grafana -n monitoring >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

wait_for_object() {
  local kind="$1" name="$2" namespace="$3"
  local deadline=$((SECONDS + PACKAGE_TIMEOUT))
  local next_hb=$((SECONDS + HEARTBEAT_SECS))
  local description="$kind/$name in $namespace"
  echo "==> Waiting for $description"
  until kwl get "$kind" "$name" -n "$namespace" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || {
      echo "timed out waiting for $description" >&2
      return 1
    }
    if (( SECONDS >= next_hb )); then
      heartbeat "$description" "$deadline"
      next_hb=$((SECONDS + HEARTBEAT_SECS))
    fi
    sleep 5
  done
  echo "==> Found $description"
}

wait_for_ran() {
  local deadline=$((SECONDS + PACKAGE_TIMEOUT))
  local terminal=""
  while (( SECONDS < deadline )); do
    echo "==> RAN rollout status"
    kwl get pods -n ran -o wide || true
    kwl get deployment ocudu-cu ocudu-du -n ran \
      -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,AVAILABLE:.status.availableReplicas,DESIRED:.spec.replicas' \
      || true

    terminal="$(kwl get pods -n ran -o jsonpath=\
'{range .items[*]}{range .status.initContainerStatuses[*]}{.state.waiting.reason}{"\n"}{end}{range .status.containerStatuses[*]}{.state.waiting.reason}{"\n"}{end}{end}' \
      2>/dev/null || true)"
    if printf '%s\n' "$terminal" | grep -Eq \
      '^(ImagePullBackOff|ErrImagePull|InvalidImageName|CreateContainerConfigError)$'; then
      echo "ERROR: terminal RAN pod error" >&2
      printf '%s\n' "$terminal" | sort -u >&2
      kwl describe pods -n ran >&2 || true
      return 1
    fi

    if kwl wait --for=condition=Available \
      deployment/ocudu-cu deployment/ocudu-du -n ran --timeout=20s \
      >/dev/null 2>&1; then
      echo "ocudu-cu and ocudu-du are Available"
      return 0
    fi
    sleep 15
  done
  echo "timed out waiting for ocudu-cu and ocudu-du" >&2
  return 1
}

wait_for_prometheus() {
  local deadline=$((SECONDS + PACKAGE_TIMEOUT))
  local statefulset=""
  local next_hb=$((SECONDS + HEARTBEAT_SECS))
  echo "==> Waiting for Prometheus StatefulSet"
  while (( SECONDS < deadline )); do
    statefulset="$(kwl get statefulset -n monitoring \
      -l app.kubernetes.io/name=prometheus -o name 2>/dev/null | awk 'NR == 1')"
    if [[ -n "$statefulset" ]]; then
      kwl_rollout_status "Prometheus $statefulset rollout" \
        "$statefulset" -n monitoring
      return
    fi
    if (( SECONDS >= next_hb )); then
      heartbeat "Prometheus StatefulSet" "$deadline"
      next_hb=$((SECONDS + HEARTBEAT_SECS))
    fi
    sleep 5
  done
  echo "timed out waiting for the Prometheus StatefulSet" >&2
  return 1
}

apply_xapp_lifecycle_settings() {
  kwl create configmap xapp-lifecycle-settings -n oran-verify \
    --from-literal="WAIT_RETRIES=$XAPP_LIFECYCLE_RETRIES" \
    --from-literal="WAIT_DELAY=$XAPP_LIFECYCLE_DELAY" \
    --from-literal="INDICATION_RETRIES=$XAPP_INDICATION_RETRIES" \
    --from-literal="INDICATION_DELAY=$XAPP_INDICATION_DELAY" \
    --dry-run=client -o yaml | kwl apply -f -
}

apply_verification_settings() {
  kwl create configmap oran-verification-settings -n oran-verify \
    --from-literal="E2_WAIT_RETRIES=$E2_WAIT_RETRIES" \
    --from-literal="E2_WAIT_DELAY=$E2_WAIT_DELAY" \
    --from-literal="E2_RECOVERY_ENABLED=$E2_RECOVERY_ENABLED" \
    --from-literal="UE_WAIT_RETRIES=$UE_WAIT_RETRIES" \
    --from-literal="UE_WAIT_DELAY=$UE_WAIT_DELAY" \
    --from-literal="UE_ATTACH_REQUIRED=$UE_ATTACH_REQUIRED" \
    --dry-run=client -o yaml | kwl apply -f -
}

rootsync_commit() {
  local stage="$1"
  kwl get rootsync oran-lab -n config-management-system \
    -o "jsonpath={.status.${stage}.commit}"
}

wait_for_new_source_commit() {
  local deadline=$((SECONDS + PACKAGE_TIMEOUT)) commit=""
  local next_hb=$((SECONDS + HEARTBEAT_SECS))
  echo "==> Waiting for Config Sync to observe a new source commit"
  while (( SECONDS < deadline )); do
    commit="$(rootsync_commit source)"
    if [[ -n "$commit" && "$commit" != "$LAST_SOURCE_COMMIT" ]]; then
      EXPECTED_SYNC_COMMIT="$commit"
      LAST_SOURCE_COMMIT="$commit"
      echo "==> Config Sync observed source commit $commit"
      return 0
    fi
    if (( SECONDS >= next_hb )); then
      heartbeat "Config Sync new source commit" "$deadline"
      next_hb=$((SECONDS + HEARTBEAT_SECS))
    fi
    sleep 5
  done
  echo "timed out waiting for Config Sync to observe a new source commit" >&2
  return 1
}

wait_for_expected_sync() {
  local deadline=$((SECONDS + PACKAGE_TIMEOUT))
  local rendering="" synced=""
  local next_hb=$((SECONDS + HEARTBEAT_SECS))
  echo "==> Waiting for Config Sync to apply $EXPECTED_SYNC_COMMIT"
  while (( SECONDS < deadline )); do
    rendering="$(rootsync_commit rendering)"
    synced="$(rootsync_commit sync)"
    if [[ "$rendering" == "$EXPECTED_SYNC_COMMIT" &&
          "$synced" == "$EXPECTED_SYNC_COMMIT" ]]; then
      echo "==> Config Sync applied commit $EXPECTED_SYNC_COMMIT"
      return 0
    fi
    if (( SECONDS >= next_hb )); then
      echo "==> still waiting: Config Sync apply" \
        "(source rendering=$rendering sync=$synced;" \
        "want $EXPECTED_SYNC_COMMIT; $((deadline - SECONDS))s left)" >&2
      next_hb=$((SECONDS + HEARTBEAT_SECS))
    fi
    sleep 5
  done
  echo "timed out waiting for Config Sync to apply $EXPECTED_SYNC_COMMIT" >&2
  kwl get rootsync oran-lab -n config-management-system -o yaml >&2
  return 1
}

wait_for_package() {
  local package="$1"
  echo "==> Waiting for $package on workload cluster"
  case "$package" in
    ns-and-secrets)
      for ns in 5g-core near-rt-ric ran ricxapp monitoring oran-verify; do
        local deadline=$((SECONDS + PACKAGE_TIMEOUT))
        local next_hb=$((SECONDS + HEARTBEAT_SECS))
        echo "==> Waiting for namespace/$ns"
        until kwl get namespace "$ns" >/dev/null 2>&1; do
          (( SECONDS < deadline )) || {
            echo "timed out waiting for namespace/$ns" >&2
            return 1
          }
          if (( SECONDS >= next_hb )); then
            heartbeat "namespace/$ns" "$deadline"
            next_hb=$((SECONDS + HEARTBEAT_SECS))
          fi
          sleep 5
        done
      done
      apply_xapp_lifecycle_settings
      apply_verification_settings
      ;;
    5g-core)
      wait_for_object statefulset mongodb 5g-core
      ;;
    mongodb-init)
      wait_for_object job mongodb-init 5g-core
      kwl_rollout_status "statefulset/mongodb rollout" \
        statefulset/mongodb -n 5g-core
      kwl_wait_job "job/mongodb-init complete" mongodb-init 5g-core
      wait_for_object deployment amf 5g-core
      kwl_wait_condition "5g-core deployments Available" \
        --for=condition=Available deployment --all -n 5g-core
      ;;
    near-rt-ric)
      wait_for_object deployment ric-e2term near-rt-ric
      kwl_wait_condition "near-rt-ric deployments Available" \
        --for=condition=Available deployment --all -n near-rt-ric
      ;;
    ran)
      wait_for_object deployment ocudu-cu ran
      wait_for_ran
      ;;
    verify-e2)
      wait_for_object job verify-e2 oran-verify
      kwl_wait_job "job/verify-e2 complete" verify-e2 oran-verify
      ;;
    xapp-simple-mon)
      wait_for_object deployment r4-simple-mon ricxapp
      kwl_rollout_status "deployment/r4-simple-mon rollout" \
        deployment/r4-simple-mon -n ricxapp
      ;;
    xapp-lifecycle)
      apply_xapp_lifecycle_settings
      wait_for_object job xapp-lifecycle oran-verify
      kwl_wait_job "job/xapp-lifecycle complete" xapp-lifecycle oran-verify
      ;;
    verify-ue)
      wait_for_object job verify-ue oran-verify
      kwl_wait_job "job/verify-ue complete" verify-ue oran-verify
      ;;
    monitoring)
      wait_for_object deployment monitoring-grafana monitoring
      kwl_rollout_status "deployment/monitoring-grafana rollout" \
        deployment/monitoring-grafana -n monitoring
      wait_for_prometheus
      ;;
  esac
}

pause_variants() {
  $VARIANTS_PAUSED && return 0
  echo "==> Pausing PackageVariants while fresh revisions are published"
  # Mark recovery active before the first mutation so EXIT restoration also
  # runs after a partial patch/delete failure.
  VARIANTS_PAUSED=true
  local variants
  variants="$(kmgmt get packagevariants -n "$PORCH_NAMESPACE" \
    -o name | awk '/packagevariant\/oran-lab-/')"
  if [[ -n "$variants" ]]; then
    while read -r variant; do
      [[ -n "$variant" ]] || continue
      kmgmt patch -n "$PORCH_NAMESPACE" "$variant" --type=merge \
        -p '{"spec":{"deletionPolicy":"orphan"}}'
    done <<<"$variants"
    kmgmt delete -f "$VARIANTS" -n "$PORCH_NAMESPACE" --ignore-not-found
  fi
}

configured_upstream_revision() {
  local package="$1"
  wait_for_revision \
    "${UPSTREAM_REPO[$package]}" \
    "${UPSTREAM_PACKAGE[$package]}" \
    'Published' \
    "${UPSTREAM_WORKSPACE[$package]}"
}

publish_revision() {
  local name="$1" lifecycle
  lifecycle="$(kmgmt get packagerevision "$name" -n "$PORCH_NAMESPACE" \
    -o jsonpath='{.spec.lifecycle}')"
  if [[ "$lifecycle" == "Draft" ]]; then
    porch rpkg propose "$name" -n "$PORCH_NAMESPACE"
    lifecycle="Proposed"
  fi
  if [[ "$lifecycle" == "Proposed" ]]; then
    porch rpkg approve "$name" -n "$PORCH_NAMESPACE"
  fi
  wait_for_revision "$DOWNSTREAM_REPO" \
    "$(kmgmt get packagerevision "$name" -n "$PORCH_NAMESPACE" -o jsonpath='{.spec.packageName}')" \
    'Published' \
    "$(kmgmt get packagerevision "$name" -n "$PORCH_NAMESPACE" -o jsonpath='{.spec.workspaceName}')" \
    >/dev/null
  DEPLOY_CHANGED=true
  wait_for_new_source_commit
}

fresh_revision() {
  local package="$1" upstream downstream name source_dir target_dir lifecycle

  upstream="$(configured_upstream_revision "$package")"
  downstream="$(find_latest_published "$DOWNSTREAM_REPO" "$package")"
  name="$(find_revision "$DOWNSTREAM_REPO" "$package" 'Draft|Proposed')"

  if [[ -n "$name" ]]; then
    echo "==> Reusing existing $package draft $name"
    lifecycle="$(kmgmt get packagerevision "$name" -n "$PORCH_NAMESPACE" \
      -o jsonpath='{.spec.lifecycle}')"
    if [[ "$lifecycle" == "Proposed" ]]; then
      porch rpkg reject "$name" -n "$PORCH_NAMESPACE"
    fi
  elif [[ -n "$downstream" ]]; then
    # clone creates the first cross-repository revision. Once a package already
    # exists, copy its latest revision and replace the draft content with the
    # currently configured upstream blueprint.
    echo "==> Creating fresh $package revision from $downstream (workspace $RUN_WORKSPACE)"
    porch rpkg copy "$downstream" \
      --workspace="$RUN_WORKSPACE" \
      -n "$PORCH_NAMESPACE"
    name="$(wait_for_revision "$DOWNSTREAM_REPO" "$package" 'Draft|Proposed' "$RUN_WORKSPACE")"
  else
    echo "==> Cloning initial $package from $upstream (workspace $RUN_WORKSPACE)"
    porch rpkg clone "$upstream" "$package" \
      --repository="$DOWNSTREAM_REPO" \
      --workspace="$RUN_WORKSPACE" \
      -n "$PORCH_NAMESPACE"
    name="$(wait_for_revision "$DOWNSTREAM_REPO" "$package" 'Draft|Proposed' "$RUN_WORKSPACE")"
  fi

  # Keep the target draft's Porch metadata while replacing its package content
  # with the blueprint in this checkout. This intentionally avoids a stale
  # Porch repository cache during rebuild recovery: the command deploys the
  # exact repository content it was invoked from.
  source_dir="$TEMP_ROOT/$package-source"
  target_dir="$TEMP_ROOT/$package-target"
  mkdir -p "$source_dir"
  cp -a "$ROOT/packages/blueprints/$package/." "$source_dir/"
  porch rpkg pull "$name" "$target_dir" -n "$PORCH_NAMESPACE"
  cp "$target_dir/.KptRevisionMetadata" "$source_dir/.KptRevisionMetadata"
  porch rpkg push "$name" "$source_dir" -n "$PORCH_NAMESPACE"
  publish_revision "$name"
  # Jobs are immutable. Remove prior failed/completed instances after publish
  # so Config Sync can create the fresh gate with the same stable name.
  case "$package" in
    mongodb-init) kwl delete job mongodb-init -n 5g-core --ignore-not-found ;;
    verify-e2) kwl delete job verify-e2 -n oran-verify --ignore-not-found ;;
    xapp-lifecycle) kwl delete job xapp-lifecycle -n oran-verify --ignore-not-found ;;
    verify-ue) kwl delete job verify-ue -n oran-verify --ignore-not-found ;;
  esac
}

echo "==> Checking management and workload clusters"
kmgmt get repository blueprints -n "$PORCH_NAMESPACE" >/dev/null
kmgmt get repository "$DOWNSTREAM_REPO" -n "$PORCH_NAMESPACE" >/dev/null
kwl get nodes >/dev/null
LAST_SOURCE_COMMIT="$(rootsync_commit source)"

if ! kmgmt create configmap oran-stack-nephio-deploy-lock \
  -n "$PORCH_NAMESPACE" \
  --from-literal="holder=$RUN_WORKSPACE" >/dev/null 2>&1; then
  holder="$(kmgmt get configmap oran-stack-nephio-deploy-lock \
    -n "$PORCH_NAMESPACE" -o jsonpath='{.data.holder}' 2>/dev/null || true)"
  echo "another deployment holds the management lock: ${holder:-unknown}" >&2
  echo "delete configmap/oran-stack-nephio-deploy-lock only if that run is gone" >&2
  exit 1
fi
LOCK_ACQUIRED=true

echo "==> Syncing blueprint repository"
porch repo sync blueprints -n "$PORCH_NAMESPACE"

echo "==> Applying PackageVariants"
kmgmt apply -f "$VARIANTS"

# Cache upstream selectors before a stale-state recovery temporarily removes
# PackageVariants to avoid reconciliation races with direct fresh clones.
for package in "${PACKAGES[@]}"; do
  variant="oran-lab-$package"
  UPSTREAM_REPO["$package"]="$(kmgmt get packagevariant "$variant" -n "$PORCH_NAMESPACE" \
    -o jsonpath='{.spec.upstream.repo}')"
  UPSTREAM_PACKAGE["$package"]="$(kmgmt get packagevariant "$variant" -n "$PORCH_NAMESPACE" \
    -o jsonpath='{.spec.upstream.package}')"
  UPSTREAM_WORKSPACE["$package"]="$(kmgmt get packagevariant "$variant" -n "$PORCH_NAMESPACE" \
    -o jsonpath='{.spec.upstream.workspaceName}')"
done

# Let the PackageVariant controller create normal Drafts before deciding the
# deployment repository is stale. A healthy existing workload is not changed.
sleep 10
if ! package_present 5g-core && \
   [[ -z "$(find_revision "$DOWNSTREAM_REPO" 5g-core 'Draft|Proposed')" ]]; then
  echo "==> Detected stale deployment state: 5g-core is absent and Porch has no current Draft"
  FORCE_FRESH=true
fi

if $FORCE_FRESH; then
  pause_variants
fi

for package in "${PACKAGES[@]}"; do
  echo "==== $package ===="

  if ! $FORCE_FRESH && [[ "$package" == "xapp-lifecycle" ]] && \
     package_present "$package"; then
    echo "==> Re-running xApp lifecycle recovery on the existing deployment"
    apply_xapp_lifecycle_settings
    kwl delete job xapp-lifecycle -n oran-verify --ignore-not-found
    wait_for_package "$package"
    DEPLOY_CHANGED=true
    continue
  fi

  if ! $FORCE_FRESH && package_present "$package"; then
    echo "already present on workload cluster; skip publish and verify readiness"
    wait_for_package "$package"
    continue
  fi

  revision=""
  if ! $FORCE_FRESH; then
    revision="$(variant_target_revision "$package")"
  fi

  if [[ -n "$revision" ]]; then
    echo "==> Publishing PackageVariant draft $revision"
    publish_revision "$revision"
  else
    pause_variants
    fresh_revision "$package"
  fi

  wait_for_expected_sync
  wait_for_package "$package"
done

if $VARIANTS_PAUSED; then
  echo "==> Reapplying PackageVariants to resume upstream reconciliation"
  kmgmt apply -f "$VARIANTS"
  echo "==> Waiting for PackageVariants Ready"
  deadline=$((SECONDS + PACKAGE_TIMEOUT))
  variants_ready=false
  while (( SECONDS < deadline )); do
    left=$((deadline - SECONDS))
    chunk=$HEARTBEAT_SECS
    (( left < chunk )) && chunk=$left
    (( chunk < 1 )) && break
    if kmgmt wait --for=condition=Ready packagevariant --all \
      -n "$PORCH_NAMESPACE" --timeout="${chunk}s" >/dev/null 2>&1; then
      echo "==> PackageVariants Ready"
      variants_ready=true
      break
    fi
    heartbeat "PackageVariants Ready" "$deadline"
  done
  if ! $variants_ready; then
    echo "timed out waiting for PackageVariants Ready" >&2
    exit 1
  fi
  # Adoption can create one final reconciliation Draft to restore the
  # PackageVariant upstream lock. Publish those drafts in the same safe order.
  sleep 10
  for package in "${PACKAGES[@]}"; do
    revision="$(find_revision "$DOWNSTREAM_REPO" "$package" 'Draft|Proposed')"
    if [[ -n "$revision" ]]; then
      echo "==> Publishing reconciliation draft $revision"
      publish_revision "$revision"
      wait_for_expected_sync
      wait_for_package "$package"
    fi
  done
  VARIANTS_PAUSED=false
fi

echo "==> Deployment complete"
echo "DEPLOY_RESULT_CHANGED=$DEPLOY_CHANGED"
kwl get pods -A
kwl get jobs -n oran-verify
