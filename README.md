# macOS Virtual Display

Creates a single virtual monitor on macOS and changes its resolution and refresh rate while live. It has no dependencies other than AppKit and CoreGraphics.

It does not capture the screen or stream it to another device. Because the created display appears like a regular monitor, you can capture it by passing the display ID returned by `id()` to ScreenCaptureKit or similar APIs.

## Files

| File | Description |
|---|---|
| `virtual_display.h` | Public functions |
| `virtual_display.mm` | Implementation |
| `main.mm` | Example. Creates a display and keeps it alive until Ctrl-C |

## Build and Run

```bash
clang++ -std=c++17 -fno-objc-arc main.mm virtual_display.mm -framework AppKit -framework CoreGraphics -o vd-demo
```

```bash
./vd-demo 2420 1668 120
```

Arguments are `width height refresh_rate [hidpi]`, defaulting to `1920x1080@60` if omitted. Passing `1` for `hidpi` uses 2x mode (half the logical size).

## Usage

```cpp
#include "virtual_display.h"

virtual_display::apply(1920, 1080, 60, false);  // Creates if missing, or resizes if it already exists
unsigned int id = virtual_display::id();        // CGDirectDisplayID
```

## Notes

- **Compile with ARC disabled.** `virtual_display.mm` uses manual reference counting (`-fno-objc-arc`).
- **Uses private APIs.** `CGVirtualDisplay` is an undocumented class, so its behavior may change across macOS versions and it cannot be submitted to the App Store. If the class is unavailable, `apply()` returns `false`.
- **The display disappears when the process exits.** There is no removal function.
- **Maximum resolution is 3840x2400.** You can change this by modifying `max_width` and `max_height` in `virtual_display.mm`.
- **Requires an AppKit connection and a run loop.** Mode changes will not take effect unless `NSApplication` is initialized and the main run loop is running. Calling `apply()` on the main thread pumps the run loop automatically while waiting. When calling from another thread, the main run loop must already be running.
- **A mode-maintenance thread runs in the background.** Because macOS reverts the mode when the display configuration changes, it checks every second and re-selects the mode.
- **Created as an HDR-capable display.** This is set only at creation time and cannot be disabled later. If you only need SDR, change `hdr_transfer_function` to `0`.
- **Creation can take up to 15 seconds.** If a previous process using the same identifier just exited, macOS rejects creation for a few seconds, so it retries.
- Logs are written to `stderr`. Redefine the `VD_LOG` macro to route them to another logger.
