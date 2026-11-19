param(
  [string]$ApiKey = "",
  [switch]$DryRun
)
# LUNI Gateway-Kit - SETUP (ohne Adminrechte)
$ErrorActionPreference = "Continue"
$GATEWAY = "https://edipoc-gateway.westeurope.cloudapp.azure.com"
$MODEL   = "local-medium-xhigh"  # Standardroute (balanced); zur Wahl: local-short-none, local-long-xhigh
$here    = $PSScriptRoot
function Say($msg, $col = "Gray") { Write-Host $msg -ForegroundColor $col }

Say "== 1/6 Zertifikat (Caddy-Root) in den Benutzer-Stammspeicher =="
$cert = Join-Path $here "root.crt"
if (-not (Test-Path $cert)) { Say "root.crt fehlt - brich ab" Red; exit 1 }
if ($DryRun) { Say "DryRun: certutil -addstore -user Root $cert" Yellow }
else { certutil.exe -addstore -user Root $cert | Out-Null; Say "Zertifikat importiert (oder war schon drin)." Green }

Say "== 2/6 Node-CLIs installieren/aktualisieren (opencode, Copilot CLI) =="
$npm = Get-Command npm -ErrorAction SilentlyContinue
if (-not $npm) {
  Say "npm/node nicht gefunden - Ueberspringen. Optional: winget install OpenJS.NodeJS.LTS" Yellow
} else {
  foreach ($p in "opencode-ai@latest", "@github/copilot@latest") {
    if ($DryRun) { Say "DryRun: npm install -g --allow-scripts=opencode-ai,@github/copilot $p" Yellow }
    else {
      Say "npm install -g $p ..." Cyan
      & npm install -g --allow-scripts=opencode-ai,@github/copilot $p 2>&1 | Select-Object -Last 1
    }
  }
}

Say "== 3/6 API-Key =="
if (-not $ApiKey) {
  $secure = Read-Host "Persoenlichen LUNI-API-Key eingeben (sk-..., wird nicht angezeigt)" -AsSecureString
  if ($secure) { $ApiKey = [Net.NetworkCredential]::new('', $secure).Password }
}
if (-not $ApiKey) { Say "Kein Key angegeben - Umgebungsvariablen fuer Key werden nicht gesetzt." Yellow }
elseif ($ApiKey -notmatch '^sk-') { Say "Key sieht nicht nach sk-... aus - trotzdem gespeichert." Yellow }

Say "== 4/6 Umgebungsvariablen (setx, wirkt in NEUEN Terminals) =="
$envVars = @{
  NODE_EXTRA_CA_CERTS          = $cert
  COPILOT_PROVIDER_TYPE        = "openai"
  COPILOT_PROVIDER_BASE_URL    = "$GATEWAY/v1"
  COPILOT_MODEL                = $MODEL
}
if ($ApiKey) {
  $envVars["LUNI_API_KEY"]              = $ApiKey
  $envVars["COPILOT_PROVIDER_API_KEY"]  = $ApiKey
}
foreach ($k in $envVars.Keys) {
  if ($DryRun) { Say ("DryRun: setx {0} ..." -f $k) Yellow }
  else {
    Start-Process -FilePath setx.exe -ArgumentList @($k, "`"$($envVars[$k])`"") -NoNewWindow -Wait
    [Environment]::SetEnvironmentVariable($k, $envVars[$k], "Process")
  }
}
if (-not $DryRun) { Say "Umgebung gesetzt." Green }

Say "== 5/6 opencode-Konfiguration (~\.config\opencode\opencode.json) =="
$ocDir  = Join-Path $env:USERPROFILE ".config\opencode"
$ocPath = Join-Path $ocDir "opencode.json"
$luni = @{
  npm     = "@ai-sdk/openai-compatible"
  options = @{ baseURL = "$GATEWAY/v1"; apiKey = "{env:LUNI_API_KEY}" }
  models  = @{
    "local-short-none"   = @{ name = "LUNI efficient (kein Reasoning)" }
    "local-medium-xhigh" = @{ name = "LUNI balanced (Reasoning xhigh)" }
    "local-long-xhigh"   = @{ name = "LUNI intelligent (xhigh, 462k)" }
  }
}
if ($DryRun) { Say "DryRun: schreibe provider.luni in $ocPath" Yellow }
else {
  New-Item -ItemType Directory -Force -Path $ocDir | Out-Null
  $cfg = $null
  if (Test-Path $ocPath) {
    try { $cfg = Get-Content $ocPath -Raw | ConvertFrom-Json }
    catch { Copy-Item $ocPath "$ocPath.bak" -Force; Say "Bestehende opencode.json ungueltig - Backup angelegt: $ocPath.bak" Yellow }
  }
  if (-not $cfg) { $cfg = [PSCustomObject]@{} }
  if (-not $cfg.PSObject.Properties["provider"]) { $cfg | Add-Member NoteProperty provider ([PSCustomObject]@{}) }
  $cfg.provider | Add-Member -Force NoteProperty luni ($luni | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
  $cfg | ConvertTo-Json -Depth 10 | Set-Content $ocPath -Encoding UTF8
  Say "opencode-Konfig aktualisiert: Modell 'luni/$MODEL'" Green
}

Say "== 6/6 Funktionstest =="
if ($DryRun -or -not $ApiKey) { Say "DryRun oder kein Key - Test uebersprungen." Yellow }
else {
  try {
    $r = Invoke-RestMethod -Uri "$GATEWAY/v1/models" -Headers @{ Authorization = "Bearer $ApiKey" } -TimeoutSec 30
    $hit = $r.data | Where-Object { $_.id -eq $MODEL }
    if ($hit) { Say "TEST ERFOLGREICH: $MODEL erreichbar." Green }
    else      { Say "Verbunden, aber Modell nicht in Liste?" Yellow }
  } catch { Say "FEHLER: $($_.Exception.Message)" Red }
}

Say ""
Say "Fertig. Neue Terminals oeffnen, dann:" Green
Say "  opencode run -m luni/$MODEL 'hallo'" White
Say "  copilot    (BYOK aktiv ueber COPILOT_PROVIDER_*-Variablen)" White
