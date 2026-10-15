# OpenTouch

Free, open-source touch screen and pen support for macOS.

macOS has no built-in support for touch screens. Plug in a touch monitor such as the
**Lenovo ThinkVision M14t** and the picture works, but touching it does nothing. OpenTouch
is a small menu bar app that reads the touch screen and the pen, and turns them into normal
clicks, drags, scrolling and pressure-sensitive pen input.

No kernel extension or system extension is needed. OpenTouch reads the panel through
Apple's public HID API and posts regular macOS input events.

## What works

| You do | Mac gets |
| --- | --- |
| Tap | Click (tap twice for a double click) |
| Touch and drag | Click and drag (move windows, select text) |
| Long press | Right click |
| Two-finger drag | Smooth scrolling, with momentum |
| Two-finger tap | Right click |
| Pen hover | Pointer follows the pen |
| Pen down | Click and drag with **pressure and tilt** (works in apps that support tablets) |
| Pen with barrel button | Right click |
| Pen eraser end / eraser button | Eraser tool in apps that support it |

Touches are ignored while the pen is near the screen, so your palm doesn't click things
while you write.

Not supported (yet): pinch to zoom and rotate. macOS gives apps no public way to create
trackpad gestures. Pull requests that find a reliable way are very welcome.

## Supported hardware

Any touch screen or pen that follows the standard USB HID digitizer spec should work.
That covers almost every touch monitor sold for Windows.

| Device | Touch | Pen | Notes |
| --- | --- | --- | --- |
| Lenovo ThinkVision M14t Gen 2 | ✅ | 🧪 | Development device; pen not yet tested on hardware |

Tried another device? Please open an issue or a pull request so it can be added here.

## Install

1. Download `OpenTouch.app` from [Releases](https://github.com/nielsvanharen/opentouch/releases), or build it
   yourself (see below), and move it to `/Applications`.
2. Open it. A hand icon appears in the menu bar.
3. Grant **Accessibility** when asked (System Settings → Privacy & Security → Accessibility).
   OpenTouch needs this to click and scroll for you.
4. If macOS also asks for **Input Monitoring**, allow that too.
5. Touch the screen.

If touches land on the wrong monitor, choose the right one under
**menu bar icon → Touch Screen Display**. Rotated displays are handled automatically.

### Coming from UPDD

UPDD (Touch-Base) takes exclusive control of the touch screen, so OpenTouch can't read it while
UPDD is installed. Remove it first with **/Applications/Utilities/UPDD Uninstall.app**, then
unplug and replug the monitor's USB-C cable.

## Build from source

You need macOS 13 or newer and Swift 5.10 or newer (Xcode or the Command Line Tools).

```sh
git clone https://github.com/nielsvanharen/opentouch.git
cd opentouch
swift test
scripts/build-app.sh          # creates build/OpenTouch.app
open build/OpenTouch.app
```

The build is signed ad hoc, so macOS treats each new build as a different app. After a
rebuild, turn OpenTouch off and on again in the Accessibility settings.

## Troubleshooting and new devices

Run OpenTouch from the terminal in dump mode to see exactly what the panel sends,
without moving the pointer:

```sh
build/OpenTouch.app/Contents/MacOS/OpenTouch --dump        # decoded touches and pen samples
build/OpenTouch.app/Contents/MacOS/OpenTouch --dump --raw  # also the raw report bytes
```

The first lines show the device's HID report descriptor. Include that output when you open
an issue for a device that doesn't work.

## How it works

```
USB touch panel ──HID reports──▶ HIDService ──▶ DigitizerDecoder ──▶ TouchGestureEngine ─┐
                                 (IOKit)        (descriptor parser)  PenTracker           ├─▶ EventPoster ──▶ macOS
                                                                     DisplayMapper ───────┘   (CGEvent)
```

- **`HIDDescriptor`** parses the panel's HID report descriptor, so OpenTouch knows where X, Y,
  contact IDs, pressure and so on sit in each report. No device-specific code is needed.
- **`DigitizerDecoder`** turns reports into touch frames and pen samples. It also handles
  "hybrid mode" panels that split one frame across several reports, and switches
  Windows-style panels into multi-touch mode.
- **`TouchGestureEngine`** and **`PenTracker`** decide what a touch means: tap, drag, long
  press, scroll, or pen stroke.
- **`DisplayMapper`** maps panel coordinates onto the right display, taking rotation into account.
- **`EventPoster`** posts mouse, scroll and tablet events with `CGEvent`.

The `OpenTouchCore` module has no macOS dependencies and is covered by unit tests.

## Contributing

Issues and pull requests are welcome, especially reports from other touch monitors.
Run `swift test` before opening a pull request.

## License

[MIT](LICENSE)
