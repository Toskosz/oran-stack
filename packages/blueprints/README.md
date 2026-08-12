# Blueprint packages for Nephio / Porch / Config Sync.
#
# Helm charts under ../../helm are the generator of truth. Re-render with:
#   ./scripts/render-nephio-packages.sh
#
# Hand-maintained (not overwritten by the render script):
#   mongodb-init, verify-e2, xapp-lifecycle, verify-ue
# Generated shared settings:
#   ns-and-secrets/settings.yaml (from packages/values/lab-defaults.yaml)
#
# Deploy order on the workload cluster (via oran-lab deployment repo):
#   1. ns-and-secrets
#   2. 5g-core
#   3. mongodb-init
#   4. near-rt-ric
#   5. ran          (CU + DU + srsUE sidecar)
#   6. verify-e2
#   7. xapp-simple-mon
#   8. xapp-lifecycle (RTMgr sync + subscription routes + KPM gate)
#   9. verify-ue
#  10. monitoring
#
# See docs/NEPHIO.md for management/workload bootstrap and PackageRevision
# propose/approve commands (ns-and-secrets → … → monitoring).
