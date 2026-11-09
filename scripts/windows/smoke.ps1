param(
    [Parameter(Mandatory)][string]$BundleDirectory,
    [string]$Label = 'portable'
)

$ErrorActionPreference = 'Stop'
$bundle = (Resolve-Path $BundleDirectory).Path
$exe = Join-Path $bundle 'JustOrganizeYourself.exe'
$info = [System.Diagnostics.ProcessStartInfo]::new($exe)
$info.WorkingDirectory = $bundle
$info.UseShellExecute = $false
$info.Environment['PATH'] = "$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\Wbem"
$process = [System.Diagnostics.Process]::new()
$process.StartInfo = $info
$started = $false
try {
    $started = $process.Start()
    if (-not $started) { throw 'Windows application did not start.' }
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 300
        $process.Refresh()
        if ($process.HasExited) { throw "Application exited before showing a window: $($process.ExitCode)" }
    } until ($process.MainWindowHandle -ne 0 -or [DateTime]::UtcNow -gt $deadline)
    if ($process.MainWindowHandle -eq 0) { throw 'No visible application window appeared within 30 seconds.' }

    $database = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'dev.justorganize/joy/joy.sqlite'
    if (-not (Test-Path $database)) { throw 'The native app did not initialize its SQLite workspace.' }
    $stream = [IO.File]::Open($database, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $header = [byte[]]::new(16)
        if ($stream.Read($header, 0, 16) -ne 16 -or [Text.Encoding]::ASCII.GetString($header) -ne "SQLite format 3`0") {
            throw 'The workspace is not a valid SQLite database.'
        }
    } finally { $stream.Dispose() }

    foreach ($name in @('flutter_windows.dll', 'sqlite3.dll', 'msvcp140.dll', 'vcruntime140.dll')) {
        $module = $process.Modules | Where-Object { $_.ModuleName -ieq $name } | Select-Object -First 1
        if (-not $module -or -not $module.FileName.StartsWith($bundle + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "The application did not load its app-local runtime: $name"
        }
    }
    Write-Output "${Label}: native window visible, SQLite initialized, Flutter/SQLite/C++ loaded from the bundle with SDK-free PATH."
} finally {
    if ($started -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
    $process.Dispose()
}
