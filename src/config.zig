const std = @import("std");
const options = @import("options.zig");
pub const Sizes = struct {
    transcript_bytes: usize = 1048576,
    control_clients: usize = 8,
    clipboard_slots: usize = 3,
    transfers: usize = 8,

    pub fn validate(self: Sizes) !void {
        _ = try std.math.mul(usize, self.transcript_bytes, try std.math.add(usize, self.clipboard_slots, 1));
        if (self.transcript_bytes == 0 or self.transcript_bytes > 64 * 1024 * 1024) return error.InvalidTranscriptCapacity;
        if (self.control_clients == 0 or self.control_clients > 64) return error.InvalidControlCapacity;
        if (self.clipboard_slots < 2 or self.clipboard_slots > 8) return error.InvalidClipboardSlots;
        if (self.transfers == 0 or self.transfers > 64) return error.InvalidTransferCapacity;
    }
};
pub const sizes: Sizes = .{
    .transcript_bytes = options.transcript_bytes,
    .control_clients = options.control_clients,
    .clipboard_slots = options.clipboard_slots,
    .transfers = options.transfers,
};
comptime {
    sizes.validate() catch |err| @compileError(@errorName(err));
}
