/**
 * @file virtual_display.h
 * @brief A single macOS virtual display that can be resized while it lives.
 *
 * Standalone copy: depends only on AppKit and CoreGraphics. The display exists until the process exits.
 */
#pragma once

// standard includes
#include <string>

namespace virtual_display {

  /**
   * @brief Creates the display if needed and sizes it to the client.
   * @param width Width in pixels, up to 3840.
   * @param height Height in pixels, up to 2400.
   * @param fps Refresh rate.
   * @param hidpi Requests the 2x mode, which is skipped when the size cannot be halved or is too small.
   * @return True when the settings were applied. False when the mode is unsupported or the display could not be made.
   */
  bool apply(int width, int height, int fps, bool hidpi);

  /**
   * @brief Reads the current size of a display in pixels.
   * @param output_name The display id as a decimal string, or empty for the main display.
   * @param width Receives the rotated width in pixels.
   * @param height Receives the rotated height in pixels.
   * @return False when the size is not known.
   */
  bool current_size(const std::string &output_name, int &width, int &height);

  /**
   * @brief Returns whether a display is in HDR mode.
   */
  bool hdr_enabled(unsigned int display_id);

  /**
   * @brief Returns a number that changes whenever the virtual display takes new settings.
   */
  unsigned int generation();

  /**
   * @brief Returns the id of the virtual display, or 0 when it does not exist.
   */
  unsigned int id();

  /**
   * @brief Returns whether the virtual display exists.
   */
  bool ready();

  /**
   * @brief Returns whether the virtual display can be captured in HDR.
   */
  bool hdr_ready();

  /**
   * @brief Runs the main run loop for a moment. Without it display modes read as null after a change.
   */
  void run_main_loop_briefly();

  /**
   * @brief Returns points per pixel for a display, which is 0.5 in a 2x mode.
   */
  double points_per_pixel(unsigned int display_id);

}  // namespace virtual_display
