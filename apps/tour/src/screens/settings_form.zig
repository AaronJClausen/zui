const std = @import("std");
const zui = @import("zui");

const toast_seconds = 2.5;

/// One line of text a field edits, in fixed storage.
const TextValue = struct {
    bytes: [64]u8 = undefined,
    len: usize = 0,

    fn of(content: []const u8) TextValue {
        var value: TextValue = .{ .len = content.len };
        @memcpy(value.bytes[0..content.len], content);
        return value;
    }

    fn slice(value: *const TextValue) []const u8 {
        return value.bytes[0..value.len];
    }

    fn trimmed(value: *const TextValue) []const u8 {
        return std.mem.trim(u8, value.slice(), " ");
    }
};

const Role = enum { developer, designer, manager, support };
const protocols = [_][]const u8{ "HTTPS", "HTTP", "gRPC" };
const languages = [_][]const u8{ "English", "Français", "Deutsch", "日本語", "العربية" };

const Settings = struct {
    name: TextValue = .{},
    email: TextValue = .{},
    role: Role = .developer,
    host: TextValue = .{},
    port: TextValue = .{},
    protocol: usize = 0,
    language: usize = 0,
    weekly_summary: bool = true,
    two_factor: bool = false,
    session_minutes: u32 = 30,

    const initial: Settings = .{
        .name = .of("Ada Lovelace"),
        .email = .of("ada@example.com"),
        .host = .of("api.example.com"),
        .port = .of("8443"),
    };

    fn equals(a: *const Settings, b: *const Settings) bool {
        return std.mem.eql(u8, a.name.slice(), b.name.slice()) and
            std.mem.eql(u8, a.email.slice(), b.email.slice()) and
            std.mem.eql(u8, a.host.slice(), b.host.slice()) and
            std.mem.eql(u8, a.port.slice(), b.port.slice()) and
            a.role == b.role and a.protocol == b.protocol and a.language == b.language and
            a.weekly_summary == b.weekly_summary and a.two_factor == b.two_factor and
            a.session_minutes == b.session_minutes;
    }
};

const TextField = enum { name, email, host, port };

fn problemWith(settings: *const Settings, field: TextField) ?[]const u8 {
    return switch (field) {
        .name => if (settings.name.trimmed().len == 0) "Enter the name others will see." else null,
        .email => emailProblem(settings.email.trimmed()),
        .host => if (settings.host.trimmed().len == 0)
            "Enter the server's host name."
        else if (std.mem.indexOfScalar(u8, settings.host.trimmed(), ' ') != null)
            "A host name has no spaces."
        else
            null,
        .port => portProblem(settings.port.trimmed()),
    };
}

fn emailProblem(email: []const u8) ?[]const u8 {
    if (email.len == 0) return "Enter an email address.";
    if (std.mem.indexOfScalar(u8, email, ' ') != null) return "An email address has no spaces.";
    const at = std.mem.indexOfScalar(u8, email, '@') orelse return "An email address needs an @.";
    if (at == 0 or std.mem.indexOfScalarPos(u8, email, at + 1, '@') != null) return "Use one @, with a name before it.";
    const domain = email[at + 1 ..];
    const dot = std.mem.lastIndexOfScalar(u8, domain, '.') orelse return "The domain needs a dot, as in example.com.";
    if (dot == 0 or dot + 1 == domain.len) return "The domain needs a dot, as in example.com.";
    return null;
}

fn portProblem(port: []const u8) ?[]const u8 {
    if (port.len == 0) return "Enter a port number.";
    const number = std.fmt.parseInt(u32, port, 10) catch return "A port is a whole number, such as 443.";
    if (number == 0 or number > 65535) return "A port is between 1 and 65535.";
    return null;
}

const ids = zui.ids(.{
    "settings.form",
    "settings.name",
    "settings.email",
    "settings.role",
    "settings.host",
    "settings.port",
    "settings.protocol",
    "settings.language",
    "settings.weekly",
    "settings.two_factor",
    "settings.session",
    "settings.save",
    "settings.discard",
    "settings.toast",
    "settings.right_to_left",
    "settings.high_contrast",
    "settings.reset_environment",
});

const text_scales = [_]f32{ 1, 1.5, 2 };

/// The screen, declared through `kit`, the tour's `Kit`.
pub fn Using(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;
    const EditableText = kit.zui_widgets.EditableText;
    return struct {
        pub const SettingsForm = struct {
            editing: Settings = .initial,
            saved: Settings = .initial,
            /// Fields edited since the last save, whose problems show.
            touched: std.EnumSet(TextField) = .initEmpty(),
            saves: u32 = 0,
            /// Seconds since the tour started when the last save happened.
            saved_at: ?f64 = null,

            pub fn declare(self: *SettingsForm, ui: *Ui, shell: *const Shell) void {
                shell.label(ui, .body, "An account form that stays valid, reachable by Tab, and readable at 200% text or right to left.");
                environmentStrip(ui, shell);
                ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 12 } });
                defer ui.close();
                self.form(ui, shell);
                self.sideCard(ui, shell);
            }

            fn form(self: *SettingsForm, ui: *Ui, shell: *const Shell) void {
                ui.open(.{
                    .id = ids.@"settings.form",
                    .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .child_gap = 12 },
                    .scroll = .{},
                });
                defer ui.close();
                ui.open(.{
                    .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .{ .rule = .grow, .amount = 1, .max = 820 } }, .padding = .all(20), .child_gap = 14 },
                    .decoration = .{ .background = shell.palette.surface, .border = .{ .color = shell.palette.border, .widths = .all(1) }, .corner_radius = .all(8) },
                });
                defer ui.close();
                var submitted = false;

                section(ui, shell, "Profile");
                submitted = self.textRow(ui, shell, .name, "Display name", "Shown on your comments", ids.@"settings.name") or submitted;
                submitted = self.textRow(ui, shell, .email, "Email", "name@company.com", ids.@"settings.email") or submitted;
                {
                    openRow(ui, shell, "Role");
                    defer closeRow(ui);
                    _ = shell.widgets.dropdownEnum(ui, ids.@"settings.role", &self.editing.role, .{ .label = "Role" });
                }

                shell.divider(ui);
                section(ui, shell, "Server");
                submitted = self.textRow(ui, shell, .host, "Host", "api.example.com", ids.@"settings.host") or submitted;
                submitted = self.textRow(ui, shell, .port, "Port", "443", ids.@"settings.port") or submitted;
                {
                    openRow(ui, shell, "Protocol");
                    defer closeRow(ui);
                    _ = shell.widgets.dropdown(ui, ids.@"settings.protocol", &self.editing.protocol, &protocols, .{ .label = "Protocol" });
                }

                shell.divider(ui);
                section(ui, shell, "Preferences");
                {
                    openRow(ui, shell, "Language");
                    defer closeRow(ui);
                    _ = shell.widgets.dropdown(ui, ids.@"settings.language", &self.editing.language, &languages, .{ .label = "Language" });
                }
                {
                    openRow(ui, shell, "Notifications");
                    defer closeRow(ui);
                    _ = shell.widgets.checkbox(ui, ids.@"settings.weekly", "Email me a weekly summary", &self.editing.weekly_summary, .{});
                    _ = shell.widgets.checkbox(ui, ids.@"settings.two_factor", "Ask for a second factor at sign-in", &self.editing.two_factor, .{});
                }
                {
                    openRow(ui, shell, "Sign out after");
                    defer closeRow(ui);
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 12, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    _ = shell.widgets.slider(ui, ids.@"settings.session", &self.editing.session_minutes, .{ .min = 5, .max = 240, .step = 5, .label = "Sign out after, in minutes" });
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(@round(90 * shell.text_scale)) } } });
                    shell.print(ui, .body, "{d} min", .{self.editing.session_minutes});
                    ui.close();
                }

                shell.divider(ui);
                self.footer(ui, shell, submitted);
                self.toast(ui, shell);
            }

            /// What the form is declared under right now, so a switch
            /// above shows its effect in numbers too.
            fn sideCard(self: *SettingsForm, ui: *Ui, shell: *const Shell) void {
                const palette = shell.palette;
                const environment = ui.environment();
                shell.openScrollingCard(ui, .of("settings.side"), "Declared under", .{ .width = .fixed(280), .height = .grow });
                defer ui.close();
                factRow(ui, shell, "direction", if (environment.direction == .right_to_left) "right to left" else "left to right");
                var scale_buffer: [8]u8 = undefined;
                factRow(ui, shell, "text scale", std.fmt.bufPrint(&scale_buffer, "{d:.0}%", .{environment.text_scale * 100}) catch "");
                factRow(ui, shell, "contrast", @tagName(environment.contrast));
                factRow(ui, shell, "theme", @tagName(environment.theme));
                shell.divider(ui);
                const problems = self.problemCount();
                var problems_buffer: [16]u8 = undefined;
                factRow(ui, shell, "problems", std.fmt.bufPrint(&problems_buffer, "{d}", .{problems}) catch "");
                factRow(ui, shell, "unsaved", if (self.editing.equals(&self.saved)) "no" else "yes");
                var saves_buffer: [16]u8 = undefined;
                factRow(ui, shell, "saves", std.fmt.bufPrint(&saves_buffer, "{d}", .{self.saves}) catch "");
                shell.labelColored(ui, .caption, palette.muted, "Tab walks the fields in reading order, in either direction. Enter in a field saves when the form is valid.");
            }

            fn problemCount(self: *const SettingsForm) usize {
                var count: usize = 0;
                for (std.enums.values(TextField)) |field| {
                    if (problemWith(&self.editing, field) != null) count += 1;
                }
                return count;
            }

            fn footer(self: *SettingsForm, ui: *Ui, shell: *const Shell, submitted: bool) void {
                const palette = shell.palette;
                const problems = self.problemCount();
                const changed = !self.editing.equals(&self.saved);
                const can_save = changed and problems == 0;
                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 12, .child_alignment = .{ .y = .center } } });
                defer ui.close();
                if (problems != 0) {
                    shell.printColored(ui, .body, palette.bad, "{d} {s} to fix before saving", .{ problems, if (problems == 1) "field" else "fields" });
                } else if (changed) {
                    shell.labelColored(ui, .body, palette.warn, "Unsaved changes");
                } else {
                    shell.labelColored(ui, .body, palette.muted, if (self.saves == 0) "No changes yet" else "All changes saved");
                }
                shell.spacer(ui);
                if (shell.widgets.button(ui, ids.@"settings.discard", "Discard", .{ .disabled = !changed })) {
                    self.editing = self.saved;
                    self.touched = .initEmpty();
                }
                if (shell.widgets.button(ui, ids.@"settings.save", "Save changes", .{ .disabled = !can_save }) or (submitted and can_save)) {
                    self.saved = self.editing;
                    self.touched = .initEmpty();
                    self.saves += 1;
                    self.saved_at = shell.seconds;
                }
                if (submitted and problems != 0) self.touched = .initFull();
            }

            fn toast(self: *SettingsForm, ui: *Ui, shell: *const Shell) void {
                const palette = shell.palette;
                const saved_at = self.saved_at orelse return;
                const shown_for = shell.seconds - saved_at;
                if (shown_for >= toast_seconds) {
                    self.saved_at = null;
                    return;
                }
                ui.requestFrameAt(ui.now().addSeconds(toast_seconds - shown_for));
                ui.open(.{
                    .id = ids.@"settings.toast",
                    .floating = .{ .attach_to = .{ .element = ids.@"settings.form" }, .anchor = .bottom_center, .attach_point = .bottom_center, .offset = .{ 0, -16 }, .z = 200, .capture = false },
                    .semantics = .{ .role = .label, .label = "Settings saved" },
                    .exit = .{ .seconds = 0.3, .fade = .ease_out },
                    .layout = .{ .padding = .symmetric(16, 10), .child_gap = 10, .child_alignment = .{ .y = .center } },
                    .decoration = .{ .background = palette.raised, .border = .{ .color = palette.good, .widths = .all(1) }, .corner_radius = .all(8) },
                    .effects = &.{ .shadow = .{ .color = .rgba(0x00000050), .offset = .{ 0, 6 }, .blur = 18 } },
                });
                defer ui.close();
                ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(8), .height = .fixed(8) } }, .decoration = .{ .background = palette.good, .corner_radius = .all(4) } });
                shell.label(ui, .body, "Saved");
            }

            /// Returns whether Enter was pressed in the field.
            fn textRow(self: *SettingsForm, ui: *Ui, shell: *const Shell, field: TextField, label: []const u8, placeholder: []const u8, id: zui.Id) bool {
                const palette = shell.palette;
                const value = switch (field) {
                    .name => &self.editing.name,
                    .email => &self.editing.email,
                    .host => &self.editing.host,
                    .port => &self.editing.port,
                };
                openRow(ui, shell, label);
                defer closeRow(ui);
                ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .child_gap = 4 } });
                defer ui.close();
                var text: EditableText = .{ .buffer = &value.bytes, .len = value.len };
                const result = shell.widgets.textField(ui, id, &text, .{ .placeholder = placeholder, .label = label, .width = if (field == .port) .fixed(@round(120 * shell.text_scale)) else .grow });
                value.len = text.len;
                if (result.changed) self.touched.insert(field);
                if (!self.touched.contains(field)) return result.submitted;
                if (problemWith(&self.editing, field)) |problem| shell.labelColored(ui, .caption, palette.bad, problem);
                return result.submitted;
            }
        };

        fn factRow(ui: *Ui, shell: *const Shell, name: []const u8, value: []const u8) void {
            ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8 } });
            defer ui.close();
            shell.label(ui, .caption, name);
            shell.spacer(ui);
            shell.label(ui, .body, value);
        }

        fn section(ui: *Ui, shell: *const Shell, title: []const u8) void {
            shell.label(ui, .heading, title);
        }

        /// A row with `label` in a column of its own; declare the control,
        /// then `closeRow`.
        fn openRow(ui: *Ui, shell: *const Shell, label: []const u8) void {
            ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 16 } });
            ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(@round(150 * shell.text_scale)) }, .padding = .{ .top = 6 } } });
            shell.labelColored(ui, .body, shell.palette.muted, label);
            ui.close();
            ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .child_gap = 8 } });
        }

        fn closeRow(ui: *Ui) void {
            ui.close();
            ui.close();
        }

        /// Switches that change the environment the whole tour is declared
        /// in, as the OS would.
        fn environmentStrip(ui: *Ui, shell: *const Shell) void {
            const palette = shell.palette;
            const environment = ui.environment();
            ui.open(.{
                .layout = .{ .sizing = .{ .width = .grow }, .padding = .symmetric(12, 8), .child_gap = 12, .child_alignment = .{ .y = .center } },
                .decoration = .{ .background = palette.sunken, .corner_radius = .all(8) },
            });
            defer ui.close();
            shell.labelColored(ui, .caption, palette.muted, "Environment");
            var right_to_left = environment.direction == .right_to_left;
            if (shell.widgets.checkbox(ui, ids.@"settings.right_to_left", "Right to left", &right_to_left, .{})) {
                shell.changeEnvironment(.{ .direction = if (right_to_left) .right_to_left else .left_to_right });
            }
            var high_contrast = environment.contrast == .high;
            if (shell.widgets.checkbox(ui, ids.@"settings.high_contrast", "High contrast", &high_contrast, .{})) {
                shell.changeEnvironment(.{ .contrast = if (high_contrast) .high else .normal });
            }
            shell.labelColored(ui, .caption, palette.muted, "Text size");
            for (text_scales, 0..) |scale, index| {
                const id: zui.Id = .indexed("settings.text_scale", index);
                const selected = @abs(environment.text_scale - scale) < 0.01;
                if (ui.clicked(id) and !selected) shell.changeEnvironment(.{ .text_scale = scale });
                const state = ui.widgetState(id);
                var label_buffer: [8]u8 = undefined;
                const label = std.fmt.bufPrint(&label_buffer, "{d:.0}%", .{scale * 100}) catch "";
                ui.open(.{
                    .id = id,
                    .focusable = true,
                    .cursor = .pointer,
                    .semantics = .{ .role = .radio, .label = label, .state = .{ .checked = selected } },
                    .layout = .{ .padding = .symmetric(10, 4) },
                    .decoration = .{
                        .background = if (selected) palette.accent else if (state == .hovered or state == .pressed) palette.hovered else palette.surface,
                        .border = .{ .color = if (ui.focused(id)) palette.focus else palette.border, .widths = .all(1) },
                        .corner_radius = .all(6),
                    },
                });
                shell.labelColored(ui, .caption, if (selected) palette.on_accent else palette.text, label);
                ui.close();
            }
            shell.spacer(ui);
            const changed = environment.direction != .left_to_right or environment.contrast != .normal or @abs(environment.text_scale - 1) >= 0.01;
            if (shell.widgets.button(ui, ids.@"settings.reset_environment", "Reset", .{ .disabled = !changed })) {
                shell.changeEnvironment(.{ .direction = .left_to_right });
                shell.changeEnvironment(.{ .contrast = .normal });
                shell.changeEnvironment(.{ .text_scale = 1 });
            }
        }
    };
}
