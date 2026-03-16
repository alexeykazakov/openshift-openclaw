# OpenClaw on OpenShift — Design

**Status:** Final

## Overview

Deploy OpenClaw (a personal AI assistant gateway) to an existing OpenShift namespace using the pre-built `ghcr.io/openclaw/openclaw:slim` container image. The operator has namespace-scoped `edit` access only — no cluster-admin, no namespace creation.

This design adapts the upstream Kubernetes manifests (`openclaw/scripts/k8s/`) for OpenShift's security model and conventions, and provides a deploy script that uses `oc` with a provided kubeconfig.

**Decisions from sketch phase** (see [sketch](openshift-deployment-sketch.md)):

- OpenShift Route with edge TLS (bind `lan`)
- Arbitrary UID with explicit `HOME=/home/node` (restricted SCC)
- Direct pull from `ghcr.io`
- Fresh deploy script using `oc` + kubeconfig
- Required `OPENCLAW_NAMESPACE` env var

## Design Principles

1. **No elevated privileges** — everything works under the default `restricted` SCC with namespace `edit` role.
2. **Secure secret handling** — secrets are generated in a temp directory and applied server-side; no secret material is written to the repo checkout.
3. **Minimal divergence from upstream** — changes are limited to what OpenShift requires. The manifest structure mirrors upstream so diffs are easy to review.
4. **Explicit over implicit** — namespace is required via env var; kubeconfig can be passed explicitly or resolved via standard conventions.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  OpenShift Namespace ($OPENCLAW_NAMESPACE)              │
│                                                         │
│  ┌──────────────┐    ┌──────────────┐                   │
│  │  ConfigMap   │    │   Secret     │                   │
│  │  openclaw-   │    │  openclaw-   │                   │
│  │  config      │    │  secrets     │                   │
│  └──────┬───────┘    └──────┬───────┘                   │
│         │                   │                           │
│  ┌──────┴───────────────────┴───────┐                   │
│  │         Deployment/openclaw      │                   │
│  │  ┌─────────────────────────────┐ │                   │
│  │  │ init: init-config           │ │                   │
│  │  │  (busybox via gcr mirror)   │ │                   │
│  │  │  cp config → PVC            │ │                   │
│  │  └─────────────────────────────┘ │                   │
│  │  ┌─────────────────────────────┐ │  ┌──────────────┐ │
│  │  │ container: gateway          │ │  │    PVC       │ │
│  │  │  node /app/dist/index.js    ├─┼──┤ openclaw-    │ │
│  │  │  gateway run                │ │  │ home-pvc     │ │
│  │  │  :18789                     │ │  │ (10Gi)       │ │
│  │  └──────────┬──────────────────┘ │  └──────────────┘ │
│  └─────────────┼────────────────────┘                   │
│                │                                        │
│  ┌─────────────┴──────┐                                 │
│  │  Service/openclaw  │                                 │
│  │  ClusterIP :18789  │                                 │
│  └─────────────┬──────┘                                 │
│                │                                        │
│  ┌─────────────┴──────┐                                 │
│  │  Route/openclaw    │                                 │
│  │  edge TLS, 1h WS   │                                 │
│  └────────────────────┘                                 │
└─────────────────────────────────────────────────────────┘
                │
                ▼
        https://openclaw-<ns>.apps.<cluster>/
```

## Manifests — Detailed Design

### File layout

```
manifests/
├── kustomization.yaml
├── configmap.yaml
├── deployment.yaml
├── service.yaml
├── pvc.yaml
└── route.yaml
deploy.sh
```

### `kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - pvc.yaml
  - configmap.yaml
  - deployment.yaml
  - service.yaml
  - route.yaml
```

Adds `route.yaml` compared to upstream.

### `configmap.yaml`

Identical to upstream except `"bind": "lan"` instead of `"bind": "loopback"`:

```json5
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "port": 18789,
    "auth": { "mode": "token" },
    "controlUi": { "enabled": true }
  },
  "agents": {
    "defaults": { "workspace": "~/.openclaw/workspace" },
    "list": [
      { "id": "default", "name": "OpenClaw Assistant", "workspace": "~/.openclaw/workspace" }
    ]
  },
  "cron": { "enabled": false }
}
```

The `AGENTS.md` section is updated to reference OpenShift:

```markdown
# OpenClaw Assistant

You are a helpful AI assistant running in OpenShift.
```

### `deployment.yaml`

Changes from upstream:

| Upstream | OpenShift | Reason |
|----------|-----------|--------|
| `fsGroup: 1000` | Removed | OpenShift assigns supplemental GID from namespace range |
| Init container `runAsUser: 1000`, `runAsGroup: 1000` | Removed | Arbitrary UID from restricted SCC |
| Init container `image: busybox:1.37` | `image: mirror.gcr.io/library/busybox:1.37` | Google mirror avoids Docker Hub rate limits |
| Gateway `runAsUser: 1000`, `runAsGroup: 1000` | Removed | Arbitrary UID from restricted SCC |
| `runAsNonRoot: true` | Kept | Required by restricted SCC |
| `allowPrivilegeEscalation: false` | Kept | Required by restricted SCC |
| `readOnlyRootFilesystem: true` | Kept | Security hardening |
| `capabilities.drop: [ALL]` | Kept | Security hardening |
| `seccompProfile: RuntimeDefault` | Kept | Required by restricted SCC |
| `automountServiceAccountToken: false` | Kept | Principle of least privilege |
| `HOME=/home/node` env var | Kept (already in upstream) | Ensures correct path resolution under arbitrary UID |

The probes use `exec` with a `node -e` one-liner that hits `127.0.0.1:18789/healthz` and `/readyz`. These are kept as-is — they work because the probe runs inside the container where the gateway is listening.

Resource requests/limits are kept at upstream defaults:
- Gateway: 512Mi–2Gi memory, 250m–1 CPU
- Init: 32Mi–64Mi memory, 50m–100m CPU

### `service.yaml`

Identical to upstream: ClusterIP on port 18789.

### `pvc.yaml`

Identical to upstream: 10Gi ReadWriteOnce. No storage class specified (uses cluster default).

### `route.yaml` (new)

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: openclaw
  labels:
    app: openclaw
  annotations:
    haproxy.router.openshift.io/timeout: 3600s
spec:
  to:
    kind: Service
    name: openclaw
    weight: 100
  port:
    targetPort: 18789
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
```

Key details:
- **Edge TLS termination** — OpenShift terminates TLS using the cluster's wildcard certificate. Traffic inside the cluster is plain HTTP.
- **Insecure redirect** — HTTP requests are redirected to HTTPS.
- **1-hour timeout** — `haproxy.router.openshift.io/timeout: 3600s` keeps WebSocket connections alive through idle periods. OpenClaw's Control UI, TUI, and companion apps maintain persistent WS connections.
- **No explicit hostname** — OpenShift auto-generates `openclaw-<namespace>.apps.<cluster-domain>`.

## Deploy Script — Detailed Design

### Interface

```
Usage: ./deploy.sh [OPTION]

  (no args)        Deploy OpenClaw (creates secret from env if needed)
  --create-secret  Create or update the Secret from env vars without deploying
  --show-token     Print the gateway token after deploy or secret creation
  --delete         Delete OpenClaw resources from the namespace
  --kubeconfig     Path to kubeconfig file (falls back to KUBECONFIG env, then ~/.kube/config)
  -h, --help       Show this help

Required environment:
  OPENCLAW_NAMESPACE    Target OpenShift namespace

  At least one provider API key (for first deploy):
    ANTHROPIC_API_KEY, GEMINI_API_KEY, OPENAI_API_KEY, OPENROUTER_API_KEY
```

### Kubeconfig resolution

The `--kubeconfig <path>` flag sets `KUBECONFIG` before any `oc` calls. If not provided, `oc` uses the standard resolution: `KUBECONFIG` env var, then `~/.kube/config`. The script validates cluster connectivity early via `oc whoami`.

### Prerequisites check

The script verifies at startup:
1. `oc` and `openssl` are available.
2. `OPENCLAW_NAMESPACE` is set and non-empty.
3. The cluster is reachable (`oc whoami` succeeds).
4. The namespace exists and is accessible (`oc get namespace "$NS"`).

### Secret handling

Ported from upstream `deploy.sh` with the same security model:

1. Create a temp directory (`mktemp -d`) with mode 700.
2. Set a trap to remove it on exit.
3. If the secret already exists in the cluster, read existing values (gateway token + all API keys) via `oc get secret ... -o jsonpath`.
4. Merge: env vars override existing values; existing values are preserved for keys not in the environment. Gateway token is preserved if it already exists, otherwise generated via `openssl rand -hex 32`.
5. Write each value to a temp file with mode 600.
6. Generate the secret manifest via `oc create secret generic --dry-run=client -o yaml`.
7. Apply the manifest server-side (`oc apply --server-side --field-manager=openclaw`).
8. Clean up the temp directory.

### Deploy flow

1. Validate prerequisites.
2. Ensure secret exists (create from env if not, fail if no secret and no env keys).
3. Apply manifests: `oc apply -k manifests/ -n "$NS"`.
4. Restart deployment: `oc rollout restart deployment/openclaw -n "$NS"`.
5. Wait for rollout: `oc rollout status deployment/openclaw -n "$NS" --timeout=300s`.
6. Print access info: Route URL (queried via `oc get route openclaw -n "$NS"`) and token retrieval command.

### Delete flow

1. `oc delete -k manifests/ -n "$NS" --ignore-not-found` — removes all Kustomize-managed resources (Deployment, Service, ConfigMap, PVC, Route).
2. `oc delete secret openclaw-secrets -n "$NS" --ignore-not-found` — removes the separately-managed Secret.
3. Print confirmation.

This is the natural counterpart to the deploy flow (`oc apply -k`) and stays in sync with whatever resources are defined in the manifests.

## Implementation Plan

### Phase 1: Manifests

Create the 6 manifest files in `manifests/`:

1. `kustomization.yaml` — resource list including route.yaml
2. `pvc.yaml` — copied from upstream, no changes
3. `service.yaml` — copied from upstream, no changes
4. `configmap.yaml` — copied from upstream, change bind to `lan`, update AGENTS.md text
5. `deployment.yaml` — adapted from upstream: remove hardcoded UIDs/GIDs, use `mirror.gcr.io/library/busybox:1.37` for init container
6. `route.yaml` — new, edge TLS with `haproxy.router.openshift.io/timeout: 3600s`

### Phase 2: Deploy script

Create `deploy.sh`:

1. Prerequisite checks (oc, openssl, OPENCLAW_NAMESPACE, cluster connectivity, namespace access)
2. Argument parsing (--kubeconfig, --create-secret, --delete, --show-token, --help)
3. `_apply_secret()` function — ported from upstream with `oc` instead of `kubectl`, no namespace creation
4. Deploy flow — apply kustomize, restart, wait, print Route URL
5. Delete flow — `oc delete -k manifests/` + `oc delete secret openclaw-secrets`

### Phase 3: Verify

- Dry-run: `oc apply -k manifests/ --dry-run=server -n "$NS"`
- Deploy to a test namespace and verify pod starts, probes pass, Route is accessible
