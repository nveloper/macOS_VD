/**
 * @file main.mm
 * @brief Example: makes the virtual display and keeps it until Ctrl-C.
 *
 * Usage: vd-demo [width height fps [hidpi]]
 */
#include <cstdio>
#include <cstdlib>

#import <AppKit/AppKit.h>

#include "virtual_display.h"

int main(int argc, char *argv[]) {
  const int width = argc > 3 ? std::atoi(argv[1]) : 1920;
  const int height = argc > 3 ? std::atoi(argv[2]) : 1080;
  const int fps = argc > 3 ? std::atoi(argv[3]) : 60;
  const bool hidpi = argc > 4 && std::atoi(argv[4]) != 0;

  @autoreleasepool {
    // AppKit must be connected for NSScreen to follow display changes.
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    // On the main thread apply() runs the run loop itself while it waits for the mode.
    if (!virtual_display::apply(width, height, fps, hidpi)) {
      std::fprintf(stderr, "could not make the virtual display\n");
      return 1;
    }

    const unsigned int id = virtual_display::id();
    int current_width = 0;
    int current_height = 0;
    virtual_display::current_size(std::to_string(id), current_width, current_height);
    std::printf("display id %u, %dx%d pixels, HDR %s\n", id, current_width, current_height, virtual_display::hdr_ready() ? "yes" : "no");
    std::printf("Ctrl-C removes the display.\n");

    // The display lives as long as this process. Call apply() again at any time to resize it.
    [NSApp run];
  }
  return 0;
}
