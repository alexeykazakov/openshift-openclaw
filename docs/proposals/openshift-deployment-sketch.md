# OpenClaw on OpenShift — Sketch

**Status:** Sketch complete — ready for detailed design

## Problem

Run [OpenClaw](https://github.com/openclaw/openclaw) (a personal AI assistant gateway) on an OpenShift cluster using the pre-built container image. The operator does not have cluster-admin access — they can only work within an existing namespace they have `edit` access to.

## Constraints

- **No namespace creation** — must deploy into a pre-existing namespace.
- **No source build** — use the published `ghcr.io/openclaw/openclaw:slim` image directly from ghcr.io.
- **Kubeconfig-based auth** — the deploy script uses a provided kubeconfig (not `oc login` session state).
- **Limited RBAC** — namespace-scoped `edit` role only (can create Deployments, Services, ConfigMaps, Secrets, PVCs, Routes, but not cluster-scoped resources like SCCs or ClusterRoles).

## What OpenClaw Needs at Runtime

| Concern | Detail |
|---------|--------|
| **Image** | `ghcr.io/openclaw/openclaw:slim` — Node.js 24, non-root (UID 1000 in upstream) |
| **Port** | TCP 18789 (gateway WebSocket + HTTP) |
| **Config** | `openclaw.json` (gateway settings) + `AGENTS.md` (agent instructions), mounted via ConfigMap into `/home/node/.openclaw` |
| **Secrets** | Gateway token + at least one LLM provider API key (Anthropic / OpenAI / Gemini / OpenRouter) |
| **Storage** | Persistent volume for `/home/node/.openclaw` (sessions, logs, workspace) |
| **Health** | `GET /healthz` (liveness), `GET /readyz` (readiness) on port 18789 |
| **Writable /tmp** | The image uses `readOnlyRootFilesystem`; needs an emptyDir at `/tmp` |

## Decisions

### Exposure: OpenShift Route with edge TLS (Q1)

The gateway binds to `lan` (0.0.0.0) inside the pod and is exposed via an OpenShift Route with edge TLS termination. OpenShift handles TLS using the cluster's wildcard certificate. The gateway's built-in token auth protects the endpoint. This provides a persistent URL accessible from browsers, mobile apps, and channel webhooks without maintaining a port-forward session.

### Security context: Arbitrary UID with explicit HOME (Q2)

All hardcoded `runAsUser`, `runAsGroup`, and `fsGroup` values are removed from the manifests. OpenShift's `restricted` SCC assigns an arbitrary UID from the namespace range. The `HOME` env var is explicitly set to `/home/node` so the application resolves paths correctly. The PVC mounted at `/home/node/.openclaw` is group-writable via OpenShift's automatic supplemental GID assignment. No elevated SCC or admin permissions are needed.

### Image source: Direct pull from ghcr.io (Q3)

The deployment references `ghcr.io/openclaw/openclaw:slim` directly. The image is public, so no pull secret is needed. The cluster must have egress to ghcr.io.

### Deploy tooling: Fresh deploy script using oc + kubeconfig (Q4)

A new `deploy.sh` script tailored to the OpenShift constraints, using `oc` with a provided kubeconfig. The script preserves important behaviors from the upstream `deploy.sh`:

- Secret generation in a temp directory (no secrets written to repo checkout)
- Auto-generated gateway token via `openssl rand -hex 32`
- Preservation of existing gateway token and API keys when updating the secret
- Support for multiple provider API keys (Anthropic, OpenAI, Gemini, OpenRouter)
- `--show-token`, `--create-secret`, `--delete` flags
- Rollout wait with timeout
- Token retrieval instructions after deploy

### Namespace: Required OPENCLAW_NAMESPACE env var (Q5)

The target namespace must be specified via the `OPENCLAW_NAMESPACE` environment variable. The script fails with a clear error if it is not set. This avoids accidental deploys to the wrong namespace and pairs naturally with kubeconfig-based auth where there is no implicit project context.

## Deliverables

A set of OpenShift-adapted manifests and a deploy script in this repo:

```
manifests/
├── kustomization.yaml
├── configmap.yaml        # openclaw.json (bind: lan) + AGENTS.md
├── deployment.yaml       # no hardcoded UIDs, HOME=/home/node, readOnlyRootFilesystem
├── service.yaml          # ClusterIP on 18789
├── pvc.yaml              # 10Gi ReadWriteOnce
└── route.yaml            # edge TLS termination
deploy.sh                 # oc + kubeconfig deploy script
```

## Existing Upstream Manifests

OpenClaw ships Kustomize manifests in `scripts/k8s/manifests/` (Deployment, Service, ConfigMap, PVC) and a `deploy.sh` that handles Secret creation and rollout. These target vanilla Kubernetes and were adapted for OpenShift with the following changes:

1. **Arbitrary UIDs** — removed hardcoded `runAsUser`/`runAsGroup`/`fsGroup`, added explicit `HOME=/home/node`.
2. **Namespace** — no namespace creation; `OPENCLAW_NAMESPACE` env var required.
3. **Ingress** — added OpenShift Route with edge TLS; changed gateway bind from `loopback` to `lan`.
4. **Tooling** — `oc` with kubeconfig instead of `kubectl`.

## Out of Scope

- Building OpenClaw from source.
- Cluster-admin operations (CRDs, ClusterRoles, custom SCCs).
- Multi-replica / HA deployment (OpenClaw is designed as a single-instance gateway).
- Channel-specific setup (Telegram bots, Slack apps, etc.) — that's post-deploy configuration.
- Monitoring / alerting beyond the built-in health endpoints.
