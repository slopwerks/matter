#ifndef RUNNER_LINUX_IME_BRIDGE_H_
#define RUNNER_LINUX_IME_BRIDGE_H_

#include <flutter_linux/flutter_linux.h>

// Installs one bridge owned by the view's destroy lifecycle. Call before the
// view is realized. Flutter's normal keyboard path remains the fallback.
void linux_ime_bridge_attach(FlView* view);

#endif  // RUNNER_LINUX_IME_BRIDGE_H_
