# Docky K3s 전환 실행 Runbook

작성 시각: __CREATED_AT__
대상 환경: __ENVIRONMENT__
기준 URL: __BASE_URL__
Kubeconfig: __KUBECONFIG__
백업 경로: __BACKUP_PATH__
Release tag: __RELEASE_TAG__

이 runbook은 명령을 자동 실행하지 않는다. 전환 당일 순서 실수를 줄이기 위한 실행 순서 문서다. `C:\compose`는 읽기 전용 기준이며, 백업 산출물은 `C:\K3s\backups` 아래에만 둔다.

## 1. 전환 전 불변 조건

- 현재 운영 Compose는 rollback 기준으로 유지한다.
- production/staging에는 로컬 이미지 태그를 사용하지 않는다.
- `C:\K3s\runtime\docky-secret.yml`와 `C:\K3s\runtime\ghcr-pull-secret.yml`는 실제 값으로 생성하되 외부 공유하지 않는다.
- production 전환에는 검증된 backup set이 필요하다.
- `-SkipServerDryRun`은 production 전환에서 사용하지 않는다.
- Cloudflare production tunnel은 명시적으로 전환하기 전까지 K3s에 붙이지 않는다.

## 2. 이미지 생성과 release 태그 검증

~~~powershell
__FRONTEND_BUILD_COMMAND__

C:\K3s\scripts\Test-K3sReleaseImages.ps1 `
  -Environment __ENVIRONMENT____REQUIRE_REGISTRY_FLAG__

C:\K3s\scripts\Test-K3sImagePolicy.ps1 `
  -IncludeCloudflared `
  -IncludeJobs `
  -IncludeBuildFiles `
  -IncludeScripts `
  -FailOnMutableTags
~~~

## 3. Secret과 외부 의존성 준비

~~~powershell
C:\K3s\scripts\New-DockySecretFromEnv.ps1 `
  -EnvPath C:\compose\.env `
  -ExtraEnvPath C:\secret\docky-k3s-extra.env `
  -CloudflareTunnelToken <staging-or-prod-tunnel-token> `
  -OutputPath C:\K3s\runtime\docky-secret.yml

<!-- non-docker-start -->
C:\K3s\scripts\New-GhcrImagePullSecret.ps1 `
  -Username <ghcr-username> `
  -Token <ghcr-token> `
  -OutputPath C:\K3s\runtime\ghcr-pull-secret.yml

Ollama is deployed inside Kubernetes as `StatefulSet/ollama` and `Service/ollama` on port `11435`. Confirm the model before cutover:

~~~powershell
kubectl --kubeconfig __KUBECONFIG__ exec -n docky statefulset/ollama -- ollama list
~~~
<!-- non-docker-end -->

C:\K3s\scripts\Test-K3sSecretManifests.ps1__SKIP_GHCR_SECRET_FLAG__
C:\K3s\scripts\Test-K3sExternalDependencies.ps1 `
  -Environment __ENVIRONMENT__ `
  -FailOnUnresolved
~~~

<!-- non-docker-start -->
Ollama is deployed inside Kubernetes as `StatefulSet/ollama` and `Service/ollama` on port `11435`. Confirm the model before cutover:

~~~powershell
kubectl --kubeconfig __KUBECONFIG__ exec -n docky statefulset/ollama -- ollama list
~~~
<!-- non-docker-end -->

## 4. Kubeconfig와 cluster prereq

~~~powershell
C:\K3s\scripts\Import-K3sKubeconfig.ps1 `
  -SourcePath C:\secret\k3s.yml `
  -OutputPath __KUBECONFIG__ `
  -TestClusterConnection

C:\K3s\scripts\Test-K3sClusterPrereqs.ps1 `
  -Kubeconfig __KUBECONFIG__ `
  -Environment __ENVIRONMENT__
~~~

## 5. 백업 생성과 검증

~~~powershell
C:\K3s\scripts\Invoke-K3sComposeBackup.ps1 -ConfirmBackup

C:\K3s\scripts\Test-K3sBackupSet.ps1 `
  -BackupPath __BACKUP_PATH__ `
  -RequireOracle `
  -RequireRedis `
  -RequireMinio `
  -RequireMinioContent

C:\K3s\scripts\Test-K3sStoragePlan.ps1 `
  -BackupPath __BACKUP_PATH__ `
  -FailOnInsufficient
~~~

## 6. 최초 apply와 server dry-run

~~~powershell
C:\K3s\scripts\Test-K3sCutoverGate.ps1 `
  -Environment __ENVIRONMENT__ `
  -Kubeconfig __KUBECONFIG__ `
  -BackupPath __BACKUP_PATH____CLOUDFLARED_APPLY_FLAG____BOOTSTRAP_APPLY_FLAG__

C:\K3s\scripts\Test-K3sRunbooks.ps1 `
  -Environment __ENVIRONMENT__ `
  -RequireGeneratedRunbook `
  -RequireRollbackRunbook

C:\K3s\scripts\Invoke-K3sApplySequence.ps1 `
  -Environment __ENVIRONMENT__ `
  -Kubeconfig __KUBECONFIG__ `
  -BackupPath __BACKUP_PATH__ `
  -ConfirmApply__CLOUDFLARED_APPLY_FLAG____BOOTSTRAP_APPLY_FLAG__
~~~

## 7. 데이터 복구

Oracle SQLFILE rehearsal:

~~~powershell
C:\K3s\scripts\Invoke-K3sOracleSqlfileRehearsal.ps1 `
  -DumpFile __BACKUP_PATH__\oracle\docky-<timestamp>.dmp `
  -Kubeconfig __KUBECONFIG__ `
  -SystemPassword <oracle-system-password>
~~~

Oracle 실제 restore:

~~~powershell
C:\K3s\scripts\Invoke-K3sOracleRestore.ps1 `
  -DumpFile __BACKUP_PATH__\oracle\docky-<timestamp>.dmp `
  -Kubeconfig __KUBECONFIG__ `
  -ReadCredentialsFromClusterSecret `
  -ConfirmRestore
~~~

MinIO restore:

~~~powershell
C:\K3s\scripts\Invoke-K3sMinioRestore.ps1 `
  -MinioDataBackupPath __BACKUP_PATH__\minio\minio-data `
  -Kubeconfig __KUBECONFIG__ `
  -ReplaceExisting `
  -ConfirmRestore
~~~

Redis restore 결정:

Redis를 새 상태로 시작하기로 결정했다면 이 단계를 실행하지 않는다. 기존 Redis 상태를 유지해야 한다면 runbook을 `-RestoreRedis`로 다시 생성한다.

__REDIS_RESTORE_BLOCK__

복구 검증:

~~~powershell
C:\K3s\scripts\Test-K3sRestoredData.ps1 `
  -Kubeconfig __KUBECONFIG__ `
  -BackupPath __BACKUP_PATH____ALLOW_EMPTY_REDIS_FLAG__
~~~

## 8. 후속 검증과 진단 스냅샷

~~~powershell
C:\K3s\scripts\Invoke-K3sPostApplyValidation.ps1 `
  -Kubeconfig __KUBECONFIG__ `
  -BaseUrl __BASE_URL__ `
  -IncludeExternalServices `
  -IncludeWebSocket `
  __CLOUDFLARED_POST_FLAG__

C:\K3s\scripts\Collect-K3sDiagnostics.ps1 `
  -Kubeconfig __KUBECONFIG____CLOUDFLARED_POST_FLAG__
~~~

## 9. production 완료 판정과 설명서 생성

이 단계는 production 전환 후에만 실행한다. staging이나 Docker Desktop 검증에서는 완료 판정 문서를 생성하지 않는다.

__COMPLETION_BLOCK__

## 10. rollback 기준

- 전환 전 Compose 상태와 public route 상태를 기록한다.
- K3s 검증 실패 시 Cloudflare/DNS route를 Compose 쪽으로 되돌린다.
- `C:\compose`는 rollback 기준이므로 전환 준비 중 수정하지 않는다.
- `C:\K3s\runtime\rendered`와 `C:\K3s\runtime\diagnostics`의 최신 스냅샷을 장애 분석 기준으로 보관한다.
