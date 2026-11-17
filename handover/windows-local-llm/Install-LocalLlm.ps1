param(
    [switch]$SkipApplications
)

$ErrorActionPreference = 'Stop'
$ApiBase = 'https://littlem.cachyos-x8664/v1'
$ExpectedFingerprint = '6AC744AE120E66FE258AFA5CD268F142E8C390924860BBED77969B5C2D883109'
$CertificatePath = Join-Path $PSScriptRoot 'caddy-local-authority-root.crt'
$KeyDirectory = Join-Path $env:APPDATA 'LUNI-LLM'
$KeyPath = Join-Path $KeyDirectory 'litellm-api-key.dpapi'
$BinDirectory = Join-Path $env:LOCALAPPDATA 'LUNI-LLM\bin'
$OpenCodeConfigPath = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'

function Get-CertificateFingerprint([byte[]]$RawData) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($RawData))).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
}

function Set-JsonProperty($Target, [string]$Name, $Value) {
    if ($Target -is [System.Collections.IDictionary]) {
        $Target[$Name] = $Value
        return
    }
    $property = $Target.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $Target | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    } else {
        $property.Value = $Value
    }
}

function Add-UserPath([string]$Directory) {
    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($current -split ';' | Where-Object { $_ })
    if (-not ($entries | Where-Object { $_.TrimEnd('\') -ieq $Directory.TrimEnd('\') })) {
        $entries += $Directory
        [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')
    }
    if (($env:Path -split ';' | Where-Object { $_.TrimEnd('\') -ieq $Directory.TrimEnd('\') }).Count -eq 0) {
        $env:Path = "$Directory;$env:Path"
    }
}

function Install-OpenCode {
    if (Get-Command opencode -ErrorAction SilentlyContinue) {
        Write-Host 'OpenCode ist bereits installiert.'
        return
    }

    $installDirectory = Join-Path $env:LOCALAPPDATA 'Programs\OpenCode'
    $temporaryDirectory = Join-Path $env:TEMP ("opencode-" + [Guid]::NewGuid().ToString('N'))
    $archive = "$temporaryDirectory.zip"
    New-Item -ItemType Directory -Force -Path $temporaryDirectory | Out-Null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing `
            -Uri 'https://opencode.ai/update/api/latest/cli/opencode/opencode-windows-x64.zip' `
            -OutFile $archive
        Expand-Archive -LiteralPath $archive -DestinationPath $temporaryDirectory -Force
        $executable = Get-ChildItem -LiteralPath $temporaryDirectory -Filter 'opencode.exe' -Recurse |
            Select-Object -First 1
        if ($null -eq $executable) {
            throw 'Der offizielle OpenCode-Download enthaelt kein opencode.exe.'
        }
        New-Item -ItemType Directory -Force -Path $installDirectory | Out-Null
        Copy-Item -LiteralPath $executable.FullName -Destination (Join-Path $installDirectory 'opencode.exe') -Force
    } finally {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    }
    Add-UserPath $installDirectory
    Write-Host "OpenCode installiert: $installDirectory"
}

function Install-Copilot {
    if (Get-Command copilot -ErrorAction SilentlyContinue) {
        Write-Host 'Copilot CLI ist bereits installiert.'
        return
    }
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($null -eq $winget) {
        throw 'winget fehlt. Installiere zuerst den App Installer aus dem Microsoft Store und starte dieses Skript erneut.'
    }
    & $winget.Source install --id GitHub.Copilot --exact `
        --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "Copilot CLI Installation mit winget ist fehlgeschlagen (Exitcode $LASTEXITCODE)."
    }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $env:Path = "$machinePath;$userPath"
    if (-not (Get-Command copilot -ErrorAction SilentlyContinue)) {
        Write-Host 'Copilot CLI installiert; ein neues Terminal ist noetig, damit PATH aktualisiert wird.'
    } else {
        Write-Host 'Copilot CLI installiert.'
    }
}

if (-not (Test-Path -LiteralPath $CertificatePath)) {
    throw "Caddy-Root fehlt: $CertificatePath"
}
$pem = Get-Content -LiteralPath $CertificatePath -Raw
if ($pem -notmatch '(?s)-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----') {
    throw 'Die Zertifikatsdatei ist kein PEM-Zertifikat.'
}
$der = [Convert]::FromBase64String(($Matches[1] -replace '\s', ''))
$certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($der)
$fingerprint = Get-CertificateFingerprint $certificate.RawData
if ($fingerprint -ne $ExpectedFingerprint) {
    throw "Caddy-Root Fingerprint stimmt nicht. Erwartet $ExpectedFingerprint, erhalten $fingerprint. Nichts wurde importiert."
}

$store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
    [System.Security.Cryptography.X509Certificates.StoreName]::Root,
    [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser
)
try {
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    $vorhanden = $false
    foreach ($item in $store.Certificates) {
        if ((Get-CertificateFingerprint $item.RawData) -eq $ExpectedFingerprint) {
            $vorhanden = $true
            break
        }
    }
    if (-not $vorhanden) {
        $store.Add($certificate)
        Write-Host 'Caddy-Root im Zertifikatsspeicher des aktuellen Benutzers installiert.'
    } else {
        Write-Host 'Caddy-Root ist bereits im Zertifikatsspeicher des aktuellen Benutzers.'
    }
} finally {
    $store.Close()
}

New-Item -ItemType Directory -Force -Path $KeyDirectory | Out-Null
$secureKey = Read-Host 'Persoenlichen LiteLLM-Virtual-Key eingeben' -AsSecureString
if ($secureKey.Length -eq 0) {
    throw 'Der LiteLLM-Virtual-Key darf nicht leer sein.'
}

$plainKey = $null
$pointer = [IntPtr]::Zero
$http = $null
$request = $null
$response = $null
try {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    $plainKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.CheckCertificateRevocationList = $false
    $http = [System.Net.Http.HttpClient]::new($handler)
    $request = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::Get, "$ApiBase/models"
    )
    $request.Headers.Authorization =
        [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $plainKey)
    $response = $http.SendAsync($request).GetAwaiter().GetResult()
    if ([int]$response.StatusCode -ne 200) {
        throw "LiteLLM hat HTTP $([int]$response.StatusCode) geliefert. Key/Rollen pruefen; er wurde nicht gespeichert."
    }

    $encryptedKey = ConvertFrom-SecureString $secureKey
    Set-Content -LiteralPath $KeyPath -Value $encryptedKey -Encoding ascii -NoNewline
} catch {
    if ($_.Exception.Message -like 'LiteLLM hat HTTP *') { throw }
    throw "LiteLLM-Verbindung fehlgeschlagen; Key wurde nicht gespeichert. DNS/Route, Zertifikat und LAN-Verbindung pruefen. Details: $($_.Exception.Message)"
} finally {
    if ($null -ne $response) { $response.Dispose() }
    if ($null -ne $request) { $request.Dispose() }
    if ($null -ne $http) { $http.Dispose() }
    if ($pointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
    $plainKey = $null
    $secureKey.Dispose()
}

if (-not $SkipApplications) {
    Install-OpenCode
    Install-Copilot
}

if (Test-Path -LiteralPath $OpenCodeConfigPath) {
    try {
        $config = Get-Content -LiteralPath $OpenCodeConfigPath -Raw | ConvertFrom-Json
    } catch {
        throw "OpenCode-Konfiguration ist kein gueltiges JSON: $OpenCodeConfigPath. Datei nicht geaendert. Details: $($_.Exception.Message)"
    }
    Copy-Item -LiteralPath $OpenCodeConfigPath `
        -Destination "$OpenCodeConfigPath.bak-llm-infra-$(Get-Date -Format yyyyMMdd-HHmmss)" -Force
} else {
    $config = [pscustomobject]@{}
}

$modelDefinitions = [pscustomobject]@{
    'local-short-none' = [pscustomobject]@{
        name = 'Local Short (no reasoning)'
        limit = [pscustomobject]@{ context = 131808; output = 8192 }
    }
    'local-medium-xhigh' = [pscustomobject]@{
        name = 'Local Medium (xhigh reasoning)'
        limit = [pscustomobject]@{ context = 241664; output = 8192 }
    }
    'local-long-xhigh' = [pscustomobject]@{
        name = 'Local Long (xhigh reasoning)'
        limit = [pscustomobject]@{ context = 461808; output = 8192 }
    }
}
$provider = [pscustomobject]@{
    name = 'LUNI Local LiteLLM'
    env = @('LITELLM_API_KEY')
    package = '@opencode/ai/providers/openai-compatible'
    settings = [pscustomobject]@{ baseURL = $ApiBase }
    models = $modelDefinitions
}
if ($null -eq $config.providers) {
    Set-JsonProperty $config 'providers' ([pscustomobject]@{})
}
Set-JsonProperty $config.providers 'luni-local' $provider
Set-JsonProperty $config 'model' 'luni-local/local-medium-xhigh'
Set-JsonProperty $config '$schema' 'https://opencode.ai/config.json'
$policies = @()
foreach ($existingPolicy in @($config.policies)) {
    if ($existingPolicy.action -ne 'provider.use') {
        $policies += $existingPolicy
    }
}
$policies += [pscustomobject]@{
    action = 'provider.use'
    resource = '*'
    effect = 'deny'
}
$policies += [pscustomobject]@{
    action = 'provider.use'
    resource = 'luni-local'
    effect = 'allow'
}
Set-JsonProperty $config 'policies' $policies
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OpenCodeConfigPath) | Out-Null
$json = ConvertTo-Json -InputObject $config -Depth 40
[IO.File]::WriteAllText($OpenCodeConfigPath, ($json + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))

New-Item -ItemType Directory -Force -Path $BinDirectory | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Run-LocalLlm.ps1') -Destination $BinDirectory -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'opencode-local.cmd') -Destination $BinDirectory -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'copilot-local.cmd') -Destination $BinDirectory -Force
Add-UserPath $BinDirectory

Write-Host ''
Write-Host 'Einrichtung abgeschlossen: nur der lokale LiteLLM-Endpunkt und local-* Modelle sind konfiguriert.' -ForegroundColor Green
Write-Host 'Neues Terminal oeffnen, dann opencode-local oder copilot-local starten.'
Write-Host "OpenCode-Konfiguration: $OpenCodeConfigPath"
Write-Host 'API-Key: DPAPI-verschluesselt im Benutzerprofil; nicht in der Konfiguration.'
