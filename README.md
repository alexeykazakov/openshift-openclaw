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

The script creates a Secret (gateway token + API keys), applies the Kustomize manifests, waits for the rollout, and prints the Route URL.

## Access

Open the Route URL printed by the deploy script. Paste the gateway token into the Control UI to authenticate.

To retrieve the token later:

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

## Vertex AI (Anthropic / Gemini via GCP)

OpenClaw supports routing Anthropic and Gemini requests through Google Vertex AI using the `google-vertex` provider. This uses GCP Application Default Credentials (ADC) instead of direct API keys.

### 1. Create a GCP service account

In the GCP Console (or with `gcloud`), create a service account with the **Vertex AI User** role and download a JSON key file.

### 2. Deploy with the key file

```bash
export OPENCLAW_NAMESPACE="my-namespace"
export GCP_SA_KEY_FILE="/path/to/sa-key.json"

./deploy.sh --kubeconfig /path/to/kubeconfig --show-token
```

The script creates a separate `openclaw-gcp-credentials` secret from the key file and the deployment mounts it at the path referenced by `GOOGLE_APPLICATION_CREDENTIALS`.

### 3. Configure the model provider

After deploying, open the Control UI and set the default provider to `google-vertex`, or edit `manifests/configmap.yaml` to add models under the `google-vertex` provider, e.g.:

```json
{
  "models": {
    "default": "google-vertex/gemini-3-flash-preview"
  }
}
```

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
export GCP_PROJECT_ID="my-gcp-project"    # required for ADC user credentials

./deploy.sh --kubeconfig /path/to/kubeconfig --show-token
```

`GCP_PROJECT_ID` is needed because personal ADC credentials don't contain a project ID (unlike service account keys which do). Switch to a proper service account key for production.

### 4. Add the key to an existing deployment

If OpenClaw is already deployed and you want to add Vertex AI support later:

```bash
export OPENCLAW_NAMESPACE="my-namespace"
export GCP_SA_KEY_FILE="/path/to/sa-key.json"

./deploy.sh --create-secret
./deploy.sh
```

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
