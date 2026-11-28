#include "system_font.h"

#include <cstring>

gchar* system_font_family(GtkWidget* widget) {
  g_autofree gchar* name = nullptr;
  g_object_get(gtk_widget_get_settings(widget), "gtk-font-name", &name, nullptr);
  if (!name || !*name) return nullptr;
  auto* description = pango_font_description_from_string(name);
  auto* font = pango_context_load_font(gtk_widget_get_pango_context(widget), description);
  pango_font_description_free(description);
  if (!font) return nullptr;
  auto* actual = pango_font_describe(font);
  gchar* family = g_strdup(pango_font_description_get_family(actual));
  pango_font_description_free(actual);
  g_object_unref(font);
  return family;
}

namespace {
class SystemFontBridge {
 public:
  explicit SystemFontBridge(FlView* view) : view_(GTK_WIDGET(view)) {
    settings_ = GTK_SETTINGS(g_object_ref(gtk_widget_get_settings(view_)));
    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    channel_ = fl_method_channel_new(
        fl_engine_get_binary_messenger(fl_view_get_engine(view)),
        "moe.aks.matter/system_font", FL_METHOD_CODEC(codec));
    fl_method_channel_set_method_call_handler(channel_, method, this, nullptr);
    g_signal_connect(settings_, "notify::gtk-font-name", G_CALLBACK(changed), this);
    g_signal_connect(view_, "destroy", G_CALLBACK(destroy), this);
  }
  ~SystemFontBridge() {
    g_signal_handlers_disconnect_by_data(settings_, this);
    fl_method_channel_set_method_call_handler(channel_, nullptr, nullptr, nullptr);
    g_object_unref(channel_);
    g_object_unref(settings_);
  }
 private:
  GtkWidget* view_;
  GtkSettings* settings_;
  FlMethodChannel* channel_;
  static void destroy(GtkWidget*, gpointer data) {
    delete static_cast<SystemFontBridge*>(data);
  }
  static void changed(GtkSettings*, GParamSpec*, gpointer data) {
    auto* self = static_cast<SystemFontBridge*>(data);
    g_autofree gchar* family = system_font_family(self->view_);
    g_autoptr(FlValue) value = family ? fl_value_new_string(family) : fl_value_new_null();
    fl_method_channel_invoke_method(self->channel_, "changed", value, nullptr, nullptr, nullptr);
  }
  static void method(FlMethodChannel*, FlMethodCall* call, gpointer data) {
    auto* self = static_cast<SystemFontBridge*>(data);
    if (strcmp(fl_method_call_get_name(call), "getFamily") != 0) {
      fl_method_call_respond_not_implemented(call, nullptr);
      return;
    }
    g_autofree gchar* family = system_font_family(self->view_);
    g_autoptr(FlValue) value = family ? fl_value_new_string(family) : fl_value_new_null();
    fl_method_call_respond_success(call, value, nullptr);
  }
};
}  // namespace

void system_font_attach(FlView* view) {
  new SystemFontBridge(view);
}
