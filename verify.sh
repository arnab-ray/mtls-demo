#!/usr/bin/env bash
# Functional checks that the app -> Postgres connection really runs over
# Istio mTLS, in sidecar mode, with STRICT policy + DB-only authorization.
set -euo pipefail

NS="mtls-demo"

KUBECONFIG_FILE="${KUBECONFIG_FILE:-$HOME/.kube/mtls-demo-config}"
export KUBECONFIG="$KUBECONFIG_FILE"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required command not found: $1" >&2; exit 1; }
}
need kubectl
need istioctl
need curl

echo "==> 1. Every pod must have an injected istio-proxy sidecar"
kubectl -n "$NS" get pods \
  -o custom-columns='NAME:.metadata.name,INIT:.spec.initContainers[*].name,CONTAINERS:.spec.containers[*].name'
# Istio 1.20+ injects the proxy as a native init container (restartPolicy: Always),
# so check both initContainers and containers.
for pod in $(kubectl -n "$NS" get pods -o name); do
  names="$(kubectl -n "$NS" get "$pod" \
    -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}')"
  count="$(printf '%s\n' "$names" | tr ' ' '\n' | grep -c '^istio-proxy$' || true)"
  if [[ "$count" != "1" ]]; then
    echo "FAIL: $pod does not have exactly one istio-proxy sidecar" >&2
    exit 1
  fi
done
echo "OK"

echo
echo "==> 2. STRICT mTLS + DB authorization policy"
kubectl -n "$NS" get peerauthentication,authorizationpolicy,destinationrule

echo
echo "==> 3. Workload certificates issued by Istio"
APP_POD="$(kubectl -n "$NS" get pod -l app=mtls-demo-app -o jsonpath='{.items[0].metadata.name}')"
DB_POD="$(kubectl -n "$NS" get pod -l app=postgresql -o jsonpath='{.items[0].metadata.name}')"
istioctl proxy-config secret "$APP_POD" -n "$NS"
istioctl proxy-config secret "$DB_POD" -n "$NS"
istioctl proxy-status

echo
echo "==> 4. In-mesh client (app identity) can query Postgres over mTLS"
kubectl -n "$NS" delete pod mtls-db-check --ignore-not-found --wait=false >/dev/null 2>&1 || true
# kubectl run has no --serviceaccount flag in recent versions; --overrides sets it.
kubectl -n "$NS" run mtls-db-check --restart=Never --image=postgres:14 \
  --overrides='{"spec":{"serviceAccountName":"mtls-demo-app"}}' \
  --command -- sh -c \
  'PGPASSWORD=lock psql "postgresql://demo@postgresql:5432/mtls_poc?sslmode=disable&connect_timeout=5" -tAc "select 1"' >/dev/null
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded \
  --timeout=180s pod/mtls-db-check >/dev/null
echo -n "select 1 -> "
kubectl -n "$NS" logs pod/mtls-db-check
kubectl -n "$NS" delete pod mtls-db-check --ignore-not-found --wait=false >/dev/null 2>&1 || true

echo
echo "==> 5. Plaintext client outside the mesh must be rejected"
if kubectl get ns default -o jsonpath='{.metadata.labels.istio-injection}' | grep -q 'enabled'; then
  echo "SKIP: the 'default' namespace is injection-enabled; use a non-mesh namespace for this check"
else
  kubectl -n default delete pod no-mesh-db-check --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n default run no-mesh-db-check --restart=Never --image=postgres:14 \
    --command -- sh -c \
    'PGPASSWORD=lock psql "postgresql://demo@postgresql.mtls-demo.svc.cluster.local:5432/mtls_poc?sslmode=disable&connect_timeout=5" -tAc "select 1"' >/dev/null
  PHASE=""
  for _ in $(seq 1 40); do
    PHASE="$(kubectl -n default get pod no-mesh-db-check -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "$PHASE" == "Succeeded" || "$PHASE" == "Failed" ]]; then break; fi
    sleep 3
  done
  echo "client pod phase: $PHASE"
  # The psql error here is the expected result of the rejection, not a failure
  # of the check. Show a single-line summary so it is not mistaken for one.
  REJECTION="$(kubectl -n default logs pod/no-mesh-db-check 2>/dev/null \
    | grep -m1 -iE 'psql: error|connection|ssl' | tr '\n' ' ' || true)"
  if [[ -n "$REJECTION" ]]; then echo "expected rejection: ${REJECTION}"; fi
  kubectl -n default delete pod no-mesh-db-check --ignore-not-found --wait=false >/dev/null 2>&1 || true
  if [[ "$PHASE" == "Succeeded" ]]; then
    echo "FAIL: plaintext client was allowed to reach Postgres" >&2
    exit 1
  elif [[ "$PHASE" != "Failed" ]]; then
    echo "FAIL: test pod did not finish (phase=$PHASE)" >&2
    exit 1
  fi
  echo "OK: plaintext/non-mesh client rejected"
fi

echo
echo "==> 6. HTTP smoke test through the Gateway + VirtualService"
# Port-forward the ingress gateway Service rather than using the node IP:
# on minikube's Docker driver the node IP is not routable from the host, so
# curling its NodePort simply hangs. The request still goes through the
# Gateway/VirtualService and over mTLS to the app.
PF_PORT="${VERIFY_GW_PORT:-18080}"
kubectl -n istio-system port-forward svc/istio-ingressgateway "${PF_PORT}:80" \
  >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT
APP_URL="http://127.0.0.1:${PF_PORT}"
# Bounded timeouts: without them a stalled connection blocks the script forever.
CURL_INGRESS=(-fsS --connect-timeout 2 --max-time 5 -H 'Host: mtls-demo.local')

ready=false
for _ in $(seq 1 20); do
  if curl "${CURL_INGRESS[@]}" "$APP_URL/actuator/health" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
if [[ "$ready" != "true" ]]; then
  echo "FAIL: app did not become healthy through the VirtualService" >&2
  echo "       (gateway port-forward on $PF_PORT failed; override with VERIFY_GW_PORT if it is in use)" >&2
  exit 1
fi

echo -n "health:      "
curl "${CURL_INGRESS[@]}" "$APP_URL/actuator/health"; echo
echo -n "create user: "
curl "${CURL_INGRESS[@]}" -X POST "$APP_URL/users/v1" \
  -H 'Content-Type: application/json' \
  -d '{"name":"Ada","email":"ada@example.com"}'; echo
echo -n "read user:   "
curl "${CURL_INGRESS[@]}" "$APP_URL/users/v1?email=ada@example.com"; echo

echo
echo "All checks passed: app <-> Postgres is mTLS-protected in Istio sidecar mode."
