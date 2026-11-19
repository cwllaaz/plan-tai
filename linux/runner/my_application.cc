#include "my_application.h"

#include <algorithm>

#include <flutter_linux/flutter_linux.h>
#include <gdk/gdkx.h>

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

namespace {

// Match the desktop startup policy in lib/main.dart, in GTK logical units.
constexpr int kDefaultWidth = 1440;
constexpr int kDefaultHeight = 900;
constexpr int kMinWidth = 1100;
constexpr int kMinHeight = 700;
// Leave room for decorations. On Wayland, GTK can report the full output
// instead of the usable area; allow extra height for the panel and placement.
constexpr int kFrameAllowance = 64;
constexpr int kWaylandHeightAllowance = 112;

struct StartupGeometry {
  GdkRectangle workarea;
  int width;
  int height;
};

StartupGeometry GetStartupGeometry(GtkWidget* widget) {
  GdkDisplay* display = gtk_widget_get_display(widget);
  GdkWindow* surface = gtk_widget_get_window(widget);
  GdkMonitor* monitor =
      surface ? gdk_display_get_monitor_at_window(display, surface) : nullptr;
  if (!monitor) monitor = gdk_display_get_primary_monitor(display);
  if (!monitor) monitor = gdk_display_get_monitor(display, 0);

  StartupGeometry geometry = {{}, kDefaultWidth, kDefaultHeight};
  if (monitor) {
    gdk_monitor_get_workarea(monitor, &geometry.workarea);
    const int height_allowance =
        GDK_IS_X11_DISPLAY(display) ? kFrameAllowance : kWaylandHeightAllowance;
    geometry.width = std::max(
        kMinWidth,
        std::min(kDefaultWidth, geometry.workarea.width - kFrameAllowance));
    geometry.height = std::max(
        kMinHeight,
        std::min(kDefaultHeight, geometry.workarea.height - height_allowance));
  }
  return geometry;
}

// Fit the initial allocation after the shared Dart startup requests 1440x900.
void first_frame_cb(FlView*, GtkWindow* window) {
  GtkWidget* widget = GTK_WIDGET(window);
  const StartupGeometry geometry = GetStartupGeometry(widget);
  if (!gtk_widget_get_mapped(widget) || !gtk_window_is_maximized(window)) {
    int width, height;
    gtk_window_get_size(window, &width, &height);
    const int fitted_width = std::min(width, geometry.width);
    const int fitted_height = std::min(height, geometry.height);
    if (width != fitted_width || height != fitted_height) {
      gtk_window_resize(window, fitted_width, fitted_height);
      // The Wayland compositor owns placement. Only X11 accepts a position.
      if (GDK_IS_X11_DISPLAY(gtk_widget_get_display(widget))) {
        const GdkRectangle& area = geometry.workarea;
        gtk_window_move(window,
                        area.x + (area.width - fitted_width) / 2,
                        area.y + (area.height - fitted_height) / 2);
      }
    }
  }
  gtk_widget_show(widget);
}

}  // namespace

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  const StartupGeometry geometry = GetStartupGeometry(GTK_WIDGET(window));
  gtk_window_set_default_size(window, geometry.width, geometry.height);
  gtk_window_set_position(window, GTK_WIN_POS_CENTER);

  // If you want to use a header bar, uncomment the following lines.
  // Header bars are commonly used in GNOME based desktop environments and
  // allow additional widgets to be added to the title bar.
  // See https://docs.gtk.org/gtk3/class.HeaderBar.html
  // GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
  // gtk_widget_show(GTK_WIDGET(header_bar));
  // gtk_header_bar_set_show_close_button(header_bar, TRUE);
  // gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));

  // 与 Windows 版一致的产品标题（中文，UTF-8 源码）。
  // Dart 侧 window_manager 初始化后会再次设置同样的标题。
  gtk_window_set_title(window, "计划台");
  // 窗口/任务栏/Dock 图标：使用随 deb 安装到 hicolor 主题的 jihuatai 图标
  //（.desktop 中 Icon=jihuatai 与之对应）。
  gtk_window_set_icon_name(window, "jihuatai");

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  // The shared Dart minimum is for the decorated frame and its plugin updates
  // the hints on maximize/restore. Set the Flutter content requisition too.
  gtk_widget_set_size_request(GTK_WIDGET(view), kMinWidth, kMinHeight);
  GdkRGBA background_color;
  // 与 AppColors.canvas（#F7F8FA）一致：首帧前不会闪黑/闪白，避免与 Windows 观感不同。
  gdk_rgba_parse(&background_color, "#F7F8FA");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the fallback window when Flutter renders if Dart did not show it.
  // Realize the view first so Flutter can render.
  g_signal_connect(view, "first-frame", G_CALLBACK(first_frame_cb), window);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
