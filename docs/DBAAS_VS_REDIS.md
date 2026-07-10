# DBAAS vs plain Redis

Near-RT RIC components do not talk to a generic Redis server. They use
**O-RAN SC DBAAS** (`o-ran-sc/ric-plt-dbaas`), which is Redis plus platform
extensions required by the Shared Data Layer (SDL).

In this stack the service is `ric-dbaas`, image:

```text
nexus3.o-ran-sc.org:10001/o-ran-sc/ric-plt-dbaas:0.6.5
```

## Short answer

| | Plain Redis (`redis:6-alpine`, etc.) | O-RAN SC DBAAS (`ric-plt-dbaas`) |
|---|--------------------------------------|----------------------------------|
| Wire protocol | Redis RESP on `:6379` | Same |
| Standard commands (`GET`, `SET`, `PING`, …) | Yes | Yes |
| SDL Redis module (`libredismodule.so`) | No | Yes |
| Custom commands (`MSETMPUB`, `SETIE`, …) | Missing | Present |
| Usable as e2mgr / RNIB backend | No | Yes |
| Persistence (this chart) | N/A | Disabled (`--save ""`, `--appendonly no`) |

DBAAS is still Redis under the hood. The difference that matters for the RIC
is the **SDL Redis module** and the custom commands it registers.

## Why the RIC needs DBAAS

Platform components (e2mgr, submgr, appmgr, a1mediator, …) access shared
state through the **Shared Data Layer (SDL)** API. SDL can use Redis as its
backend, but it expects Redis extension commands that are **not** part of
upstream Redis.

Those commands are implemented by DBAAS’s `libredismodule.so` and loaded at
startup:

```yaml
args:
  - redis-server
  - --loadmodule
  - /usr/local/libexec/redismodule/libredismodule.so
  - --save
  - ""
  - --appendonly
  - "no"
```

See `helm/near-rt-ric/templates/deployments.yaml`.

### Commands the module adds

Examples introduced by ric-plt/dbaas (not exhaustive):

- Atomic multi-key write + publish: `MSETPUB`, `MSETMPUB`
- Conditional set/delete: `SETIE`, `SETNE`, `DELIE`, `DELNE`
- Publish variants: `SETXXPUB`, `SETNXPUB`, `SETIEPUB`, `SETNEPUB`, `DELPUB`, …
- Namespace helpers: `NGET`, `NDEL`

SDL checks for required commands when it connects. If they are missing,
operations fail (or abort at setup) instead of falling back to plain
`SET`/`MSET`.

## What breaks with stock Redis

This stack previously used `redis:6-alpine`. Redis answered `PING` and looked
healthy, but e2mgr could not finish E2 Setup:

```text
ERR unknown command MSETMPUB
```

e2mgr uses `MSETMPUB` when updating RNIB on connection-status change
(CONNECTED). Without that command:

1. The RNIB write fails.
2. e2mgr returns before sending E2SetupResponse (RMR type `12002`).
3. The gNB never completes E2 Setup, and `/v1/nodeb/states` stays empty.

Replacing the image with `ric-plt-dbaas` and loading the module fixed that
path. Full write-up: [E2_REGISTRATION_SESSION_2026-07-10.md](./E2_REGISTRATION_SESSION_2026-07-10.md).

## Role in oran-stack

```text
e2mgr / submgr / appmgr / a1mediator
              |
              |  SDL API (DBAAS_SERVICE_HOST, etc.)
              v
         ric-dbaas :6379
              |
              +-- Redis core (keys, pub/sub, …)
              +-- SDL redismodule (MSETMPUB, SETIE, …)
```

- **RNIB** (RAN inventory / nodeb state) lives in DBAAS via SDL.
- Other platform services also store shared config and runtime data there.
- Startup order waits for DBAAS health before e2mgr and dependents start.

## Operational notes

**Verify the image**

```bash
kubectl -n near-rt-ric get deploy ric-dbaas \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Expect a tag under `o-ran-sc/ric-plt-dbaas`, not plain `redis:…`.

**Verify the SDL command**

```bash
kubectl -n near-rt-ric exec deploy/ric-dbaas -- \
  redis-cli COMMAND INFO MSETMPUB
```

A non-empty reply means the module is loaded. Empty / unknown means you are
effectively on stock Redis behavior.

**Persistence**

Official DBAAS (and this chart) run Redis **without** RDB/AOF persistence.
State is in-memory for the life of the pod. That matches O-RAN SC’s
standalone DBAAS design; HA/Sentinel options exist upstream but are not used
here.

**Extra tooling**

The DBAAS image also ships `sdlcli` for inspecting SDL-oriented keys and
backend health, in addition to `redis-cli`.

## When plain Redis is enough

Only for experiments that never call SDL (manual `SET`/`GET`, unrelated
apps). For Near-RT RIC platform components, use DBAAS.

## References

- Chart image and comment: `helm/near-rt-ric/values.yaml` (`images.dbaas`)
- Module load args: `helm/near-rt-ric/templates/deployments.yaml`
- O-RAN SC DBAAS: https://github.com/o-ran-sc/ric-plt-dbaas
- O-RAN SC SDL (required Redis modules): https://github.com/o-ran-sc/ric-plt-sdl
- Incident that exposed the gap: [E2_REGISTRATION_SESSION_2026-07-10.md](./E2_REGISTRATION_SESSION_2026-07-10.md)
