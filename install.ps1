<#
  AsciiFace installer. Needs admin once (to register the virtual camera driver).
  - copies the app to "C:\Program Files\AsciiFace"
  - registers the bundled DirectShow camera driver as "AsciiFace" (64 + 32 bit)
  - adds Start menu + desktop shortcuts and an "Apps & features" uninstall entry
#>
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Requesting administrator rights to install the AsciiFace camera driver...'
    $p = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    exit $p.ExitCode
}

function Step($text) { Write-Host "  - $text" }

try {
    Write-Host "`nInstalling AsciiFace`n" -ForegroundColor Green
    $dest = Join-Path $env:ProgramFiles 'AsciiFace'

    # Stop a running AsciiFace so files can be replaced
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*AsciiFace\asciiface.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    Step "Copying files to $dest"
    New-Item -ItemType Directory -Force (Join-Path $dest 'driver') | Out-Null
    foreach ($f in 'index.html', 'asciiface.ps1', 'uninstall.ps1', 'LICENSE', 'README.md') {
        Copy-Item (Join-Path $src $f) $dest -Force
    }
    Copy-Item (Join-Path $src 'driver\*') (Join-Path $dest 'driver') -Force
    Get-ChildItem $dest -Recurse -File | Unblock-File

    Step 'Registering virtual camera "AsciiFace"'
    $regsvr = @(
        @{ Exe = "$env:SystemRoot\System32\regsvr32.exe"; Dll = 'UnityCaptureFilter64.dll' },
        @{ Exe = "$env:SystemRoot\SysWOW64\regsvr32.exe"; Dll = 'UnityCaptureFilter32.dll' }
    )
    foreach ($r in $regsvr) {
        if (-not (Test-Path $r.Exe)) { continue }
        $dll = Join-Path $dest "driver\$($r.Dll)"
        $p = Start-Process $r.Exe -Wait -PassThru -WindowStyle Hidden -ArgumentList @(
            '/s', '"/i:UnityCaptureName=AsciiFace"', "`"$dll`"")
        if ($p.ExitCode -ne 0) { throw "regsvr32 failed for $($r.Dll) (exit code $($p.ExitCode))" }
    }

    Step 'Creating icon and shortcuts'
    $icon = Join-Path $dest 'asciiface.ico'
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object Drawing.Bitmap 256, 256
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([Drawing.Color]::Transparent)
    $g.FillEllipse((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 14, 16, 18))), 8, 8, 240, 240)
    $font = New-Object Drawing.Font 'Consolas', 120, ([Drawing.FontStyle]::Bold), ([Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object Drawing.StringFormat; $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $g.DrawString('@', $font, (New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 94, 224, 138))),
        (New-Object Drawing.RectangleF 0, 4, 256, 256), $fmt)
    $g.Dispose()
    $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    $png = $ms.ToArray()
    # ICO container with a single 256x256 PNG image
    $ico = New-Object IO.BinaryWriter ([IO.File]::Create($icon))
    $ico.Write([uint16]0); $ico.Write([uint16]1); $ico.Write([uint16]1)
    $ico.Write([byte]0); $ico.Write([byte]0); $ico.Write([byte]0); $ico.Write([byte]0)
    $ico.Write([uint16]1); $ico.Write([uint16]32); $ico.Write([uint32]$png.Length); $ico.Write([uint32]22)
    $ico.Write($png); $ico.Close()

    $shell = New-Object -ComObject WScript.Shell
    $psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $launchArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dest\asciiface.ps1`""
    $links = @(
        (Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'AsciiFace.lnk'),
        (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'AsciiFace.lnk')
    )
    foreach ($l in $links) {
        $s = $shell.CreateShortcut($l)
        $s.TargetPath = $psExe; $s.Arguments = $launchArgs; $s.WorkingDirectory = $dest
        $s.IconLocation = $icon; $s.WindowStyle = 7; $s.Description = 'Live ASCII webcam + virtual camera'
        $s.Save()
    }

    Step 'Adding uninstall entry'
    $key = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AsciiFace'
    New-Item $key -Force | Out-Null
    $props = @{
        DisplayName     = 'AsciiFace'
        DisplayVersion  = '1.0.0'
        Publisher       = 'AsciiFace'
        DisplayIcon     = $icon
        InstallLocation = $dest
        UninstallString = "`"$psExe`" -NoProfile -ExecutionPolicy Bypass -File `"$dest\uninstall.ps1`""
        NoModify        = 1
        NoRepair        = 1
    }
    foreach ($k in $props.Keys) { Set-ItemProperty $key $k $props[$k] }

    Write-Host "`nDone. Start AsciiFace from the desktop or Start menu," -ForegroundColor Green
    Write-Host 'then pick "AsciiFace" as your camera in Discord, Zoom, Teams or OBS.'
    $code = 0
}
catch {
    Write-Host "`nInstallation failed: $_" -ForegroundColor Red
    $code = 1
}
Read-Host "`nPress Enter to close"
exit $code
