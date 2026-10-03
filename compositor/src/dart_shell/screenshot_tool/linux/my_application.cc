#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif
#ifdef HAVE_GTK_LAYER_SHELL
#include <gtk-layer-shell.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Flutter channel "denial/screenshot_window". showPinCard opens the pinned
// snapshot as a small undecorated GtkWindow that is transient for the editor:
// tiling compositors (denialwm) exclude transient windows from the layout, so
// the card floats above the scroll-tiling strip while the editor is hidden.
// 继续编辑 destroys the card and re-shows the editor (notifying Dart); 关闭
// ends the session. The channel and windows are kept alive for the process
// lifetime.
static FlMethodChannel* g_window_channel = nullptr;
static GtkWindow* g_editor_window = nullptr;
static GtkWindow* g_pin_window = nullptr;

// Pinned-card placement. On the layer-shell OVERLAY layer the position is
// client-owned: anchors top-left + margins, updated while dragging. The
// margins persist across cards so re-pinning reappears where the last one
// sat.
static gboolean g_pin_is_layer_surface = FALSE;
static gboolean g_pin_dragging = FALSE;
static gdouble g_pin_drag_start_root_x = 0.0;
static gdouble g_pin_drag_start_root_y = 0.0;
static int g_pin_press_margin_left = 0;
static int g_pin_press_margin_top = 0;
static int g_pin_margin_left = 80;
static int g_pin_margin_top = 80;

static void empty_invoke_cb(GObject* object, GAsyncResult* result,
                            gpointer user_data) {
  g_autoptr(FlMethodResponse) response =
      fl_method_channel_invoke_method_finish(FL_METHOD_CHANNEL(object), result,
                                             nullptr);
  // Fire-and-forget notification; a failed reply is not actionable here.
}

static void pin_card_continue_clicked(GtkButton* button, gpointer user_data) {
  if (g_pin_window != nullptr) {
    gtk_widget_destroy(GTK_WIDGET(g_pin_window));
    g_pin_window = nullptr;
  }
  if (g_editor_window != nullptr) {
    gtk_widget_show(GTK_WIDGET(g_editor_window));
    gtk_window_present(g_editor_window);
  }
  if (g_window_channel != nullptr) {
    fl_method_channel_invoke_method(g_window_channel, "pinContinued", nullptr,
                                    nullptr, empty_invoke_cb, nullptr);
  }
}

static void pin_card_close_clicked(GtkButton* button, gpointer user_data) {
  if (g_pin_window != nullptr) {
    gtk_widget_destroy(GTK_WIDGET(g_pin_window));
    g_pin_window = nullptr;
  }
  // The editor is hidden, so dismissing the card ends the whole session.
  if (g_editor_window != nullptr) {
    gtk_window_close(g_editor_window);
  }
}

// Drag anywhere on the snapshot to move the card. On a layer surface the
// compositor ignores xdg move requests, so the drag updates the surface
// margins instead (pointer grabbed for the duration); plain toplevels use
// gtk_window_begin_move_drag, which carries a valid Wayland press serial.
static gboolean pin_card_button_press(GtkWidget* widget,
                                      GdkEventButton* event,
                                      gpointer user_data) {
  if (event->type != GDK_BUTTON_PRESS || event->button != 1) {
    return FALSE;
  }
  if (g_pin_is_layer_surface) {
    g_pin_dragging = TRUE;
    g_pin_drag_start_root_x = event->x_root;
    g_pin_drag_start_root_y = event->y_root;
    g_pin_press_margin_left = g_pin_margin_left;
    g_pin_press_margin_top = g_pin_margin_top;
    gtk_grab_add(widget);
    return TRUE;
  }
  if (g_pin_window != nullptr) {
    gtk_window_begin_move_drag(g_pin_window, (gint)event->button,
                               (gint)event->x_root, (gint)event->y_root,
                               (guint32)event->time);
  }
  return TRUE;
}

static gboolean pin_card_motion_notify(GtkWidget* widget,
                                       GdkEventMotion* event,
                                       gpointer user_data) {
  if (!g_pin_dragging || g_pin_window == nullptr) {
    return FALSE;
  }
#ifdef HAVE_GTK_LAYER_SHELL
  int left = g_pin_press_margin_left + (gint)(event->x_root - g_pin_drag_start_root_x);
  int top = g_pin_press_margin_top + (gint)(event->y_root - g_pin_drag_start_root_y);
  if (left < 0) left = 0;
  if (top < 0) top = 0;
  g_pin_margin_left = left;
  g_pin_margin_top = top;
  gtk_layer_set_margin(g_pin_window, GTK_LAYER_SHELL_EDGE_LEFT, left);
  gtk_layer_set_margin(g_pin_window, GTK_LAYER_SHELL_EDGE_TOP, top);
#endif
  return TRUE;
}

static gboolean pin_card_button_release(GtkWidget* widget,
                                        GdkEventButton* event,
                                        gpointer user_data) {
  if (g_pin_dragging) {
    g_pin_dragging = FALSE;
    gtk_grab_remove(widget);
  }
  return FALSE;
}

// Small translucent dark button floating on the snapshot. The CSS provider
// is screen-wide and created once; buttons just join the "pin-card-btn" class.
static void pin_card_style_button(GtkWidget* button) {
  static GtkCssProvider* provider = nullptr;
  if (provider == nullptr) {
    provider = gtk_css_provider_new();
    GError* error = nullptr;
    gtk_css_provider_load_from_data(
        provider,
        ".pin-card-btn { background-image: none; background-color:"
        " rgba(0, 0, 0, 0.45); color: #ffffff; border: none;"
        " border-radius: 6px; padding: 1px 7px; font-size: 11px;"
        " box-shadow: none; text-shadow: none; outline: none; }"
        ".pin-card-btn:hover { background-color: rgba(0, 0, 0, 0.72); }"
        ".pin-card-btn:active { background-color: rgba(0, 0, 0, 0.85); }"
        ".pin-card-btn label { color: #ffffff; }",
        -1, &error);
    if (error != nullptr) {
      g_warning("pin card button CSS failed: %s", error->message);
      g_error_free(error);
    }
    gtk_style_context_add_provider_for_screen(
        gdk_screen_get_default(), GTK_STYLE_PROVIDER(provider),
        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
  }
  gtk_style_context_add_class(gtk_widget_get_style_context(button),
                              "pin-card-btn");
}

// Paints the snapshot scaled to the widget's allocation, preserving aspect,
// over a dark backdrop — so the image fills the card no matter what size the
// window ends up (the compositor can reconfigure floating windows).
static gboolean pin_image_draw(GtkWidget* widget, cairo_t* cr,
                               gpointer user_data) {
  GdkPixbuf* pixbuf = GDK_PIXBUF(user_data);
  GtkAllocation alloc;
  gtk_widget_get_allocation(widget, &alloc);
  cairo_set_source_rgb(cr, 0.06, 0.08, 0.10);
  cairo_paint(cr);

  const double src_w = gdk_pixbuf_get_width(pixbuf);
  const double src_h = gdk_pixbuf_get_height(pixbuf);
  double scale = (double)alloc.width / src_w;
  if ((double)alloc.height / src_h < scale) {
    scale = (double)alloc.height / src_h;
  }
  if (scale > 0 && alloc.width > 0 && alloc.height > 0) {
    const double dst_w = src_w * scale;
    const double dst_h = src_h * scale;
    cairo_save(cr);
    cairo_translate(cr, ((double)alloc.width - dst_w) / 2.0,
                    ((double)alloc.height - dst_h) / 2.0);
    cairo_scale(cr, scale, scale);
    gdk_cairo_set_source_pixbuf(cr, pixbuf, 0, 0);
    cairo_paint(cr);
    cairo_restore(cr);
  }
  return TRUE;
}

static gboolean window_control_show_pin_card(FlMethodCall* method_call) {
  if (g_editor_window == nullptr) {
    return FALSE;
  }
  FlValue* args = fl_method_call_get_args(method_call);
  FlValue* path_value =
      fl_value_get_type(args) == FL_VALUE_TYPE_LIST && fl_value_get_length(args) > 0
          ? fl_value_get_list_value(args, 0)
          : nullptr;
  const gchar* png_path =
      path_value != nullptr ? fl_value_get_string(path_value) : nullptr;
  if (png_path == nullptr) {
    return FALSE;
  }

  GError* error = nullptr;
  GdkPixbuf* pixbuf = gdk_pixbuf_new_from_file(png_path, &error);
  if (error != nullptr) {
    g_error_free(error);
  }
  if (pixbuf == nullptr) {
    return FALSE;
  }

  // Fit the snapshot into a card of at most 520x400, preserving aspect.
  const int src_w = gdk_pixbuf_get_width(pixbuf);
  const int src_h = gdk_pixbuf_get_height(pixbuf);
  double scale = 1.0;
  if (src_w > 520) {
    scale = 520.0 / (double)src_w;
  }
  if ((double)src_h * scale > 400.0) {
    scale = 400.0 / (double)src_h;
  }
  const int card_w = src_w > 520 ? (int)((double)src_w * scale) : src_w;
  const int card_h = (int)((double)src_h * scale);
  GdkPixbuf* scaled = gdk_pixbuf_scale_simple(
      pixbuf, card_w, card_h, GDK_INTERP_BILINEAR);
  g_object_unref(pixbuf);
  if (scaled == nullptr) {
    return FALSE;
  }

  GtkWidget* card = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_decorated(GTK_WINDOW(card), FALSE);
  gtk_window_set_resizable(GTK_WINDOW(card), FALSE);
  // Pin the window to the exact card size with min==max hints so no layout
  // pass stretches it.
  GdkGeometry geometry;
  geometry.min_width = card_w;
  geometry.min_height = card_h;
  geometry.max_width = card_w;
  geometry.max_height = card_h;
  gtk_window_set_geometry_hints(GTK_WINDOW(card), nullptr, &geometry,
                                (GdkWindowHints)(GDK_HINT_MIN_SIZE |
                                                 GDK_HINT_MAX_SIZE));

  // Preferred: the compositor's overlay layer — the card then renders above
  // every ordinary window regardless of focus (this is how panels float).
  g_pin_is_layer_surface = FALSE;
#ifdef HAVE_GTK_LAYER_SHELL
  if (gtk_layer_is_supported()) {
    gtk_layer_init_for_window(GTK_WINDOW(card));
    gtk_layer_set_layer(GTK_WINDOW(card), GTK_LAYER_SHELL_LAYER_OVERLAY);
    gtk_layer_set_keyboard_mode(GTK_WINDOW(card),
                                GTK_LAYER_SHELL_KEYBOARD_MODE_ON_DEMAND);
    gtk_layer_set_anchor(GTK_WINDOW(card), GTK_LAYER_SHELL_EDGE_LEFT, TRUE);
    gtk_layer_set_anchor(GTK_WINDOW(card), GTK_LAYER_SHELL_EDGE_TOP, TRUE);
    gtk_layer_set_anchor(GTK_WINDOW(card), GTK_LAYER_SHELL_EDGE_RIGHT, FALSE);
    gtk_layer_set_anchor(GTK_WINDOW(card), GTK_LAYER_SHELL_EDGE_BOTTOM, FALSE);
    gtk_layer_set_margin(GTK_WINDOW(card), GTK_LAYER_SHELL_EDGE_LEFT,
                         g_pin_margin_left);
    gtk_layer_set_margin(GTK_WINDOW(card), GTK_LAYER_SHELL_EDGE_TOP,
                         g_pin_margin_top);
    g_pin_is_layer_surface = TRUE;
  }
#endif
  if (!g_pin_is_layer_surface) {
    // Fallback: transient child floats out of the tiling layout; keep-above
    // is honored on X11 only (Wayland compositors decide stacking).
    gtk_window_set_transient_for(GTK_WINDOW(card), g_editor_window);
    gtk_window_set_keep_above(GTK_WINDOW(card), TRUE);
  }

  GtkWidget* image = gtk_drawing_area_new();
  gtk_widget_set_size_request(image, card_w, card_h);
  gtk_widget_add_events(image, GDK_BUTTON_PRESS_MASK | GDK_BUTTON_RELEASE_MASK |
                                   GDK_BUTTON1_MOTION_MASK |
                                   GDK_POINTER_MOTION_MASK);
  g_object_set_data_full(G_OBJECT(image), "pin-pixbuf", scaled,
                         (GDestroyNotify)g_object_unref);
  g_signal_connect(image, "draw", G_CALLBACK(pin_image_draw), scaled);
  g_signal_connect(image, "button-press-event",
                   G_CALLBACK(pin_card_button_press), nullptr);
  g_signal_connect(image, "motion-notify-event",
                   G_CALLBACK(pin_card_motion_notify), nullptr);
  g_signal_connect(image, "button-release-event",
                   G_CALLBACK(pin_card_button_release), nullptr);

  // Small translucent buttons floating on the snapshot's corners; the card
  // shows the image edge-to-edge with no button bar.
  GtkWidget* continue_button = gtk_button_new_with_label("继续编辑");
  pin_card_style_button(continue_button);
  g_signal_connect(continue_button, "clicked",
                   G_CALLBACK(pin_card_continue_clicked), nullptr);
  gtk_widget_set_halign(continue_button, GTK_ALIGN_END);
  gtk_widget_set_valign(continue_button, GTK_ALIGN_END);
  gtk_widget_set_margin_bottom(continue_button, 4);
  gtk_widget_set_margin_end(continue_button, 4);

  GtkWidget* close_button = gtk_button_new_with_label("关闭");
  pin_card_style_button(close_button);
  g_signal_connect(close_button, "clicked",
                   G_CALLBACK(pin_card_close_clicked), nullptr);
  gtk_widget_set_halign(close_button, GTK_ALIGN_END);
  gtk_widget_set_valign(close_button, GTK_ALIGN_START);
  gtk_widget_set_margin_top(close_button, 4);
  gtk_widget_set_margin_end(close_button, 4);

  GtkWidget* overlay = gtk_overlay_new();
  gtk_container_add(GTK_CONTAINER(overlay), image);
  gtk_overlay_add_overlay(GTK_OVERLAY(overlay), continue_button);
  gtk_overlay_add_overlay(GTK_OVERLAY(overlay), close_button);
  gtk_container_add(GTK_CONTAINER(card), overlay);

  g_pin_window = GTK_WINDOW(card);
  gtk_widget_show_all(card);
  // The editor window is only hidden: the Flutter engine (and its drawing
  // history) stays alive and reappears untouched on 继续编辑.
  gtk_widget_hide(GTK_WIDGET(g_editor_window));
  return TRUE;
}

static gboolean quit_editor_on_idle(gpointer user_data);

static void window_control_method_call(FlMethodChannel* channel,
                                       FlMethodCall* method_call,
                                       gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);

  if (g_strcmp0(method, "showPinCard") == 0) {
    gboolean shown = window_control_show_pin_card(method_call);
    fl_method_call_respond_success(method_call, fl_value_new_bool(shown),
                                   nullptr);
  } else if (g_strcmp0(method, "moveBy") == 0) {
    FlValue* args = fl_method_call_get_args(method_call);
    FlValue* dx = fl_value_get_type(args) == FL_VALUE_TYPE_LIST &&
                          fl_value_get_length(args) > 0
                      ? fl_value_get_list_value(args, 0)
                      : nullptr;
    FlValue* dy = fl_value_get_type(args) == FL_VALUE_TYPE_LIST &&
                          fl_value_get_length(args) > 1
                      ? fl_value_get_list_value(args, 1)
                      : nullptr;
    gint x = 0;
    gint y = 0;
    gtk_window_get_position(g_editor_window, &x, &y);
    gtk_window_move(g_editor_window,
                    x + (gint)(dx != nullptr ? fl_value_get_float(dx) : 0),
                    y + (gint)(dy != nullptr ? fl_value_get_float(dy) : 0));
    fl_method_call_respond_success(method_call, fl_value_new_bool(TRUE),
                                   nullptr);
  } else if (g_strcmp0(method, "quit") == 0) {
    fl_method_call_respond_success(method_call, fl_value_new_bool(TRUE),
                                   nullptr);
    // 关窗必须推迟到主循环下一拍：立刻关会触发引擎停机，而方法应答还
    // 在渠道队列里没刷出， teardown 踩到已释放对象直接段错误。
    g_idle_add(quit_editor_on_idle, nullptr);
  } else {
    fl_method_call_respond(method_call,
                           FL_METHOD_RESPONSE(fl_method_not_implemented_response_new()),
                           nullptr);
  }
}

// Deferred editor-window close (see the quit branch): runs after the
// method response has been flushed through the messenger.
static gboolean quit_editor_on_idle(gpointer user_data) {
  if (g_editor_window != nullptr) {
    gtk_window_close(g_editor_window);
  }
  return G_SOURCE_REMOVE;
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // denialwm tiles this window without decorations (stacking will get its
  // own title-bar treatment upstream), and every action lives in the
  // Flutter toolbar. The toplevel title is still advertised so the
  // compositor can label the tile.
  gtk_window_set_title(window, "screenshot_tool");
  gtk_window_set_decorated(window, FALSE);
  gtk_window_set_default_size(window, 1280, 720);
  // 默认最大化：Wayland 下由 compositor 决定（平铺布局会按格子摆放）。
  gtk_window_maximize(window);
  gtk_widget_show(GTK_WIDGET(window));

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  if (g_window_channel == nullptr) {
    g_editor_window = window;
    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    g_window_channel = fl_method_channel_new(
        fl_engine_get_binary_messenger(fl_view_get_engine(view)),
        "denial/screenshot_window", FL_METHOD_CODEC(codec));
    fl_method_channel_set_method_call_handler(g_window_channel,
                                              window_control_method_call,
                                              window, nullptr);
  }

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application, gchar*** arguments, int* exit_status) {
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
  //MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  //MyApplication* self = MY_APPLICATION(object);

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
  G_APPLICATION_CLASS(klass)->local_command_line = my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID,
                                     "flags", G_APPLICATION_NON_UNIQUE,
                                     nullptr));
}
