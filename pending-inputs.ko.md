# K3s ?꾪솚 ???꾩슂??寃곗젙/?낅젰媛?
??臾몄꽌???꾩쭅 ?먮룞?쇰줈 ?뺤젙?????녿뒗 ??ぉ留?紐⑥븘 ??紐⑸줉?대떎.
`C:\compose`??怨꾩냽 ?쎄린 ?꾩슜 湲곗??쇰줈留??ъ슜?섍퀬, ?ㅼ젣 ?곸슜/蹂듦뎄/?꾪솚?
?꾨옒 ??ぉ???뺤젙???ㅼ뿉 吏꾪뻾?쒕떎.

## 1. K3s ????대윭?ㅽ꽣 kubeconfig

?꾩슂??寃곗젙:

- ?ㅼ젣 K3s ?대윭?ㅽ꽣??kubeconfig ?뚯씪 ?꾩튂
- ??kubeconfig瑜?`C:\K3s\runtime\kubeconfig.yml`濡?蹂듭궗???ъ슜?좎? ?щ?

?뺤씤 紐낅졊:

```powershell
C:\K3s\scripts\Import-K3sKubeconfig.ps1 `
  -SourcePath C:\secret\k3s.yml `
  -OutputPath C:\K3s\runtime\kubeconfig.yml `
  -TestClusterConnection

C:\K3s\scripts\Test-K3sClusterPrereqs.ps1 `
  -Kubeconfig C:\K3s\runtime\kubeconfig.yml `
  -Environment production
```

?꾩옱 ?곹깭:

- `kubectl`? ?ㅼ튂?섏뼱 ?덉?留?current-context媛 ?녿떎.
- ?ㅼ젣 Kubernetes apply 寃利앹? ?꾩쭅 遺덇??ν븯??

## 2. Production/Staging ?대?吏 ?쒓렇

?꾩슂??寃곗젙:

- backend? frontend??release ?쒓렇 ?대쫫
- GHCR??push?좎? ?щ?
- frontend ?뚯뒪 鍮뚮뱶瑜?湲곕떎由댁?, ?꾩옱 Compose ?뺤쟻 ?곗텧臾쇱쓣 ?꾩떆 release濡??ъ슜?좎?

?꾩옱 濡쒖뺄 寃利??대?吏:

- backend: `ghcr.io/kjsu1994/docky-backend:local-k3s-verify-20260616`
- frontend: `ghcr.io/kjsu1994/docky-frontend-nginx:local-validator-compose-current-20260616`

二쇱쓽:

- ???쒓렇??Docker Desktop 濡쒖뺄 寃利앹슜?대떎.
- ?ㅼ젣 K3s ?몃뱶?먯꽌 ?곕젮硫?GHCR??push??release ?쒓렇媛 ?꾩슂?섎떎.
- ?꾩옱 production/staging 留ㅻ땲?섏뒪?몃뒗 `replace-me` ?쒓렇瑜??섎룄?곸쑝濡??좎??섍퀬 ?덉뼱,
  release ?쒓렇媛 ?뺥빐吏湲??꾩뿉??cutover gate媛 ?ㅽ뙣?쒕떎.
- production/staging?먮뒗 `local-*`, `dev-*`, `test-*`, `*-compose-current` 媛숈?
  濡쒖뺄/?꾩떆 ?쒓렇瑜??곗? ?딅뒗?? `Test-K3sReleaseImages.ps1`媛 ?대? 寃?ы븳??

?곸슜 紐낅졊:

```powershell
C:\K3s\scripts\Invoke-K3sImagePipeline.ps1 `
  -Tag <release-tag> `
  -Push `
  -UpdateManifests

C:\K3s\scripts\Test-K3sReleaseImages.ps1 `
  -Environment production `
  -RequireRegistryAvailability
```

?꾨줎???뚯뒪媛 ?꾩쭅 鍮뚮뱶 遺덇??쇰㈃:

```powershell
C:\K3s\scripts\Test-K3sFrontendStaticSource.ps1 `
  -DistPath C:\compose\minio-data\client\current

C:\K3s\scripts\Invoke-K3sImagePipeline.ps1 `
  -Tag <frontend-release-tag> `
  -SkipBackendImage `
  -UseComposeFrontendCurrent `
  -Push `
  -UpdateManifests
```

?꾩옱 Compose ?뺤쟻 ?꾨줎???곗텧臾쇱? 援ъ“ 寃利앹쓣 ?듦낵?덉?留? 踰덈뱾 ?덉뿉
`http://localhost` 臾몄옄?댁씠 ?덉뼱 production ?밴꺽 ??寃?좉? ?꾩슂?섎떎.

## 3. Runtime Secret

?꾩슂??寃곗젙/?낅젰:

- Oracle root 鍮꾨?踰덊샇
- Oracle app user/app password
- Spring datasource username/password
- JWT secret
- OAuth client secret
- SMTP 怨꾩젙
- DART/KIS API key
- Cloudflare Tunnel token

?낅젰 ?뚯씪:

- ?쒗뵆由? `C:\K3s\secrets\docky-k3s-extra.env.example`
- ?ㅼ젣 ?뚯씪? `C:\compose`??Git 愿由?寃쎈줈媛 ?꾨땶 蹂꾨룄 ?덉쟾???꾩튂???붾떎.
- `C:\secret\docky-k3s-extra.env`泥섎읆 `C:\compose`? `C:\K3s` 諛뽰쓽 寃쎈줈???붾떎.
- 媛믪씠 以鍮꾨릺硫?`C:\K3s\scripts\Test-K3sSecretSources.ps1 -RequireExtraEnv -RequireAllKeys`濡???議댁옱? ?꾩튂留?寃利앺븳??

?앹꽦/寃利?紐낅졊:

```powershell
C:\K3s\scripts\New-DockySecretFromEnv.ps1 `
  -EnvPath C:\compose\.env `
  -ExtraEnvPath C:\secret\docky-k3s-extra.env `
  -CloudflareTunnelToken <token> `
  -OutputPath C:\K3s\runtime\docky-secret.yml

C:\K3s\scripts\Test-K3sSecretManifests.ps1
```

?꾩옱 ?곹깭:

- `C:\K3s\runtime\docky-secret.yml`???꾩쭅 ?녿떎.
- Secret gate???뺤긽?곸쑝濡??ㅽ뙣 以묒씠??

## 4. GHCR pull secret

?꾩슂??寃곗젙/?낅젰:

- K3s ?몃뱶媛 `ghcr.io/kjsu1994/*` ?대?吏瑜?pull?????덈뒗 token
- token 沅뚰븳? 理쒖냼 `read:packages`

?앹꽦 紐낅졊:

```powershell
C:\K3s\scripts\New-GhcrImagePullSecret.ps1 `
  -Username kjsu1994 `
  -Token <ghcr-read-packages-token> `
  -OutputPath C:\K3s\runtime\ghcr-pull-secret.yml
```

Docker Desktop overlay??local image瑜??곕룄濡?`imagePullSecrets`瑜??쒓굅?덇린 ?뚮Ц????secret ?놁씠??濡쒖뺄 overlay ?뚮뜑留곸? ?듦낵?쒕떎. Production/staging?먮뒗 ?꾩슂?섎떎.

## 5. IoT ?몃? ?곌껐 諛⑹떇

?꾩옱 寃곗젙:

- IoT route???먭린?쒕떎.
- K3s target?먯꽌 `/iot`, `/iot-api`, `iot-external`? ?뚮뜑留곹븯吏 ?딅뒗??
- ?꾪솚 寃뚯씠?몃룄 IoT ?몃? ?곌껐???붽뎄?섏? ?딅뒗??

## 6. Ollama ?몃? ?곌껐 諛⑹떇

?꾩슂??寃곗젙:

- Ollama瑜?K3s ?대???諛고룷?좎?, ?몃? DNS濡??곌껐?좎?
- ?몃? ?곌껐?대㈃ K3s?먯꽌 ?묎렐 媛?ν븳 DNS ?대쫫
- Ollama瑜??꾪솚 ?쒖젏??耳ㅼ?, `OLLAMA_ENABLED=false`濡??꾩떆 鍮꾪솢?깊솕?좎?

?꾩옱 ?곹깭:

- Compose? K3s ConfigMap? `OLLAMA_ENABLED=true`濡?留욎떠???덈떎.
- production/staging??`ollama`? ?꾩쭅 placeholder?쇱꽌 ?ㅽ뙣?쒕떎.

DNS 諛⑹떇 ?곸슜 紐낅졊:

```powershell
kubectl exec -n docky statefulset/ollama -- ollama list
```

## 7. 諛깆뾽/蹂듦뎄 ?꾪솚 李?
?꾩슂??寃곗젙:

- Compose瑜??좉퉸 硫덉텛怨?cold backup???????덈뒗 ?쒓컙
- Redis瑜?蹂듦뎄?좎?, ???곹깭濡??쒖옉?좎?
- Oracle Data Pump SQLFILE rehearsal 寃곌낵瑜?寃?좏븷 ?대떦??
諛깆뾽/寃利?紐낅졊:

```powershell
C:\K3s\scripts\Invoke-K3sComposeBackup.ps1 -ConfirmBackup

C:\K3s\scripts\Test-K3sBackupSet.ps1 `
  -RequireOracle `
  -RequireRedis `
  -RequireMinio `
  -RequireMinioContent
```

?꾩옱 ?곹깭:

- `C:\K3s\backups` ?꾨옒??寃利앸맂 諛깆뾽 ?명듃媛 ?녿떎.
- production apply??諛깆뾽 寃쎈줈 ?놁씠???듦낵?섏? ?딄쾶 ?섏뼱 ?덈떎.

## 8. Cloudflare Tunnel ?꾪솚 諛⑹떇

?꾩슂??寃곗젙:

- staging tunnel??癒쇱? ?몄?
- production tunnel token???몄젣 K3s??遺숈씪吏
- 湲곗〈 Compose tunnel怨??숈떆??遺숇뒗 援ш컙???덉슜?좎?
- DNS/Cloudflare route rollback ?덉감

二쇱쓽:

- production tunnel token???덈Т ?쇱컢 ?곸슜?섎㈃ K3s媛 ?ㅼ젣 ?몃옒?쎌쓣 諛쏆쓣 ???덈떎.
- staging?먯꽌 癒쇱? 寃利앺븳 ??production route瑜??꾪솚?댁빞 ?쒕떎.

## 9. Docker Desktop Kubernetes 濡쒖뺄 寃利?
?꾩옱 以鍮꾨맂 寃?

- Docker Desktop overlay??`localhost`濡??뚮뜑留곷맂??
- Ollama??`host.docker.internal`濡??곌껐?쒕떎.
- imagePullSecrets???쒓굅?섏뼱 local image瑜??대떎.
- backend/frontend 濡쒖뺄 ?대?吏媛 Docker??議댁옱?쒕떎.

?꾩옱 ?⑥? 寃?

- `kubectl current-context`媛 ?녿떎.
- Docker Desktop Kubernetes瑜?耳쒓굅??kubeconfig瑜?吏?뺥빐???ㅼ젣 apply 寃利앹씠 媛?ν븯??

寃利?紐낅졊:

```powershell
C:\K3s\scripts\Test-K3sDockerDesktopReadiness.ps1

C:\K3s\scripts\Test-K3sDockerDesktopReadiness.ps1 `
  -RequireKubernetesContext
```

泥?踰덉㎏ 紐낅졊? ?꾩옱 ?듦낵?쒕떎. ??踰덉㎏ 紐낅졊? Kubernetes context媛 ?앷릿 ???듦낵?댁빞 ?쒕떎.

## 10. ?꾨즺 ?먯젙 湲곗?

?꾨즺濡?蹂대젮硫?理쒖냼???꾨옒 利앷굅媛 ?꾩슂?섎떎.

- production/staging 留ㅻ땲?섏뒪?몄뿉 `replace-me`媛 ?녿떎.
- production/staging ?대?吏 ?쒓렇媛 release ?쒓렇?대ŉ `Test-K3sReleaseImages.ps1`媛 ?듦낵?쒕떎.
- `Test-K3sCutoverGate.ps1 -Environment production`???듦낵?쒕떎.
- K3s cluster prereq媛 ?듦낵?쒕떎.
- 諛깆뾽 ?명듃 寃利앹씠 ?듦낵?쒕떎.
- Oracle/MinIO/Redis restore? `Test-K3sRestoredData.ps1`媛 ?듦낵?쒕떎.
- `Invoke-K3sApplySequence.ps1 -Environment production`??server dry-run ?ы븿 ?듦낵?쒕떎.
- `Invoke-K3sPostApplyValidation.ps1 -BaseUrl https://docky.co.kr`媛 ?듦낵?쒕떎.
- 吏꾨떒 ?ㅻ깄?룹씠 `C:\K3s\runtime\diagnostics` ?꾨옒???⑤뒗??
- `Test-K3sCompletionGate.ps1 -BackupPath C:\K3s\backups\<timestamp>`媛 ?듦낵?쒕떎.
- 洹??ㅼ뿉留?`New-K3sExplanation.ps1 -BackupPath C:\K3s\backups\<timestamp>`濡?  `C:\K3s\explan.md`瑜??묒꽦?쒕떎.
