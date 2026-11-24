#!/usr/bin/env bash
# Bring up a local minikube + Istio (sidecar mode) environment, build the app
# image into it, and deploy the app + Postgres with mTLS enforced.
set -euo pipefail

NS="mtls-demo"
IMAGE="${IMAGE:-mtls-demo:latest}"
BUILD_IMAGE="${BUILD_IMAGE:-true}"
ISTIO_PROFILE="${ISTIO_PROFILE:-default}"
MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-minikube}"
# Empty = prefer Podman when it is installed (same engine used for the image
# build), otherwise let minikube auto-select. Set e.g. MINIKUBE_DRIVER=vfkit
# to force a different driver.
MINIKUBE_DRIVER="${MINIKUBE_DRIVER:-}"

# Keep this demo's kubeconfig separate: other tools (e.g. Rancher Desktop)
# rewrite ~/.kube/config and silently drop the minikube context.
KUBECONFIG_FILE="${KUBECONFIG_FILE:-$HOME/.kube/mtls-demo-config}"
export KUBECONFIG="$KUBECONFIG_FILE"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required command not found: $1" >&2; exit 1; }
}

need kubectl
need istioctl

cluster_ready() {
  kubectl cluster-info >/dev/null 2>&1
}

EFFECTIVE_DRIVER="$MINIKUBE_DRIVER"
if [[ -z "$EFFECTIVE_DRIVER" ]] && command -v podman >/dev/null 2>&1; then
  EFFECTIVE_DRIVER="podman"
fi

MINIKUBE_DRIVER_ARGS=()
if [[ -n "$EFFECTIVE_DRIVER" ]]; then
  MINIKUBE_DRIVER_ARGS+=(--driver="$EFFECTIVE_DRIVER")
fi

start_podman_machine() {
  command -v podman >/dev/null 2>&1 || return 0
  if ! podman info >/dev/null 2>&1; then
    echo "==> Starting podman machine"
    podman machine start
  fi
}

# A failed Podman-driver start can leave a named volume behind after its
# container is gone; the next `minikube start` then reports "volume with name
# minikube already exists" and fails to restart a container that is missing.
cleanup_stale_podman_minikube() {
  [[ "$EFFECTIVE_DRIVER" == "podman" ]] || return 0
  command -v podman >/dev/null 2>&1 || return 0
  echo "==> Cleaning stale Podman container/volume for '$MINIKUBE_PROFILE'"
  podman rm -f "$MINIKUBE_PROFILE" >/dev/null 2>&1 || true
  podman volume rm "$MINIKUBE_PROFILE" >/dev/null 2>&1 || true
}

if ! cluster_ready; then
  need minikube
  # An existing vfkit VM can still be booting; give it a moment before
  # concluding the profile is broken.
  echo "==> Cluster not ready yet; waiting briefly for an existing minikube VM"
  for _ in $(seq 1 10); do
    cluster_ready && break
    sleep 3
  done
fi

if ! cluster_ready; then
  # A stopped/half-provisioned profile can leave a stale IP behind, which makes
  # `minikube start` hang on SSH. Recreate it with a bounded wait, and retry.
  # Start Podman first: the Podman driver needs its machine running, and the
  # image build below needs it too (doing this later was too late).
  start_podman_machine
  for attempt in 1 2 3; do
    echo "==> No usable cluster; recreating minikube profile (attempt $attempt/3, driver: ${EFFECTIVE_DRIVER:-auto})"
    minikube -p "$MINIKUBE_PROFILE" delete >/dev/null 2>&1 || true
    cleanup_stale_podman_minikube
    # Cap the hang: default minikube wait-timeout is 6 minutes per component.
    minikube -p "$MINIKUBE_PROFILE" start \
      --cpus=2 --memory=2048 --wait-timeout=3m \
      "${MINIKUBE_DRIVER_ARGS[@]}" || true
    minikube -p "$MINIKUBE_PROFILE" update-context >/dev/null 2>&1 || true
    cluster_ready && break
  done
fi

# Fail fast if the kubeconfig was rewritten while minikube was starting;
# otherwise every later kubectl call would try localhost:8080 and hang/fail.
if ! cluster_ready; then
  echo "ERROR: minikube did not produce a usable context in $KUBECONFIG_FILE" >&2
  echo "       try: KUBECONFIG=$KUBECONFIG_FILE minikube -p $MINIKUBE_PROFILE update-context" >&2
  exit 1
fi

if ! kubectl get ns istio-system >/dev/null 2>&1; then
  echo "==> Installing Istio (profile: $ISTIO_PROFILE)"
  istioctl install --set profile="$ISTIO_PROFILE" \
    --set values.gateways.istio-ingressgateway.type=NodePort -y
fi

echo "==> Waiting for istiod"
kubectl -n istio-system wait --for=condition=available \
  --timeout=180s deployment/istiod

# The ingress gateway is the mesh entry point for k8s/ingress.yaml. A
# LoadBalancer gateway needs `minikube tunnel` (plus sudo) to get an
# EXTERNAL-IP; NodePort is reachable directly at the minikube node IP.
if ! kubectl -n istio-system get svc istio-ingressgateway >/dev/null 2>&1; then
  echo "ERROR: istio-ingressgateway not found; use an Istio profile that includes ingress gateways (e.g. default or demo)" >&2
  exit 1
fi
if [[ "$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.type}')" != "NodePort" ]]; then
  echo "==> Exposing istio-ingressgateway as a NodePort"
  kubectl -n istio-system patch svc istio-ingressgateway --type merge \
    -p '{"spec":{"type":"NodePort"}}' >/dev/null
fi
kubectl -n istio-system rollout status deployment/istio-ingressgateway --timeout=180s

if [[ "$BUILD_IMAGE" == "true" ]]; then
  echo "==> Building image: $IMAGE"
  if [[ "$(kubectl config current-context)" == "$MINIKUBE_PROFILE" ]]; then
    need minikube
    if command -v podman >/dev/null 2>&1; then
      # minikube disables Docker in the VM when using containerd, so
      # `minikube image build` would hang. Build locally with Podman and
      # load the archive into minikube's containerd instead.
      start_podman_machine
      podman build -t "$IMAGE" .

      if [[ "$IMAGE" == */* ]]; then
        SRC_REF="$IMAGE"
        TARGET_REF="$IMAGE"
      else
        SRC_REF="localhost/$IMAGE"
        TARGET_REF="docker.io/library/$IMAGE"
      fi

      ARCHIVE="${TMPDIR:-/tmp}/mtls-demo-image.tar"
      trap 'rm -f "$ARCHIVE"' EXIT
      podman save --format docker-archive -o "$ARCHIVE" "$SRC_REF"
      echo "==> Loading image into minikube"
      minikube -p "$MINIKUBE_PROFILE" image load "$ARCHIVE"
      if [[ "$SRC_REF" != "$TARGET_REF" ]]; then
        minikube -p "$MINIKUBE_PROFILE" ssh -- sudo ctr -n k8s.io images tag "$SRC_REF" "$TARGET_REF"
      fi
      rm -f "$ARCHIVE"
      trap - EXIT
    elif command -v docker >/dev/null 2>&1; then
      need docker
      docker build -t "$IMAGE" .
      minikube -p "$MINIKUBE_PROFILE" image load "$IMAGE"
    else
      echo "ERROR: need either podman or docker to build the image for minikube" >&2
      exit 1
    fi
  else
    need docker
    docker build -t "$IMAGE" .
    if [[ "$IMAGE" == */* ]]; then
      echo "==> Pushing $IMAGE"
      docker push "$IMAGE"
    fi
  fi
else
  echo "==> Skipping image build (BUILD_IMAGE=$BUILD_IMAGE)"
fi

echo "==> Applying manifests"
# Applied in dependency order so no resource references a missing namespace/secret.
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/secrets.yaml
kubectl apply -f k8s/postgresql.yaml
kubectl apply -f k8s/app.yaml
kubectl apply -f k8s/istio-security.yaml
kubectl apply -f k8s/ingress.yaml

if [[ "$IMAGE" != "mtls-demo:latest" ]]; then
  echo "==> Pointing deployment at $IMAGE"
  kubectl -n "$NS" set image deployment/mtls-demo-app "app=$IMAGE"
fi

echo "==> Waiting for rollout"
kubectl -n "$NS" rollout status deployment/postgresql --timeout=300s
kubectl -n "$NS" rollout status deployment/mtls-demo-app --timeout=300s

echo
echo "==> Pods (Istio 1.20+ lists istio-proxy under INIT as a native sidecar)"
kubectl -n "$NS" get pods \
  -o custom-columns='NAME:.metadata.name,INIT:.spec.initContainers[*].name,CONTAINERS:.spec.containers[*].name,READY:.status.conditions[?(@.type=="Ready")].status'

echo
echo "==> Security policy"
kubectl -n "$NS" get peerauthentication,authorizationpolicy,destinationrule

GW_HOST="$(kubectl get nodes \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
GW_PORT="$(kubectl -n istio-system get svc istio-ingressgateway \
  -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')"
if [[ -z "$GW_PORT" ]]; then
  GW_PORT="$(kubectl -n istio-system get svc istio-ingressgateway \
    -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')"
fi

echo
echo "==> Ingress (Gateway + VirtualService, host mtls-demo.local)"
kubectl -n "$NS" get gateways.networking.istio.io,virtualservices.networking.istio.io
echo
echo "    # Reliable from the host (also how verify.sh reaches the gateway):"
echo "    kubectl -n istio-system port-forward svc/istio-ingressgateway 8080:80"
echo "    curl -H 'Host: mtls-demo.local' http://127.0.0.1:8080/actuator/health"
if [[ -n "$GW_HOST" && -n "$GW_PORT" ]]; then
  echo
  echo "    # NodePort (may not be routable from the host with minikube's Docker driver):"
  echo "    curl -H 'Host: mtls-demo.local' http://${GW_HOST}:${GW_PORT}/actuator/health"
else
  echo "WARNING: could not determine ingress NodePort address; check 'kubectl -n istio-system get svc istio-ingressgateway'" >&2
fi

echo
echo "Setup complete. Run ./verify.sh to prove mTLS end to end."
