#!/usr/bin/env bash
# Deploy OpenClaw to an existing OpenShift namespace.
#
# Secrets are generated in a temp directory and applied server-side.
# No secret material is ever written to the repo checkout.
#
# Usage:
#   ./deploy.sh                          # Deploy (requires API key in env or secret already in cluster)
#   ./deploy.sh --create-secret          # Create or update the Secret from env vars
#   ./deploy.sh --show-token             # Print the gateway token after deploy
#   ./deploy.sh --kubeconfig <path>      # Use a specific kubeconfig file
#   ./deploy.sh --delete                 # Remove OpenClaw resources from the namespace
#
# Required environment:
#   OPENCLAW_NAMESPACE   Target OpenShift namespace (must already exist)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="$SCRIPT_DIR/manifests"

SHOW_TOKEN=false
MODE="deploy"

# ---------------------------------------------------------------------------
# Argument parsing (before prerequisites so --kubeconfig is set early)
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      cat <<'HELP'
Usage: ./deploy.sh [OPTION]

  (no args)            Deploy OpenClaw (creates secret from env if needed)
  --create-secret      Create or update the Secret from env vars without deploying
  --show-token         Print the gateway token after deploy or secret creation
  --kubeconfig <path>  Path to kubeconfig file (falls back to KUBECONFIG env, then ~/.kube/config)
  --delete             Delete OpenClaw resources from the namespace
  -h, --help           Show this help

Required environment:
  OPENCLAW_NAMESPACE     Target OpenShift namespace (must already exist)

  Export at least one provider API key (for first deploy):
    ANTHROPIC_API_KEY, GEMINI_API_KEY, OPENAI_API_KEY, OPENROUTER_API_KEY
HELP
      exit 0
      ;;
    --kubeconfig)
      [[ -z "${2:-}" ]] && { echo "Missing argument for --kubeconfig" >&2; exit 1; }
      export KUBECONFIG="$2"
      shift
      ;;
    --create-secret)
      MODE="create-secret"
      ;;
    --delete)
      MODE="delete"
      ;;
    --show-token)
      SHOW_TOKEN=true
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Run ./deploy.sh --help for usage." >&2
      exit 1
      ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
for cmd in oc openssl; do
  command -v "$cmd" &>/dev/null || { echo "Missing: $cmd" >&2; exit 1; }
done

if [[ -z "${OPENCLAW_NAMESPACE:-}" ]]; then
  echo "OPENCLAW_NAMESPACE is not set." >&2
  echo "" >&2
  echo "Export the target namespace and re-run:" >&2
  echo "  export OPENCLAW_NAMESPACE=\"my-namespace\"" >&2
  echo "  ./deploy.sh" >&2
  exit 1
fi
NS="$OPENCLAW_NAMESPACE"

oc whoami &>/dev/null || { echo "Cannot connect to cluster. Check kubeconfig." >&2; exit 1; }
oc get namespace "$NS" &>/dev/null || { echo "Namespace '$NS' not found or not accessible." >&2; exit 1; }

# ---------------------------------------------------------------------------
# --delete
# ---------------------------------------------------------------------------
if [[ "$MODE" == "delete" ]]; then
  echo "Deleting OpenClaw resources from namespace '$NS'..."
  oc delete -k "$MANIFESTS" -n "$NS" --ignore-not-found
  oc delete secret openclaw-secrets -n "$NS" --ignore-not-found
  echo "Done."
  exit 0
fi

# ---------------------------------------------------------------------------
# Create and apply Secret to the cluster
# ---------------------------------------------------------------------------
_apply_secret() {
  local TMP_DIR
  local EXISTING_SECRET=false
  local EXISTING_TOKEN=""
  local ANTHROPIC_VALUE=""
  local OPENAI_VALUE=""
  local GEMINI_VALUE=""
  local OPENROUTER_VALUE=""
  local TOKEN
  local SECRET_MANIFEST
  TMP_DIR="$(mktemp -d)"
  chmod 700 "$TMP_DIR"
  trap 'rm -rf "$TMP_DIR"' EXIT

  if oc get secret openclaw-secrets -n "$NS" &>/dev/null; then
    EXISTING_SECRET=true
    EXISTING_TOKEN="$(oc get secret openclaw-secrets -n "$NS" -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' | base64 -d)"
    ANTHROPIC_VALUE="$(oc get secret openclaw-secrets -n "$NS" -o jsonpath='{.data.ANTHROPIC_API_KEY}' 2>/dev/null | base64 -d)"
    OPENAI_VALUE="$(oc get secret openclaw-secrets -n "$NS" -o jsonpath='{.data.OPENAI_API_KEY}' 2>/dev/null | base64 -d)"
    GEMINI_VALUE="$(oc get secret openclaw-secrets -n "$NS" -o jsonpath='{.data.GEMINI_API_KEY}' 2>/dev/null | base64 -d)"
    OPENROUTER_VALUE="$(oc get secret openclaw-secrets -n "$NS" -o jsonpath='{.data.OPENROUTER_API_KEY}' 2>/dev/null | base64 -d)"
  fi

  TOKEN="${EXISTING_TOKEN:-$(openssl rand -hex 32)}"
  ANTHROPIC_VALUE="${ANTHROPIC_API_KEY:-$ANTHROPIC_VALUE}"
  OPENAI_VALUE="${OPENAI_API_KEY:-$OPENAI_VALUE}"
  GEMINI_VALUE="${GEMINI_API_KEY:-$GEMINI_VALUE}"
  OPENROUTER_VALUE="${OPENROUTER_API_KEY:-$OPENROUTER_VALUE}"
  SECRET_MANIFEST="$TMP_DIR/secrets.yaml"

  printf '%s' "$TOKEN" > "$TMP_DIR/OPENCLAW_GATEWAY_TOKEN"
  printf '%s' "$ANTHROPIC_VALUE" > "$TMP_DIR/ANTHROPIC_API_KEY"
  printf '%s' "$OPENAI_VALUE" > "$TMP_DIR/OPENAI_API_KEY"
  printf '%s' "$GEMINI_VALUE" > "$TMP_DIR/GEMINI_API_KEY"
  printf '%s' "$OPENROUTER_VALUE" > "$TMP_DIR/OPENROUTER_API_KEY"
  chmod 600 \
    "$TMP_DIR/OPENCLAW_GATEWAY_TOKEN" \
    "$TMP_DIR/ANTHROPIC_API_KEY" \
    "$TMP_DIR/OPENAI_API_KEY" \
    "$TMP_DIR/GEMINI_API_KEY" \
    "$TMP_DIR/OPENROUTER_API_KEY"

  oc create secret generic openclaw-secrets \
    -n "$NS" \
    --from-file=OPENCLAW_GATEWAY_TOKEN="$TMP_DIR/OPENCLAW_GATEWAY_TOKEN" \
    --from-file=ANTHROPIC_API_KEY="$TMP_DIR/ANTHROPIC_API_KEY" \
    --from-file=OPENAI_API_KEY="$TMP_DIR/OPENAI_API_KEY" \
    --from-file=GEMINI_API_KEY="$TMP_DIR/GEMINI_API_KEY" \
    --from-file=OPENROUTER_API_KEY="$TMP_DIR/OPENROUTER_API_KEY" \
    --dry-run=client \
    -o yaml > "$SECRET_MANIFEST"
  chmod 600 "$SECRET_MANIFEST"

  oc apply --server-side --field-manager=openclaw -f "$SECRET_MANIFEST" >/dev/null
  rm -rf "$TMP_DIR"
  trap - EXIT

  if $EXISTING_SECRET; then
    echo "Secret updated in namespace '$NS'. Existing gateway token preserved."
  else
    echo "Secret created in namespace '$NS'."
  fi

  if $SHOW_TOKEN; then
    echo "Gateway token: $TOKEN"
  else
    echo "Gateway token stored in Secret only."
    echo "Retrieve it with:"
    echo "  oc get secret openclaw-secrets -n $NS -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' | base64 -d && echo"
  fi
}

# ---------------------------------------------------------------------------
# --create-secret
# ---------------------------------------------------------------------------
if [[ "$MODE" == "create-secret" ]]; then
  HAS_KEY=false
  for key in ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY OPENROUTER_API_KEY; do
    if [[ -n "${!key:-}" ]]; then
      HAS_KEY=true
      echo "  Found $key in environment"
    fi
  done

  if ! $HAS_KEY; then
    echo "No API keys found in environment. Export at least one and re-run:"
    echo "  export <PROVIDER>_API_KEY=\"...\"  (ANTHROPIC, GEMINI, OPENAI, or OPENROUTER)"
    echo "  ./deploy.sh --create-secret"
    exit 1
  fi

  _apply_secret
  echo ""
  echo "Now run:"
  echo "  ./deploy.sh"
  exit 0
fi

# ---------------------------------------------------------------------------
# Check that the secret exists in the cluster
# ---------------------------------------------------------------------------
if ! oc get secret openclaw-secrets -n "$NS" &>/dev/null; then
  HAS_KEY=false
  for key in ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY OPENROUTER_API_KEY; do
    [[ -n "${!key:-}" ]] && HAS_KEY=true
  done

  if $HAS_KEY; then
    echo "Creating secret from environment..."
    _apply_secret
    echo ""
  else
    echo "No secret found and no API keys in environment."
    echo ""
    echo "Export at least one provider API key and re-run:"
    echo "  export <PROVIDER>_API_KEY=\"...\"  (ANTHROPIC, GEMINI, OPENAI, or OPENROUTER)"
    echo "  ./deploy.sh"
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------
echo "Deploying to namespace '$NS'..."
oc apply -k "$MANIFESTS" -n "$NS"
oc rollout restart deployment/openclaw -n "$NS" 2>/dev/null || true
echo ""
echo "Waiting for rollout..."
oc rollout status deployment/openclaw -n "$NS" --timeout=300s
echo ""

ROUTE_HOST="$(oc get route openclaw -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null)"

echo "Done. Access the gateway:"
if [[ -n "$ROUTE_HOST" ]]; then
  echo "  https://$ROUTE_HOST"
else
  echo "  oc port-forward svc/openclaw 18789:18789 -n $NS"
  echo "  open http://localhost:18789"
fi
echo ""
if $SHOW_TOKEN; then
  echo "Gateway token (paste into Control UI):"
  echo "  $(oc get secret openclaw-secrets -n "$NS" -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' | base64 -d)"
  echo ""
fi
echo "Retrieve the gateway token with:"
echo "  oc get secret openclaw-secrets -n $NS -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' | base64 -d && echo"
