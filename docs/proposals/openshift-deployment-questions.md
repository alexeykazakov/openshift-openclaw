# OpenClaw on OpenShift — Sketch Questions

**Status:** All questions resolved  
**Related:** [Sketch document](openshift-deployment-sketch.md)

Each question has options with trade-offs and a recommendation. Go through them one by one to form the sketch, then update the sketch document.

---

## Q1: How should the gateway be exposed?

The upstream Kubernetes manifests bind the gateway to loopback (127.0.0.1) and rely on `kubectl port-forward` for access. On OpenShift, Routes are the native way to expose services externally. This determines the gateway bind mode and whether we create a Route.

### Option B: OpenShift Route with edge TLS termination (lan bind)

Create an OpenShift Route with TLS. Change gateway bind from `loopback` to `lan` so it listens on 0.0.0.0 inside the pod.

- **Pro:** Persistent URL accessible from anywhere (browser, mobile apps, channel webhooks).
- **Pro:** OpenShift handles TLS termination automatically with the cluster's wildcard cert.
- **Pro:** Gateway token auth still protects the endpoint.
- **Con:** Exposes the service to the network — requires trusting token-based auth.
- **Con:** Slightly more configuration (Route manifest, bind mode change).

**Decision:** Option B — OpenShift Route with edge TLS is the natural pattern; provides persistent access and free TLS via the cluster wildcard cert.

_Considered and rejected: Option A — port-forward only (not persistent, single-machine access), Option C — both modes (unnecessary complexity for single-user deployment)._

---

## Q2: How should OpenShift's arbitrary UID assignment be handled?

OpenShift's default `restricted` SCC does not allow pods to run as a specific UID. Instead, it assigns a random UID from the namespace's UID range. The upstream manifests hardcode `runAsUser: 1000` and `fsGroup: 1000`. The init container (busybox) also runs as UID 1000.

### Option C: Remove hardcoded UIDs + set HOME explicitly

Same as Option A but explicitly set `HOME=/home/node` as an env var in the Deployment. The PVC is mounted at `/home/node/.openclaw` so it will be writable regardless of UID (OpenShift sets the fsGroup to the namespace's supplemental GID, which grants group-write on PVC mounts).

- **Pro:** Works with `restricted` SCC — no elevated permissions.
- **Pro:** Preserves the expected HOME path for the application.
- **Con:** Minor deviation from upstream manifests.

**Decision:** Option C — remove hardcoded UIDs and set `HOME=/home/node` explicitly. Stays within the `restricted` SCC with no extra permissions needed.

_Considered and rejected: Option A — remove UIDs without HOME override (HOME resolution may break), Option B — request nonroot-v2 SCC (requires admin grant beyond edit role)._

---

## Q3: Should the image be pulled from ghcr.io directly or mirrored?

The OpenClaw image is published at `ghcr.io/openclaw/openclaw:slim`. OpenShift clusters vary in their ability to pull from external registries.

### Option A: Pull directly from ghcr.io

Use `ghcr.io/openclaw/openclaw:slim` as the image reference. The image is public, so no pull secret is needed.

- **Pro:** Simplest — no extra steps.
- **Pro:** Always gets the latest published image.
- **Con:** Requires egress to ghcr.io from the cluster's container runtime.
- **Con:** If ghcr.io is down or rate-limited, pods won't start.

**Decision:** Option A — pull directly from ghcr.io. Simplest approach; the image is public and the cluster has egress.

_Considered and rejected: Option B — mirror to internal registry (unnecessary overhead), Option C — document both (added complexity for a non-issue)._

---

## Q4: What deploy tooling should we use?

The upstream repo has a `deploy.sh` that uses `kubectl` and handles secret creation, kustomize apply, and rollout. We need something for OpenShift.

### Option B: Write a minimal new deploy script

Write a fresh script tailored to the OpenShift constraints (existing namespace, `oc` commands, no namespace creation). Must carefully preserve the important behaviors from the upstream script:

- Secret generation in a temp directory (no secrets written to repo checkout)
- Auto-generated gateway token via `openssl rand -hex 32`
- Preservation of existing gateway token and API keys when updating the secret
- Support for multiple provider API keys (Anthropic, OpenAI, Gemini, OpenRouter)
- `--show-token`, `--create-secret`, `--delete` flags
- Rollout wait with timeout
- Token retrieval instructions printed after deploy

- **Pro:** Clean, no upstream baggage.
- **Pro:** Can be simpler since we have fewer concerns (single namespace, no namespace lifecycle).
- **Con:** Must carefully audit upstream script to not miss important logic.

**Decision:** Option B — write a fresh deploy script, but carefully audit the upstream `deploy.sh` to preserve all important behaviors (secure secret handling, token preservation, multi-provider keys, etc.).

_Considered and rejected: Option A — fork upstream script (too coupled to namespace-creation flow), Option C — manual steps only (error-prone with secrets)._

---

## Q5: How should the target namespace be specified?

The user already has an existing namespace they want to deploy into. The script needs to know which one.

### Option A: Required environment variable

Require `OPENCLAW_NAMESPACE` to be set. Fail with an error if missing.

- **Pro:** Explicit — no accidental deploys to the wrong namespace.
- **Pro:** Works naturally with kubeconfig-based auth (no reliance on `oc project` state).
- **Con:** One more thing to remember.

**Decision:** Option A — require `OPENCLAW_NAMESPACE` env var. Explicit and safe; pairs well with kubeconfig-based auth where there's no implicit project context.

_Considered and rejected: Option B — use current oc project context (no longer applicable since we use kubeconfig instead of oc login), Option C — CLI argument (verbose for repeated use)._
