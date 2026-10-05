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

Add-Type -Namespace Native -Name Kernel32 -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool MoveFileEx(string existingFileName, string newFileName, int flags);
'@

# The camera driver stays loaded in every app that listed cameras (Discord, browsers, ...), so its
# DLL can't be deleted yet. A loaded file can still be moved on the same drive, though: park it in
# Windows\Temp and let Windows delete it on the next reboot, so the install folder goes away right now.
function Remove-Folder([string]$Path) {
    $parked = 0
    foreach ($f in Get-ChildItem $Path -Recurse -File -Force) {
        try { Remove-Item $f.FullName -Force -ErrorAction Stop }
        catch {
            $target = Join-Path "$env:SystemRoot\Temp" ("asciiface-" + [guid]::NewGuid().ToString('N') + $f.Extension)
            Move-Item $f.FullName $target -Force -ErrorAction Stop
            # [NullString]::Value: a plain $null would be passed as "" and the call would fail
            [void][Native.Kernel32]::MoveFileEx($target, [NullString]::Value, 4)   # MOVEFILE_DELAY_UNTIL_REBOOT
            $parked++
        }
    }
    Remove-Item $Path -Recurse -Force -ErrorAction Stop
    $parked
}

try {
    if (Test-Path $dest) { $parked = Remove-Folder $dest } else { $parked = 0 }
    Write-Host 'AsciiFace was removed.' -ForegroundColor Green
    if ($parked) { Write-Host "$parked driver file(s) still loaded by open apps will be deleted on the next restart." }
}
catch {
    Write-Host "Could not remove ${dest}: $_" -ForegroundColor Red
}
Read-Host "`nPress Enter to close"
