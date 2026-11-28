#ifndef RUNNER_SYSTEM_FONT_H_
#define RUNNER_SYSTEM_FONT_H_
#include <flutter_linux/flutter_linux.h>
// Resolves GTK's configured UI font through the same Pango context as the view.
gchar* system_font_family(GtkWidget* widget);
void system_font_attach(FlView* view);
#endif
