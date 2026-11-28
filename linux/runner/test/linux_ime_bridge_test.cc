#include <flutter_linux/flutter_linux.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <deque>
#include <set>
#include <string>

// Exercise the exact native routing state machine without sending desktop input.
#define private public
#include "../linux_ime_bridge.cc"
#undef private

namespace {
void test_consumed_repeat_keeps_release() {
  g_autoptr(FlDartProject) project = fl_dart_project_new();
  GtkWidget* view = GTK_WIDGET(fl_view_new(project));
  g_object_ref_sink(view);
  auto* bridge = new LinuxImeBridge(FL_VIEW(view));
  bridge->consumed_.insert(55);  // Initial V press consumed by GTK.
  GdkEventKey event{};
  event.type = GDK_KEY_PRESS;
  event.time = 10;
  event.hardware_keycode = 55;
  event.keyval = GDK_KEY_v;
  event.state = GDK_CONTROL_MASK;
  g_assert_true(LinuxImeBridge::key(view, &event, bridge));
  g_assert_true(bridge->forwarded_down_.empty());
  event.type = GDK_KEY_RELEASE;
  event.time++;
  g_assert_true(LinuxImeBridge::key(view, &event, bridge));
  g_assert_true(bridge->consumed_.empty());
  g_assert_true(bridge->forwarded_down_.empty());
  // The next shortcut has a fresh down/up and is not mistaken for a repeat.
  event.type = GDK_KEY_PRESS;
  event.time++;
  g_assert_false(LinuxImeBridge::key(view, &event, bridge));
  g_assert_cmpuint(bridge->forwarded_down_.count(55), ==, 1);
  event.type = GDK_KEY_RELEASE;
  event.time++;
  g_assert_false(LinuxImeBridge::key(view, &event, bridge));
  g_assert_true(bridge->forwarded_down_.empty());
  gtk_widget_destroy(view);
  g_object_unref(view);
}

void test_redispatch_is_not_filtered_again() {
  g_autoptr(FlDartProject) project = fl_dart_project_new();
  GtkWidget* view = GTK_WIDGET(fl_view_new(project));
  g_object_ref_sink(view);
  auto* bridge = new LinuxImeBridge(FL_VIEW(view));
  GdkEventKey event{};
  event.type = GDK_KEY_PRESS;
  event.time = 20;
  event.hardware_keycode = 113;
  event.keyval = GDK_KEY_Left;
  g_assert_false(LinuxImeBridge::key(view, &event, bridge));
  g_assert_cmpuint(bridge->forwarded_.size(), ==, 1);
  g_assert_false(LinuxImeBridge::key(view, &event, bridge));
  g_assert_true(bridge->forwarded_.empty());
  g_assert_cmpuint(bridge->forwarded_down_.count(113), ==, 1);
  event.type = GDK_KEY_RELEASE;
  event.time++;
  g_assert_false(LinuxImeBridge::key(view, &event, bridge));
  g_assert_false(LinuxImeBridge::key(view, &event, bridge));
  g_assert_true(bridge->forwarded_down_.empty());
  g_assert_true(bridge->forwarded_.empty());
  gtk_widget_destroy(view);
  g_object_unref(view);
}
}  // namespace

int main(int argc, char** argv) {
  g_test_init(&argc, &argv, nullptr);
  // Local GTK theme/settings warnings are not failures in the routing test.
  g_log_set_always_fatal(static_cast<GLogLevelFlags>(G_LOG_LEVEL_ERROR | G_LOG_LEVEL_CRITICAL));
  if (!gtk_init_check(&argc, &argv)) return 77;
  g_test_add_func("/ime/consumed-repeat-keeps-release", test_consumed_repeat_keeps_release);
  g_test_add_func("/ime/redispatch-not-filtered-twice", test_redispatch_is_not_filtered_again);
  return g_test_run();
}
