# AsciiFace

Turn your webcam into live ASCII art, in color or monochrome, and use it as a camera in Discord, Zoom, Teams or OBS.

**No dependencies.** Python, OBS, Node and accounts aren't needed. AsciiFace uses only what ships with Windows 10/11 (PowerShell, .NET Framework, Edge) plus a small bundled camera driver.

```
@@@@@@@@@@QQQQQQ$$$$&8BBO0pmqdhXXwkZZ]]}unI[YfC]|)vvLLicr/\!+;:,"^`'..
```

## Install

1. Download the repo ([Code → Download ZIP](../../archive/refs/heads/main.zip)) and unzip it.
2. Double-click **`install.cmd`** and confirm the admin prompt. Admin rights are needed once, to register the camera driver.
3. Start **AsciiFace** from the desktop or the Start menu.
4. In Discord, open *Settings → Voice & Video → Camera* and choose **AsciiFace**. Zoom, Teams, OBS and browsers work the same way.

To remove it, use *Settings → Apps → AsciiFace → Uninstall* or run `uninstall.cmd`.

**Preview without installing:** double-click `AsciiFace.cmd`. The virtual camera needs the install step.

## Features

- **Live side-by-side view:** the camera on the left (pick any connected device) and the ASCII render on the right.
- **Virtual webcam "AsciiFace":** any app that uses webcams can select it. The status dot shows grey for off, yellow for ready, green when an app is showing it, and red when the driver is missing.
- **Pure ASCII:** every cell is a printable ASCII character. "Copy text" copies the current frame as plain text.
- **Density-calibrated glyphs:** each character is rendered in the real font and its ink coverage is measured. Brightness maps to the character whose density matches, not to a hand-ordered ramp.
- **Color mode:** each character takes the color of the pixels under it. Turn it off for single-color ink on paper.
- **Tuning controls:** six charsets (up to all 95 printable characters), 40–320 columns, font size, brightness, contrast, gamma, invert, mirror, and ink and paper colors.
- **No login, no prompts:** the app runs in its own Edge window with a private profile, and the camera is granted automatically.
- **Keeps running when minimized:** the virtual camera doesn't freeze when the window is in the background.
- **Local only:** the only network traffic is between the window and `localhost`.

## How it works

```
webcam ─► Edge app window (index.html)
            ├─ downsample to one pixel per character cell
            ├─ tone curve (brightness / contrast / gamma / invert)
            ├─ luminance ─► glyph with closest measured ink coverage
            └─ blit glyph masks (optionally tinted with the pixel color)
                  │ glyph shapes once + 4 bytes per cell over ws://localhost:8090/vcam
                  ▼
          asciiface.ps1  (PowerShell + inline C#: draws the frame at 1280×720, steady 30 fps)
                  │ shared memory
                  ▼
          "AsciiFace" DirectShow camera driver ─► Discord / Zoom / Teams / OBS
```

Frames are only sent while an app is actually showing the camera. The camera image is drawn at a fixed 1280×720, so its cost does not depend on columns or font size, and the bridge repeats the last frame if the page is late, so apps never fall back to a "no signal" image.

## Files

| File | Purpose |
|---|---|
| `index.html` | The whole UI and ASCII renderer. It also works when opened directly in a browser. |
| `asciiface.ps1` | Launcher: local web server, WebSocket-to-camera bridge, and the Edge app window. |
| `install.cmd` / `install.ps1` | Installs to `C:\Program Files\AsciiFace`, registers the camera, and creates shortcuts. |
| `uninstall.cmd` / `uninstall.ps1` | Removes everything again. |
| `AsciiFace.cmd` | Runs from the repo folder without installing. |
| `driver/` | Prebuilt [Unity Capture](https://github.com/schellingb/UnityCapture) DirectShow filter (MIT), registered under the name "AsciiFace". |

## Troubleshooting

| Problem | Fix |
|---|---|
| Red dot, "driver not installed" | Run `install.cmd`. |
| "AsciiFace" isn't listed in Discord | Restart Discord after installing. Apps read the camera list at startup. |
| The app shows a "not started" image | Open the AsciiFace window. Frames only flow while it's running. |
| Camera is busy | Another app is using the physical webcam. Close it or pick another device. |

## Credits

- Virtual camera driver: [Unity Capture](https://github.com/schellingb/UnityCapture) by Bernhard Schelling, MIT. See `driver/LICENSE-UnityCapture.txt`.

## License

MIT
