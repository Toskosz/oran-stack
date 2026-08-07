# Blueprint packages for Nephio / Porch / Config Sync.
#
# Helm charts under ../../helm are the generator of truth. Re-render with:
#   ./scripts/render-nephio-packages.sh
#
# Hand-maintained (not overwritten by the render script):
#   ns-and-secrets, mongodb-init, verify-e2, verify-ue
#
# Deploy order on the workload cluster (via oran-lab deployment repo):
#   1. ns-and-secrets
#   2. 5g-core
#   3. mongodb-init
#   4. near-rt-ric
#   5. ran          (CU + DU + srsUE sidecar)
#   6. verify-e2
#   7. xapp-simple-mon
#   8. verify-ue
#   9. monitoring
#
# See docs/NEPHIO.md for management/workload bootstrap.
