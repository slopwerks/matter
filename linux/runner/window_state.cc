#include "window_state.h"

#include <gtk/gtk.h>

#include <algorithm>
#include <string>

namespace {
constexpr char kStateKey[] = "matter-window-state";

struct WindowState {
  std::string path;
  int width = 1280;
  int height = 720;
  bool maximized = false;
};

void write_state(const WindowState* state) {
  g_autofree gchar* directory = g_path_get_dirname(state->path.c_str());
  if (g_mkdir_with_parents(directory, 0700) != 0) {
    g_warning("Failed to create window state directory: %s", directory);
    return;
  }
  g_autoptr(GKeyFile) file = g_key_file_new();
  g_key_file_set_integer(file, "window", "width", state->width);
  g_key_file_set_integer(file, "window", "height", state->height);
  g_key_file_set_boolean(file, "window", "maximized", state->maximized);
  g_autoptr(GError) error = nullptr;
  if (!g_key_file_save_to_file(file, state->path.c_str(), &error)) {
    g_warning("Failed to save window state: %s", error->message);
  }
}

gboolean on_configure(GtkWidget* widget, GdkEventConfigure* event,
                      WindowState* state) {
  const auto flags = gdk_window_get_state(gtk_widget_get_window(widget));
  if (!state->maximized &&
      !(flags & (GDK_WINDOW_STATE_MAXIMIZED | GDK_WINDOW_STATE_FULLSCREEN |
                 GDK_WINDOW_STATE_ICONIFIED))) {
    state->width = event->width;
    state->height = event->height;
  }
  return FALSE;
}

gboolean on_window_state(GtkWidget*, GdkEventWindowState* event,
                         WindowState* state) {
  state->maximized = event->new_window_state & GDK_WINDOW_STATE_MAXIMIZED;
  return FALSE;
}

void on_destroy(GtkWidget*, WindowState* state) { write_state(state); }
}  // namespace

void restore_window_state(GtkWindow* window) {
  auto* state = new WindowState();
  g_autofree gchar* path = g_build_filename(
      g_get_user_config_dir(), APPLICATION_ID, "window.ini", nullptr);
  state->path = path;
  g_autoptr(GKeyFile) file = g_key_file_new();
  if (g_key_file_load_from_file(file, path, G_KEY_FILE_NONE, nullptr)) {
    const int width = g_key_file_get_integer(file, "window", "width", nullptr);
    const int height =
        g_key_file_get_integer(file, "window", "height", nullptr);
    if (width >= 320 && width <= 16384) state->width = width;
    if (height >= 240 && height <= 16384) state->height = height;
    state->maximized =
        g_key_file_get_boolean(file, "window", "maximized", nullptr);
  }
  // A window saved on a larger display must still fit the current monitor.
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
  GdkMonitor* monitor = gdk_display_get_primary_monitor(display);
  if (monitor == nullptr && gdk_display_get_n_monitors(display) > 0) {
    monitor = gdk_display_get_monitor(display, 0);
  }
  if (monitor != nullptr) {
    GdkRectangle area;
    gdk_monitor_get_workarea(monitor, &area);
    state->width = std::min(state->width, area.width);
    state->height = std::min(state->height, area.height);
  }
  gtk_window_set_default_size(window, state->width, state->height);
  if (state->maximized) gtk_window_maximize(window);
  g_object_set_data_full(G_OBJECT(window), kStateKey, state, [](gpointer data) {
    delete static_cast<WindowState*>(data);
  });
  g_signal_connect(window, "configure-event", G_CALLBACK(on_configure), state);
  g_signal_connect(window, "window-state-event", G_CALLBACK(on_window_state),
                   state);
  g_signal_connect(window, "destroy", G_CALLBACK(on_destroy), state);
}

void save_window_state(GtkWindow* window) {
  auto* state =
      static_cast<WindowState*>(g_object_get_data(G_OBJECT(window), kStateKey));
  if (state != nullptr) write_state(state);
}
