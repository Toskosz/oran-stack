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
| `ue.imsi` / `k` / `opc` / `apn` | ran | Must match mongodb-init seed |
| `secondaryNetworks.n2.*` | 5g-core, ran | Multus N2 IPs |
| `secondaryNetworks.f1c.*` | ran | Multus F1-C IPs |
| `secondaryNetworks.e2.*` | ran, near-rt-ric | Multus E2 IPs |
| `plmn.*` | 5g-core, ran | MCC/MNC/TAC |
| `xapp.e2NodeId` | xapp-simple-mon | Must match e2mgr ranName |
| `image.repository` / `tag` | xapp-simple-mon | xApp image |
| `E2_NODE_ID` (Job env) | verify-e2 | Override in Job if gNB id changes |

Fabric (NADs / OVS bridges) is **not** a setter — use Ansible `provision.yml`.
