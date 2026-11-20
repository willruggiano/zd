// Bounded clipboard serving shared by native Wayland and deterministic I/O tests.
// Sources are single-use protocol identities. Cancelling one relinquishes ownership,
// not already requested transfers. Only the last user may clear/recycle its bytes.
pub const idle_timeout_ms = 5000;
pub const write_budget = 65536;
pub const Write = union(enum) { progress: usize, blocked, failed };

pub fn Clipboard(comptime capacity: usize, comptime slots: usize, comptime readers: usize, comptime Source: type) type {
    return struct {
        const Self = @This();
        offers: [slots]Offer = @splat(.{}),
        transfers: [readers]Transfer = @splat(.{}),

        const Offer = struct {
            source: ?Source = null,
            bytes: [capacity]u8 = undefined,
            len: usize = 0,
            pins: usize = 0,

            fn release(self: *Offer) void {
                if (self.source == null and self.pins == 0) {
                    @memset(self.bytes[0..self.len], 0);
                    self.len = 0;
                }
            }
        };
        const Transfer = struct {
            fd: i32 = -1,
            offer: usize = 0,
            offset: usize = 0,
            deadline: i64 = 0,
        };

        // io creates/destroys native sources and queues selection; no borrowed text
        // escapes publish. A full table must not unset or destroy the old selection.
        pub fn publish(self: *Self, value: []const u8, io: anytype) bool {
            if (value.len == 0 or value.len > capacity) return false;
            for (&self.offers) |*offer| {
                if (offer.source != null or offer.pins != 0) continue;
                const source = io.create() orelse return false;
                offer.source = source;
                @memcpy(offer.bytes[0..value.len], value);
                offer.len = value.len;
                if (!io.select(source)) {
                    io.destroy(source);
                    offer.source = null;
                    offer.release();
                    return false;
                }
                return true;
            }
            return false;
        }

        pub fn cancelled(self: *Self, source: Source, io: anytype) void {
            for (&self.offers) |*offer| {
                if (offer.source != source) continue;
                io.destroy(source);
                offer.source = null;
                offer.release();
                return;
            }
        }

        // Always consumes fd, including rejected/unsupported requests. prepare
        // must establish nonblocking I/O before a transfer is allowed onto tick.
        pub fn send(self: *Self, source: Source, fd: i32, now: i64, io: anytype) void {
            for (&self.offers, 0..) |*offer, index| {
                if (offer.source != source) continue;
                for (&self.transfers) |*transfer| {
                    if (transfer.fd >= 0) continue;
                    if (!io.prepare(fd)) break;
                    transfer.* = .{ .fd = fd, .offer = index, .deadline = now + idle_timeout_ms };
                    offer.pins += 1;
                    return;
                }
                break;
            }
            io.close(fd);
        }

        pub fn tick(self: *Self, now: i64, io: anytype) void {
            for (&self.transfers) |*transfer| {
                if (transfer.fd < 0) continue;
                // Expire before attempting I/O: activity after the deadline must
                // not resurrect an abandoned request and pin its source forever.
                if (now >= transfer.deadline) {
                    self.close(transfer, io);
                    continue;
                }
                const offer = &self.offers[transfer.offer];
                const remaining = offer.bytes[transfer.offset..offer.len];
                switch (io.write(transfer.fd, remaining[0..@min(remaining.len, write_budget)])) {
                    .progress => |n| {
                        // A zero-length write is no progress, just like EAGAIN/EINTR.
                        if (n > 0) {
                            transfer.offset += n;
                            transfer.deadline = now + idle_timeout_ms;
                        }
                        if (transfer.offset == offer.len) self.close(transfer, io);
                    },
                    .blocked => {},
                    .failed => self.close(transfer, io),
                }
            }
        }

        fn close(self: *Self, transfer: *Transfer, io: anytype) void {
            io.close(transfer.fd);
            const offer = &self.offers[transfer.offer];
            offer.pins -= 1;
            offer.release();
            transfer.* = .{};
        }

        pub fn deinit(self: *Self, io: anytype) void {
            for (&self.transfers) |*transfer| {
                if (transfer.fd >= 0) self.close(transfer, io);
            }
            for (&self.offers) |*offer| {
                if (offer.source) |source| io.destroy(source);
                offer.source = null;
                offer.release();
            }
        }
    };
}
