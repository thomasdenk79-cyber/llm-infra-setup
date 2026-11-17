$ErrorActionPreference = 'Stop'
$keyPath = Join-Path $env:APPDATA 'LUNI-LLM\litellm-api-key.dpapi'
if (-not (Test-Path -LiteralPath $keyPath)) {
    throw "LiteLLM-Key fehlt: $keyPath. Install-LocalLlm.ps1 erneut ausfuehren."
}
$previousApiKey = [Environment]::GetEnvironmentVariable('LITELLM_API_KEY', 'Process')
$secureKey = Get-Content -LiteralPath $keyPath -Raw | ConvertTo-SecureString
$pointer = [IntPtr]::Zero
$plainKey = $null
try {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    $plainKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    $env:LITELLM_API_KEY = $plainKey
    $command = Get-Command opencode -ErrorAction Stop
    & $command.Source @args
    $result = $LASTEXITCODE
} finally {
    if ($null -eq $previousApiKey) {
        Remove-Item Env:LITELLM_API_KEY -ErrorAction SilentlyContinue
    } else {
        $env:LITELLM_API_KEY = $previousApiKey
    }
    if ($pointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
    $plainKey = $null
    $secureKey.Dispose()
}
if ($null -eq $result) { $result = 0 }
exit $result
