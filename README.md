# Docky K3s Migration Workspace

This directory is the Kubernetes-only preparation area for moving Docky from
Docker Compose to K3s. The Compose directory is a read-only source of truth while
this workspace is being prepared. Do not write to `C:\compose` from these files.

## Current Scope

- Runtime target: K3s-compatible Kubernetes manifests.
- Local validation target: Docker Desktop Kubernetes through a separate overlay.
- Public domain: `docky.co.kr`, `www.docky.co.kr`.
- Front door: Kubernetes Ingress routes `docky.co.kr` and `www.docky.co.kr`
  to the in-cluster `nginx` service.
- App gateway: nginx serves the built React app and proxies `/api`, `/ws`,
  OAuth callbacks, and MinIO object paths.
- Backend: one active Spring Boot replica, `Recreate` rollout strategy.
- State: Oracle, MinIO, and Redis run in-cluster with PVCs.
- Secrets: not stored here. Generate and apply a Kubernetes Secret separately.

## Directory Layout

```text
C:\K3s
|-- build
|   |-- backend
|   |   `-- Dockerfile
|   `-- frontend
|       `-- Dockerfile
|-- jobs
|   `-- minio-bootstrap-job.yml
|-- manifests
|   |-- config
|   |-- network
|   |-- secrets
|   |-- storage
|   |-- workloads
|   `-- kustomization.yml
|-- scripts
|-- runtime
|   |-- diagnostics
|   `-- rendered
|-- overlays
|   |-- staging
|   `-- docker-desktop
`-- inventory.md
```

Open `pending-inputs.ko.md` for the Korean list of decisions and external
inputs that must be resolved before production cutover.
Generate a timestamped Korean execution runbook with
`scripts\New-K3sCutoverRunbook.ps1` when preparing a staging or production
cutover window.
Generate a timestamped Korean rollback runbook with
`scripts\New-K3sRollbackRunbook.ps1` before any public traffic switch.

## Preparation Flow

1. Install the pinned nginx-ingress controller.

   The controller manifest is vendored under `ingress-nginx\upstream` from the
   official ingress-nginx static manifest for controller `v1.15.1`. The local
   kustomization patches the controller Service to `ClusterIP` because
   Cloudflare Tunnel targets it inside the cluster.

   ```powershell
   kubectl apply -k C:\K3s\ingress-nginx
   ```

2. Build and push immutable images.

   Full image pipeline:

   ```powershell
   C:\K3s\scripts\Invoke-K3sImagePipeline.ps1 `
     -Tag 20260615-001 `
     -Push `
     -UpdateManifests
   ```

   If the frontend source is still in progress, build only the backend image and
   leave the frontend image/tag untouched:

   ```powershell
   C:\K3s\scripts\Invoke-K3sImagePipeline.ps1 `
     -Tag 20260615-backend-001 `
     -SkipFrontendImage `
     -Push `
     -UpdateManifests
   ```

   Frontend can be built later with the same script by using
   `-SkipBackendImage`.

   If the frontend source is temporarily not buildable, build the frontend image
   from the static files currently served by Compose. This reads
   `C:\compose\minio-data\client\current` and does not modify `C:\compose`:

   ```powershell
   C:\K3s\scripts\Test-K3sFrontendStaticSource.ps1 `
     -DistPath C:\compose\minio-data\client\current

   C:\K3s\scripts\Invoke-K3sImagePipeline.ps1 `
     -Tag 20260615-frontend-from-compose `
     -SkipBackendImage `
     -UseComposeFrontendCurrent `
     -Push `
     -UpdateManifests
   ```

   You can also pass any reviewed static output directory with
   `-FrontendDistPath <path>`.
   `Build-FrontendImage.ps1` runs the same static source validation before
   copying files into the generated Docker build context.
   The validation warns when local-only strings such as `http://localhost` are
   present in the built bundle. Use `-FailOnLocalhostReferences` when you want
   that warning to become a hard gate after reviewing the current frontend
   bundle.

   After building images, verify the image runtime surface. During frontend
   work-in-progress periods, skip the frontend image check:

   ```powershell
   C:\K3s\scripts\Test-K3sImageRuntime.ps1 `
     -BackendImage ghcr.io/kjsu1994/docky-backend:20260615-backend-001 `
     -SkipFrontendImage
   ```

   Backend image expects a built `app.jar`:

   ```powershell
   C:\K3s\scripts\Build-BackendImage.ps1 `
     -JarPath C:\Users\honeybadger\Desktop\ctfmon_project\CommunityServer\server\build\libs\app.jar `
     -ImageName ghcr.io/kjsu1994/docky-backend:20260615
   ```

   Frontend image expects a Vite `dist` directory:

   ```powershell
   C:\K3s\scripts\Build-FrontendImage.ps1 `
     -DistPath C:\Users\honeybadger\Desktop\ctfmon_project\client\api-client-ui\dist `
     -ImageName ghcr.io/kjsu1994/docky-frontend-nginx:20260615
   ```

   To package the already-running Compose frontend instead:

   ```powershell
   C:\K3s\scripts\Build-FrontendImage.ps1 `
     -DistPath C:\compose\minio-data\client\current `
     -ImageName ghcr.io/kjsu1994/docky-frontend-nginx:20260615-compose-current
   ```

3. Update image tags in `manifests/kustomization.yml`.

   ```powershell
   C:\K3s\scripts\Set-K3sImageTags.ps1 `
     -BackendTag 20260615-001 `
     -FrontendTag 20260615-001
   ```

4. Create the private GHCR image pull secret.

   ```powershell
   C:\K3s\scripts\New-GhcrImagePullSecret.ps1 `
     -Username kjsu1994 `
     -Token <ghcr-read-packages-token> `
     -OutputPath C:\K3s\runtime\ghcr-pull-secret.yml
   kubectl apply -f C:\K3s\runtime\ghcr-pull-secret.yml
   ```

5. Create the runtime secret from the Compose env plus K3s-only values.

   ```powershell
   C:\K3s\scripts\New-DockySecretFromEnv.ps1 `
     -EnvPath C:\compose\.env `
     -ExtraEnvPath C:\secret\docky-k3s-extra.env `
     -CloudflareTunnelToken <staging-or-prod-tunnel-token> `
     -OutputPath C:\K3s\runtime\docky-secret.yml
   kubectl apply -f C:\K3s\runtime\docky-secret.yml
   ```

   `ExtraEnvPath` must provide values that do not exist in `C:\compose\.env`,
   such as Oracle root/app credentials and Spring datasource credentials. Do not
   store this file under `C:\compose`.

   Start from `secrets\docky-k3s-extra.env.example`, copy it outside source
   control, and fill real values there.
   `ORACLE_APP_USER` must match `SPRING_DATASOURCE_USERNAME`, and
   `ORACLE_APP_USER_PASSWORD` must match `SPRING_DATASOURCE_PASSWORD`, because
   the in-cluster Oracle container creates the app user that Spring logs in as.
   DART and KIS keys are required for feature parity with the current Compose
   env.

   To check the source files without writing a Kubernetes Secret manifest:

   ```powershell
   C:\K3s\scripts\New-DockySecretFromEnv.ps1 `
     -EnvPath C:\compose\.env `
     -ExtraEnvPath C:\secret\docky-k3s-extra.env `
     -CloudflareTunnelToken <staging-or-prod-tunnel-token> `
     -ValidateOnly
   ```

   The generated Secret intentionally writes only allowlisted sensitive keys:
   credentials, tokens, OAuth client secrets, SMTP credentials, and optional API
   keys. Route-specific values such as CORS origins, OAuth redirect URIs, S3
   endpoints, Redis host, CSV paths, and streaming paths belong to ConfigMaps
   and overlays. Keeping that split prevents staging and Docker Desktop values
   from being overwritten by Compose production env values.

6. Validate the rendered manifests locally.

   ```powershell
   C:\K3s\scripts\Test-K3sHostPrereqs.ps1
   C:\K3s\scripts\Test-K3sManifests.ps1
   C:\K3s\scripts\Test-K3sImagePolicy.ps1 -IncludeCloudflared -IncludeJobs -IncludeBuildFiles -IncludeScripts
   C:\K3s\scripts\Test-K3sReleaseImages.ps1 -Environment staging
   C:\K3s\scripts\Test-K3sReleaseImages.ps1 -Environment production
   C:\K3s\scripts\Test-K3sExternalDependencies.ps1
   C:\K3s\scripts\Test-K3sComposeParity.ps1 -FailOnMismatch
   C:\K3s\scripts\Test-K3sStoragePlan.ps1
   C:\K3s\scripts\Test-K3sBackupPreflight.ps1
   C:\K3s\scripts\Test-K3sCutoverInputs.ps1
   C:\K3s\scripts\Test-K3sCutoverInputs.ps1 -WriteReport
   C:\K3s\scripts\Test-K3sComposeBoundary.ps1
   C:\K3s\scripts\Test-K3sRunbooks.ps1 -RequireGeneratedRunbook -RequireRollbackRunbook
   C:\K3s\scripts\Test-K3sSecretSources.ps1
   C:\K3s\scripts\Test-K3sRenderedSnapshots.ps1
   C:\K3s\scripts\Export-K3sRenderedManifests.ps1 -Environment staging
   C:\K3s\scripts\Test-K3sLocalReadiness.ps1
   C:\K3s\scripts\Get-K3sMigrationStatus.ps1
   ```

   `Get-K3sMigrationStatus.ps1` is a non-secret status summary. It reports
   local readiness, image placeholder status, runtime secret status, kubeconfig
   presence, and backup set readiness without printing secret values.

   `Test-K3sImagePolicy.ps1` reports mutable image references such as `latest`,
   `stable`, tagless images, and third-party images that are not pinned by
   digest. Apply-time gates fail on mutable Kubernetes images for the resources
   being applied. This keeps Oracle, Redis, MinIO, Cloudflared, and build-base
   images from silently changing at runtime. Update those digests deliberately
   when upgrading dependencies. The two Docky application images may use
   reviewed immutable release tags.

   `Test-K3sReleaseImages.ps1` checks the two Docky application image tags
   rendered for each environment. Production and staging reject placeholders and
   local/test-looking tags such as `local-*`, `dev-*`, or `*-compose-current`.
   Use `-RequireRegistryAvailability` after registry login when you also want
   to verify that the pushed GHCR manifests are inspectable from this machine.

   `Test-K3sRunbooks.ps1` checks the UTF-8 templates and the latest generated
   cutover/rollback runbooks. It blocks unresolved template placeholders and
   environment mixups, such as Docker Desktop runbooks containing GHCR
   pull-secret or registry availability steps.

   `Test-K3sComposeBoundary.ps1` enforces the migration boundary: `C:\compose`
   remains a read-only source, generated files stay under `C:\K3s`, and backup
   output stays under `C:\K3s\backups`.

   `Test-K3sRenderedSnapshots.ps1` validates generated rendered-manifest
   snapshots under `C:\K3s\runtime\rendered`. Completion requires a production
   snapshot with no placeholder image tags.

   `Test-K3sSecretSources.ps1` checks secret source readiness without printing
   secret values. It enforces `C:\compose\.env` as the read-only Compose source
   and requires the K3s-only extra env file to live outside `C:\compose` and
   `C:\K3s`.

   `Test-K3sBackupPreflight.ps1` checks that the K3s backup wrapper uses the
   existing Compose backup script safely and writes backup sessions only under
   `C:\K3s\backups`.

   `Test-K3sCutoverInputs.ps1` summarizes whether required cutover inputs are
   ready: release images, external DNS names, secret sources, runtime secrets,
   kubeconfig, backup set, runbooks, and rendered snapshots. Add `-WriteReport`
   to write a timestamped Markdown and JSON report under
   `C:\K3s\runtime\reports` without printing secret values.

   `Test-K3sExternalDependencies.ps1` checks external dependencies that cannot
   be proven by Kubernetes rendering alone. IOT routes are intentionally removed
   from the K3s target. Ollama remains enabled as an in-cluster `StatefulSet/ollama` on port `11435`; the Docky Kubernetes app does not use the existing Windows or learnbot Ollama instance.

   Compose has KIS and Ollama enabled. K3s keeps that behavior: KIS uses the
   public Korea Investment API through outbound network access, and Ollama is
   routed through `Service/ollama` with `gemma4:e2b-it-qat` stored on
   `PVC/ollama-data`.

   `Test-K3sStoragePlan.ps1` validates the expected PVCs and can compare PVC
   requests against backup or Compose data sizes. The Compose scan is read-only:

   ```powershell
   C:\K3s\scripts\Test-K3sStoragePlan.ps1 `
     -CheckComposeDataSize `
     -FailOnInsufficient
   ```

   After a cutover backup exists, check it directly:

   ```powershell
   C:\K3s\scripts\Test-K3sStoragePlan.ps1 `
     -BackupPath C:\K3s\backups\<timestamp> `
     -FailOnInsufficient
   ```

   `Export-K3sRenderedManifests.ps1` writes the rendered app and ingress
   manifests under `C:\K3s\runtime\rendered\<timestamp>`. The apply sequence
   creates this snapshot automatically before applying resources unless
   `-SkipRenderSnapshot` is passed.

   After applying to a real cluster, collect a non-Secret runtime snapshot for
   troubleshooting and rollback evidence:

   ```powershell
   C:\K3s\scripts\Collect-K3sDiagnostics.ps1 `
     -Kubeconfig C:\K3s\runtime\kubeconfig.yml
   ```

   The diagnostics script does not collect Kubernetes Secret resources. It does
   collect pod logs, so review the generated files before sharing them outside
   the machine.

   Before applying to Docker Desktop Kubernetes or K3s, a kubectl context must
   exist. Enforce that with:

   ```powershell
   C:\K3s\scripts\Test-K3sHostPrereqs.ps1 -RequireKubernetesContext
   ```

   If the target cluster kubeconfig is available as a file, import it into the
   K3s runtime area instead of editing the user's default kubeconfig:

   ```powershell
   C:\K3s\scripts\Import-K3sKubeconfig.ps1 `
     -SourcePath C:\secret\k3s.yml `
     -OutputPath C:\K3s\runtime\kubeconfig.yml `
     -TestClusterConnection
   ```

   Then pass it explicitly to apply and validation commands:

   ```powershell
   C:\K3s\scripts\Test-K3sHostPrereqs.ps1 `
     -Kubeconfig C:\K3s\runtime\kubeconfig.yml `
     -RequireKubernetesContext

   C:\K3s\scripts\Test-K3sClusterPrereqs.ps1 `
     -Kubeconfig C:\K3s\runtime\kubeconfig.yml `
     -Environment staging
   ```

   `Test-K3sClusterPrereqs.ps1` checks the active context, node readiness,
   Linux node OS, StorageClass availability, CoreDNS, and kubectl permissions
   needed by the apply sequence. The cutover gate runs it automatically before
   applying resources.

   Apply-time gates are stricter than local rendering checks. They require a
   Kubernetes context, non-placeholder image tags, clean runtime secret
   manifests, a generated target cutover runbook, a generated target rollback
   runbook, and for production a validated backup set:

   ```powershell
   C:\K3s\scripts\Test-K3sCutoverGate.ps1 `
     -Environment staging `
     -Kubeconfig C:\K3s\runtime\kubeconfig.yml `
     -DockySecretPath C:\K3s\runtime\docky-secret.yml `
     -GhcrSecretPath C:\K3s\runtime\ghcr-pull-secret.yml
   ```

7. Create a cold-cutover backup under `C:\K3s\backups`.

   This wrapper calls the existing Compose backup script but forces the output
   root to `C:\K3s\backups`. It requires explicit confirmation and does not write
   backup output under `C:\compose`.

   ```powershell
   C:\K3s\scripts\Invoke-K3sComposeBackup.ps1 -ConfirmBackup
   C:\K3s\scripts\Test-K3sBackupSet.ps1 -RequireOracle -RequireRedis -RequireMinio -RequireMinioContent
   ```

8. Rehearse data restore against K3s PVCs.

   Oracle rehearsal is non-destructive because it uses Data Pump `SQLFILE`.

   ```powershell
   C:\K3s\scripts\Invoke-K3sOracleSqlfileRehearsal.ps1 `
     -DumpFile C:\K3s\backups\<timestamp>\oracle\docky-<timestamp>.dmp `
     -Kubeconfig C:\K3s\runtime\kubeconfig.yml `
     -SystemPassword <oracle-system-password>
   ```

   During the approved cutover window, restore Oracle with the destructive
   import script after the SQLFILE rehearsal has been reviewed:

   ```powershell
   C:\K3s\scripts\Invoke-K3sOracleRestore.ps1 `
     -DumpFile C:\K3s\backups\<timestamp>\oracle\docky-<timestamp>.dmp `
     -Kubeconfig C:\K3s\runtime\kubeconfig.yml `
     -ReadCredentialsFromClusterSecret `
     -ConfirmRestore
   ```

   The restore source must be under `C:\K3s\backups`. By default the script
   scales the backend Deployment to zero during import, imports with
   `table_exists_action=REPLACE`, copies the import log back under
   `C:\K3s\backups\oracle-restore`, validates that the target schema contains
   database objects, and then restores the backend replica count.

   MinIO and Redis restore scripts mutate PVC data and require explicit
   confirmation. Use them only against staging or during the approved cutover.

   ```powershell
   C:\K3s\scripts\Invoke-K3sMinioRestore.ps1 `
     -MinioDataBackupPath C:\K3s\backups\<timestamp>\minio\minio-data `
     -Kubeconfig C:\K3s\runtime\kubeconfig.yml `
     -ConfirmRestore

   C:\K3s\scripts\Invoke-K3sRedisRestore.ps1 `
     -RdbPath C:\K3s\backups\<timestamp>\redis\docky-redis-<timestamp>.rdb `
     -Kubeconfig C:\K3s\runtime\kubeconfig.yml `
     -ReplaceExisting `
     -ConfirmRestore
   ```

   After restore, validate the restored data from inside the cluster before
   moving on to public smoke checks:

   ```powershell
   C:\K3s\scripts\Test-K3sRestoredData.ps1 `
     -Kubeconfig C:\K3s\runtime\kubeconfig.yml `
     -BackupPath C:\K3s\backups\<timestamp>
   ```

   This checks Oracle schema object count, required CSV files and streaming
   directory through the backend pod mounts, and Redis connectivity/DB size.

9. Apply staging first.

   ```powershell
   C:\K3s\scripts\Invoke-K3sApplySequence.ps1 `
     -Environment staging `
     -Kubeconfig C:\K3s\runtime\kubeconfig.yml `
     -ConfirmApply
   ```

   The apply sequence creates the `docky` and `ingress-nginx` namespaces first,
   then runs `Test-K3sServerDryRun.ps1` against secrets, ingress-nginx, app
   manifests, and optional resources before submitting the real workload apply.
   This catches API-server validation and admission errors after local rendering
   but before the main resources are changed.

   Then run the post-apply validation wrapper. It waits for rollouts, checks PVC
   binding, runs HTTP smoke checks, and collects diagnostics under
   `C:\K3s\runtime\diagnostics` even when validation fails:

   ```powershell
   C:\K3s\scripts\Invoke-K3sPostApplyValidation.ps1 `
     -Kubeconfig C:\K3s\runtime\kubeconfig.yml `
     -BaseUrl https://staging.docky.co.kr `
     -IncludeExternalServices `
     -IncludeWebSocket `
   ```

   The apply sequence runs `Test-K3sCutoverGate.ps1`, applies the `docky`
   namespace, applies runtime secrets, installs ingress-nginx, and then applies
   the selected app manifests.

10. For Docker Desktop Kubernetes local validation, use the local overlay.

   This keeps the same Kubernetes resources but changes ingress/CORS/OAuth
   values to `http://localhost:8080`. It uses a relaxed `docker-desktop` Spring
   profile because the production strict profile intentionally rejects localhost
   origins. It also removes `imagePullSecrets` so locally built images can be
   used without GHCR access.

   ```powershell
   C:\K3s\scripts\Test-K3sDockerDesktopReadiness.ps1

   C:\K3s\scripts\Invoke-K3sApplySequence.ps1 `
     -Environment docker-desktop `
     -Kubeconfig C:\K3s\runtime\kubeconfig.yml `
     -ConfirmApply
   C:\K3s\scripts\Start-DockerDesktopPortForward.ps1 `
     -Kubeconfig C:\K3s\runtime\kubeconfig.yml
   ```

   In another PowerShell window, validate the local route:

   ```powershell
   C:\K3s\scripts\Invoke-K3sPostApplyValidation.ps1 `
     -Kubeconfig C:\K3s\runtime\kubeconfig.yml `
     -BaseUrl http://localhost:8080 `
     -IncludeExternalServices `
     -IncludeWebSocket `
   ```

   Then open:

   ```text
   http://localhost:8080
   ```

   The Docker Desktop overlay has its own local image tags and removes
   `imagePullSecrets`. This lets local Kubernetes validation proceed while the
   production and staging manifests still wait for pushed GHCR release tags.
   Rebuild local images and update only the Docker Desktop overlay tags when
   local validation needs a new image:

   ```powershell
   C:\K3s\scripts\Set-K3sImageTags.ps1 `
     -KustomizationPath C:\K3s\overlays\docker-desktop\kustomization.yml `
     -BackendTag <local-backend-tag> `
     -FrontendTag <local-frontend-tag>
   ```

11. Apply production manifests only during the approved cutover.

   ```powershell
   C:\K3s\scripts\Invoke-K3sApplySequence.ps1 `
     -Environment production `
     -Kubeconfig C:\K3s\runtime\kubeconfig.yml `
     -BackupPath C:\K3s\backups\<timestamp> `
     -ConfirmApply
   ```

   Do not pass `-SkipServerDryRun` during production cutover unless a failed
   dry-run has been reviewed and the exact API-server/admission issue is already
   understood.

   Immediately after production apply, validate the public route and keep the
   generated diagnostics as cutover evidence:

   ```powershell
   C:\K3s\scripts\Invoke-K3sPostApplyValidation.ps1 `
     -Kubeconfig C:\K3s\runtime\kubeconfig.yml `
     -BaseUrl https://docky.co.kr `
     -IncludeExternalServices `
     -IncludeWebSocket `
   ```

   If the production apply followed a data restore in the same window, run
   restored-data validation as part of the evidence bundle:

   ```powershell
   C:\K3s\scripts\Test-K3sRestoredData.ps1 `
     -Kubeconfig C:\K3s\runtime\kubeconfig.yml `
     -BackupPath C:\K3s\backups\<timestamp>
   ```

   To prove the full completion criteria before writing `explan.md`, run the
   completion gate after production apply, restore, smoke checks, and
   diagnostics are available:

   ```powershell
   C:\K3s\scripts\Test-K3sCompletionGate.ps1 `
     -Kubeconfig C:\K3s\runtime\kubeconfig.yml `
     -BackupPath C:\K3s\backups\<timestamp> `
     -BaseUrl https://docky.co.kr
   ```

   After that gate passes, generate the Korean Kubernetes explanation document:

   ```powershell
   C:\K3s\scripts\New-K3sExplanation.ps1 `
     -Kubeconfig C:\K3s\runtime\kubeconfig.yml `
     -BackupPath C:\K3s\backups\<timestamp> `
     -BaseUrl https://docky.co.kr
   ```

12. Bootstrap MinIO buckets only after MinIO is healthy.

   ```powershell
   kubectl apply -f C:\K3s\jobs\minio-bootstrap-job.yml
   ```

13. Apply Cloudflare Tunnel only when the target tunnel is safe to attach.

   ```powershell
   kubectl apply -k C:\K3s\cloudflared
   ```

## Ingress

The base manifest includes `manifests\network\ingress.yml` with
`ingressClassName: nginx`. It routes `docky.co.kr` and `www.docky.co.kr` to the
in-cluster app nginx Service. The staging overlay replaces those hosts with
`staging.docky.co.kr` and uses staging OAuth redirect URIs.

The Docker Desktop overlay replaces the host with `localhost` and is intended
for local port-forward testing only. It is not a production configuration.

`cloudflared\cloudflared.yml` is intentionally not part of the base
`kustomization.yml`. Applying it with the current production tunnel token can
join the same Cloudflare Tunnel as Compose and receive traffic before cutover.
Use a staging tunnel token first. In Cloudflare Zero Trust, the public hostname
target should be:

```text
http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80
```

Use `kubectl apply -k C:\K3s\cloudflared` only after that hostname target is set
to the intended staging or production tunnel.

## Data Migration Notes

Full transition needs a rehearsed restore path for:

- Oracle schema/data into the `oracle-data` PVC.
- MinIO object data into the `minio-data` PVC.
- Redis RDB into the `redis-data` PVC if current Redis state must survive.
- CSV and streaming directories under the MinIO PVC paths used by the backend.

Use a restore rehearsal before production cutover. Keep Compose running until the
K3s stack passes health, API, WebSocket, auth, upload, streaming, and admin smoke
checks against the production domain or a staging tunnel.

After rollout, run a smoke check against the route being tested. Prefer the
post-apply validation wrapper above because it also waits for Kubernetes
rollouts, verifies PVC binding, and collects diagnostics. For a narrow HTTP-only
check:

```powershell
C:\K3s\scripts\Test-K3sHttpSmoke.ps1 -BaseUrl http://localhost:8080
```

For a fuller route check after WebSocket and external upstreams are ready:

```powershell
C:\K3s\scripts\Test-K3sHttpSmoke.ps1 `
  -BaseUrl https://staging.docky.co.kr `
  -IncludeWebSocket `
```
