# K3s 전환 입력 상태 보고서

작성 시각: __GENERATED_AT__
작업 루트: `__ROOT__`
대상 환경: `__ENVIRONMENT__`
kubeconfig: `__KUBECONFIG__`
백업 경로: `__BACKUP_PATH__`
Strict 모드: `__STRICT_MODE__`
레지스트리 이미지 조회 요구: `__REQUIRE_REGISTRY__`
JSON 원본: `__JSON_PATH__`

이 보고서는 실제 전환 전에 남아 있는 외부 입력과 실행 증거를 한 번에 확인하기 위한 기록이다. Secret 값은 출력하지 않고, 파일 존재 여부와 필수 키 이름 같은 준비 상태만 남긴다. `C:\compose`는 계속 읽기 전용 기준으로만 사용하며, 이 보고서와 JSON 파일은 `C:\K3s\runtime\reports` 아래에 생성된다.

## 요약

- PASS: __PASS_COUNT__
- WARN: __WARN_COUNT__
- FAIL: __FAIL_COUNT__

## 항목별 결과

| 항목 | 상태 | 상세 |
| --- | --- | --- |
__RESULT_ROWS__

## 판정 방법

- `PASS`: 해당 입력이나 증거가 준비되어 있다.
- `WARN`: 아직 준비되지 않았지만, 비엄격 모드에서는 전체 상태 확인을 계속할 수 있다.
- `FAIL`: Strict 모드이거나 필수 항목이어서 전환 게이트를 통과할 수 없다.

## 다음 확인 순서

1. `WARN` 또는 `FAIL` 항목부터 해결한다.
2. production/staging 이미지 태그, 외부 Ollama DNS, runtime secret, kubeconfig, backup set, rendered snapshot을 다시 검증한다.
3. `Test-K3sCutoverInputs.ps1 -Strict -WriteReport`가 통과할 때까지 보고서를 갱신한다.
4. 전환 완료 판정은 이 보고서만으로 하지 않고, 최종적으로 `Test-K3sCompletionGate.ps1`가 통과해야 한다.
