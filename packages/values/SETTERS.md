# Blueprint setters / overlay knobs

Edit [`lab-defaults.yaml`](lab-defaults.yaml) and re-run
`./scripts/render-nephio-packages.sh`, or mutate PackageVariants with
`gcr.io/kpt-fn/apply-setters`.

| Key | Package | Notes |
|-----|---------|-------|
| `images.core.repository` / `tag` | 5g-core | Open5GS image |
| `images.webui.repository` / `tag` | 5g-core | WebUI image |
| `images.ocudu.repository` / `tag` | ran | CU/DU image |
| `images.srsue.repository` / `tag` | ran | **srsUE sidecar** image |
| `deployUE` | ran | `true` includes srsUE in ocudu-du |
| `ue.imsi` / `k` / `opc` / `apn` | ran, mongodb-init, verification | Render script generates shared `oran-lab-settings` ConfigMaps |
| `secondaryNetworks.n2.*` | 5g-core, ran | Multus N2 IPs |
| `secondaryNetworks.f1c.*` | ran | Multus F1-C IPs |
| `secondaryNetworks.e2.*` | ran, near-rt-ric | Multus E2 IPs |
| `plmn.*` | 5g-core, ran | MCC/MNC/TAC |
| `xapp.e2NodeId` | xapp-simple-mon, verify-e2, xapp-lifecycle | Render script generates shared `oran-lab-settings` ConfigMaps |
| `image.repository` / `tag` | xapp-simple-mon | xApp image |

Fabric (NADs / OVS bridges) is **not** a setter — use Ansible `provision.yml`.
