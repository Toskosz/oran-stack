# Example: apply PackageVariants then wait for Config Sync + verify Jobs.
# Run against MANAGEMENT kubeconfig for variants; WORKLOAD for job status.
#
#   export KUBECONFIG_MGMT=$(pwd)/kubeconfig-mgmt
#   export KUBECONFIG=$(pwd)/kubeconfig
#   ./packages/examples/deploy-oran-lab.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KUBECONFIG_MGMT="${KUBECONFIG_MGMT:-$ROOT/kubeconfig-mgmt}"
KUBECONFIG_WL="${KUBECONFIG:-$ROOT/kubeconfig}"

echo "==> Applying PackageVariants on management cluster"
kubectl --kubeconfig="$KUBECONFIG_MGMT" apply -f "$ROOT/packages/variants/oran-lab-packagevariants.yaml"

echo "==> Waiting for verify-e2 Job on workload (approve PackageRevisions in Porch first)"
echo "    kubectl --kubeconfig=$KUBECONFIG_WL get packagerevisions -A"
echo "    Then: kubectl --kubeconfig=$KUBECONFIG_WL wait --for=condition=complete job/verify-e2 -n oran-verify --timeout=900s"
echo "    Then: kubectl --kubeconfig=$KUBECONFIG_WL wait --for=condition=complete job/verify-ue -n oran-verify --timeout=900s"
