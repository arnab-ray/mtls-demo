#!/usr/bin/env bash
# Bring up a local minikube + Istio (sidecar mode) environment, build the app
# image into it, and deploy the app + Postgres with mTLS enforced.
set -euo pipefail

NS="mtls-demo"
IMAGE="${IMAGE:-mtls-demo:latest}"
BUILD_IMAGE="${BUILD_IMAGE:-true}"
ISTIO_PROFILE="${ISTIO_PROFILE:-default}"

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
  # `minikube start` hang on SSH. Recreate it with a bounded wait, and retry:
  # vfkit occasionally boots a VM that never becomes reachable on its NAT IP.
  for attempt in 1 2 3; do
    echo "==> No usable cluster; recreating minikube profile (attempt $attempt/3)"
    minikube delete >/dev/null 2>&1 || true
    # Cap the hang: default minikube wait-timeout is 6 minutes per component.
    minikube start --cpus=2 --memory=2048 --wait-timeout=3m || true
    minikube update-context >/dev/null 2>&1 || true
    cluster_ready && break
  done
fi

# Fail fast if the kubeconfig was rewritten while minikube was starting;
# otherwise every later kubectl call would try localhost:8080 and hang/fail.
if ! cluster_ready; then
  echo "ERROR: minikube did not produce a usable context in $KUBECONFIG_FILE" >&2
  echo "       try: KUBECONFIG=$KUBECONFIG_FILE minikube update-context" >&2
  exit 1
fi

if ! kubectl get ns istio-system >/dev/null 2>&1; then
  echo "==> Installing Istio (profile: $ISTIO_PROFILE)"
  istioctl install --set profile="$ISTIO_PROFILE" -y
fi

echo "==> Waiting for istiod"
kubectl -n istio-system wait --for=condition=available \
  --timeout=180s deployment/istiod

if [[ "$BUILD_IMAGE" == "true" ]]; then
  echo "==> Building image: $IMAGE"
  if [[ "$(kubectl config current-context)" == "minikube" ]]; then
    need minikube
    if command -v podman >/dev/null 2>&1; then
      # minikube disables Docker in the VM when using containerd, so
      # `minikube image build` would hang. Build locally with Podman and
      # load the archive into minikube's containerd instead.
      if ! podman info >/dev/null 2>&1; then
        echo "==> Starting podman machine"
        podman machine start
      fi
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
      minikube image load "$ARCHIVE"
      if [[ "$SRC_REF" != "$TARGET_REF" ]]; then
        minikube ssh -- sudo ctr -n k8s.io images tag "$SRC_REF" "$TARGET_REF"
      fi
      rm -f "$ARCHIVE"
      trap - EXIT
    elif command -v docker >/dev/null 2>&1; then
      need docker
      docker build -t "$IMAGE" .
      minikube image load "$IMAGE"
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

echo
echo "Setup complete. Run ./verify.sh to prove mTLS end to end."
