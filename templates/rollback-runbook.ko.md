# Docky K3s Rollback Runbook

작성 시각: __CREATED_AT__
대상 환경: __ENVIRONMENT__
검증 URL: __BASE_URL__
Kubeconfig: __KUBECONFIG__

이 문서는 K3s 전환 중 검증 실패, 심각한 장애, 외부 라우팅 문제, 데이터 복구 문제를 발견했을 때 Compose 기준 운영으로 되돌리기 위한 실행 순서다. `C:\compose`는 rollback 기준이므로 이 문서의 어떤 단계에서도 수정하지 않는다.

## 1. 즉시 판단 기준

- 로그인, API, WebSocket, 업로드, 스트리밍, 관리자 경로 중 핵심 경로가 실패한다.
- Oracle/MinIO/Redis 복구 검증이 실패한다.
- Cloudflare/DNS route가 K3s ingress까지 안정적으로 도달하지 않는다.
- backend가 반복 재시작하거나 strict security/env 검증에 실패한다.
- 원인 분석보다 서비스 복구가 우선인 cutover window다.

## 2. 증거 보존

Rollback 전에 K3s 상태를 먼저 남긴다. Secret 리소스는 수집하지 않지만, 로그에는 URL이나 사용자 데이터가 섞일 수 있으므로 외부 공유 전 검토한다.

__DIAGNOSTIC_COMMAND__

## 3. 외부 라우팅 복구

- Cloudflare Tunnel 또는 DNS public route를 Compose가 받던 기존 대상으로 되돌린다.
- production tunnel token을 K3s에 붙였다면 Cloudflare public hostname target을 Compose 쪽으로 되돌린다.
- staging rollback도 같은 방식으로 이전 staging route owner를 복구한다.
- DNS TTL, Cloudflare cache, browser cache 때문에 즉시 반영되지 않을 수 있으므로 route owner를 기준으로 확인한다.

## 4. K3s 트래픽 중지

외부 라우팅을 Compose 쪽으로 되돌린 뒤 K3s가 계속 일부 트래픽을 받지 않도록 app entrypoint를 멈춘다. PVC와 namespace는 삭제하지 않는다.

__PAUSE_COMMAND__

## 5. Compose 경로 검증

라우팅을 되돌린 뒤 사용자가 접근하는 같은 URL에서 smoke를 실행한다. 이 검증은 Compose가 다시 트래픽을 받고 있다는 운영 확인이다.

__VALIDATION_COMMAND__

## 6. 금지 작업

- `kubectl delete pvc`를 실행하지 않는다.
- `kubectl delete namespace docky`를 실행하지 않는다.
- `C:\compose` 아래 파일을 수정하지 않는다.
- K3s PVC 데이터를 덮어쓰는 restore 스크립트를 rollback 중 반복 실행하지 않는다.
- 실패 원인이 확인되기 전 production Cloudflare tunnel을 K3s에 다시 붙이지 않는다.

## 7. rollback 후 정리

- Compose route가 정상임을 기록한다.
- `C:\K3s\runtime\diagnostics`의 최신 스냅샷 위치를 장애 분석 기준으로 남긴다.
- K3s의 rendered manifest snapshot, image tag, secret 생성 시각, backup set 경로를 같이 기록한다.
- 다시 전환을 시도하기 전에 `Get-K3sMigrationStatus.ps1`와 target runbook을 새로 생성한다.
