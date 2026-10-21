const std = @import("std");
const broker_mod = @import("../broker/broker.zig");
const auth_mod = @import("auth.zig");
const sse_mod = @import("sse.zig");
const server_mod = @import("server.zig");
const metrics_mod = @import("../obs/metrics.zig");
const logs_mod = @import("../obs/logs.zig");

/// Queue pause is per-broker state; a file-level flag is enough for the mock.
var mock_paused: bool = false;

const Mock = struct {
    fn enqueueCb(_: *anyopaque, _: []const u8, _: []const u8, _: broker_mod.EnqueueOptions, out: *broker_mod.Enqueued) anyerror!void {
        out.* = .{ .id = 7 };
    }
    fn claimCb(_: *anyopaque, _: []const u8, _: u32, _: []const u8, _: u64, _: []broker_mod.Claimed) anyerror!usize {
        return 0;
    }
    fn heartbeatCb(_: *anyopaque, _: []const u8, _: []const i64, _: []const u64, _: u64) anyerror!void {}
    fn finishCb(_: *anyopaque, _: []const u8, _: i64, _: u64) anyerror!void {}
    fn failCb(_: *anyopaque, _: []const u8, _: i64, _: u64, _: []const u8, _: bool, _: i64, _: *broker_mod.FailOutcome) anyerror!void {
        return error.Unsupported;
    }
    fn cancelCb(_: *anyopaque, _: []const u8, _: i64, _: ?u64) anyerror!void {}
    fn promoteCb(_: *anyopaque, _: []const []const u8, _: u32) anyerror!u32 {
        return 0;
    }
    fn reapCb(_: *anyopaque, _: []const []const u8, _: u32) anyerror!u32 {
        return 0;
    }
    fn depthCb(_: *anyopaque, _: []const u8, out: *broker_mod.Depth) anyerror!void {
        out.* = .{ .available = 2, .running = 1 };
    }
    fn capabilitiesCb() broker_mod.Capabilities {
        return .{ .transactional_enqueue = false, .pubsub_wakeups = false, .named_backend = "mock" };
    }
    fn deinitCb(_: *anyopaque) void {}
    fn pauseQueueCb(_: *anyopaque, _: []const u8) anyerror!void {
        mock_paused = true;
    }
    fn resumeQueueCb(_: *anyopaque, _: []const u8) anyerror!void {
        mock_paused = false;
    }
    fn queuePausedCb(_: *anyopaque, _: []const u8) anyerror!bool {
        return mock_paused;
    }
    const vt = broker_mod.VTable{
        .enqueue = enqueueCb,
        .claim = claimCb,
        .heartbeat = heartbeatCb,
        .finish = finishCb,
        .fail = failCb,
        .cancel = cancelCb,
        .promote = promoteCb,
        .reap = reapCb,
        .depth = depthCb,
        .capabilities = capabilitiesCb,
        .deinit = deinitCb,
        .pause_queue = pauseQueueCb,
        .resume_queue = resumeQueueCb,
        .queue_paused = queuePausedCb,
    };
};

fn get(alloc: std.mem.Allocator, port: u16, path: []const u8, extra: []const std.http.Header) !struct { status: std.http.Status, body: []u8 } {
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();
    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}{s}", .{ port, path });
    const uri = try std.Uri.parse(url);
    var head_buf: [16 * 1024]u8 = undefined;
    var req = try client.open(.GET, uri, .{ .server_header_buffer = &head_buf, .extra_headers = extra });
    defer req.deinit();
    try req.send();
    try req.finish();
    try req.wait();
    const status = req.response.status;
    var body = std.ArrayList(u8).init(alloc);
    errdefer body.deinit();
    try req.reader().readAllArrayList(&body, 1024 * 1024);
    return .{ .status = status, .body = try body.toOwnedSlice() };
}

fn post(alloc: std.mem.Allocator, port: u16, path: []const u8, payload: []const u8, extra: []const std.http.Header) !struct { status: std.http.Status, body: []u8 } {
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();
    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}{s}", .{ port, path });
    const uri = try std.Uri.parse(url);
    var head_buf: [16 * 1024]u8 = undefined;
    var all_extra = std.ArrayList(std.http.Header).init(alloc);
    defer all_extra.deinit();
    try all_extra.append(.{ .name = "content-type", .value = "application/json" });
    for (extra) |h| try all_extra.append(h);
    var req = try client.open(.POST, uri, .{ .server_header_buffer = &head_buf, .extra_headers = all_extra.items });
    defer req.deinit();
    req.transfer_encoding = .{ .content_length = payload.len };
    try req.send();
    try req.writeAll(payload);
    try req.finish();
    try req.wait();
    const status = req.response.status;
    var body = std.ArrayList(u8).init(alloc);
    errdefer body.deinit();
    try req.reader().readAllArrayList(&body, 1024 * 1024);
    return .{ .status = status, .body = try body.toOwnedSlice() };
}

fn getFull(alloc: std.mem.Allocator, port: u16, path: []const u8, extra: []const std.http.Header) !struct { status: std.http.Status, body: []u8, location: []u8 } {
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();
    var url_buf: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}{s}", .{ port, path });
    const uri = try std.Uri.parse(url);
    var head_buf: [16 * 1024]u8 = undefined;
    var req = try client.open(.GET, uri, .{ .server_header_buffer = &head_buf, .extra_headers = extra, .redirect_behavior = .unhandled });
    defer req.deinit();
    try req.send();
    try req.finish();
    try req.wait();
    const status = req.response.status;
    var location: []u8 = "";
    var it = req.response.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "location")) location = try alloc.dupe(u8, h.value);
    }
    var body = std.ArrayList(u8).init(alloc);
    errdefer body.deinit();
    try req.reader().readAllArrayList(&body, 1024 * 1024);
    return .{ .status = status, .body = try body.toOwnedSlice(), .location = location };
}

test "oidc: unconfigured is 404, configured redirects with state and pkce" {
    const alloc = std.testing.allocator;
    var m: u8 = 0;
    const br = broker_mod.Broker{ .ptr = &m, .vtable = &Mock.vt };
    var auth = auth_mod.Auth.init(alloc, "testsecret", false);
    defer auth.deinit();
    var bus = sse_mod.Bus.init(alloc);
    defer bus.deinit();
    var metrics = metrics_mod.Metrics.init(alloc);
    defer metrics.deinit();
    var log = logs_mod.Logger.init(std.io.getStdErr());

    const port: u16 = 19485;
    var srv = server_mod.Server.init(alloc, br, &auth, &bus, &metrics, &log, &.{"default"}, "127.0.0.1:19485", false, true);
    try srv.start();
    defer srv.stopServer();
    std.time.sleep(150 * std.time.ns_per_ms);

    // No provider configured: the SSO entry points do not exist.
    {
        const r = try getFull(alloc, port, "/auth/oidc", &.{});
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.not_found, r.status);
    }

    auth.oidc = .{
        .issuer = "https://idp.example.com",
        .authorize_endpoint = "https://idp.example.com/authorize",
        .token_endpoint = "http://127.0.0.1:1/token",
        .userinfo_endpoint = "http://127.0.0.1:1/userinfo",
        .client_id = "beanline",
        .redirect_uri = "http://127.0.0.1:19485/auth/oidc/callback",
    };

    // The UI now advertises SSO and no longer requires a password user.
    {
        const r = try get(alloc, port, "/", &.{});
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.ok, r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "sign in with SSO") != null);
    }
    // Anonymous reads are now gated (OIDC counts as configured auth).
    {
        const r = try get(alloc, port, "/api/queues", &.{});
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.unauthorized, r.status);
    }
    // Start redirects to the provider with state and PKCE.
    {
        const r = try getFull(alloc, port, "/auth/oidc", &.{});
        defer alloc.free(r.body);
        defer alloc.free(r.location);
        try std.testing.expectEqual(std.http.Status.see_other, r.status);
        try std.testing.expect(std.mem.startsWith(u8, r.location, "https://idp.example.com/authorize?"));
        try std.testing.expect(std.mem.indexOf(u8, r.location, "response_type=code") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.location, "code_challenge_method=S256") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.location, "redirect_uri=http%3A%2F%2F127.0.0.1%3A19485%2Fauth%2Foidc%2Fcallback") != null);
    }
    // A callback without code/state is a bad request; a bogus state is
    // rejected before any provider call.
    {
        const r = try get(alloc, port, "/auth/oidc/callback", &.{});
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.bad_request, r.status);
    }
    {
        const r = try get(alloc, port, "/auth/oidc/callback?code=abc&state=0011", &.{});
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.bad_request, r.status);
    }
    // A provider-reported error (user declined consent) is unauthorized.
    {
        const r = try get(alloc, port, "/auth/oidc/callback?error=access_denied", &.{});
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.unauthorized, r.status);
    }
}

test "live http smoke: healthz, api, auth gate, metrics" {
    const alloc = std.testing.allocator;
    var m: u8 = 0;
    const br = broker_mod.Broker{ .ptr = &m, .vtable = &Mock.vt };
    var auth = auth_mod.Auth.init(alloc, "testsecret", false);
    defer auth.deinit();
    try auth.addUser("ops:hunter2:admin");
    try auth.addKey("metrics:testsecret:jobs_read");
    var bus = sse_mod.Bus.init(alloc);
    defer bus.deinit();
    var metrics = metrics_mod.Metrics.init(alloc);
    defer metrics.deinit();
    metrics.incrEnqueued("emails.send", "mailers");
    var log = logs_mod.Logger.init(std.io.getStdErr());

    const port: u16 = 19484;
    var srv = server_mod.Server.init(alloc, br, &auth, &bus, &metrics, &log, &.{"default"}, "127.0.0.1:19484", false, true);
    try srv.start();
    defer srv.stopServer();
    std.time.sleep(150 * std.time.ns_per_ms);

    // healthz is open
    {
        const r = try get(alloc, port, "/healthz", &.{});
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.ok, r.status);
    }
    // readyz is open
    {
        const r = try get(alloc, port, "/readyz", &.{});
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.ok, r.status);
    }
    // metrics has our counter
    {
        const r = try get(alloc, port, "/metrics", &.{.{ .name = "authorization", .value = "Bearer metrics.testsecret" }});
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.ok, r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "beanline_jobs_enqueued_total{kind=\"emails.send\"} 1") != null);
    }
    // protected read is gated
    {
        const r = try get(alloc, port, "/api/queues", &.{});
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.unauthorized, r.status);
    }
    // UI page serves
    {
        const r = try get(alloc, port, "/", &.{});
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.ok, r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "beanline dashboard") != null);
    }
    // login succeeds and returns a csrf token (cookie session verified via
    // the auth unit tests; the API-key path below covers authed reads).
    {
        const r = try post(alloc, port, "/login", "{\"username\":\"ops\",\"password\":\"hunter2\"}", &.{});
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.ok, r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"ok\":true") != null);
        const ci = std.mem.indexOf(u8, r.body, "\"csrf\":\"") orelse return error.TestUnexpectedResult;
        try std.testing.expect(ci + 8 < r.body.len);
    }
    // bad password is rejected
    {
        const r = try post(alloc, port, "/login", "{\"username\":\"ops\",\"password\":\"nope\"}", &.{});
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.unauthorized, r.status);
    }
    // API key grants access
    try auth.addKey("t1:s3krit:jobs_read,jobs_write,queues_control");
    {
        const r = try get(alloc, port, "/api/queues", &.{.{ .name = "authorization", .value = "Bearer t1.s3krit" }});
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.ok, r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"name\":\"default\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"available\":2") != null);
    }
    // enqueue via API
    {
        const r = try post(alloc, port, "/api/enqueue", "{\"kind\":\"emails.send\",\"args\":{\"to\":\"a\"}}", &.{.{ .name = "authorization", .value = "Bearer t1.s3krit" }});
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.ok, r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"id\":7") != null);
    }
}

test "api authorization matrix: scopes gate reads, writes, and the event stream" {
    const alloc = std.testing.allocator;
    var m: u8 = 0;
    const br = broker_mod.Broker{ .ptr = &m, .vtable = &Mock.vt };
    var auth = auth_mod.Auth.init(alloc, "testsecret", false);
    defer auth.deinit();
    try auth.addUser("ops:hunter2:admin");
    try auth.addKey("rk:readsecret:jobs_read");
    try auth.addKey("wk:writesecret:jobs_write");
    try auth.addKey("ck:controlsecret:queues_control");
    var bus = sse_mod.Bus.init(alloc);
    defer bus.deinit();
    var metrics = metrics_mod.Metrics.init(alloc);
    defer metrics.deinit();
    var log = logs_mod.Logger.init(std.io.getStdErr());

    const port: u16 = 19486;
    var srv = server_mod.Server.init(alloc, br, &auth, &bus, &metrics, &log, &.{"default"}, "127.0.0.1:19486", false, true);
    try srv.start();
    defer srv.stopServer();
    std.time.sleep(150 * std.time.ns_per_ms);

    const read_key = [_]std.http.Header{.{ .name = "authorization", .value = "Bearer rk.readsecret" }};
    const write_key = [_]std.http.Header{.{ .name = "authorization", .value = "Bearer wk.writesecret" }};
    const control_key = [_]std.http.Header{.{ .name = "authorization", .value = "Bearer ck.controlsecret" }};
    const payload = "{\"kind\":\"emails.send\",\"args\":{}}";

    // Anonymous: reads, writes, and the event stream all require auth.
    {
        const r = try get(alloc, port, "/api/queues", &.{});
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.unauthorized, r.status);
    }
    {
        const r = try get(alloc, port, "/api/live", &.{});
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.unauthorized, r.status);
    }
    {
        const r = try post(alloc, port, "/api/enqueue", payload, &.{});
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.unauthorized, r.status);
    }
    // jobs_read: may read, may not enqueue or retry.
    {
        const r = try get(alloc, port, "/api/queues", &read_key);
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.ok, r.status);
    }
    {
        const r = try post(alloc, port, "/api/enqueue", payload, &read_key);
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.forbidden, r.status);
    }
    {
        const r = try post(alloc, port, "/api/jobs/7/retry", "{}", &read_key);
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.forbidden, r.status);
    }
    // jobs_write implies jobs_read, and permits enqueue.
    {
        const r = try get(alloc, port, "/api/queues", &write_key);
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.ok, r.status);
    }
    {
        const r = try post(alloc, port, "/api/enqueue", payload, &write_key);
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.ok, r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"id\":7") != null);
    }
    // queues_control does not grant reads or writes.
    {
        const r = try get(alloc, port, "/api/queues", &control_key);
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.forbidden, r.status);
    }
    {
        const r = try get(alloc, port, "/api/live", &control_key);
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.forbidden, r.status);
    }
    {
        const r = try post(alloc, port, "/api/enqueue", payload, &control_key);
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.forbidden, r.status);
    }
    // A bad key is treated as anonymous.
    {
        const r = try get(alloc, port, "/api/queues", &.{.{ .name = "authorization", .value = "Bearer rk.wrong" }});
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.unauthorized, r.status);
    }
}

test "readonly mode blocks api key mutations" {
    const alloc = std.testing.allocator;
    var m: u8 = 0;
    const br = broker_mod.Broker{ .ptr = &m, .vtable = &Mock.vt };
    var auth = auth_mod.Auth.init(alloc, "testsecret", true);
    defer auth.deinit();
    try auth.addKey("wk:writesecret:jobs_write");
    var bus = sse_mod.Bus.init(alloc);
    defer bus.deinit();
    var metrics = metrics_mod.Metrics.init(alloc);
    defer metrics.deinit();
    var log = logs_mod.Logger.init(std.io.getStdErr());

    const port: u16 = 19487;
    var srv = server_mod.Server.init(alloc, br, &auth, &bus, &metrics, &log, &.{"default"}, "127.0.0.1:19487", true, true);
    try srv.start();
    defer srv.stopServer();
    std.time.sleep(150 * std.time.ns_per_ms);

    const write_key = [_]std.http.Header{.{ .name = "authorization", .value = "Bearer wk.writesecret" }};
    {
        const r = try get(alloc, port, "/api/queues", &write_key);
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.ok, r.status);
    }
    {
        const r = try post(alloc, port, "/api/enqueue", "{\"kind\":\"emails.send\",\"args\":{}}", &write_key);
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.forbidden, r.status);
    }
}

test "queue pause and resume: control scope, method, and reflected state" {
    const alloc = std.testing.allocator;
    mock_paused = false;
    var m: u8 = 0;
    const br = broker_mod.Broker{ .ptr = &m, .vtable = &Mock.vt };
    var auth = auth_mod.Auth.init(alloc, "testsecret", false);
    defer auth.deinit();
    try auth.addKey("rk:readsecret:jobs_read");
    try auth.addKey("ck:controlsecret:queues_control");
    var bus = sse_mod.Bus.init(alloc);
    defer bus.deinit();
    var metrics = metrics_mod.Metrics.init(alloc);
    defer metrics.deinit();
    var log = logs_mod.Logger.init(std.io.getStdErr());

    const port: u16 = 19488;
    var srv = server_mod.Server.init(alloc, br, &auth, &bus, &metrics, &log, &.{"default"}, "127.0.0.1:19488", false, true);
    try srv.start();
    defer srv.stopServer();
    std.time.sleep(150 * std.time.ns_per_ms);

    const read_key = [_]std.http.Header{.{ .name = "authorization", .value = "Bearer rk.readsecret" }};
    const control_key = [_]std.http.Header{.{ .name = "authorization", .value = "Bearer ck.controlsecret" }};

    // Anonymous is gated; jobs_read is not queue control.
    {
        const r = try post(alloc, port, "/api/queues/default/pause", "", &.{});
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.unauthorized, r.status);
    }
    {
        const r = try post(alloc, port, "/api/queues/default/pause", "", &read_key);
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.forbidden, r.status);
    }
    // The control route is gated on queues_control, even for wrong verbs.
    {
        const r = try get(alloc, port, "/api/queues/default/pause", &control_key);
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.method_not_allowed, r.status);
    }
    {
        const r = try get(alloc, port, "/api/queues/default/pause", &read_key);
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.forbidden, r.status);
    }
    // Pause flips the state, and GET /api/queues reports it.
    {
        const r = try post(alloc, port, "/api/queues/default/pause", "", &control_key);
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.ok, r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"paused\":true") != null);
    }
    {
        const r = try get(alloc, port, "/api/queues", &read_key);
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.ok, r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"paused\":true") != null);
    }
    // Resume clears it.
    {
        const r = try post(alloc, port, "/api/queues/default/resume", "", &control_key);
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.ok, r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"paused\":false") != null);
    }
    {
        const r = try get(alloc, port, "/api/queues", &read_key);
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.ok, r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"paused\":false") != null);
    }
    // Unknown verbs and empty names are 404.
    {
        const r = try post(alloc, port, "/api/queues/default/stop", "", &control_key);
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.not_found, r.status);
    }
    {
        const r = try post(alloc, port, "/api/queues//pause", "", &control_key);
        defer alloc.free(r.body);
        try std.testing.expectEqual(std.http.Status.not_found, r.status);
    }
}
