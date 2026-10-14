#include "media_controls.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <systemmediatransportcontrolsinterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.Streams.h>

#include <atomic>
#include <chrono>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using winrt::Windows::Foundation::Uri;
using winrt::Windows::Media::MediaPlaybackStatus;
using winrt::Windows::Media::MediaPlaybackType;
using winrt::Windows::Media::PlaybackPositionChangeRequestedEventArgs;
using winrt::Windows::Media::SystemMediaTransportControls;
using winrt::Windows::Media::SystemMediaTransportControlsButton;
using winrt::Windows::Media::SystemMediaTransportControlsButtonPressedEventArgs;
using winrt::Windows::Media::SystemMediaTransportControlsDisplayUpdater;
using winrt::Windows::Media::SystemMediaTransportControlsTimelineProperties;
using winrt::Windows::Storage::StorageFile;
using winrt::Windows::Storage::Streams::RandomAccessStreamReference;

std::wstring Utf16(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  const int length = ::MultiByteToWideChar(
      CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring result(length, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                        static_cast<int>(utf8.size()), result.data(), length);
  return result;
}

std::string StringField(const EncodableMap& map, const char* key) {
  const auto it = map.find(EncodableValue(key));
  if (it == map.end()) return std::string();
  const auto* value = std::get_if<std::string>(&it->second);
  return value ? *value : std::string();
}

int64_t IntField(const EncodableMap& map, const char* key) {
  const auto it = map.find(EncodableValue(key));
  if (it == map.end()) return 0;
  if (const auto* v32 = std::get_if<int32_t>(&it->second)) return *v32;
  if (const auto* v64 = std::get_if<int64_t>(&it->second)) return *v64;
  return 0;
}

bool BoolField(const EncodableMap& map, const char* key) {
  const auto it = map.find(EncodableValue(key));
  if (it == map.end()) return false;
  const auto* value = std::get_if<bool>(&it->second);
  return value && *value;
}

const char* ButtonName(SystemMediaTransportControlsButton button) {
  switch (button) {
    case SystemMediaTransportControlsButton::Play:
      return "play";
    case SystemMediaTransportControlsButton::Pause:
      return "pause";
    case SystemMediaTransportControlsButton::Stop:
      return "stop";
    case SystemMediaTransportControlsButton::Next:
      return "next";
    case SystemMediaTransportControlsButton::Previous:
      return "previous";
    default:
      return nullptr;
  }
}

struct Event {
  std::string method;
  EncodableValue argument;
  // Set for a cover loaded in the background: applied on the platform thread
  // only if [generation] is still the current metadata generation.
  StorageFile thumbnail{nullptr};
  int generation = 0;
};

// Shared with SMTC handlers and thumbnail threads, which may still be running
// after MediaControls is destroyed (revoking a WinRT handler does not wait
// for an invocation already in flight).
struct EventQueue {
  std::mutex mutex;
  std::vector<Event> pending;
  HWND window = nullptr;
  bool alive = true;

  void Post(Event event) {
    std::lock_guard<std::mutex> lock(mutex);
    if (!alive) return;
    pending.push_back(std::move(event));
    ::PostMessage(window, MediaControls::kEventMessage, 0, 0);
  }
};

}  // namespace

struct MediaControls::Impl {
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel;
  SystemMediaTransportControls smtc{nullptr};
  winrt::event_token button_token{};
  winrt::event_token seek_token{};
  std::shared_ptr<EventQueue> events = std::make_shared<EventQueue>();

  // Bumped on every metadata update (platform thread only): a thumbnail
  // loaded in the background for an older track must not overwrite the
  // current one.
  int artwork_generation = 0;

  void Init(HWND window) {
    events->window = window;
    auto interop = winrt::get_activation_factory<
        SystemMediaTransportControls, ISystemMediaTransportControlsInterop>();
    winrt::check_hresult(interop->GetForWindow(
        window, winrt::guid_of<SystemMediaTransportControls>(),
        winrt::put_abi(smtc)));
    smtc.IsPlayEnabled(true);
    smtc.IsPauseEnabled(true);
    smtc.IsStopEnabled(true);
    smtc.IsNextEnabled(true);
    smtc.IsPreviousEnabled(true);
    smtc.IsEnabled(false);
    button_token = smtc.ButtonPressed(
        [events = events](
            const SystemMediaTransportControls&,
            const SystemMediaTransportControlsButtonPressedEventArgs& args) {
          if (const char* name = ButtonName(args.Button())) {
            events->Post({"onButton", EncodableValue(std::string(name))});
          }
        });
    seek_token = smtc.PlaybackPositionChangeRequested(
        [events = events](const SystemMediaTransportControls&,
                          const PlaybackPositionChangeRequestedEventArgs& args) {
          const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
              args.RequestedPlaybackPosition());
          events->Post(
              {"onSeek", EncodableValue(static_cast<int64_t>(ms.count()))});
        });
  }

  void Revoke() {
    if (!smtc) return;
    if (button_token) smtc.ButtonPressed(button_token);
    if (seek_token) smtc.PlaybackPositionChangeRequested(seek_token);
    button_token = {};
    seek_token = {};
  }

  void Update(const EncodableMap& args) {
    smtc.IsEnabled(true);
    SystemMediaTransportControlsDisplayUpdater updater = smtc.DisplayUpdater();
    updater.ClearAll();
    updater.Type(MediaPlaybackType::Music);
    auto music = updater.MusicProperties();
    music.Title(Utf16(StringField(args, "title")));
    music.Artist(Utf16(StringField(args, "artist")));
    music.AlbumTitle(Utf16(StringField(args, "album")));

    const int generation = ++artwork_generation;
    const std::string artwork = StringField(args, "artwork");
    if (artwork.rfind("http://", 0) == 0 || artwork.rfind("https://", 0) == 0) {
      try {
        updater.Thumbnail(
            RandomAccessStreamReference::CreateFromUri(Uri(Utf16(artwork))));
      } catch (const winrt::hresult_error&) {
        // Malformed URL: publish the text metadata without a cover.
      }
    } else if (!artwork.empty()) {
      LoadFileThumbnail(Utf16(artwork), generation);
    }
    updater.Update();
  }

  // StorageFile lookup is async and must not block the STA platform thread;
  // the loaded file is handed back to the platform thread to be applied.
  void LoadFileThumbnail(std::wstring path, int generation) {
    std::thread([events = events, path = std::move(path), generation]() {
      try {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
      } catch (const winrt::hresult_error&) {
        return;
      }
      try {
        Event event;
        event.thumbnail = StorageFile::GetFileFromPathAsync(path).get();
        event.generation = generation;
        events->Post(std::move(event));
      } catch (...) {
        // Missing or unreadable cover: keep the text metadata only.
      }
      winrt::uninit_apartment();
    }).detach();
  }

  void ApplyThumbnail(const Event& event) {
    if (!smtc || event.generation != artwork_generation) return;
    try {
      SystemMediaTransportControlsDisplayUpdater updater = smtc.DisplayUpdater();
      updater.Thumbnail(RandomAccessStreamReference::CreateFromFile(event.thumbnail));
      updater.Update();
    } catch (const winrt::hresult_error&) {
    }
  }

  void SetState(const EncodableMap& args) {
    smtc.PlaybackStatus(BoolField(args, "playing") ? MediaPlaybackStatus::Playing
                                                   : MediaPlaybackStatus::Paused);
    const std::chrono::milliseconds duration(IntField(args, "durationMs"));
    const std::chrono::milliseconds position(IntField(args, "positionMs"));
    SystemMediaTransportControlsTimelineProperties timeline;
    timeline.StartTime(std::chrono::milliseconds(0));
    timeline.MinSeekTime(std::chrono::milliseconds(0));
    timeline.EndTime(duration);
    timeline.MaxSeekTime(duration);
    timeline.Position(position < duration ? position : duration);
    smtc.UpdateTimelineProperties(timeline);
  }

  void Clear() {
    ++artwork_generation;
    smtc.DisplayUpdater().ClearAll();
    smtc.DisplayUpdater().Update();
    smtc.PlaybackStatus(MediaPlaybackStatus::Closed);
    smtc.IsEnabled(false);
  }

  void HandleMethodCall(
      const flutter::MethodCall<EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    if (!smtc) {
      result->Error("unavailable", "SMTC is not available");
      return;
    }
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    try {
      if (call.method_name() == "update" && args) {
        Update(*args);
      } else if (call.method_name() == "state" && args) {
        SetState(*args);
      } else if (call.method_name() == "clear") {
        Clear();
      } else {
        result->NotImplemented();
        return;
      }
      result->Success();
    } catch (const winrt::hresult_error& e) {
      result->Error("smtc", winrt::to_string(e.message()));
    }
  }
};

MediaControls::MediaControls(flutter::BinaryMessenger* messenger, HWND window)
    : impl_(std::make_unique<Impl>()) {
  impl_->channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "player/media_controls",
      &flutter::StandardMethodCodec::GetInstance());
  try {
    impl_->Init(window);
  } catch (const winrt::hresult_error&) {
    // No SMTC (e.g. Windows N without Media Feature Pack): Dart gets an
    // "unavailable" error and stops sending updates.
    impl_->Revoke();
    impl_->smtc = nullptr;
  }
  Impl* impl = impl_.get();
  impl_->channel->SetMethodCallHandler(
      [impl](const auto& call, auto result) {
        impl->HandleMethodCall(call, std::move(result));
      });
}

MediaControls::~MediaControls() {
  impl_->channel->SetMethodCallHandler(nullptr);
  {
    std::lock_guard<std::mutex> lock(impl_->events->mutex);
    impl_->events->alive = false;
    impl_->events->pending.clear();
  }
  impl_->Revoke();
}

void MediaControls::DispatchPendingEvents() {
  std::vector<Event> events;
  {
    std::lock_guard<std::mutex> lock(impl_->events->mutex);
    events.swap(impl_->events->pending);
  }
  for (auto& event : events) {
    if (event.thumbnail) {
      impl_->ApplyThumbnail(event);
      continue;
    }
    impl_->channel->InvokeMethod(
        event.method, std::make_unique<EncodableValue>(event.argument));
  }
}
