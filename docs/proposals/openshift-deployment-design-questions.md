# OpenClaw on OpenShift — Design Questions

**Status:** All questions resolved  
**Related:** [Design document](openshift-deployment-design.md)

Each question has options with trade-offs and a recommendation. Go through them one by one to form the design, then update the design document.

---

## Q1: What image should the init container use?

The init container copies `openclaw.json` and `AGENTS.md` from the ConfigMap volume into the PVC before the gateway starts. The upstream uses `busybox:1.37` from Docker Hub. On OpenShift with the restricted SCC, any image works as long as it contains `sh`, `cp`, and `mkdir`. The question is whether to keep busybox or reuse the OpenClaw image.

### Option A: Keep `busybox:1.37` via Google mirror

Use `mirror.gcr.io/library/busybox:1.37` — Google's container mirror of Docker Hub, which falls back to Docker Hub if the image isn't cached there. Avoids Docker Hub rate limits.

- **Pro:** Tiny image (~4MB), fast to pull.
- **Pro:** Matches upstream manifests — easy to diff.
- **Pro:** Google mirror avoids Docker Hub rate limits; falls back transparently.
- **Con:** Adds a second image dependency beyond ghcr.io (though mirror.gcr.io is highly available).

**Decision:** Option A — keep busybox:1.37, pulled from `mirror.gcr.io/library/busybox:1.37` to avoid Docker Hub rate limits.

_Considered and rejected: Option B — use OpenClaw image as init container (unnecessarily heavy for a trivial copy task)._

---

## Q2: What Route timeout should be set for WebSocket support?

OpenClaw uses WebSockets for its control plane — the Control UI, TUI, and companion apps all maintain persistent WS connections to the gateway on port 18789. OpenShift's HAProxy router has a default timeout of 30 seconds for inactive connections, which would disconnect idle WebSocket sessions.

### Option A: Set `haproxy.router.openshift.io/timeout: 3600s` (1 hour)

- **Pro:** Keeps WebSocket connections alive for up to an hour of inactivity.
- **Pro:** Matches common practice for WebSocket-heavy apps on OpenShift.
- **Con:** Very long idle connections consume HAProxy resources (minor for a single-user deployment).

**Decision:** Option A — 1 hour timeout. Single-user gateway with few connections; avoids unnecessary reconnection churn.

_Considered and rejected: Option B — 5 minutes (too frequent reconnections), Option C — cluster default 30s (far too short for WebSockets)._

---

## Q3: How should the deploy script locate the kubeconfig?

The sketch decided on kubeconfig-based auth rather than `oc login`. The question is how the script finds the kubeconfig file.

### Option C: Support `--kubeconfig <path>` flag, fall back to env/default

Add a `--kubeconfig` CLI flag that sets `KUBECONFIG` before running `oc`. Fall back to `KUBECONFIG` env var, then `~/.kube/config`.

- **Pro:** Most flexible — explicit flag for scripts, env var for automation, default for interactive use.
- **Con:** More argument parsing code for marginal benefit. Users can already do `KUBECONFIG=/path ./deploy.sh`.

**Decision:** Option C — support `--kubeconfig <path>` flag, fall back to `KUBECONFIG` env var, then `~/.kube/config`. Explicit when needed, standard otherwise.

_Considered and rejected: Option A — rely on standard env/default only (less explicit), Option B — require KUBECONFIG env var (breaks common default config workflow)._

---

## Q4: What should `--delete` remove?

The upstream `--delete` deletes the entire namespace. Since we're deploying into an existing shared namespace, deleting it would destroy other workloads. The delete operation needs to be scoped to OpenClaw resources only.

### Option B: Delete by Kustomize (`oc delete -k manifests/`)

Use Kustomize to identify the resources and delete them: `oc delete -k manifests/ -n "$NS"`, then separately delete the Secret (which is not in manifests).

- **Pro:** Deletes exactly what `oc apply -k` created — precise and consistent.
- **Pro:** No dependency on labels.
- **Con:** Does not delete the Secret (created separately by the script).
- **Con:** Two commands: kustomize delete + secret delete.

**Decision:** Option B — `oc delete -k manifests/` plus explicit Secret delete. Natural counterpart to `oc apply -k`, stays in sync with manifests automatically.

_Considered and rejected: Option A — label selector (depends on all resources being labeled, `oc delete all` doesn't cover ConfigMaps/PVCs/Routes), Option C — explicit resource names (must be manually kept in sync with manifests)._
