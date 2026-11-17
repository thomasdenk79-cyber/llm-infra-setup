param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('opencode', 'copilot')]
    [string]$Client
)

$ErrorActionPreference = 'Stop'
$keyPath = Join-Path $env:APPDATA 'LUNI-LLM\litellm-api-key.dpapi'
if (-not (Test-Path -LiteralPath $keyPath)) {
    throw "LiteLLM-Key fehlt: $keyPath. Install-LocalLlm.ps1 erneut ausfuehren."
}

$providerVariables = @(
    'LITELLM_API_KEY',
    'COPILOT_PROVIDER_BASE_URL',
    'COPILOT_PROVIDER_TYPE',
    'COPILOT_PROVIDER_API_KEY',
    'COPILOT_MODEL'
)
$previousProviderValues = @{}
foreach ($name in $providerVariables) {
    $previousProviderValues[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

$secureKey = Get-Content -LiteralPath $keyPath -Raw | ConvertTo-SecureString
$pointer = [IntPtr]::Zero
$plainKey = $null
$result = 0
try {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    $plainKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    if ($Client -eq 'opencode') {
        $env:LITELLM_API_KEY = $plainKey
        $command = Get-Command opencode -ErrorAction Stop
    } else {
        $env:COPILOT_PROVIDER_BASE_URL = 'https://littlem.cachyos-x8664/v1'
        $env:COPILOT_PROVIDER_TYPE = 'openai'
        $env:COPILOT_PROVIDER_API_KEY = $plainKey
        $env:COPILOT_MODEL = if ($env:LOCAL_LLM_MODEL) { $env:LOCAL_LLM_MODEL } else { 'local-medium-xhigh' }
        $command = Get-Command copilot -ErrorAction Stop
    }

    & $command.Source @args
    if ($null -ne $LASTEXITCODE) { $result = $LASTEXITCODE }
} finally {
    foreach ($name in $providerVariables) {
        $previousValue = $previousProviderValues[$name]
        if ($null -eq $previousValue) {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        } else {
            Set-Item "Env:$name" -Value $previousValue
        }
    }
    if ($pointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
    $plainKey = $null
    $secureKey.Dispose()
}
exit $result
