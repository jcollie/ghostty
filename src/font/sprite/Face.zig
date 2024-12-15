//! This implements the built-in "sprite face". This font renders
//! the built-in glyphs for the terminal, such as box drawing fonts, as well
//! as specific sprites that are part of our rendering model such as
//! text decorations (underlines).
//!
//! This isn't really a "font face" so much as it is quacks like a font
//! face with regards to how it works with font.Group. We don't use any
//! dynamic dispatch so it isn't truly an interface but the functions
//! and behaviors are close enough to a system face that it makes it easy
//! to integrate with font.Group. This is desirable so that higher level
//! processes such as GroupCache, Shaper, etc. don't need to be aware of
//! special sprite handling and just treat it like a normal font face.
const Face = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const font = @import("../main.zig");
const Sprite = font.sprite.Sprite;
const Box = @import("Box.zig");
const Powerline = @import("Powerline.zig");
const underline = @import("underline.zig");
const cursor = @import("cursor.zig");

const log = std.log.scoped(.font_sprite);

/// Grid metrics for rendering sprites.
metrics: font.Metrics,

/// Returns true if the codepoint exists in our sprite font.
pub fn hasCodepoint(self: Face, cp: u32, p: ?font.Presentation) bool {
    // We ignore presentation. No matter what presentation is requested
    // we always provide glyphs for our codepoints.
    _ = p;
    _ = self;
    return Kind.init(cp) != null;
}

/// Render the glyph.
pub fn renderGlyph(
    self: Face,
    alloc: Allocator,
    atlas: *font.Atlas,
    cp: u32,
    opts: font.face.RenderOptions,
) !font.Glyph {
    if (std.debug.runtime_safety) {
        if (!self.hasCodepoint(cp, null)) {
            log.err("invalid codepoint cp={x}", .{cp});
            unreachable; // crash
        }
    }

    const metrics = opts.grid_metrics orelse self.metrics;

    // We adjust our sprite width based on the cell width.
    const width = switch (opts.cell_width orelse 1) {
        0, 1 => metrics.cell_width,
        else => |width| metrics.cell_width * width,
    };

    // It should be impossible for this to be null and we assert that
    // in runtime safety modes but in case it is its not worth memory
    // corruption so we return a valid, blank glyph.
    const kind = Kind.init(cp) orelse return .{
        .width = 0,
        .height = 0,
        .offset_x = 0,
        .offset_y = 0,
        .atlas_x = 0,
        .atlas_y = 0,
        .advance_x = 0,
    };

    // Safe to ".?" because of the above assertion.
    return switch (kind) {
        .box => (Box{ .metrics = metrics }).renderGlyph(alloc, atlas, cp),

        .underline => try underline.renderGlyph(
            alloc,
            atlas,
            @enumFromInt(cp),
            width,
            metrics.cell_height,
            metrics.underline_position,
            metrics.underline_thickness,
        ),

        .strikethrough => try underline.renderGlyph(
            alloc,
            atlas,
            @enumFromInt(cp),
            width,
            metrics.cell_height,
            metrics.strikethrough_position,
            metrics.strikethrough_thickness,
        ),

        .overline => overline: {
            var g = try underline.renderGlyph(
                alloc,
                atlas,
                @enumFromInt(cp),
                width,
                metrics.cell_height,
                0,
                metrics.overline_thickness,
            );

            // We have to manually subtract the overline position
            // on the rendered glyph since it can be negative.
            g.offset_y -= metrics.overline_position;

            break :overline g;
        },

        .powerline => powerline: {
            const f: Powerline = .{
                .width = metrics.cell_width,
                .height = metrics.cell_height,
                .thickness = metrics.box_thickness,
            };

            break :powerline try f.renderGlyph(alloc, atlas, cp);
        },

        .cursor => cursor: {
            // Cursors should be drawn with the original cell height if
            // it has been adjusted larger, so they don't get stretched.
            const height, const dy = adjust: {
                const h = metrics.cell_height;
                if (metrics.original_cell_height) |original| {
                    if (h > original) {
                        break :adjust .{ original, (h - original) / 2 };
                    }
                }
                break :adjust .{ h, 0 };
            };

            var g = try cursor.renderGlyph(
                alloc,
                atlas,
                @enumFromInt(cp),
                width,
                height,
                metrics.cursor_thickness,
            );

            // Keep the cursor centered in the cell if it's shorter.
            g.offset_y += @intCast(dy);

            break :cursor g;
        },
    };
}

/// Kind of sprites we have. Drawing is implemented separately for each kind.
const Kind = enum {
    box,
    underline,
    overline,
    strikethrough,
    powerline,
    cursor,

    pub fn init(cp: u32) ?Kind {
        return switch (cp) {
            Sprite.start...Sprite.end => switch (@as(Sprite, @enumFromInt(cp))) {
                .underline,
                .underline_double,
                .underline_dotted,
                .underline_dashed,
                .underline_curly,
                => .underline,

                .overline,
                => .overline,

                .strikethrough,
                => .strikethrough,

                .cursor_rect,
                .cursor_hollow_rect,
                .cursor_bar,
                => .cursor,
            },

            // == Box fonts ==

            // "Box Drawing" block
            // ─ ━ │ ┃ ┄ ┅ ┆ ┇ ┈ ┉ ┊ ┋ ┌ ┍ ┎ ┏ ┐ ┑ ┒ ┓ └ ┕ ┖ ┗ ┘ ┙ ┚ ┛ ├ ┝ ┞ ┟ ┠
            // ┡ ┢ ┣ ┤ ┥ ┦ ┧ ┨ ┩ ┪ ┫ ┬ ┭ ┮ ┯ ┰ ┱ ┲ ┳ ┴ ┵ ┶ ┷ ┸ ┹ ┺ ┻ ┼ ┽ ┾ ┿ ╀ ╁
            // ╂ ╃ ╄ ╅ ╆ ╇ ╈ ╉ ╊ ╋ ╌ ╍ ╎ ╏ ═ ║ ╒ ╓ ╔ ╕ ╖ ╗ ╘ ╙ ╚ ╛ ╜ ╝ ╞ ╟ ╠ ╡ ╢
            // ╣ ╤ ╥ ╦ ╧ ╨ ╩ ╪ ╫ ╬ ╭ ╮ ╯ ╰ ╱ ╲ ╳ ╴ ╵ ╶ ╷ ╸ ╹ ╺ ╻ ╼ ╽ ╾ ╿
            0x2500...0x257F,

            // "Block Elements" block
            // ▀ ▁ ▂ ▃ ▄ ▅ ▆ ▇ █ ▉ ▊ ▋ ▌ ▍ ▎ ▏ ▐ ░ ▒ ▓ ▔ ▕ ▖ ▗ ▘ ▙ ▚ ▛ ▜ ▝ ▞ ▟
            0x2580...0x259F,

            // "Braille" block
            0x2800...0x28FF,

            // "Symbols for Legacy Computing" block
            // (Block Mosaics / "Sextants")
            // 🬀 🬁 🬂 🬃 🬄 🬅 🬆 🬇 🬈 🬉 🬊 🬋 🬌 🬍 🬎 🬏 🬐 🬑 🬒 🬓 🬔 🬕 🬖 🬗 🬘 🬙 🬚 🬛 🬜 🬝 🬞 🬟 🬠
            // 🬡 🬢 🬣 🬤 🬥 🬦 🬧 🬨 🬩 🬪 🬫 🬬 🬭 🬮 🬯 🬰 🬱 🬲 🬳 🬴 🬵 🬶 🬷 🬸 🬹 🬺 🬻
            // (Smooth Mosaics)
            // 🬼 🬽 🬾 🬿 🭀 🭁 🭂 🭃 🭄 🭅 🭆
            // 🭇 🭈 🭉 🭊 🭋 🭌 🭍 🭎 🭏 🭐 🭑
            // 🭒 🭓 🭔 🭕 🭖 🭗 🭘 🭙 🭚 🭛 🭜
            // 🭝 🭞 🭟 🭠 🭡 🭢 🭣 🭤 🭥 🭦 🭧
            // 🭨 🭩 🭪 🭫 🭬 🭭 🭮 🭯
            // (Block Elements)
            // 🭰 🭱 🭲 🭳 🭴 🭵 🭶 🭷 🭸 🭹 🭺 🭻
            // 🭼 🭽 🭾 🭿 🮀 🮁
            // 🮂 🮃 🮄 🮅 🮆
            // 🮇 🮈 🮉 🮊 🮋
            // (Rectangular Shade Characters)
            // 🮌 🮍 🮎 🮏 🮐 🮑 🮒
            0x1FB00...0x1FB92,
            // (Rectangular Shade Characters)
            // 🮔
            // (Fill Characters)
            // 🮕 🮖 🮗
            // (Diagonal Fill Characters)
            // 🮘 🮙
            // (Smooth Mosaics)
            // 🮚 🮛
            // (Triangular Shade Characters)
            // 🮜 🮝 🮞 🮟
            // (Character Cell Diagonals)
            // 🮠 🮡 🮢 🮣 🮤 🮥 🮦 🮧 🮨 🮩 🮪 🮫 🮬 🮭 🮮
            // (Light Solid Line With Stroke)
            // 🮯
            0x1FB94...0x1FBAF,
            // (Negative Terminal Characters)
            // 🮽 🮾 🮿
            0x1FBBD...0x1FBBF,
            // (Block Elements)
            // 🯎 🯏
            // (Character Cell Diagonals)
            // 🯐 🯑 🯒 🯓 🯔 🯕 🯖 🯗 🯘 🯙 🯚 🯛 🯜 🯝 🯞 🯟
            // (Geometric Shapes)
            // 🯠 🯡 🯢 🯣 🯤 🯥 🯦 🯧 🯨 🯩 🯪 🯫 🯬 🯭 🯮 🯯
            0x1FBCE...0x1FBEF,
            => .box,

            // Branch drawing character set, used for drawing git-like
            // graphs in the terminal. Originally implemented in Kitty.
            // Ref:
            // - https://github.com/kovidgoyal/kitty/pull/7681
            // - https://github.com/kovidgoyal/kitty/pull/7805
            // NOTE: Kitty is GPL licensed, and its code was not referenced
            //       for these characters, only the loose specification of
            //       the character set in the pull request descriptions.
            //
            //          
            //                    
            //                    
            //            
            0xF5D0...0xF60D => .box,

            // Separated Block Quadrants from Symbols for Legacy Computing Supplement
            // 𜰡 𜰢 𜰣 𜰤 𜰥 𜰦 𜰧 𜰨 𜰩 𜰪 𜰫 𜰬 𜰭 𜰮 𜰯
            0x1CC21...0x1CC2F => .box,

            // Block Octants from Symbols for Legacy Computing Supplement
            0x1CD00...0x1CDE5 => .box,

            // Powerline fonts
            0xE0B0,
            0xE0B1,
            0xE0B3,
            0xE0B4,
            0xE0B6,
            0xE0B2,
            0xE0B8,
            0xE0BA,
            0xE0BC,
            0xE0BE,
            0xE0D2,
            0xE0D4,
            => .powerline,

            else => null,
        };
    }
};

test {
    @import("std").testing.refAllDecls(@This());
}
