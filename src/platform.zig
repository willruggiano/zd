const c = @import("c");
pub fn errno() c_int {
    return c.__errno_location().*;
}
pub fn now() i64 {
    var time: c.timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &time) != 0) return 0;
    return time.tv_sec * 1000 + @divTrunc(time.tv_nsec, 1000000);
}
pub fn diagnostic(value: []const u8) void {
    _ = c.write(2, value.ptr, value.len);
}
