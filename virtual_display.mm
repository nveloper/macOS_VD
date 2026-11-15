/**
 * @file virtual_display.mm
 * @brief A single virtual display, which uses the private CGVirtualDisplay classes.
 *
 * The classes are looked up at run time, so a macOS release without them makes apply()
 * return false instead of failing to launch. Applying settings to a live display keeps
 * its identifier, so a size change needs no new display.
 */
// standard includes
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <dlfcn.h>
#include <iostream>
#include <mutex>
#include <sstream>
#include <thread>

// platform includes
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

// local includes
#include "virtual_display.h"

// Writes one line to stderr. Replace with your own logger.
namespace {
  struct log_line {
    std::ostringstream text;
    explicit log_line(const char *level) {
      text << "[virtual_display] " << level << ": ";
    }
    ~log_line() {
      text << '\n';
      std::cerr << text.str();
    }
    template<class T>
    log_line &operator<<(const T &value) {
      text << value;
      return *this;
    }
  };
}  // namespace
#define VD_LOG(level) log_line(#level)

using namespace std::literals;

@interface CGVirtualDisplayMode: NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate transferFunction:(unsigned int)transferFunction;
@end

@interface CGVirtualDisplaySettings: NSObject
@property (nonatomic) unsigned int hiDPI;
@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@end

@interface CGVirtualDisplayDescriptor: NSObject
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int serialNum;
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplay: NSObject
@property (readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

namespace virtual_display {

  namespace {
    constexpr int max_width = 3840;
    constexpr int max_height = 2400;
    constexpr int min_hidpi_width = 1600;
    constexpr auto settle_timeout = 8s;
    // Makes the display HDR capable. macOS reads it when the display is created and cannot turn it off afterwards,
    // so SDR streams use the same display and capture it as SDR.
    constexpr unsigned int hdr_transfer_function = 1;

    std::mutex mutex;
    CGVirtualDisplay *display = nil;
    int wanted_width = 0;  // Logical size, half the pixels in a 2x mode.
    int wanted_height = 0;
    int wanted_pixel_width = 0;
    bool keeper_started = false;
    std::atomic_uint settings_generation {0};

    bool mode_is_wanted(CGDirectDisplayID id) {
      // Bounds and the screen scale, since CGDisplayCopyDisplayMode can return null for this display.
      const auto bounds = CGDisplayBounds(id);
      CGFloat scale = 0;
      for (NSScreen *screen in NSScreen.screens) {
        if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == id) {
          scale = screen.backingScaleFactor;
        }
      }
      return (int) bounds.size.width == wanted_width && (int) bounds.size.height == wanted_height &&
             (int) (bounds.size.width * scale) == wanted_pixel_width;
    }

    /**
     * @brief Selects the wanted mode, since macOS can stay on a mode with the same pixels but another scale.
     */
    void select_wanted_mode(CGDirectDisplayID id) {
      const void *keys[] = {kCGDisplayShowDuplicateLowResolutionModes};
      const void *values[] = {kCFBooleanTrue};
      CFDictionaryRef options = CFDictionaryCreate(nullptr, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
      CFArrayRef modes = CGDisplayCopyAllDisplayModes(id, options);
      CFRelease(options);
      if (modes == nullptr) {
        return;
      }
      for (CFIndex i = 0; i < CFArrayGetCount(modes); ++i) {
        auto mode = (CGDisplayModeRef) CFArrayGetValueAtIndex(modes, i);
        if ((int) CGDisplayModeGetWidth(mode) != wanted_width ||
            (int) CGDisplayModeGetHeight(mode) != wanted_height ||
            (int) CGDisplayModeGetPixelWidth(mode) != wanted_pixel_width) {
          continue;
        }
        CGDisplayConfigRef config;
        if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
          CGConfigureDisplayWithDisplayMode(config, id, mode, nullptr);
          const auto status = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
          VD_LOG(debug) << "selected "sv << wanted_width << 'x' << wanted_height << ", status "sv << status;
        }
        break;
      }
      CFRelease(modes);
    }

    /**
     * @brief Puts the wanted mode back, because macOS resets it when the display configuration changes.
     */
    void keep_mode() {
      while (true) {
        std::this_thread::sleep_for(1s);
        @autoreleasepool {
        std::lock_guard lock {mutex};
        if (!mode_is_wanted(display.displayID)) {
          select_wanted_mode(display.displayID);
        }
        }
      }
    }

    bool create_display() {
      Class descriptor_class = NSClassFromString(@"CGVirtualDisplayDescriptor");
      Class display_class = NSClassFromString(@"CGVirtualDisplay");
      if (descriptor_class == nil || display_class == nil || NSClassFromString(@"CGVirtualDisplaySettings") == nil || NSClassFromString(@"CGVirtualDisplayMode") == nil) {
        VD_LOG(warning) << "this macOS has no CGVirtualDisplay"sv;
        return false;
      }
      CGVirtualDisplayDescriptor *descriptor = [[[descriptor_class alloc] init] autorelease];
      [descriptor setDispatchQueue:dispatch_queue_create("standalone.virtual_display", DISPATCH_QUEUE_SERIAL)];
      descriptor.name = @"Virtual Display";
      descriptor.maxPixelsWide = max_width;
      descriptor.maxPixelsHigh = max_height;
      descriptor.sizeInMillimeters = CGSizeMake(559, 385);
      // Any values work. macOS remembers per-display settings by these three.
      descriptor.vendorID = 0x5644;
      descriptor.productID = 0x0001;
      descriptor.serialNum = 1;
      // macOS keeps the identifiers of a previous process for a few seconds after it exits.
      for (int attempt = 0; attempt < 15 && display == nil; ++attempt) {
        if (attempt > 0) {
          std::this_thread::sleep_for(1s);
        }
        display = [[display_class alloc] initWithDescriptor:descriptor];
      }
      if (display == nil) {
        VD_LOG(warning) << "creation failed"sv;
        return false;
      }
      return true;
    }
  }  // namespace

  double points_per_pixel(unsigned int display_id) {
    @autoreleasepool {
      for (NSScreen *screen in NSScreen.screens) {
        if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == display_id) {
          return 1.0 / screen.backingScaleFactor;
        }
      }
    }
    return 1.0;
  }

  bool current_size(const std::string &output_name, int &width, int &height) {
    // A given display that is not active falls back to the main one.
    CGDirectDisplayID id = CGMainDisplayID();
    CGDirectDisplayID active[32];
    uint32_t count = 0;
    if (!output_name.empty() && CGGetActiveDisplayList(32, active, &count) == kCGErrorSuccess) {
      const auto wanted = static_cast<CGDirectDisplayID>(std::strtoul(output_name.c_str(), nullptr, 10));
      for (uint32_t i = 0; i < count; ++i) {
        if (active[i] == wanted) {
          id = wanted;
        }
      }
    }

    // Bounds follow rotation and a mode does not, so the mode only supplies the scale.
    double scale = 1.0 / points_per_pixel(id);
    if (CGDisplayModeRef mode = CGDisplayCopyDisplayMode(id)) {
      if (CGDisplayModeGetWidth(mode) > 0) {
        scale = static_cast<double>(CGDisplayModeGetPixelWidth(mode)) / CGDisplayModeGetWidth(mode);
      }
      CFRelease(mode);
    }
    const auto bounds = CGDisplayBounds(id);
    width = static_cast<int>(bounds.size.width * scale + 0.5);
    height = static_cast<int>(bounds.size.height * scale + 0.5);
    return width > 0 && height > 0;
  }

  bool hdr_enabled(unsigned int display_id) {
    using is_hdr_enabled_fn = bool (*)(CGDirectDisplayID);
    static const auto is_hdr_enabled = [] {
      void *skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
      return skylight ? reinterpret_cast<is_hdr_enabled_fn>(dlsym(skylight, "SLSDisplayIsHDRModeEnabled")) : nullptr;
    }();
    return is_hdr_enabled && is_hdr_enabled(display_id);
  }

  unsigned int generation() {
    return settings_generation.load();
  }

  unsigned int id() {
    std::lock_guard lock {mutex};
    return display != nil ? display.displayID : 0;
  }

  bool ready() {
    std::lock_guard lock {mutex};
    return display != nil;
  }

  bool hdr_ready() {
    std::lock_guard lock {mutex};
    if (@available(macOS 15.0, *)) {
      return display != nil && hdr_enabled(display.displayID);
    }
    return false;
  }

  void run_main_loop_briefly() {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
  }

  bool apply(int width, int height, int fps, bool hidpi) {
    if (width <= 0 || height <= 0 || fps <= 0 || width > max_width || height > max_height) {
      VD_LOG(warning) << "unsupported mode "sv << width << 'x' << height << '@' << fps;
      return false;
    }
    @autoreleasepool {
      std::lock_guard lock {mutex};
      if (display == nil && !create_display()) {
        return false;
      }

      const bool use_hidpi = hidpi && width >= min_hidpi_width && width % 2 == 0 && height % 2 == 0;
      wanted_width = use_hidpi ? width / 2 : width;
      wanted_height = use_hidpi ? height / 2 : height;
      wanted_pixel_width = width;

      CGVirtualDisplaySettings *settings = [[[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init] autorelease];
      settings.hiDPI = use_hidpi ? 1 : 0;
      CGVirtualDisplayMode *mode = [NSClassFromString(@"CGVirtualDisplayMode") alloc];
      if ([mode respondsToSelector:@selector(initWithWidth:height:refreshRate:transferFunction:)]) {
        mode = [mode initWithWidth:wanted_width height:wanted_height refreshRate:fps transferFunction:hdr_transfer_function];
      } else {
        mode = [mode initWithWidth:wanted_width height:wanted_height refreshRate:fps];
      }
      settings.modes = @[[mode autorelease]];
      if (![display applySettings:settings]) {
        VD_LOG(warning) << "applying "sv << width << 'x' << height << '@' << fps << " failed"sv;
        return false;
      }
      // Lets callers that cached the size notice the change.
      ++settings_generation;

      if (!keeper_started) {
        keeper_started = true;
        std::thread(keep_mode).detach();
      }
      const auto id = display.displayID;
      const auto deadline = std::chrono::steady_clock::now() + settle_timeout;
      while (!mode_is_wanted(id) || !CGDisplayIsActive(id)) {
        if (std::chrono::steady_clock::now() >= deadline) {
          // Not fatal: the keeper thread goes on selecting the mode once this process sees the new list.
          VD_LOG(warning) << width << 'x' << height << '@' << fps << " did not settle in time"sv;
          break;
        }
        // A mode change takes a moment, and a new request during it can undo it.
        if ([NSThread isMainThread]) {
          CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1, false);
        } else {
          std::this_thread::sleep_for(1s);
        }
        if (!mode_is_wanted(id)) {
          select_wanted_mode(id);
        }
      }
      if (!CGDisplayIsMain(id)) {
        VD_LOG(info) << "another display is the main one"sv;
      }
      VD_LOG(info) << "display "sv << id << " is "sv << width << 'x' << height << '@' << fps << (use_hidpi ? " HiDPI"sv : ""sv);
      return true;
    }
  }

}  // namespace virtual_display
