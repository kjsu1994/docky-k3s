# Docky Compose To K3s Inventory

## Service Mapping

| Compose service | K3s object | Notes |
| --- | --- | --- |
| external entrypoint | `Ingress/docky` | Uses nginx-ingress; production hosts route to `Service/nginx`. |
| `cloudflare-tunnel` | optional `Deployment/cloudflared` | Not included in base kustomization to avoid premature traffic on the production tunnel. |
| `nginx` | `Deployment/nginx`, `Service/nginx` | Serves frontend image and proxies API, WS, MinIO, and OAuth. |
| `minio` | `StatefulSet/minio`, `Service/minio`, `PVC/minio-data` | `/data` stores MinIO buckets plus csv/streaming compatibility paths. |
| `oracle` | `StatefulSet/oracle`, `Service/oracle`, `PVC/oracle-data` | Keeps Oracle XE service name `oracle`. |
| `redis` | `Deployment/redis`, `Service/redis`, `PVC/redis-data` | Adds persistence that Compose did not explicitly mount. |
| Docky Ollama | `StatefulSet/ollama`, `Service/ollama`, `PVC/ollama-data` | Runs Docky-owned Ollama on port `11435`; the Windows/learnbot Ollama is not used. |
| `backend-blue`, `backend-green` | `Deployment/backend`, `Service/backend` | Starts as one active replica because some game runtime is JVM-local. |

## Image Strategy

- Backend must become an immutable image containing `app.jar` and `ffmpeg`.
- Frontend must become an immutable nginx image containing Vite `dist` files.
- If the frontend source is temporarily not buildable, the frontend image can be
  built from the already-running Compose static output at
  `C:\compose\minio-data\client\current`; this is read-only with respect to
  Compose.
- The Compose style JAR mount is intentionally not carried forward.
- Third-party runtime and build-base images are pinned by digest in the K3s
  workspace: Oracle XE, Redis, MinIO server, MinIO client, Cloudflared,
  backend JRE base, and the frontend nginx build base.
- Private GHCR images are the default:
  - `ghcr.io/kjsu1994/docky-backend:<immutable-tag>`
  - `ghcr.io/kjsu1994/docky-frontend-nginx:<immutable-tag>`

## Config Strategy

- Non-secret runtime settings live in `ConfigMap/docky-app-config`.
- Secret values live in `Secret/docky-secret`, generated outside source control.
- `Invoke-K3sApplySequence.ps1` applies the namespace and runtime secrets before
  applying app workloads.
- `Invoke-K3sApplySequence.ps1` creates the `docky` and `ingress-nginx`
  namespaces first, then runs `Test-K3sServerDryRun.ps1` before applying secrets,
  ingress-nginx, app workloads, and optional resources for real.
- `Test-K3sCutoverGate.ps1` blocks apply when image tags, runtime secrets,
  environment boundaries, Kubernetes context, or production backup validation
  are incomplete.
- `Test-K3sImagePolicy.ps1` detects mutable image references such as `latest`,
  `stable`, or tagless images; apply gates fail on mutable references for the
  resources being applied.
- `Test-K3sRunbooks.ps1` validates the UTF-8 Korean templates and latest
  generated cutover/rollback runbooks so Docker Desktop and production/staging
  execution steps do not get mixed.
- `Test-K3sComposeBoundary.ps1` enforces that `C:\compose` remains a read-only
  source and that generated output stays under `C:\K3s`.
- `Test-K3sRenderedSnapshots.ps1` validates rendered-manifest snapshots and
  prevents completion evidence from pointing at the wrong environment.
- `Test-K3sSecretSources.ps1` validates secret source file locations and
  required key presence without printing secret values.
- `Test-K3sBackupPreflight.ps1` validates the backup wrapper and read-only
  Compose backup source before a cold backup is started.
- `Test-K3sCutoverInputs.ps1` aggregates the required external inputs for the
  actual cutover without printing secret values. Use `-WriteReport` to store a
  timestamped Markdown/JSON input status report under
  `C:\K3s\runtime\reports`.
- `Test-K3sExternalDependencies.ps1` blocks cutover when external dependencies
  such as Ollama are missing from the rendered in-cluster Service/StatefulSet.
- `Test-K3sStoragePlan.ps1` validates required PVC declarations and can compare
  PVC capacity against either read-only Compose MinIO data or a K3s backup set.
- `Import-K3sKubeconfig.ps1` can copy a reviewed target kubeconfig into
  `C:\K3s\runtime\kubeconfig.yml`; apply, runtime, and restore scripts accept
  `-Kubeconfig` so they do not rely on the user's default kubectl context.
- `Test-K3sClusterPrereqs.ps1` verifies actual cluster conditions before apply:
  node readiness, Linux node OS, StorageClass availability, CoreDNS, and
  kubectl permissions.
- `Export-K3sRenderedManifests.ps1` writes non-secret rendered manifests under
  `C:\K3s\runtime\rendered\<timestamp>`; apply sequence exports a snapshot
  before resource apply unless explicitly skipped.
- `Collect-K3sDiagnostics.ps1` writes cluster status, rollout status, events,
  pod descriptions, and selected logs under `C:\K3s\runtime\diagnostics\<timestamp>`.
  It does not collect Kubernetes Secret resources, but generated logs must still
  be reviewed before sharing because application logs can contain sensitive data.
- `Invoke-K3sPostApplyValidation.ps1` runs rollout/PVC checks, optional HTTP
  smoke checks, and diagnostics collection as one post-apply sequence.
- `Test-K3sInClusterConnectivity.ps1` execs into a backend pod to verify
  in-cluster DNS and HTTP reachability for Oracle, Redis, MinIO, backend, nginx,
  and optionally the Ollama ExternalName service.
- Active profile is `prod`, not a new `k8s` profile, so existing strict security
  validation remains active without backend source changes.

## Storage Strategy

- `minio-data` PVC is shared by MinIO and the backend with subPath mounts:
  - `/data/csv_data`
  - `/data/streaming`
- This mirrors the Compose host directory layout.
- The planned two-server shape is one control-plane/data-leading node first, then one worker/load node later.
- With the current RWO storage, Oracle, MinIO, Redis, and the backend should stay on the data-leading node unless the storage class is replaced with RWX or the backend stops mounting `minio-data` directly.
- For multi-node K3s, replace the default RWO storage class with an RWX-capable class, split these volumes, or add explicit node placement before scaling stateful/backend workloads across nodes.

## Known Cutover Blockers

- No K3s context is currently configured on this machine.
- `k3s` binary is not on PATH; this Windows host needs a Linux K3s node, WSL/VM, or an imported kubeconfig before apply.
- Production/staging image tags are still `replace-me` until release images are pushed and `Set-K3sImageTags.ps1` is run for `C:\K3s\manifests`.
- App runtime secret exists under `C:\K3s\runtime\docky-secret.yml`; GHCR image pull secret is still missing.
- Backup set exists under `C:\K3s\backups\20260616-195948`; live data restore into PVCs is not rehearsed yet.
- No runtime diagnostics snapshot exists until workloads are applied to a real Kubernetes context and `Collect-K3sDiagnostics.ps1` is run.
- Oracle SQLFILE rehearsal from Compose backup passed, but Oracle import, MinIO restore, and Redis restore into K3s PVCs have not been executed.
- `Test-K3sRestoredData.ps1` exists to validate restored Oracle objects, required CSV files, streaming directory, and Redis state from inside the cluster after a restore.
- Cloudflare staging tunnel must target `ingress-nginx-controller.ingress-nginx.svc.cluster.local:80`.
- Ollama upstream uses an `ExternalName` placeholder and must be pointed at an Ollama service reachable from the cluster, exposed from this host, deployed in-cluster, or deliberately disabled before cutover.

## Environment Overlays

- Base production: `C:\K3s\manifests`
- Staging K3s: `C:\K3s\overlays\staging`
- Docker Desktop Kubernetes: `C:\K3s\overlays\docker-desktop`
- Optional Cloudflare connector: `C:\K3s\cloudflared`
