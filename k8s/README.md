# App -> Postgres over Istio mTLS (sidecar mode)

For a project-level overview, see the [root README](../README.md).

## What this does

Both the Spring Boot app and PostgreSQL run as Kubernetes workloads in the
`mtls-demo` namespace, which is labelled `istio-injection: enabled`. Each pod
gets an `istio-proxy` sidecar. The app keeps using a **plaintext** JDBC URL
(`sslmode=disable`); its sidecar encrypts the connection with mTLS, the
Postgres sidecar terminates it, and plaintext is forwarded to Postgres over
loopback. No application or Postgres TLS configuration is needed.

Traffic flow:

```
host --HTTP--> ingress gateway ==mTLS==> app sidecar --plaintext--> app container
app container --plaintext--> app sidecar ==mTLS==> postgres sidecar --plaintext--> postgres:5432
```

Security is enforced with:

- `PeerAuthentication` in `STRICT` mode for the whole namespace.
- `AuthorizationPolicy` on the Postgres workload: only the service account
  `mtls-demo-app` may connect, and only to port `5432`.

Because the namespace is STRICT, kubelet HTTP probes to the app would be
rejected by its sidecar. The pod carries
`sidecar.istio.io/rewriteAppHTTPProbers: "true"` so Istio rewrites them to the
local pilot-agent port. That requires `/actuator/health`, hence the
`spring-boot-starter-actuator` dependency added to `pom.xml`. Postgres uses
`exec` (`pg_isready`) probes, which do not traverse the sidecar.

## Files

| File | Purpose |
| --- | --- |
| `namespace.yaml` | Namespace with `istio-injection=enabled` |
| `secrets.yaml` | Demo DB credentials shared by both workloads |
| `postgresql.yaml` | Postgres ServiceAccount, Service (`tcp-postgresql` port) and Deployment |
| `app.yaml` | App ServiceAccount, Service and Deployment with the JDBC URL |
| `istio-security.yaml` | STRICT `PeerAuthentication`, DB-only `AuthorizationPolicy`, explicit `ISTIO_MUTUAL` `DestinationRule` |
| `ingress.yaml` | `Gateway`, `VirtualService` and `ISTIO_MUTUAL` `DestinationRule` exposing the app via `istio-ingressgateway`; applied by `setup.sh` |

## Run

From the repository root:

```bash
./setup.sh     # starts minikube if needed, installs Istio, builds the image, deploys, applies the VirtualService
./verify.sh    # proves sidecars, mTLS certs, allowed/denied DB access, app HTTP via ingress
./teardown.sh  # deletes the demo namespace, stops minikube
```

All scripts use `~/.kube/mtls-demo-config` as their kubeconfig (override with
`KUBECONFIG_FILE`), so tools that rewrite `~/.kube/config` cannot drop the
minikube context while the demo is running.

Environment overrides for `setup.sh`:

- `IMAGE=registry.example.com/mtls-demo:1.0` — use a pushed image instead of
  the locally built `mtls-demo:latest` (the script runs `kubectl set image`).
- `BUILD_IMAGE=false` — skip building (image already present in the cluster).
- `ISTIO_PROFILE=demo` — install a different Istio profile (default: `default`).
  It must include an ingress gateway (e.g. `default` or `demo`); `setup.sh`
  patches `istio-ingressgateway` to `NodePort`, including on an existing install.
- `MINIKUBE_DRIVER=vfkit` — force a driver when recreating the profile
  (default: `podman` if installed, otherwise minikube's auto-selection).
- `MINIKUBE_PROFILE=minikube` — use a different minikube profile name.

If no cluster is reachable, `setup.sh` waits briefly for an existing minikube
VM to finish booting; if it is still unusable (a stale profile can leave an old
IP and make `minikube start` hang on SSH), the profile is recreated and
minikube is started with 2 CPUs / 2 GiB. The Podman machine is started first,
and stale Podman container/volume entries for the profile are removed, so a
previous failed start cannot leave `volume with name minikube already exists`
behind. Preferring the Podman driver also avoids vfkit ISO boots that can
kernel-panic on some macOS hosts.
On minikube it builds locally with Podman (or Docker as a fallback) and loads
the image into minikube's containerd as an archive. `minikube image build` is
deliberately avoided: minikube disables Docker in the VM with the containerd
runtime, which makes that command hang. For a non-minikube cluster it needs
`docker` to build and, for a registry-qualified image, to push.

## Teardown

`./teardown.sh` performs a soft shutdown by default: it deletes the `mtls-demo`
namespace (app, Postgres, secret, Istio policies and the Gateway/VirtualService)
and stops the minikube VM while keeping it for the next run. It is safe to run
when nothing is deployed.

Environment overrides:

- `FULL=true` — also uninstall Istio and delete the minikube VM entirely
  (shortcut for the two options below).
- `DELETE_NAMESPACE=false` — keep the namespace/workloads.
- `UNINSTALL_ISTIO=true` — remove the Istio control plane as well.
- `STOP_MINIKUBE=false` — leave minikube running.
- `DELETE_MINIKUBE=true` — remove the minikube VM; this also skips in-cluster
  cleanup since the whole cluster goes away.
- `NS` / `ISTIO_NS` / `MINIKUBE_PROFILE` — override the default names.

Examples:

```bash
./teardown.sh                    # soft stop
FULL=true ./teardown.sh          # remove everything
DELETE_MINIKUBE=true ./teardown.sh  # just throw away the local cluster
```

The original `docker-compose.yaml` is not managed by these scripts; use
`docker compose down` separately if you started that stack.

## Reaching the app

`setup.sh` applies `ingress.yaml` and patches `istio-ingressgateway` to
`NodePort`. With minikube's Docker driver the node IP is not reachable from the
host, though, so curling that NodePort hangs. Port-forward the gateway Service
instead; the request still goes through the Gateway/VirtualService and over
mTLS to the app. Direct `kubectl` commands need the demo kubeconfig exported
first (the scripts export it only for themselves):

```bash
export KUBECONFIG="$HOME/.kube/mtls-demo-config"
kubectl -n istio-system port-forward svc/istio-ingressgateway 8080:80
```

Then, in another shell, call the API with the gateway host header:

```bash
curl -H 'Host: mtls-demo.local' 'http://127.0.0.1:8080/actuator/health'
curl -H 'Host: mtls-demo.local' -X POST 'http://127.0.0.1:8080/users/v1' \
  -H 'Content-Type: application/json' \
  -d '{"name":"Ada","email":"ada@example.com"}'
curl -H 'Host: mtls-demo.local' 'http://127.0.0.1:8080/users/v1?email=ada@example.com'
```

If your driver routes the node IP, the NodePort URL printed by `setup.sh` is an
alternative:

```bash
GW_IP="$(kubectl get nodes \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
GW_PORT="$(kubectl -n istio-system get svc istio-ingressgateway \
  -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')"
echo "http://$GW_IP:$GW_PORT/  (Host: mtls-demo.local)"
```

`ingress.yaml` creates a `Gateway` bound to the existing `istio-ingressgateway`
in `istio-system`, a `VirtualService` routing host `mtls-demo.local` to
`mtls-demo-app:8080`, and an `ISTIO_MUTUAL` `DestinationRule` for the app. The
last part matters: the ingress gateway is a mesh workload, so it initiates mTLS
to the app and the namespace-wide STRICT policy remains satisfied. The app
Service itself stays `ClusterIP`; sending plaintext HTTP straight to an app
port would be rejected by its sidecar.

`./verify.sh` starts its own short-lived port-forward for the HTTP checks and
caps each curl with a connect/read timeout, so a stale NodePort address can no
longer make it hang (`VERIFY_GW_PORT` overrides the local port 18080).
Adding `127.0.0.1 mtls-demo.local` to `/etc/hosts` lets you omit the `Host`
header while the port-forward runs. `./teardown.sh` removes the
Gateway/VirtualService with the namespace.

### Local access troubleshooting

- `no route to host` for `192.168.64.2:22` or `:8443` is typically a transient
  vfkit networking issue. Check with `nc -z -G 3 192.168.64.2 8443` and retry.
- `minikube status` SSHes into the VM for a disk-capacity check, which can fail
  while Kubernetes is healthy. Prefer `kubectl get nodes`,
  `kubectl -n mtls-demo get pods` and `./verify.sh`.
- Run `minikube status` with `KUBECONFIG="$HOME/.kube/mtls-demo-config"`;
  without it, minikube reads `~/.kube/config` (often rewritten by Rancher
  Desktop) and reports `kubeconfig: Misconfigured`.
- Never Ctrl+C `setup.sh` during `minikube start` — that leaves a stale profile
  and an empty kubeconfig. The script retries with a bounded wait; see the
  root README for the full troubleshooting list.

## Notes / caveats

- Postgres data is on an `emptyDir` (lost when the DB pod is recreated). The
  Kubernetes deployment sets `ddl-auto=update` plus `generate-ddl=true` so the
  schema is recreated after a DB restart and is not dropped during a rolling
  restart; `application.yaml` sets `generate-ddl: false`, which would otherwise
  suppress Hibernate schema actions. Docker Compose still uses `create-drop`.
- Both pods set `proxy.istio.io/config` with `holdApplicationUntilProxyStarts`
  so Hibernate does not attempt a JDBC connection before the sidecar is ready.
- The Service port is named `tcp-postgresql` so Istio treats it as opaque TCP
  and does not try HTTP protocol sniffing.
- The `DestinationRule` sets `ISTIO_MUTUAL` explicitly for extra clarity;
  auto-mTLS between the two sidecars would also work. Changing it to
  `DISABLE` or `SIMPLE` would break the STRICT policy.
- To tear down, use `./teardown.sh` (see above).
