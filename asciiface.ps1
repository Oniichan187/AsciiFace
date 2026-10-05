<#
  AsciiFace launcher. Uses only what ships with Windows (PowerShell 5.1, .NET Framework, Edge).

  - Serves index.html on http://localhost:<Port>/ (localhost = secure context, so the camera works)
  - Accepts per-cell ASCII frames on ws://localhost:<Port>/vcam, draws them at the camera
    resolution and feeds the "AsciiFace" virtual camera driver (installed by install.cmd)
  - Opens the UI in its own Edge app window and shuts down when that window closes
#>
param(
    [int]$Port = 8090,
    [int]$Width = 1280,   # virtual camera resolution
    [int]$Height = 720,
    [int]$Fps = 30,
    [switch]$NoBrowser
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.MemoryMappedFiles;
using System.Net;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace AsciiFace
{
    // Sender side of the Unity Capture shared-memory protocol (see driver/LICENSE-UnityCapture.txt).
    // The driver instance inside the consuming app (Discord, Zoom, ...) creates the mutex, the
    // "sent" event and the frame buffer; the sender creates the "want" event.
    public class VirtualCamera
    {
        const int HeaderSize = 32;   // maxSize, width, height, stride, format, resizemode, mirrormode, timeout
        Mutex mutex;
        EventWaitHandle wantEvent, sentEvent;
        MemoryMappedFile file;
        MemoryMappedViewAccessor view;
        IntPtr basePtr;
        DateTime lastWant;

        public bool IsOpen { get { return view != null; } }

        public static bool DriverInstalled()
        {
            using (var k = Registry.ClassesRoot.OpenSubKey(@"CLSID\{5C2CD55C-92AD-4999-8666-912BD3E70010}"))
                return k != null;
        }

        // Handshake: the driver creates the mutex, then waits until the "want" event exists before it
        // creates the "sent" event and the frame buffer. So handles that are already open must be kept
        // across attempts - closing "want" on a partial open would deadlock both sides.
        bool TryOpen()
        {
            try
            {
                if (mutex == null) mutex = Mutex.OpenExisting("UnityCapture_Mutx");
                if (wantEvent == null) wantEvent = new EventWaitHandle(false, EventResetMode.AutoReset, "UnityCapture_Want");
                if (sentEvent == null) sentEvent = EventWaitHandle.OpenExisting("UnityCapture_Sent", EventWaitHandleRights.Modify | EventWaitHandleRights.Synchronize);
                if (file == null) file = MemoryMappedFile.OpenExisting("UnityCapture_Data", MemoryMappedFileRights.ReadWrite);
                view = file.CreateViewAccessor(0, 0, MemoryMappedFileAccess.ReadWrite);
                basePtr = new IntPtr(view.SafeMemoryMappedViewHandle.DangerousGetHandle().ToInt64() + view.PointerOffset);
                lastWant = DateTime.UtcNow;
                return true;
            }
            catch (WaitHandleCannotBeOpenedException) { return false; }   // driver not (fully) there yet
            catch (FileNotFoundException) { return false; }
            catch
            {
                Close();
                return false;
            }
        }

        // Called periodically: connect when an app opens the camera, disconnect when it stops asking for frames.
        public void Poll()
        {
            if (view == null) { TryOpen(); return; }
            if (wantEvent.WaitOne(0)) lastWant = DateTime.UtcNow;
            if ((DateTime.UtcNow - lastWant).TotalSeconds > 3) Close();
        }

        // pixels: RGBA as little-endian ints, rows bottom-up (the order the driver expects).
        public bool Send(int[] pixels, int width, int height)
        {
            if (view == null) return false;
            if ((uint)Marshal.ReadInt32(basePtr) < (uint)(width * height * 4)) return false;
            bool locked = false;
            try
            {
                try { locked = mutex.WaitOne(500); }
                catch (AbandonedMutexException) { locked = true; }
                if (!locked) return false;
                Marshal.WriteInt32(basePtr, 4, width);
                Marshal.WriteInt32(basePtr, 8, height);
                Marshal.WriteInt32(basePtr, 12, width);  // stride in pixels
                Marshal.WriteInt32(basePtr, 16, 0);      // FORMAT_UINT8 (RGBA)
                Marshal.WriteInt32(basePtr, 20, 1);      // RESIZEMODE_LINEAR if the app asks for another size
                Marshal.WriteInt32(basePtr, 24, 0);      // no mirroring
                Marshal.WriteInt32(basePtr, 28, 2000);   // ms until the driver shows "no signal"
                Marshal.Copy(pixels, 0, new IntPtr(basePtr.ToInt64() + HeaderSize), width * height);
            }
            finally
            {
                if (locked) mutex.ReleaseMutex();
            }
            sentEvent.Set();
            if (wantEvent.WaitOne(0)) lastWant = DateTime.UtcNow;
            return true;
        }

        public void Close()
        {
            if (view != null) view.Dispose();
            if (file != null) file.Dispose();
            if (sentEvent != null) sentEvent.Dispose();
            if (wantEvent != null) wantEvent.Dispose();
            if (mutex != null) mutex.Dispose();
            view = null; file = null; sentEvent = null; wantEvent = null; mutex = null;
            basePtr = IntPtr.Zero;
        }
    }

    // Draws the ASCII frame at the camera resolution from per-cell data, so the cost is the same
    // no matter how many columns or how large the font is in the preview.
    public class Renderer
    {
        public readonly int Width, Height;
        public readonly int[] Pixels;        // bottom-up RGBA, ready for VirtualCamera.Send
        byte[] masks; int cw, ch, glyphCount;
        int lastLayout = -1, lastPaper;

        public Renderer(int width, int height)
        {
            Width = width; Height = height;
            Pixels = new int[width * height];
        }

        // atlas: one cw*ch alpha mask per glyph, in the same order as the indices in frames
        public void SetAtlas(byte[] data, int offset, int cellW, int cellH, int count)
        {
            var m = new byte[cellW * cellH * count];
            Buffer.BlockCopy(data, offset, m, 0, m.Length);
            masks = m; cw = cellW; ch = cellH; glyphCount = count;
            lastLayout = -1;
        }

        static int Rgba(int r, int g, int b) { return r | (g << 8) | (b << 16) | (255 << 24); }

        // cells: 4 bytes per cell (glyph index, r, g, b), row-major from the top-left
        public bool Draw(byte[] cells, int cols, int rows, bool color, int ink, int paper)
        {
            if (masks == null) return false;
            int gw = cols * cw, gh = rows * ch;
            if (gw > Width || gh > Height) return false;   // atlas from an older layout; wait for the new one
            int x0 = (Width - gw) / 2, y0 = (Height - gh) / 2;

            int pr = paper & 255, pg = (paper >> 8) & 255, pb = (paper >> 16) & 255;
            int ir = ink & 255, ig = (ink >> 8) & 255, ib = (ink >> 16) & 255;
            int bgPixel = Rgba(pr, pg, pb), glyphSize = cw * ch;
            int[] px = Pixels; byte[] mk = masks;

            int layout = (cols * 7919) ^ (rows * 104729) ^ (cw << 20) ^ (ch << 26);
            if (layout != lastLayout || paper != lastPaper)
            {
                for (int i = 0; i < px.Length; i++) px[i] = bgPixel;
                lastLayout = layout; lastPaper = paper;
            }

            for (int cy = 0; cy < rows; cy++)
            {
                for (int cx = 0; cx < cols; cx++)
                {
                    int c = (cy * cols + cx) * 4;
                    int gi = cells[c];
                    if (gi >= glyphCount) gi = glyphCount - 1;
                    int fr = ir, fg = ig, fb = ib;
                    if (color) { fr = cells[c + 1]; fg = cells[c + 2]; fb = cells[c + 3]; }
                    int fgPixel = Rgba(fr, fg, fb);
                    int m = gi * glyphSize;
                    int top = y0 + cy * ch, left = x0 + cx * cw;
                    for (int y = 0; y < ch; y++)
                    {
                        int o = (Height - 1 - (top + y)) * Width + left;
                        for (int x = 0; x < cw; x++, m++, o++)
                        {
                            int a = mk[m];
                            if (a == 0) px[o] = bgPixel;
                            else if (a == 255) px[o] = fgPixel;
                            else
                            {
                                int na = 255 - a;
                                px[o] = Rgba((fr * a + pr * na) / 255, (fg * a + pg * na) / 255, (fb * a + pb * na) / 255);
                            }
                        }
                    }
                }
            }
            return true;
        }
    }

    public class Server
    {
        readonly string root;
        readonly HttpListener listener = new HttpListener();
        readonly VirtualCamera cam = new VirtualCamera();
        readonly Renderer renderer;
        readonly int fps;
        byte[] pendingCells; int pendingCols, pendingRows, pendingInk, pendingPaper; bool pendingColor;
        bool hasFrame;
        volatile bool running;
        readonly List<Client> clients = new List<Client>();
        Timer timer;
        string state = "";

        class Client
        {
            public WebSocket Socket;
            public SemaphoreSlim SendLock = new SemaphoreSlim(1, 1);
        }

        public Server(string root, int port, int width, int height, int fps)
        {
            renderer = new Renderer(width, height);
            this.fps = fps;
            this.root = Path.GetFullPath(root).TrimEnd('\\') + "\\";
            listener.Prefixes.Add("http://localhost:" + port + "/");
        }

        public void Start()
        {
            listener.Start();
            Task.Run(() => AcceptLoop());
            timer = new Timer(_ => Tick(), null, 0, 500);
            running = true;
            new Thread(SendLoop) { IsBackground = true, Priority = ThreadPriority.AboveNormal }.Start();
        }

        // Feeds the driver at a steady rate, repeating the last frame if the page is late,
        // so apps never fall back to the driver's "no signal" pattern.
        void SendLoop()
        {
            var clock = System.Diagnostics.Stopwatch.StartNew();
            long next = 0, interval = 1000 / fps;
            while (running)
            {
                lock (renderer)
                {
                    if (pendingCells != null)
                    {
                        if (renderer.Draw(pendingCells, pendingCols, pendingRows, pendingColor, pendingInk, pendingPaper)) hasFrame = true;
                        pendingCells = null;
                    }
                    if (hasFrame) lock (cam) cam.Send(renderer.Pixels, renderer.Width, renderer.Height);
                }
                next += interval;
                long wait = next - clock.ElapsedMilliseconds;
                if (wait > 0) Thread.Sleep((int)wait);
                else next = clock.ElapsedMilliseconds;   // fell behind: don't try to catch up
            }
        }

        public void Stop()
        {
            running = false;
            if (timer != null) timer.Dispose();
            try { listener.Stop(); } catch { }
            lock (cam) cam.Close();
        }

        string CurrentState()
        {
            if (cam.IsOpen) return "live";
            return VirtualCamera.DriverInstalled() ? "waiting" : "nodriver";
        }

        string StatusJson()
        {
            return "{\"state\":\"" + state + "\",\"device\":\"AsciiFace\",\"width\":" + renderer.Width +
                   ",\"height\":" + renderer.Height + "}";
        }

        void Tick()
        {
            lock (cam) cam.Poll();
            string s = CurrentState();
            if (s == state) return;
            state = s;
            Client[] snapshot;
            lock (clients) snapshot = clients.ToArray();
            foreach (var c in snapshot) { var _ = SendText(c, StatusJson()); }
        }

        async Task AcceptLoop()
        {
            while (listener.IsListening)
            {
                HttpListenerContext ctx;
                try { ctx = await listener.GetContextAsync(); }
                catch { return; }
                var _ = Handle(ctx);
            }
        }

        async Task Handle(HttpListenerContext ctx)
        {
            try
            {
                if (ctx.Request.Url.AbsolutePath == "/vcam" && ctx.Request.IsWebSocketRequest)
                    await HandleSocket(ctx);
                else
                    ServeFile(ctx);
            }
            catch { try { ctx.Response.Abort(); } catch { } }
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

        async Task SendText(Client c, string text)
        {
            await c.SendLock.WaitAsync();
            try
            {
                var bytes = Encoding.UTF8.GetBytes(text);
                await c.Socket.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, CancellationToken.None);
            }
            catch { }
            finally { c.SendLock.Release(); }
        }

        async Task HandleSocket(HttpListenerContext ctx)
        {
            var wsctx = await ctx.AcceptWebSocketAsync(null);
            var client = new Client { Socket = wsctx.WebSocket };
            lock (clients) clients.Add(client);
            try
            {
                await SendText(client, StatusJson());
                byte[] buf = new byte[1 << 20];
                while (client.Socket.State == WebSocketState.Open)
                {
                    int count = 0;
                    WebSocketReceiveResult r;
                    do
                    {
                        if (count == buf.Length)
                        {
                            if (buf.Length >= 64 * 1024 * 1024) return;
                            Array.Resize(ref buf, buf.Length * 2);
                        }
                        r = await client.Socket.ReceiveAsync(new ArraySegment<byte>(buf, count, buf.Length - count), CancellationToken.None);
                        if (r.MessageType == WebSocketMessageType.Close) return;
                        count += r.Count;
                    } while (!r.EndOfMessage);

                    if (r.MessageType != WebSocketMessageType.Binary || count < 16) continue;
                    int type = BitConverter.ToInt32(buf, 0);
                    if (type == 1)
                    {
                        // atlas: type, cellW, cellH, count, then count*cellW*cellH alpha bytes
                        int cw = BitConverter.ToInt32(buf, 4), ch = BitConverter.ToInt32(buf, 8), n = BitConverter.ToInt32(buf, 12);
                        if (cw <= 0 || ch <= 0 || n <= 0 || n > 256 || 16L + (long)cw * ch * n != count) continue;
                        lock (renderer) renderer.SetAtlas(buf, 16, cw, ch, n);
                    }
                    else if (type == 2 && count >= 24)
                    {
                        // frame: type, cols, rows, flags (1 = color), ink RGBA, paper RGBA, then 4 bytes per cell
                        int cols = BitConverter.ToInt32(buf, 4), rows = BitConverter.ToInt32(buf, 8);
                        if (cols <= 0 || rows <= 0 || 24L + (long)cols * rows * 4 != count) continue;
                        var cells = new byte[cols * rows * 4];
                        Buffer.BlockCopy(buf, 24, cells, 0, cells.Length);
                        lock (renderer)
                        {
                            pendingCells = cells; pendingCols = cols; pendingRows = rows;
                            pendingColor = (BitConverter.ToInt32(buf, 12) & 1) != 0;
                            pendingInk = BitConverter.ToInt32(buf, 16); pendingPaper = BitConverter.ToInt32(buf, 20);
                        }
                    }
                }
            }
            catch { }
            finally
            {
                lock (clients) clients.Remove(client);
                client.Socket.Dispose();
            }
        }
    }
}
'@

Add-Type -TypeDefinition $source -ReferencedAssemblies System.Core

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
$server = New-Object AsciiFace.Server($root, $Port, $Width, $Height, $Fps)
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
    # Keep rendering while minimized so the virtual camera never freezes
    '--disable-background-timer-throttling', '--disable-renderer-backgrounding',
    '--disable-backgrounding-occluded-windows',
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
