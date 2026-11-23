const std = @import("std");

/// Misuse that must fail to compile with zui's own message. The build
/// system matches the *end* of an error line, so each `expected_error` is a
/// complete message.
const compile_error_cases = [_]struct { name: []const u8, expected_error: []const u8 }{
    .{ .name = "state_slots_not_power_of_two", .expected_error = "zui: limits.state_slots must be a power of two, got 1000" },
    .{ .name = "string_cache_entries_not_power_of_two", .expected_error = "zui: limits.string_cache_entries must be a power of two, got 1000" },
    .{ .name = "font_id_not_integer", .expected_error = "zui: FontId must be an integer or enum type, got f32" },
    .{ .name = "color_not_a_zui_color", .expected_error = "zui: Color must be zui.Color or zui.ExtendedColor, got [4]u8" },
    .{ .name = "text_missing_measure", .expected_error = "zui: text_missing_measure.Text does not implement zui.Text: missing `zuiMeasure`" },
    .{ .name = "text_measure_wrong_signature", .expected_error = "zui: text_measure_wrong_signature.Text.zuiMeasure must be fn (*text_measure_wrong_signature.Text, []const u8, style.MeasureKey(u16)) [2]f32, found fn (*text_measure_wrong_signature.Text, []const u8, u16, f32) [2]f32" },
    .{ .name = "text_unknown_declaration", .expected_error = "zui: text_unknown_declaration.Text declares unknown `zui_threadsafe`" },
    .{ .name = "text_thread_safe_not_bool", .expected_error = "zui: text_thread_safe_not_bool.Text.zui_thread_safe must be a bool, found comptime_int" },
    .{ .name = "text_without_text_contract", .expected_error = "zui: text() needs Config.Text set to a text contract" },
    .{ .name = "image_without_image_handle", .expected_error = "zui: image() needs Config.ImageHandle set to your image type" },
    .{ .name = "ids_repeated_name", .expected_error = "zui.ids: \"save\" appears more than once" },
    .{ .name = "semantics_without_feature", .expected_error = "zui: semantics() needs Config.features.semantics = true" },
    .{ .name = "chrome_regions_without_feature", .expected_error = "zui: chromeRegions() needs Config.features.chrome_regions = true" },
    .{ .name = "manipulation_without_gestures", .expected_error = "zui: manipulation() needs Config.features.gestures = true" },
    .{ .name = "double_tapped_without_gestures", .expected_error = "zui: doubleTapped() needs Config.features.gestures = true" },
    .{ .name = "pointer_events_without_gestures", .expected_error = "zui: pointerEvents() needs Config.features.gestures = true" },
    .{ .name = "dropped_without_gestures", .expected_error = "zui: dropped() needs Config.features.gestures = true" },
    .{ .name = "drag_payload_too_large", .expected_error = "zui: state type drag_payload_too_large.Document is 72 bytes, but a state slot holds at most 64; store an index into your own storage instead" },
    .{ .name = "wrap_without_feature", .expected_error = "zui: wrapChildren() needs Config.features.flex_wrap = true" },
    .{ .name = "nested_corners_without_feature", .expected_error = "/?/zui: Decoration.nested_corners needs Config.features.nested_corners = true' does not support struct initialization syntax" },
    .{ .name = "custom_without_custom_data", .expected_error = "zui: custom() needs Config.CustomData set to your payload type" },
    .{ .name = "state_type_too_large", .expected_error = "zui: state type state_type_too_large.History is 80 bytes, but a state slot holds at most 64; store an index into your own storage instead" },
    .{ .name = "config_material_without_handle", .expected_error = "zui: commands includes .material but MaterialHandle is void" },
    .{ .name = "config_corner_shapes_without_round", .expected_error = "zui: corner_shapes does not include .round, which every other shape is drawn as" },
    .{ .name = "renderer_missing_submit", .expected_error = "zui: renderer_missing_submit.Renderer does not implement zui.Renderer: missing `zuiSubmit`" },
    .{ .name = "renderer_submit_wrong_signature", .expected_error = "zui: renderer_submit_wrong_signature.Renderer.zuiSubmit must be fn (*renderer_submit_wrong_signature.Renderer, zui.Surface, frame: anytype) !void" },
    .{ .name = "renderer_unknown_declaration", .expected_error = "zui: renderer_unknown_declaration.Renderer declares unknown `zui_command`" },
    .{ .name = "renderer_without_surfaces", .expected_error = "zui: renderer_without_surfaces.Renderer.zui_surfaces names no surface kind, so no host can give it one" },
    .{ .name = "renderer_material_without_handle", .expected_error = "zui: renderer_material_without_handle.Renderer.zui_commands includes .material but renderer_material_without_handle.Renderer.MaterialHandle is void" },
    .{ .name = "renderer_corner_shapes_without_round", .expected_error = "zui: renderer_corner_shapes_without_round.Renderer.zui_corner_shapes does not include .round, which every other shape is drawn as" },
    .{ .name = "renderer_output_formats_without_sdr", .expected_error = "zui: renderer_output_formats_without_sdr.Renderer.zui_output_formats does not include .sdr, which every window falls back to" },
    .{ .name = "renderer_hdr_output_without_extended_color", .expected_error = "zui: renderer_hdr_output_without_extended_color.Renderer.zui_output_formats includes .scrgb_fp16 but renderer_hdr_output_without_extended_color.Renderer.zui_extended_color is not true, so it would be given only clamped colors" },
    .{ .name = "renderer_render_thread_not_bool", .expected_error = "zui: renderer_render_thread_not_bool.Renderer.zui_render_thread must be a bool, found comptime_int" },
    .{ .name = "renderer_commands_wrong_type", .expected_error = "zui: renderer_commands_wrong_type.Renderer.zui_commands must be a zui.CommandSet, found struct { comptime @EnumLiteral() = .gradient, comptime @EnumLiteral() = .shadow }" },
    .{ .name = "host_missing_poll", .expected_error = "zui: host_missing_poll.Host does not implement zui.Host: missing `zuiPoll`" },
    .{ .name = "host_wait_wrong_signature", .expected_error = "zui: host_wait_wrong_signature.Host.zuiWait must be fn (*host_wait_wrong_signature.Host, zui.NextFrame) void, found fn (*host_wait_wrong_signature.Host, u32) void" },
    .{ .name = "host_wait_and_run", .expected_error = "zui: host_wait_and_run.Host declares both `zuiWait` and `zuiRun`; zui pulls a host's loop or the platform pushes it, never both" },
    .{ .name = "host_run_wrong_signature", .expected_error = "zui: host_run_wrong_signature.Host.zuiRun must be fn (*host_run_wrong_signature.Host, std.Io, zui.WindowOptions, zui.Driver) !void, or noreturn, found fn (*host_run_wrong_signature.Host, host.Driver) void" },
    .{ .name = "app_run_on_stepped_host", .expected_error = "zui_app: app_run_on_stepped_host.PanelHost declares neither `zuiWait` nor `zuiRun`, so only the application's own loop can turn it: step a zui_app.Session(app_run_on_stepped_host.App) from that loop" },
    .{ .name = "app_wait_on_stepped_host", .expected_error = "zui_app: app_wait_on_stepped_host.PanelHost declares no `zuiWait`, so zui_app cannot wait on it; the loop that calls step waits as the zui.NextFrame it returns says" },
    .{ .name = "app_pushed_host_with_init", .expected_error = "zui_app: app_pushed_host_with_init.PageHost declares `zuiRun`, which opens and closes its window, so it declares no `init`" },
    .{ .name = "app_start_on_pushed_host", .expected_error = "zui_app: app_start_on_pushed_host.PageHost declares `zuiRun`, so it opens its own window and runs its own loop: start it with zui_app.run(app_start_on_pushed_host.App, ...)" },
    .{ .name = "host_unknown_declaration", .expected_error = "zui: host_unknown_declaration.Host declares unknown `zuiWake`" },
    .{ .name = "host_without_surfaces", .expected_error = "zui: host_without_surfaces.Host.zui_surfaces names no surface kind, so no renderer can draw into it" },
    .{ .name = "host_capabilities_wrong_type", .expected_error = "zui: host_capabilities_wrong_type.Host.zui_capabilities must be a zui.HostCapabilities, found bool" },
    .{ .name = "host_output_formats_wrong_type", .expected_error = "zui: host_output_formats_wrong_type.Host.zui_output_formats must be a zui.OutputFormats, found @EnumLiteral()" },
    .{ .name = "host_file_watch_wrong_signature", .expected_error = "zui: host_file_watch_wrong_signature.Host.zuiFileWatch.watch must be fn (*host_file_watch_wrong_signature.Host, []const u8, zui.FileChangeSink) zui.FileWatchError!void, found fn (*host_file_watch_wrong_signature.Host, []const u8) void" },
    .{ .name = "host_service_not_struct", .expected_error = "zui: host_service_not_struct.Host.zuiMenus must be a struct type, got u8" },
    .{ .name = "host_clipboard_missing_read", .expected_error = "zui: host_clipboard_missing_read.Host.zuiClipboard is missing `read`, which must be fn (*host_clipboard_missing_read.Host, zui.ServiceRequest, zui.ServiceSink) zui.ServiceError!void" },
    .{ .name = "host_clipboard_write_wrong_signature", .expected_error = "zui: host_clipboard_write_wrong_signature.Host.zuiClipboard.write must be fn (*host_clipboard_write_wrong_signature.Host, []const u8) zui.ServiceError!void, found fn (*host_clipboard_write_wrong_signature.Host, []const u8) void" },
    .{ .name = "host_notifications_wrong_signature", .expected_error = "zui: host_notifications_wrong_signature.Host.zuiNotifications.show must be fn (*host_notifications_wrong_signature.Host, zui.ServiceRequest, zui.Notification, zui.ServiceSink) zui.ServiceError!void, found fn (*host_notifications_wrong_signature.Host, []const u8) void" },
    .{ .name = "host_file_dialogs_missing_show", .expected_error = "zui: host_file_dialogs_missing_show.Host.zuiFileDialogs is missing `show`, which must be fn (*host_file_dialogs_missing_show.Host, zui.WindowId, zui.ServiceRequest, zui.FileDialog, zui.ServiceSink) zui.ServiceError!void" },
    .{ .name = "host_open_url_wrong_signature", .expected_error = "zui: host_open_url_wrong_signature.Host.zuiOpenUrl.open must be fn (*host_open_url_wrong_signature.Host, []const u8) zui.ServiceError!void, found fn (*host_open_url_wrong_signature.Host, []const u8) bool" },
    .{ .name = "host_menus_missing_popup", .expected_error = "zui: host_menus_missing_popup.Host.zuiMenus is missing `popup`, which must be fn (*host_menus_missing_popup.Host, zui.WindowId, zui.ServiceRequest, []const zui.MenuItem, [2]f32, zui.ServiceSink) zui.ServiceError!void" },
    .{ .name = "host_menu_bar_wrong_signature", .expected_error = "zui: host_menu_bar_wrong_signature.Host.zuiMenus.setBar must be fn (*host_menu_bar_wrong_signature.Host, zui.WindowId, zui.ServiceRequest, []const zui.MenuItem, zui.ServiceSink) zui.ServiceError!void, found fn (*host_menu_bar_wrong_signature.Host) void" },
    .{ .name = "service_sink_not_replies", .expected_error = "zui: zui.ServiceSink.of needs a source whose publish takes a zui.ServiceReply(n), found u64" },
    .{ .name = "app_service_without_guard", .expected_error = "zui_app: app_service_without_guard.Host has no `zuiNotifications`; guard the call with `if (zui_app.ServicesOf(app_service_without_guard.Host).has_notifications)`" },
    .{ .name = "host_semantics_wrong_signature", .expected_error = "zui: host_semantics_wrong_signature.Host.zuiSemantics must be fn (*host_semantics_wrong_signature.Host, zui.WindowId, []const zui.SemanticNode) zui.SemanticsDropped, found fn (*host_semantics_wrong_signature.Host, u32) void" },
    .{ .name = "host_chrome_regions_wrong_signature", .expected_error = "zui: host_chrome_regions_wrong_signature.Host.zuiChromeRegions must be fn (*host_chrome_regions_wrong_signature.Host, zui.WindowId, []const zui.ChromeRegion) void, found fn (*host_chrome_regions_wrong_signature.Host, []const chrome.ChromeRegion) void" },
    .{ .name = "host_custom_title_bar_without_chrome_regions", .expected_error = "zui: host_custom_title_bar_without_chrome_regions.Host.zui_capabilities.custom_title_bar is true but host_custom_title_bar_without_chrome_regions.Host does not declare zuiChromeRegions, so the OS could not move its window" },
    .{ .name = "host_many_windows_without_open", .expected_error = "zui: host_many_windows_without_open.Host declares zui_capabilities.windows = .many but not `zuiOpenWindow`, which must be fn (*host_many_windows_without_open.Host, zui.WindowOptions) zui.OpenWindowError!zui.WindowId" },
    .{ .name = "host_open_window_on_one", .expected_error = "zui: host_open_window_on_one.Host declares `zuiOpenWindow`, but its zui_capabilities.windows is .one" },
    .{ .name = "host_open_window_wrong_signature", .expected_error = "zui: host_open_window_wrong_signature.Host.zuiOpenWindow must be fn (*host_open_window_wrong_signature.Host, zui.WindowOptions) zui.OpenWindowError!zui.WindowId, found fn (*host_open_window_wrong_signature.Host, host.WindowOptions) ?host.WindowId" },
    .{ .name = "renderer_attach_without_detach", .expected_error = "zui: renderer_attach_without_detach.Renderer declares `zuiAttachSurface` without `zuiDetachSurface`; a renderer that keeps something per window declares both" },
    .{ .name = "renderer_attach_wrong_signature", .expected_error = "zui: renderer_attach_wrong_signature.Renderer.zuiAttachSurface must be fn (*renderer_attach_wrong_signature.Renderer, zui.Surface) !void, found fn (*renderer_attach_wrong_signature.Renderer, surface.Surface) bool" },
    .{ .name = "host_and_renderer_share_no_surface", .expected_error = "zui: host_and_renderer_share_no_surface.Host and host_and_renderer_share_no_surface.Renderer share no surface kind: the host gives .library, the renderer draws into .offscreen, .terminal" },
    .{ .name = "tracer_not_struct", .expected_error = "zui: Tracer must be a struct type, got u32" },
    .{ .name = "tracer_missing_end", .expected_error = "zui: tracer_missing_end.Tracer does not implement zui.Tracer: missing `zuiEnd`" },
    .{ .name = "tracer_begin_not_comptime", .expected_error = "zui: tracer_begin_not_comptime.Tracer.zuiBegin must be fn (comptime zone: zui.TraceZone) Span, found fn (trace.TraceZone) u32" },
    .{ .name = "tracer_end_wrong_signature", .expected_error = "zui: tracer_end_wrong_signature.Tracer.zuiEnd must be fn (u32) void, the span zuiBegin returns, found fn (u64) void" },
    .{ .name = "tracer_unknown_declaration", .expected_error = "zui: tracer_unknown_declaration.Tracer declares unknown `zuiFrameMark`" },
    .{ .name = "sources_not_struct", .expected_error = "zui: Sources must be a struct type, got u32" },
    .{ .name = "sources_field_not_source", .expected_error = "zui: sources_field_not_source.AppSources.count must be a struct type implementing zui.Source, got u32" },
    .{ .name = "sources_missing_swap", .expected_error = "zui: sources_missing_swap.AppSources.quotes does not implement zui.Source: missing `zuiSwap`" },
    .{ .name = "sources_missing_delivery", .expected_error = "zui: sources_missing_delivery.AppSources.quotes does not implement zui.Source: missing `Delivery`" },
    .{ .name = "sources_swap_wrong_signature", .expected_error = "zui: sources_swap_wrong_signature.AppSources.quotes.zuiSwap must be fn (*sources_swap_wrong_signature.Quotes) void, found fn (*const sources_swap_wrong_signature.Quotes) void" },
    .{ .name = "sources_pending_wrong_signature", .expected_error = "zui: sources_pending_wrong_signature.AppSources.quotes.zuiPending must be fn (*const sources_pending_wrong_signature.Quotes) bool, found fn (*sources_pending_wrong_signature.Quotes) bool" },
    .{ .name = "sources_unknown_declaration", .expected_error = "zui: sources_unknown_declaration.AppSources.quotes declares unknown `zuiPendng`" },
    .{ .name = "source_without_sources", .expected_error = "zui: source() needs Config.Sources set to a struct of sources" },
    .{ .name = "source_not_in_sources", .expected_error = "enum 'meta.FieldEnum(source_not_in_sources.AppSources)' has no member named 'quotez'" },
    .{ .name = "status_failed_on_infallible", .expected_error = "enum '@typeInfo(sources.StatusWithProgress(u32,void)).@\"union\".tag_type.?' has no member named 'failed'" },
    .{ .name = "status_missing_prong", .expected_error = "switch must handle all possibilities" },
    .{ .name = "async_stream_capacity", .expected_error = "zui_async: Stream capacity must be a power of two, got 100" },
    .{ .name = "async_keyed_progress_too_large", .expected_error = "zui_async: KeyedLoads Progress must fit in a usize, got [3]f64" },
    .{ .name = "async_keyed_no_capacity", .expected_error = "zui_async: KeyedLoads capacity must be at least 1" },
    .{ .name = "async_release_without_ownership", .expected_error = "zui_async: toRelease() needs .owns_resources = true" },
    .{ .name = "testing_deliver_nothing", .expected_error = "zui_testing: frameDelivering cannot deliver nothing to `other`, whose Delivery is neither optional nor declares `empty`; give it a delivery" },
    .{ .name = "widgets_slider_on_bool", .expected_error = "zui_widgets: slider needs a pointer to an integer or float, got *bool" },
    .{ .name = "reflect_misspelled_option", .expected_error = "no field named 'volum' in struct 'zui_reflect.FieldOptionsOf(reflect_misspelled_option.Settings)'" },
    .{ .name = "reflect_untyped_options", .expected_error = "; declare it as `pub const zui_inspector: zui_reflect.Options(@This())` so misspelled options fail to compile" },
    .{ .name = "reflect_unsupported_field", .expected_error = "zui_reflect: reflect_unsupported_field.Settings.on_change is *const fn () void, which the inspector cannot edit; hide it with `.fields.on_change = .{ .hidden = true }`" },
    .{ .name = "reflect_range_on_bool", .expected_error = "zui_reflect: reflect_range_on_bool.Settings.fullscreen is bool; min, max and step only apply to numbers" },
    .{ .name = "reflect_min_above_max", .expected_error = "zui_reflect: reflect_min_above_max.Settings.max_fps has min 240 above max 30" },
    .{ .name = "app_missing_declare", .expected_error = "zui_app: app_missing_declare.App does not implement zui_app's application: missing `zuiDeclare`" },
    .{ .name = "app_declare_wrong_signature", .expected_error = "zui_app: app_declare_wrong_signature.App.zuiDeclare must be fn (*app_declare_wrong_signature.App, *Ui) void, or fn (*app_declare_wrong_signature.App, *Ui, zui.WindowId) void for many windows, where Ui is a zui.Context" },
    .{ .name = "app_unknown_declaration", .expected_error = "zui_app: app_unknown_declaration.App declares unknown `zuiLoder`" },
    .{ .name = "app_field_without_default", .expected_error = "zui_app: app_field_without_default.App has no `init`, so every field needs a default; `window_count` has none" },
    .{ .name = "app_without_sources_field", .expected_error = "zui_app: app_without_sources_field.App needs a field `sources: app_without_sources_field.AppSources`, the Config's Sources or a pointer to them, for zui_app to swap" },
    .{ .name = "app_text_not_declared", .expected_error = "zui_app: app_text_not_declared.App's Ui measures text with app_text_not_declared.Fonts, which zui_app makes only when app_text_not_declared.App declares `pub const Text = app_text_not_declared.Fonts`" },
    .{ .name = "app_text_mismatch", .expected_error = "zui_app: app_text_mismatch.App.Text is app_text_mismatch.OtherFonts, but its Ui measures text with app_text_mismatch.Fonts" },
    .{ .name = "app_renderer_init_anytype_text_wrong_surface", .expected_error = "zui_app: app_renderer_init_anytype_text_wrong_surface.FontsRenderer.init must be fn (*app_renderer_init_anytype_text_wrong_surface.FontsRenderer, zui.Surface, *const app_renderer_init_anytype_text_wrong_surface.Fonts) !void, or take its text as `anytype`" },
    .{ .name = "app_renderer_init_wrong_text", .expected_error = "zui_app: app_renderer_init_wrong_text.FontsRenderer.init must be fn (*app_renderer_init_wrong_text.FontsRenderer, zui.Surface, *const app_renderer_init_wrong_text.Fonts) !void, found fn (*app_renderer_init_wrong_text.FontsRenderer, surface.Surface, *const u8) error{OutOfMemory}!void" },
    .{ .name = "app_record_wrong_signature", .expected_error = "zui_app: app_record_wrong_signature.App.zuiRecord must be fn (*app_record_wrong_signature.App, *zui.RecordBuilder) void, found fn (*app_record_wrong_signature.App, *const record.RecordBuilder) void" },
    .{ .name = "app_observe_wrong_signature", .expected_error = "zui_app: app_observe_wrong_signature.App.zuiObserve must be fn (*app_observe_wrong_signature.App, *const Ui, *const Ui.Frame) void" },
    .{ .name = "app_open_window_one_host", .expected_error = "zui_app: app_open_window_one_host.Host opens one window (its zui_capabilities.windows is .one), so app_open_window_one_host.App cannot open another" },
    .{ .name = "app_windows_without_sources", .expected_error = "zui_app: app_windows_without_sources.App declares each window's UI, so it needs `pub fn zuiSources(app: *app_windows_without_sources.App, window: zui.WindowId) *app_windows_without_sources.AppSources`, the sources of each window's context" },
    .{ .name = "app_window_loader_wrong_signature", .expected_error = "zui_app: app_window_loader_wrong_signature.App.zuiLoader must be fn (*app_window_loader_wrong_signature.App, *const Ui, zui.WindowId, std.Io) void, since its zuiDeclare takes a zui.WindowId, found fn (*app_window_loader_wrong_signature.App, host.WindowId) void" },
    .{ .name = "app_window_closed_one_window", .expected_error = "zui_app: app_window_closed_one_window.App declares `zuiWindowClosed`, but its zuiDeclare takes no zui.WindowId, so it has one window" },
    .{ .name = "testing_many_windows_harness", .expected_error = "zui_testing: testing_many_windows_harness.Harness tests a host with many windows, so it must declare `fn postTo(self, window: zui.WindowId, event: zui.Event) bool`" },
    .{ .name = "app_host_without_init", .expected_error = "zui_app: app_host_without_init.OffscreenHost must declare `pub fn init(self: *app_host_without_init.OffscreenHost, io: std.Io, window: zui.WindowOptions) !void`, which opens its window" },
    .{ .name = "wire_delivery_holds_pointer", .expected_error = "zui_wire: delivery of source `catalog` holds a pointer (*const wire_delivery_holds_pointer.Catalog); declare zuiSerialize on it to send it" },
    .{ .name = "wire_image_handle_holds_pointer", .expected_error = "zui_wire: ImageHandle holds a pointer (*const wire_image_handle_holds_pointer.Texture); declare zuiSerialize on it to send it" },
    .{ .name = "wire_serialize_without_deserialize", .expected_error = "zui_wire: wire_serialize_without_deserialize.Handle declares zuiSerialize but not zuiDeserialize" },
    .{ .name = "debug_without_text", .expected_error = "zui_debug: Inspector needs a context with Config.Text, which draws its panel" },
    .{ .name = "debug_zone_timer_inner_not_tracer", .expected_error = "zui_debug: ZoneTimer passes its zones on to a tracer or to void, got debug_zone_timer_inner_not_tracer.Fonts" },
    .{ .name = "debug_theme_changes_not_file_changes", .expected_error = "zui_debug: Sources.theme_files is not a stream of zui.FileChange, such as zui_async.Stream(zui.FileChange, ...)" },
    .{ .name = "debug_theme_source_not_theme", .expected_error = "zui_debug: Sources.theme does not hold the panel's theme, as a zui_async.Latest(zui_debug.PanelTheme(FontId, Color)) does" },
    .{ .name = "motion_value_not_animatable", .expected_error = "zui_motion: cannot animate u32; animate f32, [N]f32, zui.Color, zui.ExtendedColor or a struct of them" },
    .{ .name = "text_fingerprint_wrong_signature", .expected_error = "zui: text_fingerprint_wrong_signature.Text.zuiFingerprint must be fn (*const text_fingerprint_wrong_signature.Text) u64, found fn (*text_fingerprint_wrong_signature.Text) u32" },
    .{ .name = "text_segment_wrong_signature", .expected_error = "zui: text_segment_wrong_signature.Text.zuiSegment must be fn (*text_segment_wrong_signature.Text, []const u8, *text.BreakSink) void, found fn (*text_segment_wrong_signature.Text, []const u8, []u32) void" },
    .{ .name = "color_ramp_too_few_steps", .expected_error = "zui_color: ramp needs at least 2 steps, one for each end; got 0" },
    .{ .name = "color_lightness_scale_too_few_steps", .expected_error = "zui_color: lightnessScale needs at least 2 steps, one for each end; got 1" },
    .{ .name = "design_status_roles_collapse", .expected_error = "zui_design: demo.design's danger and success are 0.13 apart in lightness under protanopia in light high contrast, need 0.15; success at L 0.43 passes" },
    .{ .name = "skin_not_a_struct", .expected_error = "zui_widgets: a skin must be a struct type, got u32" },
    .{ .name = "skin_unknown_declaration", .expected_error = "zui_widgets: skin_unknown_declaration.Skin declares unknown `zuiStlye`" },
    .{ .name = "skin_missing_style", .expected_error = "zui_widgets: skin_missing_style.Skin does not implement the skin contract: missing `zuiStyle`" },
    .{ .name = "skin_wrong_style_signature", .expected_error = "zui_widgets: skin_wrong_style_signature.Skin.zuiStyle must be fn (*const skin_wrong_style_signature.Skin, zui_widgets.Part, zui.WidgetState, *const zui.Environment) zui_widgets.Style(Ui), found fn (*const skin_wrong_style_signature.Skin, zui_widgets.Part, interaction.WidgetState) zui_widgets.Style(context.Context(.{ .limits = .{ ... }, .Text = skin_wrong_style_signature.Text, .Sources = void, .commands = .{ ... }, .ImageHandle = void, .CustomData = void, .MaterialHandle = void, .FontId = u16, .Color = style.Color, .extended_color = false, .corner_shapes = .{ ... }, .features = .{ ... }, .frames_in_flight = 2 }))" },
    .{ .name = "appearance_missing_part", .expected_error = "zui: appearance_missing_part.Chip's appearance has no part `container` of appearance_missing_part.Chip.Part" },
    .{ .name = "appearance_text_without_on", .expected_error = "zui: appearance_text_without_on.Chip.label draws text but names no part it is drawn `.on`" },
    .{ .name = "appearance_icon_without_on", .expected_error = "zui: appearance_icon_without_on.Chip.close draws an icon but names no part it is drawn `.on`" },
    .{ .name = "appearance_on_unknown_part", .expected_error = "zui: appearance_on_unknown_part.Chip.label is drawn on `badge`, which is not a part of appearance_on_unknown_part.Chip.Part" },
    .{ .name = "appearance_unchecked_without_reason", .expected_error = "zui: appearance_unchecked_without_reason.Chip.close's `.unchecked` color needs a reason" },
    .{ .name = "appearance_on_part_without_surface", .expected_error = "zui: appearance_on_part_without_surface.Chip.label is drawn on `close`, which has no surface" },
    .{ .name = "appearance_text_and_icon", .expected_error = "zui: appearance_text_and_icon.Chip.close draws both text and an icon; give each a part of its own" },
    .{ .name = "appearance_without_part", .expected_error = "zui: appearance_without_part.Chip declares no `Part`, the enum of its parts" },
    .{ .name = "appearance_not_declared", .expected_error = "zui: appearance_not_declared.Chip declares no `zuiAppearance`" },
    .{ .name = "appearance_of_another_part", .expected_error = "zui: appearance_of_another_part.Chip.zuiAppearance must be a zui.design.Appearance(appearance_of_another_part.Chip.Part, …)" },
    .{ .name = "appearance_part_not_enum", .expected_error = "zui: an appearance's Part must be an enum, got appearance_part_not_enum.Chip.Part" },
    .{ .name = "appearance_extra_roles_mismatch", .expected_error = "zui: appearance_extra_roles_mismatch.Badge's appearance names the extra roles appearance_extra_roles_mismatch.Roles, but the tokens' extra roles are void" },
    .{ .name = "appearance_unknown_declaration", .expected_error = "zui: appearance_unknown_declaration.Chip declares unknown `zuiDistinguis`" },
    .{ .name = "distinguish_not_a_pair", .expected_error = "zui: each entry of distinguish_not_a_pair.Chip.zuiDistinguish is two parts, or a part and two states" },
    .{ .name = "distinguish_unknown_part", .expected_error = "zui: distinguish_unknown_part.Chip.zuiDistinguish names `badge`, which is not a part of distinguish_unknown_part.Chip.Part" },
    .{ .name = "distinguish_unknown_state", .expected_error = "zui: distinguish_unknown_state.Chip.zuiDistinguish names `normal`, which is not a zui.WidgetState" },
    .{ .name = "distinguish_without_cue", .expected_error = "zui_design: under demo.design, distinguish_without_cue.Chip's container and container_selected are 0.01 apart in lightness under protanopia in light, need 0.15; give one a `.cue` that is not color" },
    .{ .name = "previews_of_two_types", .expected_error = "zui: previews_of_two_types.Chip.zuiPreviews.count is a u32, but .short is a previews_of_two_types.Chip.Content; every preview is the same type" },
    .{ .name = "distinguish_states_without_cue", .expected_error = "zui_design: under demo.design, distinguish_states_without_cue.Chip.close's idle and hovered layers are 0.03 apart in lightness under protanopia in light, need 0.15; give it a `.cue` that is not color" },
    .{ .name = "extra_roles_not_enum", .expected_error = "zui: ExtraRoles must be an enum or void, got u8" },
    .{ .name = "extra_roles_shadow_color_role", .expected_error = "zui: extra_roles_shadow_color_role.Roles's `accent` is already a zui.design.ColorRole" },
    .{ .name = "extra_roles_without_pairs", .expected_error = "zui: extra_roles_without_pairs.Roles declares no `zuiPairs`, the role each of its roles pairs with" },
    .{ .name = "extra_roles_unpaired_role", .expected_error = "zui: extra_roles_unpaired_role.Roles.zuiPairs gives no pair for `on_brand`" },
    .{ .name = "extra_roles_pair_unknown_role", .expected_error = "zui: extra_roles_pair_unknown_role.Roles.zuiPairs pairs `brand` with `logo`, which is neither a zui.design.ColorRole nor a role of extra_roles_pair_unknown_role.Roles" },
    .{ .name = "extra_roles_pairs_unknown_key", .expected_error = "zui: extra_roles_pairs_unknown_key.Roles.zuiPairs names `logo`, which is not a role of extra_roles_pairs_unknown_key.Roles" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sanitize_thread = b.option(bool, "zui-sanitize-thread", "Build zui and its modules with ThreadSanitizer, through LLVM (Linux)") orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "debug", b.option(bool, "zui-debug", "Keep id names for diagnostics") orelse false);

    const zui_module = b.addModule("zui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = if (sanitize_thread) true else null,
    });
    zui_module.addOptions("zui_options", build_options);

    // Each optional module sits in its own directory and can only reach
    // zui through @import("zui"), so the compiler holds them to the public API.
    const testing_module = b.addModule("zui_testing", .{
        .root_source_file = b.path("zui_testing/zui_testing.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = if (sanitize_thread) true else null,
        .imports = &.{.{ .name = "zui", .module = zui_module }},
    });
    const widgets_module = b.addModule("zui_widgets", .{
        .root_source_file = b.path("zui_widgets/zui_widgets.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = if (sanitize_thread) true else null,
        .imports = &.{.{ .name = "zui", .module = zui_module }},
    });
    const async_module = b.addModule("zui_async", .{
        .root_source_file = b.path("zui_async/zui_async.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = if (sanitize_thread) true else null,
        .imports = &.{.{ .name = "zui", .module = zui_module }},
    });
    const tracy_enabled = b.option(bool, "zui-tracy", "Link Tracy's client, so zui_tracy.Tracer traces into the Tracy profiler") orelse false;
    const tracy_options = b.addOptions();
    tracy_options.addOption(bool, "enabled", tracy_enabled);
    const tracy_module = b.addModule("zui_tracy", .{
        .root_source_file = b.path("zui_tracy/zui_tracy.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = if (sanitize_thread) true else null,
        .imports = &.{
            .{ .name = "zui", .module = zui_module },
            .{ .name = "zui_tracy_options", .module = tracy_options.createModule() },
        },
    });
    if (tracy_enabled) linkTracy(b, tracy_module);
    const reflect_module = b.addModule("zui_reflect", .{
        .root_source_file = b.path("zui_reflect/zui_reflect.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = if (sanitize_thread) true else null,
        .imports = &.{
            .{ .name = "zui", .module = zui_module },
            .{ .name = "zui_widgets", .module = widgets_module },
        },
    });

    const app_module = b.addModule("zui_app", .{
        .root_source_file = b.path("zui_app/zui_app.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = if (sanitize_thread) true else null,
        .imports = &.{.{ .name = "zui", .module = zui_module }},
    });

    const wire_module = b.addModule("zui_wire", .{
        .root_source_file = b.path("zui_wire/zui_wire.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = if (sanitize_thread) true else null,
        .imports = &.{.{ .name = "zui", .module = zui_module }},
    });

    const debug_module = b.addModule("zui_debug", .{
        .root_source_file = b.path("zui_debug/zui_debug.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = if (sanitize_thread) true else null,
        .imports = &.{.{ .name = "zui", .module = zui_module }},
    });

    const motion_module = b.addModule("zui_motion", .{
        .root_source_file = b.path("zui_motion/zui_motion.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = if (sanitize_thread) true else null,
        .imports = &.{.{ .name = "zui", .module = zui_module }},
    });

    const color_module = b.addModule("zui_color", .{
        .root_source_file = b.path("zui_color/zui_color.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = if (sanitize_thread) true else null,
        .imports = &.{.{ .name = "zui", .module = zui_module }},
    });

    const design_module = b.addModule("zui_design", .{
        .root_source_file = b.path("zui_design/zui_design.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = if (sanitize_thread) true else null,
        .imports = &.{.{ .name = "zui", .module = zui_module }},
    });

    const test_step = b.step("test", "Run the unit tests and the compile-error tests, and compile the benchmark tools");
    const unit_test_step = b.step("test-unit", "Run the unit tests, in the selected optimize mode");
    const compile_error_test_step = b.step("test-compile-errors", "Check every compile error's message, which no optimize mode changes");
    const bench_tools_step = b.step("check-bench-tools", "Compile counts, bench-compare and bench-report, each in its own fixed optimize mode");
    for ([_]*std.Build.Step{ unit_test_step, compile_error_test_step, bench_tools_step }) |part| test_step.dependOn(part);
    const bench_statistics_module = b.createModule(.{
        .root_source_file = b.path("bench/statistics.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Each binary compiles all of zui again, so a release build of every one
    // outlasts a small CI runner, and CI runs each shard as a job of its own.
    // zui's own binary is the longest, so its shard takes the cheap ones.
    const unit_test_shards = [_][]const *std.Build.Module{
        &.{ zui_module, bench_statistics_module, color_module, design_module, motion_module, tracy_module, reflect_module },
        &.{ testing_module, app_module, debug_module, async_module, widgets_module, wire_module },
    };
    for (unit_test_shards, 1..) |shard_modules, shard_number| {
        const shard_step = b.step(
            b.fmt("test-unit-{d}", .{shard_number}),
            b.fmt("Run shard {d} of {d} of the unit tests, which CI runs as jobs of their own", .{ shard_number, unit_test_shards.len }),
        );
        unit_test_step.dependOn(shard_step);
        for (shard_modules) |tested_module| {
            const module_tests = b.addTest(.{ .root_module = tested_module, .use_llvm = if (sanitize_thread) true else null });
            shard_step.dependOn(&b.addRunArtifact(module_tests).step);
        }
    }
    for ([_]*std.Build.Module{ async_module, widgets_module, reflect_module, tracy_module, wire_module, debug_module, motion_module }) |module_with_driven_tests| {
        module_with_driven_tests.addImport("zui_testing", testing_module);
    }
    for ([_]*std.Build.Module{ widgets_module, reflect_module }) |module_with_designed_tests| {
        module_with_designed_tests.addImport("zui_design", design_module);
    }
    wire_module.addImport("zui_async", async_module);
    wire_module.addImport("zui_app", app_module);
    debug_module.addImport("zui_async", async_module);
    debug_module.addImport("zui_bench_scenes", b.createModule(.{
        .root_source_file = b.path("bench/scenes.zig"),
        .imports = &.{
            .{ .name = "zui", .module = zui_module },
            .{ .name = "zui_async", .module = async_module },
        },
    }));

    for (compile_error_cases) |case| {
        const failing_object = b.addObject(.{
            .name = case.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("tests/compile_errors/{s}.zig", .{case.name})),
                .target = target,
                .imports = &.{
                    .{ .name = "zui", .module = zui_module },
                    .{ .name = "zui_testing", .module = testing_module },
                    .{ .name = "zui_async", .module = async_module },
                    .{ .name = "zui_widgets", .module = widgets_module },
                    .{ .name = "zui_reflect", .module = reflect_module },
                    .{ .name = "zui_app", .module = app_module },
                    .{ .name = "zui_wire", .module = wire_module },
                    .{ .name = "zui_debug", .module = debug_module },
                    .{ .name = "zui_motion", .module = motion_module },
                    .{ .name = "zui_color", .module = color_module },
                    .{ .name = "zui_design", .module = design_module },
                },
            }),
        });
        failing_object.expect_errors = .{ .contains = case.expected_error };
        compile_error_test_step.dependOn(&failing_object.step);
    }

    // A static library is only built so its documentation can be emitted;
    // consumers import the module above, not this artifact.
    const docs_library = b.addLibrary(.{ .name = "zui", .root_module = zui_module, .linkage = .static });
    b.addNamedLazyPath("docs", docs_library.getEmittedDocs());
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_library.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.step("docs", "Generate API documentation into zig-out/docs").dependOn(&install_docs.step);

    // Nothing requests this object's outputs, so compiling it emits no files:
    // a fast feedback loop for editors (ZLS build-on-save) and for
    // cross-target CI. It instantiates zui, because generic code is only
    // type-checked once instantiated.
    const check_object = b.addObject(.{
        .name = "zui_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/instantiate.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui", .module = zui_module },
                .{ .name = "zui_testing", .module = testing_module },
                .{ .name = "zui_async", .module = async_module },
                .{ .name = "zui_widgets", .module = widgets_module },
                .{ .name = "zui_reflect", .module = reflect_module },
                .{ .name = "zui_app", .module = app_module },
                .{ .name = "zui_tracy", .module = tracy_module },
                .{ .name = "zui_wire", .module = wire_module },
                .{ .name = "zui_debug", .module = debug_module },
                .{ .name = "zui_motion", .module = motion_module },
                .{ .name = "zui_color", .module = color_module },
                .{ .name = "zui_design", .module = design_module },
            },
        }),
    });
    const check_step = b.step("check", "Type-check zui for the selected target");
    check_step.dependOn(&check_object.step);

    const bench_zui = releaseFastZui(b, target, build_options);
    const bench_options = b.addOptions();
    bench_options.addOption(u64, "layout_seed", b.option(u64, "bench-layout-seed", "Move every function of the benchmark by a seed-chosen offset, as bench-compare's layouts do") orelse 0);
    const bench_executable = b.addExecutable(.{
        .name = "zui-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zui", .module = bench_zui },
                .{ .name = "zui_async", .module = releaseFastAsync(b, target, bench_zui) },
                .{ .name = "bench_options", .module = bench_options.createModule() },
            },
        }),
    });
    b.addNamedLazyPath("zui-bench", bench_executable.getEmittedBin());
    const run_bench = b.addRunArtifact(bench_executable);
    if (b.args) |arguments| run_bench.addArgs(arguments);
    b.step("bench", "Run the benchmarks in ReleaseFast").dependOn(&run_bench.step);
    b.step("bench-install", "Install the benchmark executable, which bench-compare runs one scenario at a time").dependOn(&b.addInstallArtifact(bench_executable, .{}).step);

    // A fixed CPU model and no libc, so every runner executes the same
    // instructions; Valgrind supports every extension of x86-64-v3.
    const counts_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .none,
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 },
    });
    const counts_zui = releaseFastZui(b, counts_target, build_options);
    const counts_executable = b.addExecutable(.{
        .name = "zui-counts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/counts.zig"),
            .target = counts_target,
            .optimize = .ReleaseFast,
            .valgrind = true,
            .imports = &.{
                .{ .name = "zui", .module = counts_zui },
                .{ .name = "zui_async", .module = releaseFastAsync(b, counts_target, counts_zui) },
            },
        }),
    });
    b.addNamedLazyPath("zui-counts", counts_executable.getEmittedBin());
    const run_counts = b.addRunArtifact(counts_executable);
    if (b.args) |arguments| run_counts.addArgs(arguments);
    b.step("counts", "Count each scenario's instructions per frame under Callgrind (x86_64 Linux with Valgrind)").dependOn(&run_counts.step);
    bench_tools_step.dependOn(&counts_executable.step);

    const bench_compare_executable = b.addExecutable(.{
        .name = "zui-bench-compare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/compare.zig"),
            .target = b.graph.host,
            // Resampling the intervals after every round is slow in Debug.
            .optimize = .ReleaseSafe,
        }),
    });
    b.addNamedLazyPath("zui-bench-compare", bench_compare_executable.getEmittedBin());
    const run_bench_compare = b.addRunArtifact(bench_compare_executable);
    run_bench_compare.addArgs(&.{ "--zig", b.graph.zig_exe, "--repository", b.pathFromRoot(".") });
    if (b.args) |arguments| run_bench_compare.addArgs(arguments);
    b.step("bench-compare", "Alternate the benchmarks of two commits, pinned to one core: -- <base> [<head>], or -- --calibrate").dependOn(&run_bench_compare.step);
    bench_tools_step.dependOn(&bench_compare_executable.step);

    const bench_report_executable = b.addExecutable(.{
        .name = "zui-bench-report",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/report.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    b.addNamedLazyPath("zui-bench-report", bench_report_executable.getEmittedBin());
    const run_bench_report = b.addRunArtifact(bench_report_executable);
    if (b.args) |arguments| run_bench_report.addArgs(arguments);
    b.step("bench-report", "Set side by side each machine's results for one commit: -- <results dir> [<commit>]").dependOn(&run_bench_report.step);
    bench_tools_step.dependOn(&bench_report_executable.step);

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src", "tests", "bench", "zui_testing", "zui_async", "zui_widgets", "zui_reflect", "zui_tracy", "zui_app", "zui_wire", "zui_debug", "zui_motion", "zui_color", "zui_design" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);
}

/// The benchmarks always measure ReleaseFast, whatever `-Doptimize` says.
fn releaseFastZui(b: *std.Build, target: std.Build.ResolvedTarget, build_options: *std.Build.Step.Options) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "zui_options", .module = build_options.createModule() }},
    });
}

fn releaseFastAsync(b: *std.Build, target: std.Build.ResolvedTarget, zui_module: *std.Build.Module) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("zui_async/zui_async.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "zui", .module = zui_module }},
    });
}

/// Tracy is a lazy dependency, fetched only by a build that asks for it.
fn linkTracy(b: *std.Build, tracy_module: *std.Build.Module) void {
    const tracy = b.lazyDependency("tracy", .{}) orelse return;
    const windows = tracy_module.resolved_target.?.result.os.tag == .windows;
    // With callstacks, a MinGW build's process exits with code 9 after
    // Tracy shuts down. zui's zones collect no callstacks.
    const flags: []const []const u8 = if (windows)
        &.{ "-DTRACY_ENABLE", "-DTRACY_NO_CALLSTACK" }
    else
        &.{"-DTRACY_ENABLE"};
    tracy_module.addCSourceFile(.{ .file = tracy.path("public/TracyClient.cpp"), .flags = flags });
    tracy_module.link_libcpp = true;
    if (windows) {
        for ([_][]const u8{ "ws2_32", "dbghelp", "advapi32", "user32", "secur32" }) |library| tracy_module.linkSystemLibrary(library, .{});
    }
}
