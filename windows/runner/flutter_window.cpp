#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include <algorithm>
#include <optional>

#include "caption_pin.h"
#include "flutter/generated_plugin_registrant.h"

// Host the existing Flutter view in a second HWND. Windows retains both the
// main window's snap layout and the normal bounds it will use when unsnapped.
class MiniPlayerWindow : public Win32Window {
 public:
  MiniPlayerWindow(Win32Window& main_window, flutter::FlutterEngine& engine)
      : main_window_(main_window), engine_(engine) {
    SetMinimumSize({208, 156});
  }

  bool Enter(bool portrait) {
    if (GetHandle()) return true;
    in_size_move_ = false;
    pending_orientation_.reset();
    if (!Place(portrait)) return false;
    if (!main_window_.TransferChildContent(*this)) {
      Destroy();
      return false;
    }
    ShowWindow(GetHandle(), SW_SHOW);
    ShowWindow(main_window_.GetHandle(), SW_HIDE);
    return true;
  }

  bool Exit() {
    if (!GetHandle()) return true;
    const bool active = GetForegroundWindow() == GetHandle();
    if (!TransferChildContent(main_window_)) return false;
    ShowWindow(main_window_.GetHandle(), active ? SW_SHOW : SW_SHOWNA);
    Destroy();
    return true;
  }

  bool SetOrientation(bool portrait) {
    if (!GetHandle()) return true;
    if (in_size_move_ || IsIconic(GetHandle())) {
      pending_orientation_ = portrait;
      return true;
    }
    pending_orientation_.reset();
    return portrait == portrait_ || Place(portrait);
  }

 protected:
  LRESULT MessageHandler(HWND hwnd, UINT message, WPARAM wparam,
                         LPARAM lparam) noexcept override {
    if (message == WM_CLOSE) {
      PostMessage(main_window_.GetHandle(), WM_CLOSE, wparam, lparam);
      return 0;
    }
    if (message == WM_ENTERSIZEMOVE) in_size_move_ = true;
    if (message == WM_EXITSIZEMOVE) {
      RECT rect{};
      if (GetWindowRect(hwnd, &rect)) {
        const UINT dpi = FlutterDesktopGetDpiForHWND(hwnd);
        sizes_[portrait_] = {MulDiv(rect.right - rect.left, 96, dpi),
                             MulDiv(rect.bottom - rect.top, 96, dpi)};
      }
      in_size_move_ = false;
    }
    if (pending_orientation_ && (message == WM_EXITSIZEMOVE ||
        (message == WM_SIZE && wparam == SIZE_RESTORED))) {
      SetOrientation(*pending_orientation_);
    }
    engine_.ProcessExternalWindowMessage(hwnd, message, wparam, lparam);
    return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  }

 private:
  bool Place(bool portrait) {
    HWND hwnd = GetHandle();
    HMONITOR monitor = MonitorFromWindow(hwnd ? hwnd : main_window_.GetHandle(),
                                         MONITOR_DEFAULTTONEAREST);
    MONITORINFO info{};
    info.cbSize = sizeof(info);
    RECT current{};
    if (!GetMonitorInfo(monitor, &info) ||
        (hwnd && !GetWindowRect(hwnd, &current))) {
      return false;
    }
    const UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
    const int margin = MulDiv(16, dpi, 96);
    const RECT& work = info.rcWork;
    const SIZE size = sizes_[portrait];
    const LONG width = std::min<LONG>(
        MulDiv(size.cx, dpi, 96), std::max<LONG>(1, work.right - work.left - 2 * margin));
    const LONG height = std::min<LONG>(
        MulDiv(size.cy, dpi, 96), std::max<LONG>(1, work.bottom - work.top - 2 * margin));
    const LONG x = hwnd ? std::clamp(current.left, work.left, work.right - width)
                        : work.right - width - margin;
    const LONG y = hwnd ? std::clamp(current.top, work.top, work.bottom - height)
                        : work.bottom - height - margin;
    if (hwnd) {
      if (!SetWindowPos(hwnd, nullptr, x, y, width, height,
                        SWP_NOZORDER | SWP_NOACTIVATE)) {
        return false;
      }
    } else if (!Create(L"ApexDrama", {x, y, x + width, y + height},
                       WS_POPUP | WS_THICKFRAME, WS_EX_APPWINDOW | WS_EX_TOPMOST)) {
      return false;
    }
    portrait_ = portrait;
    return true;
  }

  Win32Window& main_window_;
  flutter::FlutterEngine& engine_;
  bool portrait_ = false;
  bool in_size_move_ = false;
  std::optional<bool> pending_orientation_;
  SIZE sizes_[2] = {{384, 216}, {216, 384}};
};

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  mini_player_ = std::make_unique<MiniPlayerWindow>(
      *this, *flutter_controller_->engine());
  flutter::MethodChannel<> mini_channel(
      flutter_controller_->engine()->messenger(), "apexduanju/mini_player",
      &flutter::StandardMethodCodec::GetInstance());
  mini_channel.SetMethodCallHandler([this](const auto& call, auto result) {
    bool ok;
    if ((call.method_name() == "enter" || call.method_name() == "setOrientation") &&
        call.arguments() &&
        std::holds_alternative<bool>(*call.arguments())) {
      const bool portrait = std::get<bool>(*call.arguments());
      ok = call.method_name() == "enter" ? mini_player_->Enter(portrait)
                                         : mini_player_->SetOrientation(portrait);
    } else if (call.method_name() == "exit") {
      ok = mini_player_->Exit();
    } else if (call.method_name() == "drag" && mini_player_->GetHandle()) {
      ReleaseCapture();
      ok = PostMessage(mini_player_->GetHandle(), WM_SYSCOMMAND,
                       SC_MOVE | HTCAPTION, 0) != 0;
    } else {
      result->NotImplemented();
      return;
    }
    if (ok) {
      result->Success();
    } else {
      result->Error("window", "Could not change mini player mode");
    }
  });
  if (!SetChildContent(flutter_controller_->view()->GetNativeWindow())) return false;
  caption_pin_ = CreateCaptionPin(GetHandle());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  caption_pin_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }
  mini_player_.reset();

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_THEMECHANGED:
    case WM_SETTINGCHANGE:
    case WM_DWMCOLORIZATIONCOLORCHANGED:
      if (caption_pin_) InvalidateRect(caption_pin_, nullptr, FALSE);
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  const LRESULT result = Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  if (message == WM_WINDOWPOSCHANGED && caption_pin_) {
    UpdateCaptionPin(caption_pin_);
  }
  return result;
}
