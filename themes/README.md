# zui_themes

The design languages of the desktops zui runs on, each a
`zui.design.Design` an application resolves with `zui_design` in place
of `zui_design.default`. A design is data in the core's vocabulary, so
the module imports only `zui`.

| Design | Language | Accent | Body text | Corners |
|---|---|---|---|---|
| `zui_themes.fluent` | Windows 11's Fluent 2, as WinUI 3 draws it | #0078D4 | 14 on a 1.2 scale | 4 for controls and cards, 8 for flyouts and dialogs |
| `zui_themes.libadwaita` | GNOME's, as libadwaita draws it | #3584E4 | Adwaita Sans' 11 pt, 14.67, on a 1.18 scale | 8 for buttons, 16 for cards and popovers, pill chips |
| `zui_themes.breeze` | KDE Plasma's Breeze | #3DAEE9 | Noto Sans' 10 pt, 13.33, on a 1.16 scale | 4 everywhere |

Each changes the default's seeds (its accent, its neutral and its status
hues), its type scale, its shape roles and corner shape, its density
table where the language spaces differently, and its motion, and keeps
every tone, so each meets the same contrast targets as the default in
light, dark and high contrast at every density. Each value's source is
in its design's doc comment: learn.microsoft.com's Windows design pages
for Fluent; libadwaita's stylesheets (`_colors.scss`, `_palette.scss`,
`_common.scss`, `widgets/_labels.scss`), its CSS variables and
`org.gnome.desktop.interface` for libadwaita; Breeze's colour schemes
and `breezemetrics.h`, Kirigami's `Units` and `Heading`, and
plasma-integration's default fonts for Breeze. The accent seeds are the
sRGB colors converted to OKLCH, which the tests check against
`zui_color`'s conversion.

## Using one

Fill in the application's fonts, then resolve the design whenever the
preferences change, as with the default:

```zig
const app_design: zui.design.Design = design: {
    var language = switch (builtin.os.tag) {
        .windows => zui_themes.fluent,
        else => zui_themes.libadwaita,
    };
    language.type.fonts = .{
        .regular = @intFromEnum(FontId.body),
        .strong = @intFromEnum(FontId.body_bold),
        .monospace = @intFromEnum(FontId.mono),
    };
    break :design language;
};

const preferences: zui_design.Preferences = .from(ui.environment(), app.choices);
if (!std.meta.eql(preferences, app.preferences)) {
    app.preferences = preferences;
    _ = zui_design.resolve(app_design, preferences, &app.tokens);
}
```

The user's accent, which the Windows and Linux hosts report in
`zui.Environment.accent`, replaces the design's accent seed through
`Preferences.from`, and an accent in `zui_design.Choices` replaces both.

The package is reached by path, naming the repository's `themes/`
directory in the application's `build.zig.zon`, and its module is
`zui_themes`.

## Limits

- **No fonts are bundled.** Segoe UI, Adwaita Sans and Noto Sans are the
  systems' own, so each design sizes the application's fonts to the
  language's x-height when it gives their faces (`Design.type.faces`),
  or draws them at the language's body size when it does not.
- **Corners come in five sizes.** A shape role takes a `CornerSize`, so
  libadwaita's 9-unit buttons draw at 8 and its 12- and 15-unit cards
  and popovers at 16; Breeze's 5 draws at 4.
- **Tones are the resolver's.** A design changes seeds, never a tone, so
  each language's surfaces and text take the default's lightness on the
  language's hues. Fluent's success hue is moved from WinUI's 143 to 148
  so that, at those tones, it stays apart from danger under tritanopia.
- **Motion** takes the language's durations and the nearest of
  `zui.motion.Easing`'s curves; the springs are the default's, and no
  control scales when pressed, as none does in these languages.
- macOS's design is `14-macos:03-macos-skin`.

## Building

```sh
zig build test    # resolves each design in every scheme and density, at comptime too
zig build check
```

The tests import `zui_design` and `zui_color`; the `zui_themes` module
does not.
