param(
    [string]$LanIp = '192.168.0.198',
    [string]$Domain = 'cachyos-x8664'
)

$ErrorActionPreference = 'Stop'
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$startMarker = '# BEGIN LUNI local-LLM routes'
$endMarker = '# END LUNI local-LLM routes'

if ($LanIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or
    @($LanIp.Split('.') | Where-Object { [int]$_ -gt 255 }).Count -gt 0) {
    throw "Ungueltige IPv4-Adresse: $LanIp"
}
if ($Domain -notmatch '^[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?$') {
    throw "Ungueltige lokale Domain: $Domain"
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Dieses Skript muss nur fuer die hosts-Datei als Administrator laufen.'
}
if (-not (Test-Path -LiteralPath $hostsPath)) {
    throw "hosts-Datei fehlt: $hostsPath"
}

$names = @("homepage.$Domain", "littlem.$Domain")
$content = @(Get-Content -LiteralPath $hostsPath -Encoding ascii)
$newContent = New-Object System.Collections.Generic.List[string]
$inside = $false
foreach ($line in $content) {
    if ($line -eq $startMarker) {
        if ($inside) { throw 'Doppelter BEGIN-Marker in der hosts-Datei.' }
        $inside = $true
        continue
    }
    if ($line -eq $endMarker) {
        if (-not $inside) { throw 'END-Marker ohne BEGIN-Marker in der hosts-Datei.' }
        $inside = $false
        continue
    }
    if (-not $inside) { $newContent.Add($line) }
}
if ($inside) { throw 'BEGIN-Marker ohne END-Marker in der hosts-Datei.' }
$newContent.Add($startMarker)
$newContent.Add("$LanIp $($names -join ' ')")
$newContent.Add($endMarker)
Set-Content -LiteralPath $hostsPath -Value $newContent -Encoding ascii
ipconfig.exe /flushdns | Out-Null
Write-Host "Nur diese lokalen Namen wurden eingetragen: $($names -join ', ')" -ForegroundColor Green
