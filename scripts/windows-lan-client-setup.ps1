# Windows-LAN-Einrichtung fuer den LLM-Stapel (Einmal-Aufruf, PowerShell als Administrator)
#
# Was dieses Skript tut (alles idempotent):
#   1. hosts-Datei um die LAN-Namen des Rechners ergaenzen
#   2. das exportierte Caddy-Root importieren (falls als Datei angegeben)
#   3. jede Route pruefen und das Ergebnis ausgeben
#
# Vorbereitung auf dem Linux-Rechner (liefert beides):
#   ./scripts/74-setup-local-proxy.sh --ca-export      # Root-Datei + Pfade
#   ./scripts/74-setup-local-proxy.sh --print-hosts    # Namen und Adresse
#
# Aufruf auf Windows 11 (PowerShell als Administrator):
#   Set-ExecutionPolicy -Scope Process Bypass -Force
#   .\windows-lan-client-setup.ps1 -LanIp 192.168.0.198 -Domain cachyos-x8664 `
#       -CertPath C:\temp\caddy-local-authority-root.crt
#
# Rueckbau:
#   .\windows-lan-client-setup.ps1 -RemoveOnly
#   certutil -delstore ROOT "Caddy Local Authority"

param(
    [string]$LanIp = '192.168.0.198',
    [string]$Domain = 'cachyos-x8664',
    [string]$CertPath = '',
    [string[]]$RouteNames = @('homepage', 'grafana', 'littlem', 'llm-direct', 'dozzle', 'direct-llm'),
    [switch]$RemoveOnly
)

$ErrorActionPreference = 'Stop'
$HostsDatei = "$env:SystemRoot\System32\drivers\etc\hosts"
# Massgeblich ist die Liste auf dem Linux-Rechner: ./scripts/74-setup-local-proxy.sh
# --print-hosts. -RouteNames ueberschreibt die Auswahl hier, falls dort Namen
# geaendert oder ergaenzt wurden.
$Namen = $RouteNames

function Write-Schritt($Text) { Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok($Text)      { Write-Host "    OK   $Text" -ForegroundColor Green }
function Write-Fehl($Text)    { Write-Host "    FEHLT $Text" -ForegroundColor Red }

# --- Administrator pruefen: hosts-Datei und Stammzertifikat brauchen Rechte ---
$IstAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IstAdmin) {
    Write-Fehl 'Diese PowerShell ist nicht als Administrator geoeffnet.hosts-Datei und Stammzertifikat brauchen Rechte.'
    exit 1
}

# --- Rueckbau ---
if ($RemoveOnly) {
    Write-Schritt 'Rueckbau: Eintraege dieses Rechners aus der hosts-Datei entfernen'
    $alt = Get-Content $HostsDatei -Encoding ascii
    $neu = $alt | Where-Object { $_ -notmatch "\.$Domain\b" }
    Set-Content -Path $HostsDatei -Value $neu -Encoding ascii
    Write-Ok "$($alt.Count - $neu.Count) Zeile(n) entfernt"
    exit 0
}

# --- 1) hosts-Datei ---
Write-Schritt "hosts-Datei: $LanIp -> $($Namen -join ', ').$Domain"
$zeile = "$LanIp " + (($Namen | ForEach-Object { "$_.$Domain" }) -join ' ')
$alt = Get-Content $HostsDatei -Encoding ascii
if (($alt | Where-Object { $_ -match "\.$Domain\b" }) -join "`n" -eq $zeile) {
    Write-Ok 'Eintrag ist bereits vorhanden'
} else {
    $ohneFremde = $alt | Where-Object { $_ -notmatch "\.$Domain\b" }
    Set-Content -Path $HostsDatei -Value ($ohneFremde + $zeile) -Encoding ascii
    Write-Ok 'Eintrag geschrieben'
}
ipconfig /flushdns | Out-Null

# --- 2) Stammzertifikat ---
if ($CertPath -ne '') {
    if (-not (Test-Path $CertPath)) {
        Write-Fehl "Zertifikatsdatei nicht gefunden: $CertPath  (vom Linux-Rechner mit --ca-export holen)"
        exit 1
    }
    Write-Schritt 'Stammzertifikat importieren (Lokaler Computer / Vertrauenswuerdige Stammzertifizierungsstellen)'
    $finger = (certutil -dump $CertPath | Select-String -Pattern 'Cert Hash|SHA256' | Select-Object -First 1)
    Write-Host "    Fingerprint gegen die Ausgabe von --ca-export auf dem Linux-Rechner vergleichen!" -ForegroundColor Yellow
    Write-Host "    $finger"
    certutil -addstore -f ROOT $CertPath | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Ok 'Root importiert' } else { Write-Fehl "certutil meldete $LASTEXITCODE" }
} else {
    Write-Host '    HINWEIS: kein -CertPath angegeben - Zertifikatspruefungen schlagen dann mit TLS-Fehler fehl.' -ForegroundColor Yellow
}

# --- 3) Pruefen, wie ein normaler Client ---
Write-Schritt 'Routen pruefen'
$Erwartet = @{
    'homepage'            = @{ Pfad = '/';                Erwartet = 200 }
    'grafana'             = @{ Pfad = '/grafana/';        Erwartet = 200 }
    'littlem'             = @{ Pfad = '/v1/models';       Erwartet = 401 }
    'llm-direct'          = @{ Pfad = '/v1/models';       Erwartet = 401 }
    'dozzle'              = @{ Pfad = '/';                Erwartet = 401 }
    'direct-llm'          = @{ Pfad = '/v1/models';       Erwartet = 401 }
}
foreach ($Name in $Namen) {
    if (-not $Erwartet.ContainsKey($Name)) {
        Write-Host "    UEBERSPRUNGEN $Name - keine erwartete Antwort hinterlegt (Route in -RouteNames ergaenzen oder in \$Erwartet nachtragen)" -ForegroundColor Yellow
        continue
    }
    $url = "https://$Name.$Domain$($Erwartet[$Name].Pfad)"
    try {
        $antwort = Invoke-WebRequest -Uri $url -MaximumRedirection 0 -UseBasicParsing -ErrorAction Stop
        $code = $antwort.StatusCode
    } catch {
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        else { $code = 0 }
    }
    if ($code -eq $Erwartet[$Name].Erwartet) {
        Write-Ok "$Name : $code (wie erwartet)"
    } else {
        Write-Fehl "$Name : $code statt $($Erwartet[$Name].Erwartet) - URL $url"
    }
}

Write-Schritt 'Grundseite des Portals (Zeigt der Browser denselben Titel, ist der Weg durch)'
try {
    $start = Invoke-WebRequest -Uri "https://homepage.$Domain/" -UseBasicParsing -ErrorAction Stop
    if ($start.Content -match '<title[^>]*>([^<]+)</title>') {
        Write-Ok "Titel der Startseite: $($Matches[1].Trim())"
    }
} catch {
    Write-Fehl "Startseite nicht erreichbar: $($_.Exception.Message)"
}

Write-Host ''
Write-Host 'Weiter auf dem Linux-Rechner: ./scripts/74-setup-local-proxy.sh --check' -ForegroundColor Cyan
Write-Host 'Zugangsdaten der beiden Basic-Auth-Routen: cat ~/.config/llm-infra/proxy/lan-credentials.txt' -ForegroundColor Cyan
