<#
  AsciiFace uninstaller: unregisters the camera driver and removes files, shortcuts and settings.
#>
$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $p = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    exit $p.ExitCode
}

Write-Host "`nUninstalling AsciiFace`n" -ForegroundColor Yellow
$dest = Join-Path $env:ProgramFiles 'AsciiFace'

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*asciiface.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

foreach ($r in @(@("$env:SystemRoot\System32\regsvr32.exe", 'UnityCaptureFilter64.dll'),
                 @("$env:SystemRoot\SysWOW64\regsvr32.exe", 'UnityCaptureFilter32.dll'))) {
    $dll = Join-Path $dest "driver\$($r[1])"
    if ((Test-Path $r[0]) -and (Test-Path $dll)) {
        Start-Process $r[0] -Wait -WindowStyle Hidden -ArgumentList '/u', '/s', "`"$dll`""
    }
}

Remove-Item (Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'AsciiFace.lnk') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'AsciiFace.lnk') -Force -ErrorAction SilentlyContinue
Remove-Item 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AsciiFace' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:LOCALAPPDATA 'AsciiFace') -Recurse -Force -ErrorAction SilentlyContinue

try {
    Remove-Item $dest -Recurse -Force
    Write-Host 'AsciiFace was removed.' -ForegroundColor Green
}
catch {
    Write-Host "Some files in $dest are still in use (close Discord/Zoom/OBS) - delete the folder manually." -ForegroundColor Red
}
Read-Host "`nPress Enter to close"
