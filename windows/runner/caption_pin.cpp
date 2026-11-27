#include "caption_pin.h"

#include <commctrl.h>
#include <flutter_windows.h>
#include <windowsx.h>

#include <algorithm>
#include <cstdint>
#include <optional>

#include "win32_window.h"

namespace {

bool IsTopmost(HWND window) {
  return (GetWindowLongPtr(window, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0;
}

const wchar_t* PinLabel(bool pinned) {
  return pinned ? L"\u53d6\u6d88\u7f6e\u9876" : L"\u7a97\u53e3\u7f6e\u9876";
}

void TogglePin(HWND button) {
  HWND owner = GetWindow(button, GW_OWNER);
  const bool pin = !IsTopmost(owner);
  const LONG_PTR style = GetWindowLongPtr(owner, GWL_STYLE);
  // Explorer's Show Desktop skips minimization for windows without a minimize box.
  if (!SetWindowLongPtr(owner, GWL_STYLE,
                        pin ? style & ~WS_MINIMIZEBOX : style | WS_MINIMIZEBOX)) {
    return;
  }
  constexpr UINT flags = SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED;
  if (!SetWindowPos(owner, pin ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0, flags)) {
    SetWindowLongPtr(owner, GWL_STYLE, style);
    SetWindowPos(owner, nullptr, 0, 0, 0, 0, flags | SWP_NOZORDER);
  }
  // Windows finishes reordering owned popups after WM_WINDOWPOSCHANGED.
  UpdateCaptionPin(button);
}

void PaintPin(HWND button) {
  HWND owner = GetWindow(button, GW_OWNER);
  RECT rect{};
  GetClientRect(button, &rect);
  const LONG width = rect.right;
  const LONG height = rect.bottom;
  if (width <= 0 || height <= 0) return;

  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  HDC dc = CreateCompatibleDC(nullptr);
  if (!dc) return;
  void* bits = nullptr;
  HBITMAP bitmap =
      CreateDIBSection(dc, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (!bitmap) {
    DeleteDC(dc);
    return;
  }
  HGDIOBJ old_bitmap = SelectObject(dc, bitmap);
  HFONT font =
      CreateFont(-MulDiv(14, FlutterDesktopGetDpiForHWND(owner), 96), 0, 0, 0,
                 FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                 OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY,
                 DEFAULT_PITCH, L"Segoe MDL2 Assets");
  HGDIOBJ old_font = SelectObject(dc, font);
  PatBlt(dc, 0, 0, width, height, BLACKNESS);
  SetBkMode(dc, TRANSPARENT);
  SetTextColor(dc, RGB(255, 255, 255));
  DrawText(dc, IsTopmost(owner) ? L"\uE841" : L"\uE718", 1, &rect,
           DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  GdiFlush();

  const COLORREF ink = Win32Window::GetCaptionTextColor(owner);
  POINT cursor{};
  GetCursorPos(&cursor);
  ScreenToClient(button, &cursor);
  // Alpha 1 keeps the entire target clickable while revealing the real caption.
  const int background =
      PtInRect(&rect, cursor) ? (GetCapture() == button ? 48 : 26) : 1;
  auto* pixels = static_cast<uint32_t*>(bits);
  for (LONG i = 0; i < width * height; ++i) {
    const unsigned int alpha =
        background + (255 - background) * (pixels[i] & 255) / 255;
    pixels[i] = (alpha << 24) | ((GetRValue(ink) * alpha / 255) << 16) |
                ((GetGValue(ink) * alpha / 255) << 8) |
                (GetBValue(ink) * alpha / 255);
  }
  SIZE size{width, height};
  POINT origin{};
  BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  UpdateLayeredWindow(button, nullptr, nullptr, &size, dc, &origin, 0, &blend,
                      ULW_ALPHA);
  SelectObject(dc, old_font);
  SelectObject(dc, old_bitmap);
  DeleteObject(font);
  DeleteObject(bitmap);
  DeleteDC(dc);
}

LRESULT CALLBACK PinProc(HWND button, UINT message, WPARAM wparam,
                         LPARAM lparam, UINT_PTR id, DWORD_PTR) {
  switch (message) {
    case WM_PAINT: {
      PAINTSTRUCT paint;
      BeginPaint(button, &paint);
      PaintPin(button);
      EndPaint(button, &paint);
      return 0;
    }
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    case WM_NCHITTEST: {
      const LRESULT hit =
          DefWindowProc(GetWindow(button, GW_OWNER), message, wparam, lparam);
      if (hit == HTTOP) return HTTRANSPARENT;
      break;
    }
    case WM_LBUTTONDOWN:
    case WM_LBUTTONDBLCLK:
      SetCapture(button);
      InvalidateRect(button, nullptr, FALSE);
      return 0;
    case WM_LBUTTONUP:
      if (GetCapture() == button) {
        ReleaseCapture();
        RECT rect{};
        GetClientRect(button, &rect);
        if (PtInRect(&rect, {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)})) {
          TogglePin(button);
        }
      }
      return 0;
    case BM_CLICK:
      TogglePin(button);
      return 0;
    case WM_MOUSEMOVE: {
      TRACKMOUSEEVENT track{sizeof(track), TME_QUERY, button, 0};
      TrackMouseEvent(&track);
      if (track.hwndTrack != button || !(track.dwFlags & TME_LEAVE)) {
        track = {sizeof(track), TME_LEAVE, button, 0};
        TrackMouseEvent(&track);
        InvalidateRect(button, nullptr, FALSE);
      }
      return 0;
    }
    case WM_NOTIFYFORMAT:
      return NFR_UNICODE;
    case WM_NOTIFY: {
      auto* header = reinterpret_cast<NMHDR*>(lparam);
      if (header->code == TTN_GETDISPINFOW) {
        auto* tip = reinterpret_cast<NMTTDISPINFOW*>(lparam);
        GetWindowText(button, tip->szText, ARRAYSIZE(tip->szText));
        return 0;
      }
      break;
    }
    case WM_NCDESTROY:
      RemoveWindowSubclass(button, PinProc, id);
      break;
  }
  const LRESULT result = DefSubclassProc(button, message, wparam, lparam);
  if (message == WM_MOUSELEAVE || message == WM_CAPTURECHANGED) {
    InvalidateRect(button, nullptr, FALSE);
  }
  return result;
}

std::optional<RECT> GetPinBounds(HWND owner) {
  POINT client{};
  if (!IsWindowVisible(owner) || IsIconic(owner) ||
      !ClientToScreen(owner, &client)) {
    return std::nullopt;
  }
  TITLEBARINFOEX title{sizeof(title)};
  SendMessage(owner, WM_GETTITLEBARINFOEX, 0, reinterpret_cast<LPARAM>(&title));
  const RECT& minimize = title.rgrect[2];
  const LONG width = minimize.right - minimize.left;
  const LONG bottom = std::min(minimize.bottom, client.y);
  // In fullscreen the Flutter view occupies the caption area.
  if (width <= 0 || bottom - minimize.top <
                        MulDiv(12, FlutterDesktopGetDpiForHWND(owner), 96)) {
    return std::nullopt;
  }
  return RECT{minimize.left - width, minimize.top, minimize.left, bottom};
}

}  // namespace

HWND CreateCaptionPin(HWND owner) {
  INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_WIN95_CLASSES};
  InitCommonControlsEx(&controls);
  HWND button = CreateWindowEx(
      WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED, WC_BUTTON,
      PinLabel(false), WS_POPUP | BS_CHECKBOX | BS_PUSHLIKE, 0, 0, 0, 0, owner,
      nullptr, GetModuleHandle(nullptr), nullptr);
  if (!button) return nullptr;
  if (!SetWindowSubclass(button, PinProc, 1, 0)) {
    DestroyWindow(button);
    return nullptr;
  }
  HWND tooltip =
      CreateWindowEx(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, TOOLTIPS_CLASS,
                     nullptr, WS_POPUP | TTS_ALWAYSTIP | TTS_NOPREFIX, 0, 0, 0,
                     0, button, nullptr, GetModuleHandle(nullptr), nullptr);
  TOOLINFO tool{TTTOOLINFOW_V2_SIZE};
  tool.uFlags = TTF_IDISHWND | TTF_SUBCLASS;
  tool.hwnd = button;
  tool.uId = reinterpret_cast<UINT_PTR>(button);
  tool.lpszText = LPSTR_TEXTCALLBACK;
  SendMessage(tooltip, TTM_ADDTOOL, 0, reinterpret_cast<LPARAM>(&tool));
  return button;
}

void UpdateCaptionPin(HWND button) {
  HWND owner = GetWindow(button, GW_OWNER);
  const bool pinned = IsTopmost(owner);
  if ((SendMessage(button, BM_GETCHECK, 0, 0) == BST_CHECKED) != pinned) {
    SendMessage(button, BM_SETCHECK, pinned ? BST_CHECKED : BST_UNCHECKED, 0);
    SetWindowText(button, PinLabel(pinned));
  }
  const auto bounds = GetPinBounds(owner);
  if (!bounds) {
    ShowWindow(button, SW_HIDE);
    return;
  }
  HWND above = GetWindow(owner, GW_HWNDPREV);
  UINT flags = SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_SHOWWINDOW;
  if (above == button) {
    flags |= SWP_NOZORDER;
  } else if (!pinned && above && IsTopmost(above)) {
    // HWND_NOTOPMOST does not raise a button that is already non-topmost.
    above = IsTopmost(button) ? HWND_NOTOPMOST : HWND_TOP;
  }
  SetWindowPos(button, above, bounds->left, bounds->top,
               bounds->right - bounds->left, bounds->bottom - bounds->top,
               flags);
  InvalidateRect(button, nullptr, FALSE);
}
