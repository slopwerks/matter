#ifndef RUNNER_WINDOW_STATE_H_
#define RUNNER_WINDOW_STATE_H_

typedef struct _GtkWindow GtkWindow;

void restore_window_state(GtkWindow* window);
void save_window_state(GtkWindow* window);

#endif  // RUNNER_WINDOW_STATE_H_
