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
| `k8s/ingress.yaml` | Optional Gateway/VirtualService to expose the app through the Istio ingress gateway |
| `setup.sh` | Bring up minikube + Istio, build the image, deploy |
| `verify.sh` | Prove sidecars, mTLS certificates and DB access rules |
| `teardown.sh` | Stop port-forwards, remove workloads, stop/delete the cluster |
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

The app Service is `ClusterIP`, so it has no external IP or NodePort. Use
port-forward. The scripts set the kubeconfig internally, so direct `kubectl`
commands from your own shell need it exported first:

```bash
export KUBECONFIG="$HOME/.kube/mtls-demo-config"
```

Terminal 1 — leave this running:

```bash
kubectl -n mtls-demo port-forward svc/mtls-demo-app 8080:8080
```

Terminal 2 — call the API:

```bash
curl -s localhost:8080/actuator/health
curl -s -X POST localhost:8080/users/v1 -H 'Content-Type: application/json' \
  -d '{"name":"Ada","email":"ada@example.com"}'
curl -s 'localhost:8080/users/v1?email=ada@example.com'
```

These do **not** work from the host: `curl http://192.168.64.2:8080` (no
NodePort), `curl http://mtls-demo-app.mtls-demo.svc.cluster.local:8080`
(cluster DNS resolves only inside the mesh), or
`minikube service mtls-demo-app -n mtls-demo --url` (ClusterIP has no URL).
Changing the Service to `NodePort`/`LoadBalancer` does not help: STRICT mTLS
makes the sidecar reject plaintext HTTP arriving from outside the mesh. The
port-forward works because it reaches the app over loopback, bypassing the
sidecar; mTLS applies only to the app <-> Postgres hop.

`verify.sh` briefly uses local port 8080 for its own port-forward, so start
yours after it finishes (or use `8081:8080` and curl `localhost:8081`).

### Making the service reachable (Istio ingress)

`port-forward` is only for debugging. For a real URL, apply the optional
Gateway/VirtualService in `k8s/ingress.yaml` (it is **not** applied by
`setup.sh`):

```bash
export KUBECONFIG="$HOME/.kube/mtls-demo-config"
kubectl apply -f k8s/ingress.yaml
```

This uses the existing `istio-ingressgateway` in `istio-system` and maps host
`mtls-demo.local` to the app on port `8080`. The manifest also adds an
`ISTIO_MUTUAL` `DestinationRule` for the app service, so the gateway talks to
the app over mTLS and the namespace's STRICT policy stays intact.

Quick check without a LoadBalancer IP:

```bash
kubectl -n istio-system port-forward svc/istio-ingressgateway 8081:80
curl -H 'Host: mtls-demo.local' http://localhost:8081/actuator/health
# {"groups":["liveness","readiness"],"status":"UP"}
```

For a stable URL on minikube, run `minikube tunnel` in another terminal (it
needs sudo). The gateway's `LoadBalancer` service then gets an EXTERNAL-IP,
typically `127.0.0.1`:

```bash
minikube tunnel
kubectl -n istio-system get svc istio-ingressgateway   # note EXTERNAL-IP
curl -H 'Host: mtls-demo.local' http://<EXTERNAL-IP>/actuator/health
```

Optionally add `127.0.0.1 mtls-demo.local` to `/etc/hosts` and use
`http://mtls-demo.local/actuator/health` in a browser. Remove the ingress with
`kubectl delete -f k8s/ingress.yaml`, or just run `./teardown.sh`, which deletes
the namespace.

### Troubleshooting local access

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
