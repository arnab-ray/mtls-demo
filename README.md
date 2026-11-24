# mtls-demo

A small Spring Boot 4.2 / Java 21 REST service that stores users in PostgreSQL.
It doubles as a demo of an application-to-database connection secured with
**Istio mTLS in sidecar mode**.

## Layout

| Path | What it is |
| --- | --- |
| `src/main/java/io/arnab/mtlsdemo/` | Controller, service, JPA entity and repository |
| `src/main/resources/application.yaml` | Datasource and JPA settings |
| `Dockerfile` | Multi-stage image build |
| `docker-compose.yaml` | Local app + Postgres, no Kubernetes |
| `k8s/` | Kubernetes and Istio manifests; details in [`k8s/README.md`](k8s/README.md) |
| `k8s/ingress.yaml` | Gateway/VirtualService exposing the app through the Istio ingress gateway (applied by `setup.sh`) |
| `setup.sh` | Bring up minikube + Istio, build the image, deploy, expose the app through the VirtualService |
| `verify.sh` | Prove sidecars, mTLS certificates, DB access rules and HTTP ingress |
| `teardown.sh` | Remove workloads and ingress rules, stop/delete the cluster |
| `HELP.md` | Generated Spring Boot reference links |

## API

| Method | Path | Body / parameters |
| --- | --- | --- |
| `POST` | `/users/v1` | `{"name":"Ada","email":"ada@example.com"}` |
| `GET` | `/users/v1?email=...` | returns `{"id":...,"name":...,"email":...}` |
| `DELETE` | `/users/v1?email=...` | marks the user inactive |
| `GET` | `/actuator/health` | health check |

## Run locally with Docker Compose

```bash
docker compose up --build -d
curl -X POST localhost:8080/users/v1 -H 'Content-Type: application/json' \
  -d '{"name":"Ada","email":"ada@example.com"}'
curl 'localhost:8080/users/v1?email=ada@example.com'
docker compose down      # add -v to also delete the DB volume
```

## Run the Istio mTLS demo

Prerequisites: `kubectl`, `istioctl`; `minikube` if no cluster is already
configured. On minikube the image is built locally with Podman (or Docker, if
Podman is absent) and loaded into minikube's containerd — no `minikube image
build` is used, because that hangs when minikube disables Docker in the VM. If
a minikube profile is stale or still booting, `setup.sh` waits briefly and then
recreates it rather than hanging on SSH.

```bash
./setup.sh     # install Istio if needed, build image, deploy app + Postgres
./verify.sh    # mTLS and connectivity checks
./teardown.sh  # soft shutdown (see below)
```

All three scripts use an isolated kubeconfig at `~/.kube/mtls-demo-config`
(override with `KUBECONFIG_FILE=/path/to/file`). This prevents other tools such
as Rancher Desktop from overwriting `~/.kube/config` and dropping the minikube
context mid-demo.

### Reaching the app from your Mac

`setup.sh` applies the `Gateway`/`VirtualService` in `k8s/ingress.yaml` and
patches `istio-ingressgateway` to `NodePort`. On minikube's Docker driver,
though, the node IP is not routable from the macOS host (connections to its
NodePort hang), so use a `kubectl port-forward` to reach the gateway. The
request still goes through the Gateway/VirtualService and over mTLS to the app:

```bash
export KUBECONFIG="$HOME/.kube/mtls-demo-config"
kubectl -n istio-system port-forward svc/istio-ingressgateway 8080:80
# in another shell, with the gateway host header:
curl -H 'Host: mtls-demo.local' 'http://127.0.0.1:8080/actuator/health'
curl -H 'Host: mtls-demo.local' -X POST 'http://127.0.0.1:8080/users/v1' \
  -H 'Content-Type: application/json' \
  -d '{"name":"Ada","email":"ada@example.com"}'
curl -H 'Host: mtls-demo.local' 'http://127.0.0.1:8080/users/v1?email=ada@example.com'
```

If your driver does route the node IP, the NodePort URL printed by `setup.sh`
works too; compute it with:

```bash
export KUBECONFIG="$HOME/.kube/mtls-demo-config"
GW_IP="$(kubectl get nodes \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
GW_PORT="$(kubectl -n istio-system get svc istio-ingressgateway \
  -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')"
echo "http://$GW_IP:$GW_PORT/  (Host: mtls-demo.local)"
```

The app Service itself stays `ClusterIP`. Plaintext HTTP sent straight to an
app `NodePort` would be rejected by its sidecar because the namespace requires
STRICT mTLS. Traffic instead enters through the ingress gateway, which matches
host `mtls-demo.local` in the `VirtualService` and uses the `ISTIO_MUTUAL`
`DestinationRule` to reach the app over mTLS. The STRICT policy stays intact
while the host gets a normal HTTP URL.

Optionally map `127.0.0.1 mtls-demo.local` in `/etc/hosts` while the
port-forward is running and omit the header.

`./verify.sh` starts its own short-lived port-forward to the ingress gateway
and uses bounded curl timeouts, so it cannot hang on an unreachable node IP.
Set `VERIFY_GW_PORT` if local port 18080 is already in use. `./teardown.sh`
deletes the Gateway/VirtualService along with the namespace.

### Troubleshooting local access

- A `curl` to the ingress `<node-ip>:<nodePort>` that hangs means the minikube
  node IP is not routable from the host (normal with the Docker driver). Use
  the gateway port-forward above; `verify.sh` does this automatically.
- `no route to host` for `192.168.64.2:22` (SSH) or `:8443` (API) is usually a
  transient vfkit networking glitch. Confirm with
  `nc -z -G 3 192.168.64.2 8443 && echo reachable`, then retry.
- `minikube status` also SSHes into the VM to check disk capacity; that check
  can fail even when Kubernetes is fine. Use `kubectl get nodes`,
  `kubectl -n mtls-demo get pods` and `./verify.sh` as the real health checks.
- Plain `minikube status` inspects `~/.kube/config`, which Rancher Desktop may
  have rewritten, and can report `kubeconfig: Misconfigured`. Use
  `KUBECONFIG="$HOME/.kube/mtls-demo-config" minikube status`. If inherited
  shell state still interferes, try a clean environment:
  ```bash
  env -i HOME="$HOME" PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    KUBECONFIG="$HOME/.kube/mtls-demo-config" minikube status
  ```
- Do not interrupt `setup.sh` while it prints `minikube start` / "Updating the
  running vfkit VM": that leaves a half-provisioned profile and an empty
  kubeconfig (`current-context is not set`). The script now retries up to three
  times with a bounded wait. Run only one `setup.sh` at a time.

### `setup.sh` overrides

| Variable | Default | Purpose |
| --- | --- | --- |
| `IMAGE` | `mtls-demo:latest` | Use a pushed registry image instead |
| `BUILD_IMAGE` | `true` | Set `false` if the image is already available |
| `ISTIO_PROFILE` | `default` | Istio install profile |
| `MINIKUBE_DRIVER` | `podman` if installed, else minikube auto | Minikube driver used when recreating the profile |
| `MINIKUBE_PROFILE` | `minikube` | Minikube profile name |

`setup.sh` starts the Podman machine **before** `minikube start` and removes a
stale Podman container/volume for the profile, which avoids the
`volume with name minikube already exists` / `no container with name minikube`
failure. Set `MINIKUBE_DRIVER=vfkit` only if you specifically want vfkit; on
some macOS hosts its ISO unpacking fails and the VM kernel-panics before SSH
is reachable.

`setup.sh` also patches `istio-ingressgateway` to `NodePort` (including on an
existing Istio install), so use a profile that includes an ingress gateway,
such as `default` or `demo`.

### `teardown.sh` overrides

| Variable | Default | Purpose |
| --- | --- | --- |
| `FULL` | `false` | `true` = uninstall Istio and delete the minikube VM |
| `DELETE_NAMESPACE` | `true` | Delete the `mtls-demo` namespace |
| `UNINSTALL_ISTIO` | `false` | Remove the Istio control plane |
| `STOP_MINIKUBE` | `true` | Stop the VM but keep it for next time |
| `DELETE_MINIKUBE` | `false` | Remove the VM entirely (skips in-cluster cleanup) |
| `NS` / `ISTIO_NS` / `MINIKUBE_PROFILE` | `mtls-demo` / `istio-system` / `minikube` | Override resource names |

Examples:

```bash
./teardown.sh                       # stop workloads, keep the cluster
FULL=true ./teardown.sh             # remove everything
DELETE_MINIKUBE=true ./teardown.sh  # just discard the local cluster
```

The Docker Compose stack is independent of these scripts; stop it with
`docker compose down`.

## How the mTLS connection works

Both the app and Postgres run in the `mtls-demo` namespace, which has automatic
sidecar injection enabled:

```
host --HTTP--> ingress gateway ==mTLS==> app sidecar --plaintext--> app container
app container --plaintext--> app sidecar ==mTLS==> postgres sidecar --plaintext--> postgres:5432
```

The JDBC URL keeps `sslmode=disable`: encryption is handled by the sidecars.
Namespace-wide `PeerAuthentication` requires STRICT mTLS, and an
`AuthorizationPolicy` allows only the app's service account to reach Postgres
on port `5432`. Full details and caveats are in [`k8s/README.md`](k8s/README.md).

## Build and test

```bash
./mvnw clean verify
```

## Notes

Credentials (`demo` / `lock`) and the `emptyDir` for Postgres data are for
demonstration only. Docker Compose uses `ddl-auto=create-drop`; the Kubernetes
deployment uses `ddl-auto=update` with `generate-ddl=true` so rolling restarts
do not drop the schema and a fresh DB pod gets its tables recreated. Do not
reuse any of this in a production setup.
