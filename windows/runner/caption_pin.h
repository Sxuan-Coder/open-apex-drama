#ifndef RUNNER_CAPTION_PIN_H_
#define RUNNER_CAPTION_PIN_H_

#include <windows.h>

// An owned, non-activating button over the main window's native caption.
HWND CreateCaptionPin(HWND owner);
void UpdateCaptionPin(HWND button);

#endif  // RUNNER_CAPTION_PIN_H_
