param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$ToolsDirectory
)

$ErrorActionPreference = 'Stop'
$root = Join-Path $ToolsDirectory 'flutter'
$marker = Join-Path $ToolsDirectory 'verified-sdk.json'
$metadata = Invoke-RestMethod 'https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json'
$release = $metadata.releases | Where-Object {
    $_.version -eq $Version -and $_.channel -eq 'stable' -and $_.dart_sdk_arch -eq 'x64'
} | Select-Object -First 1
if (-not $release) { throw "Official Windows x64 Flutter release not found: $Version" }

if ((Test-Path $marker) -and (Test-Path (Join-Path $root 'bin/flutter.bat'))) {
    $verified = Get-Content $marker -Raw | ConvertFrom-Json
    if ($verified.sha256 -eq $release.sha256) {
        (Join-Path $root 'bin') | Out-File $env:GITHUB_PATH -Append -Encoding utf8
        exit 0
    }
    throw 'The cached Flutter SDK does not match the selected official release.'
}

New-Item -ItemType Directory -Path $ToolsDirectory -Force | Out-Null
$archive = Join-Path $ToolsDirectory 'flutter-sdk.zip'
Invoke-WebRequest "$($metadata.base_url)/$($release.archive)" -OutFile $archive
if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $release.sha256) {
    throw 'Flutter SDK checksum verification failed.'
}
Expand-Archive $archive -DestinationPath $ToolsDirectory
Remove-Item $archive
if (-not (Test-Path (Join-Path $root 'bin/flutter.bat'))) { throw 'Incomplete Flutter SDK archive.' }
@{ version = $Version; sha256 = $release.sha256 } | ConvertTo-Json | Set-Content $marker -Encoding utf8
(Join-Path $root 'bin') | Out-File $env:GITHUB_PATH -Append -Encoding utf8
