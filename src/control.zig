const std = @import("std");
const c = @import("c");
const platform = @import("platform.zig");
const sizes = @import("config.zig").sizes;

// One SOCK_SEQPACKET request and one reply per connection. Acceptance is not
// a claim of copied text. Idle peers expire and never hold the event loop.
pub const Control = struct {
    listener: c_int = -1,
    address: c.sockaddr_un = std.mem.zeroes(c.sockaddr_un),
    address_len: c.socklen_t = 0,
    clients: [sizes.control_clients]Client = @splat(.{}),
    request: [16]u8 = undefined,
    peer: c.ucred = undefined,
    peer_len: c.socklen_t = @sizeOf(c.ucred),
    const Client = struct { fd: c_int = -1, deadline: i64 = 0 };

    pub fn addressInit(self: *Control) void {
        self.address.sun_family = c.AF_UNIX;
        self.address.sun_path[0] = 0;
        const name = std.mem.print(self.address.sun_path[1..], "dictation-{d}", .{c.getuid()}) catch unreachable;
        self.address_len = @intCast(@offsetOf(c.sockaddr_un, "sun_path") + 1 + name.len);
    }
    pub fn init(self: *Control) !void {
        self.addressInit();
        self.listener = c.socket(c.AF_UNIX, c.SOCK_SEQPACKET | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0);
        if (self.listener < 0) return error.ControlSocket;
        if (c.bind(self.listener, .{ .__sockaddr_un__ = &self.address }, self.address_len) != 0) return error.ControlAlreadyRunning;
        if (c.listen(self.listener, @intCast(sizes.control_clients)) != 0) return error.ControlSocket;
    }
    pub fn deinit(self: *Control) void {
        for (&self.clients) |*client| if (client.fd >= 0) {
            _ = c.close(client.fd);
        };
        if (self.listener >= 0) _ = c.close(self.listener);
    }
    pub fn accept(self: *Control) void {
        // Bound work per iteration, even with a client flooding the listener.
        for (0..sizes.control_clients) |_| {
            const fd = c.accept4(self.listener, .{ .__sockaddr__ = null }, null, c.SOCK_NONBLOCK | c.SOCK_CLOEXEC);
            if (fd < 0) return;
            self.peer_len = @sizeOf(c.ucred);
            if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_PEERCRED, &self.peer, &self.peer_len) != 0 or self.peer.uid != c.getuid()) {
                _ = c.close(fd);
                continue;
            }
            var found = false;
            for (&self.clients) |*client| {
                if (client.fd >= 0) continue;
                client.* = .{ .fd = fd, .deadline = platform.now() + 1000 };
                found = true;
                break;
            }
            if (!found) {
                reply(fd, "busy");
                _ = c.close(fd);
            }
        }
    }
    pub fn tick(self: *Control, session: anytype, desktop: anytype, now: i64) void {
        for (&self.clients) |*client| {
            if (client.fd < 0) continue;
            const n = c.recv(client.fd, &self.request, self.request.len, c.MSG_DONTWAIT | c.MSG_TRUNC);
            if (n > 0) {
                if (n > self.request.len) reply(client.fd, "invalid") else {
                    const result = session.command(self.request[0..@intCast(n)], desktop);
                    reply(client.fd, @tagName(result));
                }
            } else if (n < 0 and platform.errno() == c.EAGAIN and now < client.deadline) continue;
            _ = c.close(client.fd);
            client.fd = -1;
        }
    }
};
fn reply(fd: c_int, value: []const u8) void {
    _ = c.send(fd, value.ptr, value.len, c.MSG_NOSIGNAL | c.MSG_DONTWAIT);
}

pub const Toggle = struct {
    fd: c_int = -1,
    pollfd: c.pollfd = .{ .fd = -1, .events = c.POLLIN, .revents = 0 },
    response: [16]u8 = undefined,
    pub fn run(self: *Toggle, control: *Control) !void {
        control.addressInit();
        self.fd = c.socket(c.AF_UNIX, c.SOCK_SEQPACKET | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0);
        if (self.fd < 0) return error.ControlSocket;
        defer _ = c.close(self.fd);
        if (c.connect(self.fd, .{ .__sockaddr_un__ = &control.address }, control.address_len) != 0) return error.DaemonUnavailable;
        if (c.send(self.fd, "toggle", 6, c.MSG_NOSIGNAL) != 6) return error.ControlSend;
        self.pollfd.fd = self.fd;
        if (c.poll(&self.pollfd, 1, 1500) <= 0) return error.ControlTimeout;
        const n = c.recv(self.fd, &self.response, self.response.len, c.MSG_TRUNC);
        if (n != 8 or !std.mem.eql(u8, self.response[0..8], "accepted")) return error.ControlRejected;
    }
};
