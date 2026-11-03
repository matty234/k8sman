#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

namespace {

// About 1440x900 (logical pixels) centred on the primary monitor's work area,
// like the macOS app's first launch; smaller on small screens.
void InitialFrame(Win32Window::Point* origin, Win32Window::Size* size) {
  RECT work{0, 0, 1440, 900};
  ::SystemParametersInfo(SPI_GETWORKAREA, 0, &work, 0);
  HMONITOR monitor = ::MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
  const double scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
  const double work_w = (work.right - work.left) / scale;
  const double work_h = (work.bottom - work.top) / scale;
  const double w = std::min(1440.0, work_w * 0.94);
  const double h = std::min(900.0, work_h * 0.94);
  size->width = static_cast<unsigned int>(w);
  size->height = static_cast<unsigned int>(h);
  origin->x = static_cast<unsigned int>(
      std::max(0.0, work.left / scale + (work_w - w) / 2));
  origin->y = static_cast<unsigned int>(
      std::max(0.0, work.top / scale + (work_h - h) / 2));
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1440, 900);
  InitialFrame(&origin, &size);
  if (!window.Create(L"k8sman", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
