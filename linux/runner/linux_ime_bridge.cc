#include "linux_ime_bridge.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <deque>
#include <set>
#include <string>

namespace {
class LinuxImeBridge {
 public:
  explicit LinuxImeBridge(FlView* view) : view_(GTK_WIDGET(view)) {
    context_ = gtk_im_multicontext_new();
    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    channel_ = fl_method_channel_new(
        fl_engine_get_binary_messenger(fl_view_get_engine(view)),
        "moe.aks.matter/linux_ime", FL_METHOD_CODEC(codec));
    fl_method_channel_set_method_call_handler(channel_, method, this, nullptr);
    g_signal_connect(context_, "preedit-start", G_CALLBACK(start), this);
    g_signal_connect(context_, "preedit-changed", G_CALLBACK(preedit), this);
    g_signal_connect(context_, "preedit-end", G_CALLBACK(end), this);
    g_signal_connect(context_, "commit", G_CALLBACK(commit), this);
    g_signal_connect(context_, "retrieve-surrounding", G_CALLBACK(surrounding), this);
    g_signal_connect(context_, "delete-surrounding", G_CALLBACK(delete_surrounding), this);
    g_signal_connect(view_, "realize", G_CALLBACK(realize), this);
    g_signal_connect(view_, "key-press-event", G_CALLBACK(key), this);
    g_signal_connect(view_, "key-release-event", G_CALLBACK(key), this);
    g_signal_connect(view_, "focus-in-event", G_CALLBACK(focus_in), this);
    g_signal_connect(view_, "focus-out-event", G_CALLBACK(focus_out), this);
    g_signal_connect(view_, "destroy", G_CALLBACK(destroy), this);
    window_focused_ = gtk_widget_has_focus(view_);
    if (gtk_widget_get_realized(view_)) realize(view_, this);
  }

  ~LinuxImeBridge() {
    active_ = false;
    fl_method_channel_set_method_call_handler(channel_, nullptr, nullptr, nullptr);
    g_signal_handlers_disconnect_by_data(view_, this);
    g_signal_handlers_disconnect_by_data(context_, this);
    gtk_im_context_focus_out(context_);
    gtk_im_context_set_client_window(context_, nullptr);
    g_object_unref(context_);
    g_object_unref(channel_);
  }

 private:
  struct ForwardedKey {
    GdkEventType type;
    guint32 time;
    guint16 code;
    guint keyval;
    guint state;
    bool matches(const GdkEventKey* event) const {
      return type == event->type && time == event->time &&
             code == event->hardware_keycode && keyval == event->keyval &&
             state == event->state;
    }
  };
  GtkWidget* view_;
  GtkIMContext* context_;
  FlMethodChannel* channel_;
  bool active_ = false;
  bool window_focused_ = false;
  int64_t epoch_ = 0;
  std::string text_;
  int cursor_ = 0;
  std::set<guint16> consumed_;
  std::set<guint16> forwarded_down_;
  std::deque<ForwardedKey> forwarded_;

  static FlValue* get(FlValue* map, const char* name) {
    return map && fl_value_get_type(map) == FL_VALUE_TYPE_MAP
               ? fl_value_lookup_string(map, name) : nullptr;
  }
  static bool is(FlValue* value, FlValueType type) {
    return value && fl_value_get_type(value) == type;
  }
  static bool number(FlValue* value, double* result) {
    if (is(value, FL_VALUE_TYPE_FLOAT)) *result = fl_value_get_float(value);
    else if (is(value, FL_VALUE_TYPE_INT)) *result = fl_value_get_int(value);
    else return false;
    return std::isfinite(*result) && std::abs(*result) < G_MAXINT / 2;
  }
  void emit(const char* type, const char* text = nullptr, int cursor = 0,
            int offset = 0, int count = 0) {
    if (!active_ || !window_focused_) return;
    g_autoptr(FlValue) args = fl_value_new_map();
    fl_value_set_string_take(args, "type", fl_value_new_string(type));
    fl_value_set_string_take(args, "epoch", fl_value_new_int(epoch_));
    if (text) fl_value_set_string_take(args, "text", fl_value_new_string(text));
    fl_value_set_string_take(args, "cursor", fl_value_new_int(cursor));
    fl_value_set_string_take(args, "offset", fl_value_new_int(offset));
    fl_value_set_string_take(args, "count", fl_value_new_int(count));
    fl_method_channel_invoke_method(channel_, "event", args, nullptr, nullptr, nullptr);
  }
  static void destroy(GtkWidget*, gpointer data) {
    delete static_cast<LinuxImeBridge*>(data);
  }
  static void realize(GtkWidget* widget, gpointer data) {
    gtk_im_context_set_client_window(static_cast<LinuxImeBridge*>(data)->context_,
                                     gtk_widget_get_window(widget));
  }
  static void start(GtkIMContext*, gpointer data) {
    static_cast<LinuxImeBridge*>(data)->emit("start");
  }
  static void end(GtkIMContext*, gpointer data) {
    static_cast<LinuxImeBridge*>(data)->emit("end");
  }
  static void preedit(GtkIMContext* context, gpointer data) {
    g_autofree gchar* text = nullptr;
    gint cursor = 0;
    gtk_im_context_get_preedit_string(context, &text, nullptr, &cursor);
    static_cast<LinuxImeBridge*>(data)->emit("preedit", text, cursor);
  }
  static void commit(GtkIMContext*, const gchar* text, gpointer data) {
    static_cast<LinuxImeBridge*>(data)->emit("commit", text);
  }
  static gboolean surrounding(GtkIMContext* context, gpointer data) {
    auto* self = static_cast<LinuxImeBridge*>(data);
    if (!self->active_) return FALSE;
    gtk_im_context_set_surrounding(context, self->text_.c_str(),
                                   self->text_.size(), self->cursor_);
    return TRUE;
  }
  static gboolean delete_surrounding(GtkIMContext*, gint offset, gint count,
                                     gpointer data) {
    auto* self = static_cast<LinuxImeBridge*>(data);
    if (!self->active_ || count < 0) return FALSE;
    const char* text = self->text_.c_str();
    auto cursor = g_utf8_pointer_to_offset(text, text + self->cursor_);
    auto start = cursor + static_cast<int64_t>(offset);
    auto end = start + static_cast<int64_t>(count);
    if (start < 0 || end > g_utf8_strlen(text, -1)) return FALSE;
    auto from = g_utf8_offset_to_pointer(text, start) - text;
    auto to = g_utf8_offset_to_pointer(text, end) - text;
    // GTK may retrieve/delete again before the framework round trip returns.
    self->text_.erase(from, to - from);
    self->cursor_ = self->cursor_ < from ? self->cursor_ :
        self->cursor_ > to ? self->cursor_ - (to - from) : from;
    self->emit("delete", nullptr, 0, offset, count);
    return TRUE;
  }
  static gboolean key(GtkWidget*, GdkEventKey* event, gpointer data) {
    auto* self = static_cast<LinuxImeBridge*>(data);
    // FlView puts unhandled keys back into GDK. Let its keyboard manager
    // recognize those copies without filtering them a second time.
    auto previous = std::find_if(self->forwarded_.begin(), self->forwarded_.end(),
        [event](const ForwardedKey& key) { return key.matches(event); });
    if (previous != self->forwarded_.end()) {
      self->forwarded_.erase(previous);
      return FALSE;
    }
    auto code = event->hardware_keycode;
    if (event->type == GDK_KEY_RELEASE && self->consumed_.erase(code)) {
      if (self->active_) gtk_im_context_filter_keypress(self->context_, event);
      return TRUE;
    }
    bool forwarded_down = self->forwarded_down_.count(code) != 0;
    if (self->active_ && !forwarded_down) {
      bool filtered = gtk_im_context_filter_keypress(self->context_, event);
      if (!filtered && event->type == GDK_KEY_PRESS &&
          !(event->state & (GDK_CONTROL_MASK | GDK_MOD1_MASK | GDK_SUPER_MASK | GDK_META_MASK))) {
        gunichar character = gdk_keyval_to_unicode(event->keyval);
        if (character && g_unichar_isprint(character)) {
          gchar utf8[7] = {};
          g_unichar_to_utf8(character, utf8);
          self->emit("commit", utf8);
          filtered = true;
        }
      }
      if (filtered) {
        if (event->type == GDK_KEY_PRESS) self->consumed_.insert(code);
        return TRUE;
      }
    }
    // A key belongs to the path that received its initial press, including
    // repeats whose modifiers or focus changed while it was held.
    if (self->consumed_.count(code)) return TRUE;
    if (event->type == GDK_KEY_PRESS) self->forwarded_down_.insert(code);
    else self->forwarded_down_.erase(code);
    self->forwarded_.push_back({event->type, event->time, code, event->keyval, event->state});
    if (self->forwarded_.size() > 256) self->forwarded_.pop_front();
    return FALSE;
  }
  static gboolean focus_in(GtkWidget*, GdkEventFocus*, gpointer data) {
    auto* self = static_cast<LinuxImeBridge*>(data);
    self->window_focused_ = true;
    if (self->active_) gtk_im_context_focus_in(self->context_);
    return FALSE;
  }
  static gboolean focus_out(GtkWidget*, GdkEventFocus*, gpointer data) {
    auto* self = static_cast<LinuxImeBridge*>(data);
    if (self->active_) {
      gtk_im_context_reset(self->context_);
      self->emit("blur");
      gtk_im_context_focus_out(self->context_);
    }
    self->window_focused_ = false;
    self->forwarded_down_.clear();
    return FALSE;
  }
  static void method(FlMethodChannel*, FlMethodCall* call, gpointer data) {
    auto* self = static_cast<LinuxImeBridge*>(data);
    const char* name = fl_method_call_get_name(call);
    FlValue* args = fl_method_call_get_args(call);
    FlValue* epoch_value = get(args, "epoch");
    if (!is(epoch_value, FL_VALUE_TYPE_INT)) {
      fl_method_call_respond_error(call, "arguments", "Missing integer epoch", nullptr, nullptr);
      return;
    }
    int64_t epoch = fl_value_get_int(epoch_value);
    bool valid = true;
    if (g_str_equal(name, "focus")) {
      FlValue* active_value = get(args, "active");
      valid = is(active_value, FL_VALUE_TYPE_BOOL);
      if (valid && epoch >= self->epoch_) {
        bool active = fl_value_get_bool(active_value);
        if (epoch != self->epoch_ || active != self->active_) {
          gtk_im_context_reset(self->context_);
          if (self->active_) gtk_im_context_focus_out(self->context_);
          self->epoch_ = epoch;
          self->active_ = active;
          self->text_.clear();
          self->cursor_ = 0;
          if (active && self->window_focused_) gtk_im_context_focus_in(self->context_);
        }
      }
    } else if (epoch != self->epoch_ || !self->active_) {
      // Commands sent before a focus switch cannot move/reset the new client.
    } else if (g_str_equal(name, "reset")) {
      gtk_im_context_reset(self->context_);
    } else if (g_str_equal(name, "state")) {
      FlValue* text_value = get(args, "text");
      FlValue* cursor_value = get(args, "cursor");
      valid = is(text_value, FL_VALUE_TYPE_STRING) && is(cursor_value, FL_VALUE_TYPE_INT);
      if (valid) {
        const char* text = fl_value_get_string(text_value);
        int64_t cursor = fl_value_get_int(cursor_value);
        valid = cursor >= 0 && static_cast<uint64_t>(cursor) <= strlen(text) &&
                g_utf8_validate(text, -1, nullptr) && g_utf8_validate(text, cursor, nullptr);
        if (valid) {
          self->text_ = text;
          self->cursor_ = cursor;
        }
      }
    } else if (g_str_equal(name, "cursor")) {
      double x, y, width, height;
      valid = number(get(args, "x"), &x) && number(get(args, "y"), &y) &&
              number(get(args, "width"), &width) && number(get(args, "height"), &height);
      if (valid) {
        GdkRectangle rect{static_cast<int>(std::round(x)), static_cast<int>(std::round(y)),
            std::max(1, static_cast<int>(std::round(width))),
            std::max(1, static_cast<int>(std::round(height)))};
        gtk_im_context_set_cursor_location(self->context_, &rect);
      }
    } else {
      fl_method_call_respond_not_implemented(call, nullptr);
      return;
    }
    if (valid) fl_method_call_respond_success(call, nullptr, nullptr);
    else fl_method_call_respond_error(call, "arguments", "Invalid IME arguments", nullptr, nullptr);
  }
};
}  // namespace

void linux_ime_bridge_attach(FlView* view) {
  new LinuxImeBridge(view);
}
