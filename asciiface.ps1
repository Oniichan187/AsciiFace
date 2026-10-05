<#
  AsciiFace launcher. Uses only what ships with Windows (PowerShell 5.1, .NET Framework, Edge).

  - Serves index.html on http://localhost:<Port>/ (localhost = secure context, so the camera works)
  - Opens the UI in its own Edge app window and shuts down when that window closes
#>
param(
    [int]$Port = 8090,
    [switch]$NoBrowser
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Threading.Tasks;

namespace AsciiFace
{
    public class Server
    {
        readonly string root;
        readonly HttpListener listener = new HttpListener();

        public Server(string root, int port)
        {
            this.root = Path.GetFullPath(root).TrimEnd('\\') + "\\";
            listener.Prefixes.Add("http://localhost:" + port + "/");
        }

        public void Start()
        {
            listener.Start();
            Task.Run(() => AcceptLoop());
        }

        public void Stop()
        {
            try { listener.Stop(); } catch { }
        }

        async Task AcceptLoop()
        {
            while (listener.IsListening)
            {
                HttpListenerContext ctx;
                try { ctx = await listener.GetContextAsync(); }
                catch { return; }
                try { ServeFile(ctx); }
                catch { try { ctx.Response.Abort(); } catch { } }
            }
        }

        static readonly Dictionary<string, string> Types = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            { ".html", "text/html; charset=utf-8" }, { ".js", "text/javascript" }, { ".css", "text/css" },
            { ".png", "image/png" }, { ".svg", "image/svg+xml" }, { ".ico", "image/x-icon" }
        };

        void ServeFile(HttpListenerContext ctx)
        {
            string rel = Uri.UnescapeDataString(ctx.Request.Url.AbsolutePath).TrimStart('/');
            if (rel == "") rel = "index.html";
            string full = Path.GetFullPath(Path.Combine(root, rel));
            string type;
            var res = ctx.Response;
            if (!full.StartsWith(root, StringComparison.OrdinalIgnoreCase) || !File.Exists(full) ||
                !Types.TryGetValue(Path.GetExtension(full), out type))
            {
                res.StatusCode = 404;
                res.Close();
                return;
            }
            byte[] body = File.ReadAllBytes(full);
            res.ContentType = type;
            res.Headers["Cache-Control"] = "no-store";
            res.ContentLength64 = body.Length;
            res.OutputStream.Write(body, 0, body.Length);
            res.Close();
        }
    }
}
'@

Add-Type -TypeDefinition $source

function Find-Browser {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}

$url = "http://localhost:$Port/"
$server = New-Object AsciiFace.Server($root, $Port)
$ownsServer = $true
try { $server.Start() }
catch { $ownsServer = $false }   # already running (second launch) -> just open another window

if ($NoBrowser) {
    Write-Host "AsciiFace running at $url  (Ctrl+C to stop)"
    try { while ($true) { Start-Sleep -Seconds 1 } } finally { $server.Stop() }
    return
}

$browser = Find-Browser
$profileDir = Join-Path $env:LOCALAPPDATA 'AsciiFace\browser-profile'
$browserArgs = @(
    "--user-data-dir=`"$profileDir`"", '--no-first-run', '--no-default-browser-check',
    # Auto-grant the camera for this private profile -> no permission prompt
    '--use-fake-ui-for-media-stream',
    "--app=$url"
)

if (-not $browser) {
    Start-Process $url
    if ($ownsServer) {
        Write-Host "AsciiFace running at $url  (close this window to stop)"
        try { while ($true) { Start-Sleep -Seconds 1 } } finally { $server.Stop() }
    }
    return
}

$proc = Start-Process -FilePath $browser -ArgumentList $browserArgs -PassThru
if ($ownsServer) {
    $proc.WaitForExit()
    # The profile's browser process may hand off to a child; wait until no window of it is left.
    while (Get-CimInstance Win32_Process -Filter "Name='$(Split-Path $browser -Leaf)'" |
           Where-Object { $_.CommandLine -like "*$profileDir*" }) { Start-Sleep -Seconds 2 }
    $server.Stop()
}
