const terminal = @import("../terminal/main.zig");

pub fn CursorPosition(comptime T: type) type {
    return struct {
        x: terminal.size.CellCountInt = 0,
        y: terminal.size.CellCountInt = 0,

        pub fn update(
            self: *CursorPosition(T),
            x: terminal.size.CellCountInt,
            y: terminal.size.CellCountInt,
        ) void {
            const renderer: *T = @alignCast(@fieldParentPtr("cursor_position", self));

            if (self.x != x or self.y != y) {
                _ = renderer.surface_mailbox.push(
                    .{
                        .report_cursor_position = .{
                            .x = x,
                            .y = y,
                        },
                    },
                    .{ .instant = {} },
                );
            }

            self.x = x;
            self.y = y;
        }
    };
}
