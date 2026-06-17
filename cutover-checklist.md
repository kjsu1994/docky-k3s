# Docky K3s Cutover Checklist

Do not cut over traffic until every gate below is complete. Compose remains the
rollback baseline until the final traffic switch is explicitly approved.

## Build Gates

- Backend `app.jar` is built from the intended source revision.
- Backend image includes `app.jar` and `ffmpeg`.
- Frontend image includes the intended Vite `dist` output.
- If frontend source is work-in-progress, frontend image was built from the
  reviewed Compose static output at `C:\compose\minio-data\client\current` using
  `-UseComposeFrontendCurrent` or `Build-FrontendImage.ps1 -DistPath`.
- `Test-K3sFrontendStaticSource.ps1 -DistPath <frontend-static-path>` passes for
  the exact static files used by the frontend image.
- Images are pushed to a registry reachable by K3s nodes.
- `manifests/kustomization.yml` no longer contains `replace-me` image tags.
- Image tags are updated through `Set-K3sImageTags.ps1`.
- `Test-K3sReleaseImages.ps1 -Environment <target>` passes and production/staging
  do not use local/test image tags.
- Mutable image references such as `latest`, `stable`, or tagless images are
  resolved before applying the affected resources.
- `ingress-nginx` controller is installed from `C:\K3s\ingress-nginx`.
- `ghcr-pull-secret` exists in namespace `docky`.
- Ingress class is `nginx`.
- Ingress upload/body-size and timeout behavior is verified for 3GB streaming
  uploads.
- `Test-K3sManifests.ps1 -FailOnPlaceholderImages` passes.
- `Test-K3sCutoverGate.ps1` passes for the target environment.
- `Test-K3sServerDryRun.ps1` passes during `Invoke-K3sApplySequence.ps1` after
  namespace creation and before real workload apply.
- `Test-K3sExternalDependencies.ps1 -Environment <target> -FailOnUnresolved`
  passes.
- `Invoke-K3sApplySequence.ps1` applies namespace and runtime secrets before
  applying app workloads.
- A rendered manifest snapshot exists under `C:\K3s\runtime\rendered` for the
  target apply.
- Target cluster kubeconfig is imported under `C:\K3s\runtime\kubeconfig.yml`
  or an explicit, reviewed kubeconfig path is passed to apply/restore scripts.
- `Test-K3sClusterPrereqs.ps1 -Kubeconfig C:\K3s\runtime\kubeconfig.yml -Environment <target>` passes.

## Secret Gates

- `docky-secret` exists in namespace `docky`.
- No placeholder values remain in the applied secret.
- Oracle and datasource credentials are supplied through `ExtraEnvPath`, not
  hardcoded defaults.
- `secrets\docky-k3s-extra.env.example` was copied outside source control and
  filled with real values.
- `Test-K3sSecretManifests.ps1` passes after generated secrets are created.
- `Test-K3sEnvBoundaries.ps1` passes.
- `docky-secret` does not contain route/config keys such as CORS origins,
  OAuth redirect URIs, S3 endpoints, Redis host, CSV paths, or streaming paths.
- `ORACLE_APP_USER` matches `SPRING_DATASOURCE_USERNAME`.
- `ORACLE_APP_USER_PASSWORD` matches `SPRING_DATASOURCE_PASSWORD`.
- `JWT_SECRET_KEY` is at least 32 characters.
- `DART_API_KEY`, `KIS_APP_KEY`, and `KIS_APP_SECRET` are present because those
  features are enabled in the current Compose environment and kept enabled in
  K3s.
- `SPRING_PROFILES_ACTIVE=prod` is confirmed in `docky-app-config`.
- Strict backend secret validation passes during backend startup.

## Data Gates

- Oracle restore rehearsal is complete against a non-live PVC or disposable DB.
- Cold-cutover backup was created under `C:\K3s\backups`.
- `Test-K3sBackupSet.ps1 -RequireOracle -RequireRedis -RequireMinio -RequireMinioContent` passes for the cutover backup.
- `Test-K3sStoragePlan.ps1 -BackupPath C:\K3s\backups\<timestamp> -FailOnInsufficient` passes for the cutover backup.
- Oracle Data Pump `SQLFILE` rehearsal completed from the K3s backup dump.
- Oracle Data Pump import completed through `Invoke-K3sOracleRestore.ps1`.
- Oracle restore import log was copied under `C:\K3s\backups\oracle-restore`.
- MinIO restore was rehearsed against staging or a disposable namespace.
- Redis restore decision was tested: restored RDB with `-ReplaceExisting` or
  intentionally fresh state.
- Oracle app schema user matches `SPRING_DATASOURCE_USERNAME`.
- MinIO `upload-files` bucket is restored and browse/download paths are verified.
- `Test-K3sRestoredData.ps1 -BackupPath C:\K3s\backups\<timestamp>` passes
  after Oracle, MinIO, and Redis restore.
- MinIO `csv_data` contains:
  - `Parking_Dataset.csv`
  - `Restroom_Dataset.csv`
  - `Library_Dataset.csv`
  - `Bunker_Dataset.csv`
  - `Medical_Dataset.csv`
  - `Medical_Location_Dataset.csv`
- Streaming directories exist under `/data/streaming`.
- Redis restore decision is explicit: restored RDB with existing AOF/RDB files
  replaced, or intentionally fresh state.

## Runtime Gates

- `kubectl rollout status deployment/redis -n docky` passes.
- `kubectl rollout status statefulset/oracle -n docky` passes.
- `kubectl rollout status statefulset/minio -n docky` passes.
- `kubectl rollout status deployment/backend -n docky` passes.
- `kubectl rollout status deployment/nginx -n docky` passes.
- `kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx` passes.
- `Invoke-K3sPostApplyValidation.ps1` passes for staging before production
  cutover.
- `Invoke-K3sPostApplyValidation.ps1` passes for production immediately after
  production apply.
- `Test-K3sCompletionGate.ps1 -BackupPath C:\K3s\backups\<timestamp>` passes
  before `explan.md` is created.
- `Test-K3sInClusterConnectivity.ps1 -IncludeExternalServices` passes from a
  backend pod after staging apply and production apply.
- `Collect-K3sDiagnostics.ps1` was run after staging apply and again after
  production apply, and the output was reviewed before sharing.
- Staging overlay shows only `staging.docky.co.kr`.
- Docker Desktop overlay shows only `localhost`.
- Docker Desktop overlay image tags point to locally built images and do not
  force production/staging image tags to be decided early.
- `Test-K3sDockerDesktopReadiness.ps1` passes before local Docker Desktop
  Kubernetes apply.
- Production base shows only `docky.co.kr` and `www.docky.co.kr`.
- Staging `S3_PRESIGNED_PUBLIC_ENDPOINT` is `https://staging.docky.co.kr`.
- Docker Desktop `S3_PRESIGNED_PUBLIC_ENDPOINT` is `http://localhost:8080`.
- Internal nginx `server_name` is generic (`_`) and does not pin production
  domains inside staging or Docker Desktop renders.
- If using Cloudflare Tunnel for cutover, `kubectl rollout status deployment/cloudflared -n docky` passes after the explicit tunnel apply.
- Backend readiness endpoint is healthy through nginx.
- `/api`, `/ws`, `/login/oauth2/code/*`, `/upload-files/*`, and streaming paths
  are verified through the same public route users will use.
- OAuth provider redirect URIs point to the intended K3s route.
- IoT routes and `iot-external` are not rendered; IoT is intentionally retired.
- Ollama is reachable in-cluster through `Service/ollama` on port `11435` when
  `OLLAMA_ENABLED=true`.
- `OLLAMA_CHAT_MODEL` and `OLLAMA_VISION_MODEL` are `qwen3.5:2b-q4_K_M`, and the
  model exists on `PVC/ollama-data`.
- `Invoke-K3sApplySequence.ps1` installs the vendored NVIDIA device plugin when
  `-OllamaGpuMode auto` or `-OllamaGpuMode gpu` is used, unless
  `-SkipNvidiaDevicePlugin` is explicitly passed.
- NVIDIA device plugin images are pinned by digest and render from
  `C:\K3s\nvidia-device-plugin`; the RuntimeClass retry path renders from
  `C:\K3s\nvidia-device-plugin-runtimeclass`.
- If Ollama GPU acceleration is expected, the target Kubernetes node advertises
  allocatable `nvidia.com/gpu`; a host-level `nvidia-smi` result alone is not
  sufficient for Pod scheduling.
- `Invoke-K3sApplySequence.ps1` uses the intended `-OllamaGpuMode`: `auto`
  selects a GPU overlay only when `nvidia.com/gpu` is available, `gpu` forces the
  GPU overlay, and `cpu` forces CPU mode.
- When GPU mode is selected, rendered manifests include `nvidia.com/gpu: "1"` on
  `StatefulSet/ollama` plus `OLLAMA_FLASH_ATTENTION`,
  `NVIDIA_VISIBLE_DEVICES`, and `NVIDIA_DRIVER_CAPABILITIES`.
- If the RuntimeClass retry is required, the rendered Ollama overlay includes
  `runtimeClassName: nvidia`; if the target reports `RuntimeHandler "nvidia" not
  supported`, CPU fallback is expected until the Kubernetes container runtime is
  configured for NVIDIA.

## Smoke Gates

- Login and token refresh work.
- Queue entry/status works.
- Board list/detail/write smoke works.
- Chat WebSocket connect/send/receive works.
- Game room create/join/action/reconnect works for single backend replica.
- Upload and image view work.
- Streaming list/play/HLS segment works.
- Admin command/anomalies/operations/streaming paths work.
- AI chat path returns the expected Ollama-backed response or the planned
  disabled-provider response if Ollama was deliberately disabled.
- Investment assistant/chart paths verify DART and KIS-backed data where those
  providers are expected to be active.
- Mobile and desktop frontend smoke paths load through nginx.
- `Test-K3sHttpSmoke.ps1` passes against staging before production cutover.
- `Test-K3sHttpSmoke.ps1 -IncludeWebSocket -IncludeIot` passes after WebSocket
  and IoT upstreams are intentionally enabled for the target route.

## Cutover Gates

- Compose service health is recorded before switching.
- K3s service health is recorded immediately before switching.
- DNS or Cloudflare tunnel route switch has a tested rollback path.
- `New-K3sRollbackRunbook.ps1` was run for the target environment and the
  generated rollback runbook was reviewed before switching public traffic.
- Rollback action keeps Compose untouched and restores traffic to the previous
  public route.
- Production apply is run with `-BackupPath C:\K3s\backups\<timestamp>`.
- Production apply and restore commands are run with the intended
  `-Kubeconfig` path, not an accidental default kubectl context.
