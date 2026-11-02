#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
flutter_sdk="$(dirname "$(dirname "$(readlink -f "$(command -v flutter)")")")"
engine_dir="$flutter_sdk/bin/cache/artifacts/engine/linux-x64"
test_dir="$project_dir/build/linux-desktop-test"
mkdir -p "$test_dir"
read -r -a gtk_flags <<< "$(pkg-config --cflags --libs gtk+-3.0)"

"${CXX:-clang++}" -std=c++17 -Wall -Werror \
  '-DAPPLICATION_ID="moe.aks.matter"' \
  -I"$engine_dir" -I"$project_dir/linux" -I"$project_dir/linux/runner" \
  "$project_dir/linux/runner/test/desktop_integration_test.cc" \
  "$project_dir/linux/runner/my_application.cc" \
  "$project_dir/linux/runner/window_state.cc" \
  -L"$engine_dir" -Wl,-rpath,"$engine_dir" -lflutter_linux_gtk \
  "${gtk_flags[@]}" -o "$test_dir/desktop_integration_test"

config_dir="$(mktemp -d "$test_dir/config.XXXXXX")"
trap 'rm -rf "$config_dir"' EXIT
XDG_CONFIG_HOME="$config_dir" GSETTINGS_BACKEND=memory NO_AT_BRIDGE=1 \
  GIO_USE_VFS=local GTK_USE_PORTAL=0 GDK_BACKEND=x11 \
  dbus-run-session -- xvfb-run -a -s '-screen 0 1280x1024x24' \
  "$test_dir/desktop_integration_test"
