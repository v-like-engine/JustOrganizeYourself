param(
    [string]$ReleaseDirectory = 'apps/joy/build/windows/x64/runner/Release',
    [string]$OutputDirectory = 'artifacts/windows',
    [string]$AppVersion = '0.1.0'
)

$ErrorActionPreference = 'Stop'
$release = (Resolve-Path $ReleaseDirectory).Path
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$output = (Resolve-Path $OutputDirectory).Path
$bundle = Join-Path $output 'JustOrganizeYourself'
if (Test-Path $bundle) { throw "Use a clean packaging directory: $bundle" }
New-Item -ItemType Directory -Path $bundle | Out-Null
Copy-Item (Join-Path $release '*') $bundle -Recurse
Get-ChildItem $bundle -Filter '*.pdb' -Recurse -File | Remove-Item

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $visualStudio) { throw 'Visual C++ build tools were not found on the build machine.' }
$redistVersion = (Get-Content (Join-Path $visualStudio 'VC/Auxiliary/Build/Microsoft.VCRedistVersion.default.txt') -Raw).Trim()
$redist = Join-Path $visualStudio "VC/Redist/MSVC/$redistVersion/x64/Microsoft.VC143.CRT"
if (-not (Test-Path $redist)) { throw "Visual C++ redistributable directory not found: $redist" }
Copy-Item (Join-Path $redist '*.dll') $bundle

foreach ($required in @('JustOrganizeYourself.exe', 'flutter_windows.dll', 'sqlite3.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll', 'data/icudtl.dat', 'data/app.so')) {
    if (-not (Test-Path (Join-Path $bundle $required))) { throw "Missing packaged runtime file: $required" }
}

@'
Just Organize Yourself — Windows

EN: Extract the entire ZIP, open the JustOrganizeYourself folder, and double-click
JustOrganizeYourself.exe. Keep the DLL files and the data folder next to it.
No Flutter, Visual Studio, Python, Java or separate database installation is needed.
Your workspace is stored in your Windows user profile, separately from this folder.
For an easier installation with a Start menu shortcut, use JOY-Windows-Setup.exe.

RU: Распакуйте ZIP целиком, откройте папку JustOrganizeYourself и запустите
JustOrganizeYourself.exe двойным щелчком. DLL и папку data оставьте рядом с ним.
Flutter, Visual Studio, Python, Java и отдельную базу данных устанавливать не нужно.
Ваши задачи сохраняются в профиле Windows, отдельно от папки программы.
Для установки с ярлыком используйте JOY-Windows-Setup.exe.
'@ | Set-Content (Join-Path $bundle 'READ-ME-FIRST.txt') -Encoding utf8

@'
The Microsoft Visual C++ runtime DLLs included with this application are Microsoft
redistributable components supplied with Visual Studio. They are distributed
app-locally for this application and remain subject to Microsoft's license terms.
Flutter, SQLite and other dependencies retain their respective licenses; Flutter
license notices are included with the application's bundled assets.
'@ | Set-Content (Join-Path $bundle 'RUNTIME-NOTICES.txt') -Encoding utf8

$compiler = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'
if (-not (Test-Path $compiler)) {
    & choco install innosetup --yes --no-progress --limit-output
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $compiler)) { throw 'Inno Setup installation failed on the build machine.' }
}
$recipe = Join-Path $PSScriptRoot '../../packaging/windows/installer.iss'
& $compiler "/DAppVersion=$AppVersion" "/DBundleDirectory=$bundle" "/DOutputDirectory=$output" $recipe
if ($LASTEXITCODE -ne 0) { throw 'Windows installer compilation failed.' }
Compress-Archive -Path $bundle -DestinationPath (Join-Path $output 'JOY-Windows-Portable.zip') -CompressionLevel Optimal

Get-ChildItem $output -File | Where-Object { $_.Extension -in @('.zip', '.exe') } | Sort-Object Name | ForEach-Object {
    "$((Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant())  $($_.Name)"
} | Set-Content (Join-Path $output 'SHA256SUMS.txt') -Encoding utf8
Write-Output "Windows packages created in $output"
