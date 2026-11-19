$cert = Join-Path $PSScriptRoot "root.crt"
if (-not (Test-Path $cert)) { Write-Host "root.crt fehlt noch (Thomas muss das Gateway-Zertifikat nachliefern)"; exit 1 }
Import-Certificate -FilePath $cert -CertStoreLocation Cert:\CurrentUser\Root | Out-Null
Write-Host "root.crt in CurrentUser-Stammstore importiert."
