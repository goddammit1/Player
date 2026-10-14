#ifndef RUNNER_MEDIA_CONTROLS_H_
#define RUNNER_MEDIA_CONTROLS_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

#include <memory>

// System Media Transport Controls (SMTC): the Windows media flyout, lock
// screen and hardware media keys. Dart (channel "player/media_controls")
// sends track metadata and playback state; button presses and seek requests
// are sent back to Dart.
class MediaControls {
 public:
  // Posted to the window to hand SMTC events (raised on a background thread)
  // over to the platform thread, where the channel may be used.
  static constexpr UINT kEventMessage = WM_APP + 0x51;

  MediaControls(flutter::BinaryMessenger* messenger, HWND window);
  ~MediaControls();

  MediaControls(const MediaControls&) = delete;
  MediaControls& operator=(const MediaControls&) = delete;

  // Called by FlutterWindow on kEventMessage.
  void DispatchPendingEvents();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_MEDIA_CONTROLS_H_
