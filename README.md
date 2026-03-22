# OpenClaw on OpenShift

Deploy [OpenClaw](https://github.com/openclaw/openclaw) to an existing OpenShift namespace.

## Prerequisites

- `oc` CLI installed
- `openssl` installed
- Access to an existing OpenShift namespace (edit role)
- An API key for at least one LLM provider (Anthropic, OpenAI, Gemini, or OpenRouter)

## Deploy

```bash
export OPENCLAW_NAMESPACE="my-namespace"
export ANTHROPIC_API_KEY="sk-ant-..."      # or OPENAI_API_KEY, GEMINI_API_KEY, OPENROUTER_API_KEY

./deploy.sh --kubeconfig /path/to/kubeconfig --show-token
```

The script creates two Secrets (gateway token in `openclaw-secrets`, API keys in `openclaw-proxy-secrets`), applies the Kustomize manifests, waits for the rollout, and prints the Route URL. API keys are only mounted in the credential proxy pod — the OpenClaw pod never receives them.

## Access

### 1. Open the Route URL

Open the Route URL printed by the deploy script (e.g. `https://openclaw-my-namespace.apps.cluster.example.com`).

### 2. Approve device pairing

On first connection from a new browser you'll see **"pairing required"**. This is OpenClaw's device authentication — remote connections require a one-time approval.

With the browser tab open (so the pairing request stays active), run:

```bash
# List pending pairing requests
oc exec -n $OPENCLAW_NAMESPACE deployment/openclaw -- \
  node /app/dist/index.js devices list

# Approve by request ID (copy from the Pending table above)
oc exec -n $OPENCLAW_NAMESPACE deployment/openclaw -- \
  node /app/dist/index.js devices approve <requestId>
```

Refresh the browser after approval. The device is remembered — you won't need to pair again unless you clear browser data or switch browsers.

### 3. Authenticate with the gateway token

Paste the gateway token into the Control UI. If you deployed with `--show-token`, it was printed in the terminal. Otherwise retrieve it:

```bash
oc get secret openclaw-secrets -n $OPENCLAW_NAMESPACE \
  -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' | base64 -d && echo
```

## Update API keys

```bash
export OPENCLAW_NAMESPACE="my-namespace"
export OPENAI_API_KEY="sk-..."

./deploy.sh --create-secret
./deploy.sh
```

Existing keys and the gateway token are preserved — only the keys you provide are updated.

## Vertex AI (Gemini via GCP)

OpenClaw supports Gemini models through Google Vertex AI using the `google-vertex` provider. This uses GCP Application Default Credentials (ADC) instead of direct API keys.

### 1. Create a GCP service account

In the GCP Console (or with `gcloud`), create a service account with the **Vertex AI User** role and download a JSON key file.

### 2. Deploy with the key file

```bash
export OPENCLAW_NAMESPACE="my-namespace"
export GCP_SA_KEY_FILE="/path/to/sa-key.json"
export GCP_PROJECT_ID="my-gcp-project"
export GCP_LOCATION="us-central1"          # optional, defaults to us-central1

./deploy.sh --kubeconfig /path/to/kubeconfig --show-token
```

The script creates a separate `openclaw-gcp-credentials` secret from the key file and the deployment mounts it at the path referenced by `GOOGLE_APPLICATION_CREDENTIALS`.

### 3. Configure the model provider

The default model is set to `google-vertex/gemini-3-flash-preview` in `manifests/configmap.yaml`. Available Gemini models on Vertex AI include:

- `google-vertex/gemini-3-flash-preview` — fast, cost-effective (default)
- `google-vertex/gemini-3.1-pro-preview` — most capable

You can switch models in the Control UI or by editing the configmap.

Then redeploy:

```bash
./deploy.sh
```

### Testing with personal ADC credentials

If you don't have a service account yet, you can test with your personal Application Default Credentials:

```bash
gcloud auth application-default login

export OPENCLAW_NAMESPACE="my-namespace"
export GCP_SA_KEY_FILE="$HOME/.config/gcloud/application_default_credentials.json"
export GCP_PROJECT_ID="my-gcp-project"    # required — ADC user credentials don't contain a project ID
export GCP_LOCATION="us-central1"          # optional, defaults to us-central1

./deploy.sh --kubeconfig /path/to/kubeconfig --show-token
```

`GCP_PROJECT_ID` is required because personal ADC credentials don't contain a project ID (unlike service account keys which do). `GCP_LOCATION` sets the Vertex AI region. Switch to a proper service account key for production.

### 4. Add the key to an existing deployment

If OpenClaw is already deployed and you want to add Vertex AI support later:

```bash
export OPENCLAW_NAMESPACE="my-namespace"
export GCP_SA_KEY_FILE="/path/to/sa-key.json"

./deploy.sh --create-secret
./deploy.sh
```

## Credential Proxy Architecture (OpenShell-inspired)

All API keys and integration tokens are isolated from the OpenClaw pod. This mirrors how [OpenShell](https://github.com/NVIDIA/OpenShell) uses `inference.local` — a proxy endpoint that the agent calls instead of the real API, with credentials injected server-side.

OpenClaw's `models.providers.*.baseUrl` in `openclaw.json` points each LLM provider at the proxy (e.g., `http://openclaw-proxy:8080/gemini`). A dummy `apiKey` value satisfies OpenClaw's auth resolver without exposing real credentials. The proxy replaces this with the real key before forwarding upstream.

```
┌─────────────────────────────┐       ┌───────────────────────────────────┐
│  OpenClaw Pod               │       │  Proxy Pod                        │
│                             │       │                                   │
│  No real API keys.          │──────>│  Has API keys (proxy-secrets).    │
│  baseUrl -> proxy:8080      │ :8080 │  Replaces dummy key with real.    │
│  apiKey = dummy placeholder │       │  Forwards to real API endpoints.  │
└─────────────────────────────┘       └──────────────┬────────────────────┘
        │                                            │
        │ NetworkPolicy:                             │ Allowed: HTTPS to
        │ egress only to proxy + DNS                 │ api.anthropic.com,
        │                                            │ api.openai.com, etc.
        x blocked: direct internet                   │
                                                     v
                                              External LLM APIs
```

**How it protects credentials:**

| Layer | Protection |
|-------|------------|
| **Secret split** | `openclaw-secrets` has the gateway token only. `openclaw-proxy-secrets` has all API keys and is mounted only in the proxy pod. |
| **Provider baseUrl redirect** | `openclaw.json` sets each provider's `baseUrl` to the proxy. OpenClaw's SDK calls the proxy instead of the real API. This is equivalent to OpenShell's `inference.local` mechanism. |
| **Credential injection** | The proxy's nginx config replaces the dummy auth header with real credentials per upstream (e.g., `x-api-key` for Anthropic, `Authorization: Bearer` for OpenAI). |
| **NetworkPolicy** | The OpenClaw pod's egress is restricted to the proxy Service and DNS. Even if credentials were present, they could not be exfiltrated. |
| **L7 method filtering** | Each proxy endpoint restricts HTTP methods (e.g., LLM APIs allow POST only; GitHub allows GET/HEAD/OPTIONS only). |

### Supported integrations

| Integration | Proxy path | Auth header | Methods allowed |
|-------------|-----------|-------------|-----------------|
| Anthropic | `/anthropic/` | `x-api-key` | POST |
| OpenAI | `/openai/` | `Authorization: Bearer` | POST |
| Gemini | `/gemini/` | `x-goog-api-key` | POST |
| OpenRouter | `/openrouter/` | `Authorization: Bearer` | POST |
| GitHub API | `/github/` | `Authorization: token` | GET, HEAD, OPTIONS |
| Telegram Bot | `/telegram/` | Token in URL path | POST |

### Adding a new LLM provider

1. Add the credential to `openclaw-proxy-secrets` (update `deploy.sh`)
2. Add a `location` block to `manifests/proxy-configmap.yaml`
3. Add the env var to `manifests/proxy-deployment.yaml`
4. Add a provider entry to `models.providers` in `manifests/configmap.yaml` with `baseUrl` pointing to the new proxy path and `apiKey: "ah-ah-ah-you-didnt-say-the-magic-word"`
5. Redeploy with `./deploy.sh`

## Configure

Edit `manifests/configmap.yaml` to change `openclaw.json` (gateway settings) or `AGENTS.md` (agent instructions), then redeploy:

```bash
./deploy.sh
```

You can also edit the config live through the Control UI's Config tab — changes hot-reload without a restart for most settings.

## Teardown

```bash
./deploy.sh --delete
```

Removes all OpenClaw resources (Deployment, Service, ConfigMap, PVC, Route, Secret) from the namespace. The namespace itself is not deleted.
