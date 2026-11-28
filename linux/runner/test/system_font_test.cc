#include "../system_font.h"

#include <initializer_list>

namespace {
void test_resolves_configured_family() {
  GtkWidget* label = gtk_label_new("");
  g_object_ref_sink(label);
  GtkSettings* settings = gtk_widget_get_settings(label);
  g_autofree gchar* original = nullptr;
  g_object_get(settings, "gtk-font-name", &original, nullptr);
  // GtkSettings is process-local here; no desktop configuration is written.
  for (const auto* spec : {"DejaVu Sans 10", "DejaVu Serif Bold Italic 13"}) {
    g_object_set(settings, "gtk-font-name", spec, nullptr);
    g_autofree gchar* actual = system_font_family(label);
    g_assert_nonnull(actual);
    g_assert_cmpstr(actual, ==, g_str_has_prefix(spec, "DejaVu Sans")
                                  ? "DejaVu Sans" : "DejaVu Serif");
  }
  g_object_set(settings, "gtk-font-name", original, nullptr);
  gtk_widget_destroy(label);
  g_object_unref(label);
}
void test_bridge_teardown_disconnects_notification() {
  g_autoptr(FlDartProject) project = fl_dart_project_new();
  GtkWidget* view = GTK_WIDGET(fl_view_new(project));
  g_object_ref_sink(view);
  GtkSettings* settings = gtk_widget_get_settings(view);
  system_font_attach(FL_VIEW(view));
  gtk_widget_destroy(view);
  // A disposed view must no longer be reached by GtkSettings callbacks.
  g_object_notify(G_OBJECT(settings), "gtk-font-name");
  g_object_unref(view);
}
}  // namespace

int main(int argc, char** argv) {
  g_test_init(&argc, &argv, nullptr);
  g_log_set_always_fatal(static_cast<GLogLevelFlags>(G_LOG_LEVEL_ERROR | G_LOG_LEVEL_CRITICAL));
  if (!gtk_init_check(&argc, &argv)) return 77;
  g_test_add_func("/font/resolves-configured-family", test_resolves_configured_family);
  g_test_add_func("/font/bridge-teardown", test_bridge_teardown_disconnects_notification);
  return g_test_run();
}
