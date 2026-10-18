const std = @import("std");

pub const Auth = @import("auth.zig").Auth;
pub const Scope = @import("auth.zig").Scope;
pub const Rest = @import("rest.zig").Rest;
pub const Bus = @import("sse.zig").Bus;
pub const Event = @import("sse.zig").Event;
pub const Server = @import("server.zig").Server;

test {
    std.testing.refAllDecls(@This());
    _ = @import("auth.zig");
    _ = @import("rest.zig");
    _ = @import("sse.zig");
    _ = @import("server.zig");
}
