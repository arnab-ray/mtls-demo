#!/usr/bin/env bash
# Reverse setup.sh: delete the demo namespace (including the Gateway and
# VirtualService), optionally uninstall Istio, and stop (or delete) the local
# minikube cluster.
set -euo pipefail

NS="${NS:-mtls-demo}"
ISTIO_NS="${ISTIO_NS:-istio-system}"
MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-minikube}"

# FULL=true is a shortcut for the destructive options below. Individual
# settings always win over the shortcut.
FULL="${FULL:-false}"
DELETE_NAMESPACE="${DELETE_NAMESPACE:-true}"
UNINSTALL_ISTIO="${UNINSTALL_ISTIO:-$FULL}"
STOP_MINIKUBE="${STOP_MINIKUBE:-true}"
DELETE_MINIKUBE="${DELETE_MINIKUBE:-$FULL}"

KUBECONFIG_FILE="${KUBECONFIG_FILE:-$HOME/.kube/mtls-demo-config}"
export KUBECONFIG="$KUBECONFIG_FILE"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required command not found: $1" >&2; exit 1; }
}

CLUSTER_UP=false
if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
  CLUSTER_UP=true
fi

if [[ "$DELETE_MINIKUBE" == "true" ]]; then
  echo "==> DELETE_MINIKUBE=true: skipping in-cluster cleanup (cluster will be removed)"
else
  if [[ "$DELETE_NAMESPACE" == "true" ]]; then
    if [[ "$CLUSTER_UP" == "true" ]]; then
      if kubectl get ns "$NS" >/dev/null 2>&1; then
        echo "==> Deleting namespace $NS (app, Postgres, policies, secret)"
        kubectl delete ns "$NS" --timeout=180s
      else
        echo "==> Namespace $NS not present; nothing to delete"
      fi
    else
      echo "==> Cluster not reachable; skipping namespace deletion"
    fi
  else
    echo "==> Keeping namespace $NS (DELETE_NAMESPACE=$DELETE_NAMESPACE)"
  fi

  if [[ "$UNINSTALL_ISTIO" == "true" ]]; then
    if [[ "$CLUSTER_UP" == "true" ]] && kubectl get ns "$ISTIO_NS" >/dev/null 2>&1; then
      need istioctl
      echo "==> Uninstalling Istio"
      istioctl uninstall --purge -y
      echo "==> Removing $ISTIO_NS leftovers"
      kubectl delete ns "$ISTIO_NS" --ignore-not-found --timeout=180s
    else
      echo "==> Istio not present or cluster unreachable; skipping uninstall"
    fi
  else
    echo "==> Keeping Istio (UNINSTALL_ISTIO=$UNINSTALL_ISTIO)"
  fi
fi

if command -v minikube >/dev/null 2>&1; then
  if minikube status -p "$MINIKUBE_PROFILE" >/dev/null 2>&1; then
    if [[ "$DELETE_MINIKUBE" == "true" ]]; then
      echo "==> Deleting minikube profile $MINIKUBE_PROFILE"
      minikube delete -p "$MINIKUBE_PROFILE"
    elif [[ "$STOP_MINIKUBE" == "true" ]]; then
      echo "==> Stopping minikube profile $MINIKUBE_PROFILE"
      minikube stop -p "$MINIKUBE_PROFILE"
    else
      echo "==> Leaving minikube running (STOP_MINIKUBE=$STOP_MINIKUBE)"
    fi
  else
    echo "==> minikube profile '$MINIKUBE_PROFILE' is not running"
  fi
else
  echo "==> minikube not installed; skipping VM cleanup"
fi

if [[ "$DELETE_MINIKUBE" == "true" && -f "$KUBECONFIG_FILE" ]]; then
  echo "==> Removing demo kubeconfig $KUBECONFIG_FILE"
  rm -f "$KUBECONFIG_FILE"
fi

echo
echo "==> Remaining demo resources (if any)"
if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
  kubectl get ns "$NS" "$ISTIO_NS" 2>/dev/null || echo "   none"
fi

echo
echo "Teardown complete."
