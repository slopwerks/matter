#include <flutter_linux/flutter_linux.h>
#include <glib/gstdio.h>

#include <string>

#include "my_application.h"
#include "window_state.h"

// The activation test takes the existing-window branch, before Flutter starts.
void fl_register_plugins(FlPluginRegistry*) {}

namespace {
std::string executable;

std::string state_path() {
  g_autofree gchar* path = g_build_filename(
      g_get_user_config_dir(), APPLICATION_ID, "window.ini", nullptr);
  return path;
}

void set_config(const char* data) {
  const auto path = state_path();
  g_autofree gchar* directory = g_path_get_dirname(path.c_str());
  g_assert_cmpint(g_mkdir_with_parents(directory, 0700), ==, 0);
  g_assert_true(g_file_set_contents(path.c_str(), data, -1, nullptr));
}

void configure(GtkWindow* window, int width, int height) {
  gtk_widget_realize(GTK_WIDGET(window));
  GdkEventConfigure event{};
  event.type = GDK_CONFIGURE;
  event.width = width;
  event.height = height;
  gboolean handled = FALSE;
  g_signal_emit_by_name(window, "configure-event", &event, &handled);
}

void maximize(GtkWindow* window, bool maximized) {
  GdkEventWindowState event{};
  event.type = GDK_WINDOW_STATE;
  event.changed_mask = GDK_WINDOW_STATE_MAXIMIZED;
  event.new_window_state =
      static_cast<GdkWindowState>(maximized ? GDK_WINDOW_STATE_MAXIMIZED : 0);
  gboolean handled = FALSE;
  g_signal_emit_by_name(window, "window-state-event", &event, &handled);
}

void assert_saved(int width, int height, bool maximized) {
  g_autoptr(GKeyFile) file = g_key_file_new();
  g_assert_true(g_key_file_load_from_file(file, state_path().c_str(),
                                          G_KEY_FILE_NONE, nullptr));
  g_assert_cmpint(g_key_file_get_integer(file, "window", "width", nullptr), ==,
                  width);
  g_assert_cmpint(g_key_file_get_integer(file, "window", "height", nullptr), ==,
                  height);
  g_assert_cmpint(g_key_file_get_boolean(file, "window", "maximized", nullptr),
                  ==, maximized);
}

void test_round_trip() {
  g_remove(state_path().c_str());
  auto* window = GTK_WINDOW(gtk_window_new(GTK_WINDOW_TOPLEVEL));
  restore_window_state(window);
  configure(window, 900, 600);
  gtk_widget_destroy(GTK_WIDGET(window));
  assert_saved(900, 600, false);
  auto* restored = GTK_WINDOW(gtk_window_new(GTK_WINDOW_TOPLEVEL));
  restore_window_state(restored);
  int width, height;
  gtk_window_get_default_size(restored, &width, &height);
  g_assert_cmpint(width, ==, 900);
  g_assert_cmpint(height, ==, 600);
  gtk_widget_destroy(GTK_WIDGET(restored));
}

void test_maximized() {
  set_config("[window]\nwidth=900\nheight=600\nmaximized=false\n");
  auto* window = GTK_WINDOW(gtk_window_new(GTK_WINDOW_TOPLEVEL));
  restore_window_state(window);
  configure(window, 900, 600);
  maximize(window, true);
  configure(window, 1280, 1024);
  save_window_state(window);
  assert_saved(900, 600, true);
  gtk_widget_destroy(GTK_WIDGET(window));
  auto* restored = GTK_WINDOW(gtk_window_new(GTK_WINDOW_TOPLEVEL));
  restore_window_state(restored);
  save_window_state(restored);
  assert_saved(900, 600, true);
  maximize(restored, false);
  configure(restored, 850, 550);
  gtk_widget_destroy(GTK_WIDGET(restored));
  assert_saved(850, 550, false);
}

void test_invalid_and_large_config() {
  for (const auto* config : {"not a key file", "[window]\nwidth=-1\nheight=0\n",
                             "[window]\nwidth=16000\nheight=16000\n"}) {
    set_config(config);
    auto* window = GTK_WINDOW(gtk_window_new(GTK_WINDOW_TOPLEVEL));
    restore_window_state(window);
    int width, height;
    gtk_window_get_default_size(window, &width, &height);
    g_assert_cmpint(width, >, 0);
    g_assert_cmpint(height, >, 0);
    g_assert_cmpint(width, <=, 1280);
    g_assert_cmpint(height, <=, 1024);
    gtk_widget_destroy(GTK_WIDGET(window));
  }
}

void test_repeated_activation() {
  g_autoptr(MyApplication) app = my_application_new();
  g_assert_true(g_application_register(G_APPLICATION(app), nullptr, nullptr));
  g_assert_false(g_application_get_is_remote(G_APPLICATION(app)));
  auto* window = gtk_application_window_new(GTK_APPLICATION(app));
  for (int attempt = 0; attempt < 2; attempt++) {
    gtk_widget_hide(window);
    g_autoptr(GError) error = nullptr;
    g_autoptr(GSubprocess) child =
        g_subprocess_new(G_SUBPROCESS_FLAGS_NONE, &error, executable.c_str(),
                         "--probe-instance", nullptr);
    g_assert_no_error(error);
    struct Wait {
      GMainLoop* loop;
      bool done = false;
    } wait{g_main_loop_new(nullptr, FALSE)};
    g_subprocess_wait_check_async(
        child, nullptr,
        [](GObject* source, GAsyncResult* result, gpointer data) {
          auto* wait = static_cast<Wait*>(data);
          g_autoptr(GError) error = nullptr;
          g_assert_true(g_subprocess_wait_check_finish(G_SUBPROCESS(source),
                                                       result, &error));
          g_assert_no_error(error);
          wait->done = true;
          g_main_loop_quit(wait->loop);
        },
        &wait);
    const auto timeout = g_timeout_add_seconds(
        5,
        [](gpointer data) -> gboolean {
          g_main_loop_quit(static_cast<Wait*>(data)->loop);
          return G_SOURCE_REMOVE;
        },
        &wait);
    g_main_loop_run(wait.loop);
    g_assert_true(wait.done);
    g_source_remove(timeout);
    g_main_loop_unref(wait.loop);
    g_assert_true(gtk_widget_get_visible(window));
    g_assert_cmpint(
        g_list_length(gtk_application_get_windows(GTK_APPLICATION(app))), ==,
        1);
  }
  gtk_widget_destroy(window);
}
}  // namespace

int main(int argc, char** argv) {
  gtk_init(&argc, &argv);
  if (argc == 2 && g_str_equal(argv[1], "--probe-instance")) {
    g_autoptr(MyApplication) app = my_application_new();
    if (!g_application_register(G_APPLICATION(app), nullptr, nullptr) ||
        !g_application_get_is_remote(G_APPLICATION(app))) {
      return 2;
    }
    return g_application_run(G_APPLICATION(app), 1, argv);
  }
  executable = argv[0];
  g_test_init(&argc, &argv, nullptr);
  g_test_add_func("/window/round-trip", test_round_trip);
  g_test_add_func("/window/maximized-normal-size", test_maximized);
  g_test_add_func("/window/invalid-and-large-config",
                  test_invalid_and_large_config);
  g_test_add_func("/application/repeated-activation", test_repeated_activation);
  return g_test_run();
}
