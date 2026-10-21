const std = @import("std");
const http = std.http;
const broker_mod = @import("../broker/broker.zig");
const auth_mod = @import("auth.zig");
const rest_mod = @import("rest.zig");
const sse_mod = @import("sse.zig");
const metrics_mod = @import("../obs/metrics.zig");
const logs_mod = @import("../obs/logs.zig");

const index_html = @embedFile("ui/index.html");

/// Embedded dashboard + REST API server. Serves, from the same binary:
/// the no-build HTML UI, the /api/* REST endpoints, the /api/live SSE
/// stream, /metrics (Prometheus), /healthz and /readyz. Auth: session cookie
/// for the UI, Bearer API keys for the API, CSRF on mutating UI posts.
pub const Server = struct {
    alloc: std.mem.Allocator,
    broker: broker_mod.Broker,
    auth: *auth_mod.Auth,
    rest: rest_mod.Rest,
    bus: *sse_mod.Bus,
    metrics: *metrics_mod.Metrics,
    log: *logs_mod.Logger,
    queue_names: []const []const u8,
    bind: []const u8,
    readonly: bool,
    net_server: ?std.net.Server = null,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    broken_broker: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    broken_since_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    max_conns: u32 = 256,
    active_conns: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub const Role = struct {
        auth: *auth_mod.Auth,
        queue_names: []const []const u8,
    };

    pub fn init(
        alloc: std.mem.Allocator,
        broker: broker_mod.Broker,
        auth: *auth_mod.Auth,
        bus: *sse_mod.Bus,
        metrics: *metrics_mod.Metrics,
        log: *logs_mod.Logger,
        queue_names: []const []const u8,
        bind: []const u8,
        readonly: bool,
    ) Server {
        return .{
            .alloc = alloc,
            .broker = broker,
            .auth = auth,
            .rest = rest_mod.Rest.init(alloc, broker),
            .bus = bus,
            .metrics = metrics,
            .log = log,
            .queue_names = queue_names,
            .bind = bind,
            .readonly = readonly,
        };
    }

    fn parseBind(bind: []const u8) !std.net.Address {
        const colon = std.mem.lastIndexOfScalar(u8, bind, ':') orelse return error.BadBind;
        const host = bind[0..colon];
        const port = std.fmt.parseInt(u16, bind[colon + 1 ..], 10) catch return error.BadBind;
        return std.net.Address.parseIp(host, port) catch {
            return std.net.Address.resolveIp(host, port) catch return error.BadBind;
        };
    }

    pub fn start(self: *Server) !void {
        if (std.mem.startsWith(u8, self.bind, "0.0.0.0") and
            self.auth.users.items.len == 0 and self.auth.keys.items.len == 0 and !self.auth.oidcEnabled())
        {
            self.log.warn("dashboard bound to 0.0.0.0 with NO auth configured — refusing to listen on all interfaces; bind 127.0.0.1 or set BEANLINE_DASH_USERS/BEANLINE_DASH_KEYS/BEANLINE_DASH_OIDC_*", .{});
            return error.AuthRequiredForPublicBind;
        }
        const addr = try parseBind(self.bind);
        const srv = try addr.listen(.{ .reuse_address = true });
        self.net_server = srv;
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        self.log.info("dashboard listening on {s}", .{self.bind});
    }

    pub fn stopServer(self: *Server) void {
        // The accept loop polls its listener on a short timeout and re-checks
        // `stop`, so all this needs to do is raise the flag and join. Closing
        // the listener first would race the loop's own accept().
        self.stop.store(true, .seq_cst);
        if (self.thread) |th| {
            th.join();
            self.thread = null;
        }
        if (self.net_server) |*srv| {
            srv.deinit();
            self.net_server = null;
        }
    }

    fn acceptLoop(self: *Server) void {
        if (self.net_server == null) return;
        const srv = &self.net_server.?;
        // Poll before accepting instead of blocking in accept(). close() does
        // not reliably wake a thread parked in accept() on every platform
        // (macOS in particular), and the previous self-connect wakeup was
        // racy: whenever the loop was busy handling a connection rather than
        // parked in accept(), the wakeup sat unread in the backlog and the
        // join depended on the connection happening to drain first. A bounded
        // poll makes shutdown deterministic everywhere, at the cost of one
        // poll syscall per idle tick.
        var fds = [_]std.posix.pollfd{.{
            .fd = srv.stream.handle,
            .events = std.posix.POLL.IN,
            .revents = undefined,
        }};
        while (!self.stop.load(.seq_cst)) {
            // A failed poll is not worth distinguishing: the stop flag below
            // decides whether to keep going, and the error sets differ per
            // platform (EINTR on posix, nothing extra on Windows).
            const ready = std.posix.poll(&fds, 100) catch {
                if (self.stop.load(.seq_cst)) return;
                continue;
            };
            if (ready == 0) continue;
            if (fds[0].revents & std.posix.POLL.IN == 0) continue;
            const conn = srv.accept() catch {
                if (self.stop.load(.seq_cst)) return;
                continue;
            };
            if (self.stop.load(.seq_cst)) {
                conn.stream.close();
                return;
            }
            if (self.active_conns.load(.seq_cst) >= self.max_conns) {
                conn.stream.close();
                continue;
            }
            _ = self.active_conns.fetchAdd(1, .seq_cst);
            const th = std.Thread.spawn(.{}, handleConnThread, .{ self, conn }) catch {
                _ = self.active_conns.fetchSub(1, .seq_cst);
                conn.stream.close();
                continue;
            };
            th.detach();
        }
    }

    fn handleConnThread(self: *Server, conn: std.net.Server.Connection) void {
        defer _ = self.active_conns.fetchSub(1, .seq_cst);
        self.handleConn(conn) catch {};
    }

    fn setTimeouts(fd: std.posix.socket_t) void {
        const tv = std.posix.timeval{ .sec = 30, .usec = 0 };
        const bytes = std.mem.asBytes(&tv);
        const level: i32 = switch (@import("builtin").os.tag) {
            .windows => 0xffff,
            else => 1,
        };
        const rcv: u32 = switch (@import("builtin").os.tag) {
            .windows => 0x1006,
            .macos, .ios, .tvos, .watchos => 0x1006,
            else => 20,
        };
        const snd: u32 = switch (@import("builtin").os.tag) {
            .windows => 0x1005,
            .macos, .ios, .tvos, .watchos => 0x1005,
            else => 21,
        };
        std.posix.setsockopt(fd, level, rcv, bytes) catch {};
        std.posix.setsockopt(fd, level, snd, bytes) catch {};
    }

    fn handleConn(self: *Server, conn: std.net.Server.Connection) !void {
        setTimeouts(conn.stream.handle);
        defer conn.stream.close();
        // A keep-alive client that has finished its request stays connected
        // waiting for another head; without a stop check the accept thread
        // would block in receiveHead() forever and stopServer()'s join would
        // hang. The stop flag is the shutdown signal for this thread too.
        if (self.stop.load(.seq_cst)) return;
        var read_buf: [32 * 1024]u8 = undefined;
        var srv = std.http.Server.init(conn, &read_buf);
        while (srv.state == .ready) {
            var req = srv.receiveHead() catch return;
            self.route(&req) catch |e| {
                self.respondStatus(&req, .internal_server_error, @errorName(e)) catch {};
                return;
            };
            if (srv.state != .ready or self.stop.load(.seq_cst)) return;
        }
    }

    fn respondStatus(self: *Server, req: *http.Server.Request, code: http.Status, body: []const u8) !void {
        _ = self;
        try req.respond(body, .{ .status = code });
    }

    fn jsonResponse(self: *Server, req: *http.Server.Request, code: http.Status, body: []const u8, extra: []const http.Header) !void {
        _ = self;
        var hdrs = std.ArrayList(http.Header).init(std.heap.page_allocator);
        defer hdrs.deinit();
        try hdrs.append(.{ .name = "content-type", .value = "application/json" });
        try hdrs.append(.{ .name = "cache-control", .value = "no-store" });
        for (extra) |h| try hdrs.append(h);
        try req.respond(body, .{ .status = code, .extra_headers = hdrs.items });
    }

    fn htmlResponse(self: *Server, req: *http.Server.Request, body: []const u8) !void {
        _ = self;
        try req.respond(body, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
                .{ .name = "content-security-policy", .value = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'" },
                .{ .name = "x-frame-options", .value = "DENY" },
                .{ .name = "x-content-type-options", .value = "nosniff" },
            },
        });
    }

    fn headerVal(req: *http.Server.Request, name: []const u8) ?[]const u8 {
        var it = req.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    fn cookieVal(req: *http.Server.Request, name: []const u8) ?[]const u8 {
        const c = headerVal(req, "cookie") orelse return null;
        var it = std.mem.splitScalar(u8, c, ';');
        while (it.next()) |part| {
            const t = std.mem.trim(u8, part, " ");
            if (std.mem.startsWith(u8, t, name)) {
                const rest = t[name.len..];
                if (rest.len > 0 and rest[0] == '=') return rest[1..];
            }
        }
        return null;
    }

    fn hexToken(token: [32]u8, out: *[64]u8) []const u8 {
        const hex = std.fmt.bytesToHex(token, .lower);
        @memcpy(out, &hex);
        return out[0..64];
    }

    fn parseHexToken(s: []const u8, out: *[32]u8) bool {
        if (s.len != 64) return false;
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            out[i] = std.fmt.parseInt(u8, s[i * 2 .. i * 2 + 2], 16) catch return false;
        }
        return true;
    }

    const Actor = struct {
        user_idx: ?usize = null,
        /// Present for API keys; null for a session, which carries every scope.
        scopes: ?[3]bool = null,

        fn isAuthed(self: Actor) bool {
            return self.user_idx != null or self.scopes != null;
        }

        fn isSession(self: Actor) bool {
            return self.user_idx != null;
        }
    };

    const Need = enum { read, write, control };

    /// Authenticate a request. Returns an empty actor for anonymous requests.
    /// UI routes need a session cookie; API routes accept either.
    fn authenticate(self: *Server, req: *http.Server.Request) Actor {
        if (headerVal(req, "authorization")) |h| {
            if (self.auth.keyScopes(h)) |scopes| return .{ .scopes = scopes };
        }
        if (cookieVal(req, "beanline_session")) |c| {
            var tok: [32]u8 = undefined;
            if (parseHexToken(c, &tok)) {
                var csrf: [32]u8 = undefined;
                if (self.auth.checkSession(&tok, &csrf)) |idx| {
                    return .{ .user_idx = idx };
                } else |_| {}
            }
        }
        return .{};
    }

    fn openReads(self: *Server) bool {
        return self.auth.users.items.len == 0 and self.auth.keys.items.len == 0 and !self.auth.oidcEnabled();
    }

    /// Cookie-authenticated mutations must carry the matching CSRF token.
    fn csrfOk(self: *Server, req: *http.Server.Request) bool {
        const sess = cookieVal(req, "beanline_session") orelse return true;
        const csrf_h = headerVal(req, "x-csrf-token") orelse return false;
        var tok: [32]u8 = undefined;
        if (!parseHexToken(sess, &tok)) return false;
        return self.auth.checkCsrf(&tok, csrf_h);
    }

    /// The single authorization policy. Reads are open when nothing is
    /// configured; writes need `jobs_write` (or an admin session) and queue
    /// control needs `queues_control`. Readonly blocks every mutation.
    fn authorized(self: *Server, actor: Actor, need: Need) bool {
        const open = self.openReads();
        switch (need) {
            .read => {
                if (open) return true;
                if (actor.scopes) |s| {
                    return s[@intFromEnum(auth_mod.Scope.jobs_read)] or s[@intFromEnum(auth_mod.Scope.jobs_write)];
                }
                return actor.user_idx != null;
            },
            .write, .control => {
                if (self.auth.readonly) return false;
                if (actor.scopes) |s| {
                    const scope: auth_mod.Scope = if (need == .write) .jobs_write else .queues_control;
                    return s[@intFromEnum(scope)];
                }
                if (actor.user_idx) |idx| return self.auth.canMutate(idx);
                return open;
            },
        }
    }

    /// Queue pause/resume are the only control-scoped routes; everything else
    /// under `/api/` is a read. A control-only key must not be rejected by the
    /// read gate before `handleAPI` can check its scope.
    fn apiNeed(path: []const u8) Need {
        if (std.mem.startsWith(u8, path, "/api/queues/")) {
            const end = std.mem.indexOfScalar(u8, path, '?') orelse path.len;
            const rest = path["/api/queues/".len..end];
            if (std.mem.indexOfScalar(u8, rest, '/') != null) return .control;
        }
        return .read;
    }

    fn route(self: *Server, req: *http.Server.Request) !void {
        const path = req.head.target;
        const method = req.head.method;
        if (self.log.log_payload) self.log.debug("{s} {s}", .{ @tagName(method), path });

        if (std.mem.eql(u8, path, "/healthz")) {
            try self.respondStatus(req, .ok, "ok");
            return;
        }
        if (std.mem.eql(u8, path, "/readyz")) {
            if (self.broken_broker.load(.seq_cst)) {
                try self.respondStatus(req, .service_unavailable, "broker_down");
            } else {
                try self.respondStatus(req, .ok, "ready");
            }
            return;
        }
        if (std.mem.eql(u8, path, "/metrics")) {
            const body = self.metrics.render(self.alloc) catch {
                try self.respondStatus(req, .internal_server_error, "render_failed");
                return;
            };
            defer self.alloc.free(body);
            try req.respond(body, .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; version=0.0.4" }},
            });
            return;
        }
        if (std.mem.eql(u8, path, "/")) {
            try self.serveIndex(req);
            return;
        }
        if (std.mem.eql(u8, path, "/login") and method == .POST) {
            try self.handleLogin(req);
            return;
        }
        if (std.mem.eql(u8, path, "/logout") and method == .POST) {
            if (cookieVal(req, "beanline_session")) |c| {
                var tok: [32]u8 = undefined;
                if (parseHexToken(c, &tok)) self.auth.logout(&tok);
            }
            try req.respond("{\"ok\":true}", .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "application/json" },
                    .{ .name = "set-cookie", .value = "beanline_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0" },
                },
            });
            return;
        }
        if (std.mem.eql(u8, path, "/auth/oidc") and method == .GET) {
            try self.handleOidcStart(req);
            return;
        }
        if (std.mem.startsWith(u8, path, "/auth/oidc/callback")) {
            try self.handleOidcCallback(req, path);
            return;
        }
        if (std.mem.eql(u8, path, "/api/live") or std.mem.startsWith(u8, path, "/api/")) {
            const actor = self.authenticate(req);
            if (!self.authorized(actor, apiNeed(path))) {
                if (actor.isAuthed()) {
                    try self.jsonResponse(req, .forbidden, "{\"error\":\"forbidden\"}", &.{});
                } else {
                    try self.jsonResponse(req, .unauthorized, "{\"error\":\"unauthorized\"}", &.{});
                }
                return;
            }
            if (std.mem.eql(u8, path, "/api/live")) {
                try self.handleSSE(req);
            } else {
                try self.handleAPI(req, actor, path, method);
            }
            return;
        }
        try self.respondStatus(req, .not_found, "not_found");
    }

    fn handleLogin(self: *Server, req: *http.Server.Request) !void {
        const body = req.reader() catch {
            try self.respondStatus(req, .bad_request, "bad_body");
            return;
        };
        var buf = std.ArrayList(u8).init(self.alloc);
        defer buf.deinit();
        body.readAllArrayList(&buf, 16 * 1024) catch {
            try self.respondStatus(req, .bad_request, "bad_body");
            return;
        };
        const parsed = std.json.parseFromSlice(struct { username: []const u8, password: []const u8 }, self.alloc, buf.items, .{}) catch {
            try self.respondStatus(req, .bad_request, "bad_json");
            return;
        };
        defer parsed.deinit();
        var tok: [32]u8 = undefined;
        var csrf: [32]u8 = undefined;
        self.auth.login(parsed.value.username, parsed.value.password, &tok, &csrf) catch |e| {
            if (e == error.LockedOut) {
                try self.jsonResponse(req, .too_many_requests, "{\"error\":\"locked_out\"}", &.{});
            } else {
                try self.jsonResponse(req, .unauthorized, "{\"error\":\"unauthorized\"}", &.{});
            }
            return;
        };
        var hex: [64]u8 = undefined;
        const hs = hexToken(tok, &hex);
        var csrf_hex: [64]u8 = undefined;
        const cs = hexToken(csrf, &csrf_hex);
        var cookie_buf: [256]u8 = undefined;
        const cookie = std.fmt.bufPrint(&cookie_buf, "beanline_session={s}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=86400", .{hs}) catch {
            try self.respondStatus(req, .internal_server_error, "cookie");
            return;
        };
        var csrf_buf: [128]u8 = undefined;
        const csrf_cookie = std.fmt.bufPrint(&csrf_buf, "beanline_csrf={s}; Path=/; SameSite=Strict; Max-Age=86400", .{cs}) catch {
            try self.respondStatus(req, .internal_server_error, "cookie");
            return;
        };
        const resp_body = try std.fmt.allocPrint(self.alloc, "{{\"ok\":true,\"csrf\":\"{s}\"}}", .{cs});
        defer self.alloc.free(resp_body);
        var hdrs = std.ArrayList(http.Header).init(self.alloc);
        defer hdrs.deinit();
        try hdrs.append(.{ .name = "content-type", .value = "application/json" });
        try hdrs.append(.{ .name = "set-cookie", .value = cookie });
        try hdrs.append(.{ .name = "set-cookie", .value = csrf_cookie });
        try req.respond(resp_body, .{ .status = .ok, .extra_headers = hdrs.items });
    }

    /// Serve the embedded UI. The OIDC sign-in link is spliced in only when a
    /// provider is configured, so the password form stays the only path when
    /// SSO is off.
    fn serveIndex(self: *Server, req: *http.Server.Request) !void {
        if (!self.auth.oidcEnabled()) {
            try self.htmlResponse(req, index_html);
            return;
        }
        const marker = "<!--SSO-->";
        const at = std.mem.indexOf(u8, index_html, marker) orelse {
            try self.htmlResponse(req, index_html);
            return;
        };
        const link =
            \\<div class="row"><a href="/auth/oidc"><button class="ghost">sign in with SSO</button></a></div>
        ;
        var out: []u8 = undefined;
        out = try self.alloc.alloc(u8, index_html.len - marker.len + link.len);
        defer self.alloc.free(out);
        @memcpy(out[0..at], index_html[0..at]);
        @memcpy(out[at..][0..link.len], link);
        @memcpy(out[at + link.len ..], index_html[at + marker.len ..]);
        try self.htmlResponse(req, out);
    }

    /// Extract a query parameter from a request target.
    fn queryParam(path: []const u8, name: []const u8) ?[]const u8 {
        const qi = std.mem.indexOfScalar(u8, path, '?') orelse return null;
        var it = std.mem.splitScalar(u8, path[qi + 1 ..], '&');
        while (it.next()) |pair| {
            if (std.mem.startsWith(u8, pair, name)) {
                const rest = pair[name.len..];
                if (rest.len > 0 and rest[0] == '=') return rest[1..];
            }
        }
        return null;
    }

    fn redirect(self: *Server, req: *http.Server.Request, location: []const u8) !void {
        _ = self;
        try req.respond("", .{
            .status = .see_other,
            .extra_headers = &.{
                .{ .name = "location", .value = location },
                .{ .name = "content-security-policy", .value = "default-src 'self'" },
                .{ .name = "x-frame-options", .value = "DENY" },
            },
        });
    }

    /// Kick off the OIDC code flow: mint state + PKCE and redirect the browser
    /// to the provider's authorize endpoint.
    fn handleOidcStart(self: *Server, req: *http.Server.Request) !void {
        if (!self.auth.oidcEnabled()) {
            try self.respondStatus(req, .not_found, "oidc_not_configured");
            return;
        }
        var url_buf: [4096]u8 = undefined;
        const url = self.auth.oidcStart(&url_buf) catch |e| {
            self.log.err("oidc start failed: {s}", .{@errorName(e)});
            try self.respondStatus(req, .internal_server_error, "oidc_start_failed");
            return;
        };
        try self.redirect(req, url);
    }

    /// Provider callback: redeem the code, establish a session, land on the UI.
    fn handleOidcCallback(self: *Server, req: *http.Server.Request, path: []const u8) !void {
        if (!self.auth.oidcEnabled()) {
            try self.respondStatus(req, .not_found, "oidc_not_configured");
            return;
        }
        // The provider reports user-declined consent through query params.
        if (queryParam(path, "error") != null) {
            self.log.warn("oidc: provider returned an error to the callback", .{});
            try self.respondStatus(req, .unauthorized, "oidc_cancelled");
            return;
        }
        const code = queryParam(path, "code") orelse {
            try self.respondStatus(req, .bad_request, "missing_code");
            return;
        };
        const state = queryParam(path, "state") orelse {
            try self.respondStatus(req, .bad_request, "missing_state");
            return;
        };
        var tok: [32]u8 = undefined;
        var csrf: [32]u8 = undefined;
        self.auth.oidcCallback(code, state, &tok, &csrf) catch |e| {
            self.log.warn("oidc: callback rejected ({s})", .{@errorName(e)});
            const code_out: http.Status = if (e == error.OidcStateMismatch) .bad_request else .unauthorized;
            try self.respondStatus(req, code_out, @errorName(e));
            return;
        };

        var hex: [64]u8 = undefined;
        const hs = hexToken(tok, &hex);
        var csrf_hex: [64]u8 = undefined;
        const cs = hexToken(csrf, &csrf_hex);
        var cookie_buf: [256]u8 = undefined;
        const cookie = std.fmt.bufPrint(&cookie_buf, "beanline_session={s}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=86400", .{hs}) catch {
            try self.respondStatus(req, .internal_server_error, "cookie");
            return;
        };
        var csrf_buf: [128]u8 = undefined;
        const csrf_cookie = std.fmt.bufPrint(&csrf_buf, "beanline_csrf={s}; Path=/; SameSite=Strict; Max-Age=86400", .{cs}) catch {
            try self.respondStatus(req, .internal_server_error, "cookie");
            return;
        };
        try req.respond("", .{
            .status = .see_other,
            .extra_headers = &.{
                .{ .name = "location", .value = "/" },
                .{ .name = "set-cookie", .value = cookie },
                .{ .name = "set-cookie", .value = csrf_cookie },
                .{ .name = "content-security-policy", .value = "default-src 'self'" },
            },
        });
    }

    fn handleSSE(self: *Server, req: *http.Server.Request) !void {
        const path = req.head.target;
        var queue_filter: []const u8 = "";
        if (std.mem.indexOfScalar(u8, path, '?')) |qi| {
            const q = path[qi + 1 ..];
            var it = std.mem.splitScalar(u8, q, '&');
            while (it.next()) |pair| {
                if (std.mem.startsWith(u8, pair, "queue=")) queue_filter = pair["queue=".len..];
            }
        }
        const sub = self.bus.subscribe(queue_filter) catch {
            try self.respondStatus(req, .internal_server_error, "subscribe_failed");
            return;
        };
        defer self.bus.unsubscribe(sub);

        var send_buf: [8 * 1024]u8 = undefined;
        var res = req.respondStreaming(.{
            .send_buffer = &send_buf,
            .respond_options = .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/event-stream" },
                    .{ .name = "cache-control", .value = "no-cache" },
                    .{ .name = "connection", .value = "keep-alive" },
                },
            },
        });
        try res.flush();
        const deadline = std.time.milliTimestamp() + 60_000;
        var out_buf: [4 * 1024]u8 = undefined;
        while (std.time.milliTimestamp() < deadline and !self.stop.load(.seq_cst)) {
            const n = sub.drain(out_buf[0..]);
            if (n > 0) {
                res.writeAll(out_buf[0..n]) catch return;
                res.flush() catch return;
            } else {
                std.time.sleep(100 * std.time.ns_per_ms);
                res.writeAll(": ping\n\n") catch return;
                res.flush() catch return;
            }
        }
        res.end() catch {};
    }

    fn handleAPI(self: *Server, req: *http.Server.Request, actor: Actor, path: []const u8, method: http.Method) !void {
        if (std.mem.eql(u8, path, "/api/queues") and method == .GET) {
            const body = self.rest.queues(self.queue_names) catch {
                try self.respondStatus(req, .internal_server_error, "broker_error");
                return;
            };
            defer self.alloc.free(body);
            try self.jsonResponse(req, .ok, body, &.{});
            return;
        }
        if (std.mem.startsWith(u8, path, "/api/queues/")) {
            if (method != .POST) {
                try self.respondStatus(req, .method_not_allowed, "method_not_allowed");
                return;
            }
            if (!self.authorized(actor, .control)) {
                try self.jsonResponse(req, .forbidden, "{\"error\":\"forbidden\"}", &.{});
                return;
            }
            if (actor.isSession() and !self.csrfOk(req)) {
                try self.jsonResponse(req, .forbidden, "{\"error\":\"bad_csrf\"}", &.{});
                return;
            }
            const tail = path["/api/queues/".len..];
            const slash = std.mem.indexOfScalar(u8, tail, '/') orelse {
                try self.respondStatus(req, .not_found, "unknown_action");
                return;
            };
            const name = tail[0..slash];
            var action = tail[slash + 1 ..];
            if (std.mem.indexOfScalar(u8, action, '?')) |qm| action = action[0..qm];
            if (name.len == 0) {
                try self.respondStatus(req, .not_found, "unknown_action");
                return;
            }
            const paused = if (std.mem.eql(u8, action, "pause"))
                true
            else if (std.mem.eql(u8, action, "resume"))
                false
            else {
                try self.respondStatus(req, .not_found, "unknown_action");
                return;
            };
            const body = self.rest.setQueuePaused(name, paused) catch {
                try self.respondStatus(req, .internal_server_error, "broker_error");
                return;
            };
            defer self.alloc.free(body);
            const code: http.Status = if (std.mem.indexOf(u8, body, "\"code\":501") != null)
                .not_implemented
            else if (std.mem.indexOf(u8, body, "\"code\":500") != null)
                .internal_server_error
            else
                .ok;
            try self.jsonResponse(req, code, body, &.{});
            return;
        }
        if (std.mem.startsWith(u8, path, "/api/jobs")) {
            const rest_path = path["/api/jobs".len..];
            if (rest_path.len == 0 or rest_path[0] == '?') {
                if (method != .GET) {
                    try self.respondStatus(req, .method_not_allowed, "method_not_allowed");
                    return;
                }
                const q = if (rest_path.len > 1) rest_path[1..] else "";
                const body = self.rest.listJobs(q, null) catch {
                    try self.respondStatus(req, .internal_server_error, "broker_error");
                    return;
                };
                defer self.alloc.free(body);
                try self.jsonResponse(req, .ok, body, &.{});
                return;
            }
            // /{id} or /{id}/action
            const tail = rest_path[1..];
            const slash = std.mem.indexOfScalar(u8, tail, '/');
            const id_s = if (slash) |s| tail[0..s] else blk: {
                const qm = std.mem.indexOfScalar(u8, tail, '?');
                break :blk if (qm) |q| tail[0..q] else tail;
            };
            const id = std.fmt.parseInt(i64, id_s, 10) catch {
                try self.jsonResponse(req, .bad_request, "{\"error\":\"bad_id\"}", &.{});
                return;
            };
            const action = if (slash) |s| tail[s + 1 ..] else "";
            if (action.len == 0 and method == .GET) {
                const body = self.rest.jobDetail(id) catch {
                    try self.respondStatus(req, .internal_server_error, "broker_error");
                    return;
                };
                defer self.alloc.free(body);
                const code: http.Status = if (std.mem.indexOf(u8, body, "\"code\":404") != null) .not_found else .ok;
                try self.jsonResponse(req, code, body, &.{});
                return;
            }
            if (method != .POST) {
                try self.respondStatus(req, .method_not_allowed, "method_not_allowed");
                return;
            }
            if (!self.authorized(actor, .write)) {
                try self.jsonResponse(req, .forbidden, "{\"error\":\"forbidden\"}", &.{});
                return;
            }
            // CSRF check for cookie-authed mutations.
            if (actor.isSession() and !self.csrfOk(req)) {
                try self.jsonResponse(req, .forbidden, "{\"error\":\"bad_csrf\"}", &.{});
                return;
            }
            var queue: []const u8 = "default";
            const qbody = req.reader() catch null;
            var qname_buf: [128]u8 = undefined;
            if (qbody) |r| {
                var qb = std.ArrayList(u8).init(self.alloc);
                defer qb.deinit();
                if (r.readAllArrayList(&qb, 4096)) {
                    if (qb.items.len > 0) {
                        const qp = std.json.parseFromSlice(struct { queue: ?[]const u8 = null }, self.alloc, qb.items, .{}) catch null;
                        if (qp) |p| {
                            defer p.deinit();
                            if (p.value.queue) |qn| {
                                @memcpy(qname_buf[0..@min(qn.len, qname_buf.len)], qn[0..@min(qn.len, qname_buf.len)]);
                                queue = qname_buf[0..@min(qn.len, qname_buf.len)];
                            }
                        }
                    }
                } else |_| {}
            }
            if (std.mem.eql(u8, action, "retry")) {
                const body = self.rest.jobRetry(queue, id) catch {
                    try self.respondStatus(req, .internal_server_error, "broker_error");
                    return;
                };
                defer self.alloc.free(body);
                const code: http.Status = if (std.mem.indexOf(u8, body, "\"code\":404") != null) .not_found else .ok;
                try self.jsonResponse(req, code, body, &.{});
                return;
            }
            if (std.mem.eql(u8, action, "discard")) {
                const body = self.rest.jobDiscard(queue, id) catch {
                    try self.respondStatus(req, .internal_server_error, "broker_error");
                    return;
                };
                defer self.alloc.free(body);
                const code: http.Status = if (std.mem.indexOf(u8, body, "\"code\":404") != null) .not_found else .ok;
                try self.jsonResponse(req, code, body, &.{});
                return;
            }
            if (std.mem.eql(u8, action, "cancel")) {
                const body = self.rest.jobCancel(queue, id) catch {
                    try self.respondStatus(req, .internal_server_error, "broker_error");
                    return;
                };
                defer self.alloc.free(body);
                const code: http.Status = if (std.mem.indexOf(u8, body, "\"code\":404") != null) .not_found else if (std.mem.indexOf(u8, body, "\"code\":409") != null) .conflict else .ok;
                try self.jsonResponse(req, code, body, &.{});
                return;
            }
            try self.respondStatus(req, .not_found, "unknown_action");
            return;
        }
        if (std.mem.eql(u8, path, "/api/enqueue") and method == .POST) {
            if (!self.authorized(actor, .write)) {
                try self.jsonResponse(req, .forbidden, "{\"error\":\"forbidden\"}", &.{});
                return;
            }
            if (actor.isSession() and !self.csrfOk(req)) {
                try self.jsonResponse(req, .forbidden, "{\"error\":\"bad_csrf\"}", &.{});
                return;
            }
            const rdr = req.reader() catch {
                try self.respondStatus(req, .bad_request, "bad_body");
                return;
            };
            var qb = std.ArrayList(u8).init(self.alloc);
            defer qb.deinit();
            rdr.readAllArrayList(&qb, 64 * 1024) catch {
                try self.respondStatus(req, .bad_request, "bad_body");
                return;
            };
            const body = self.rest.enqueue(qb.items) catch {
                try self.respondStatus(req, .internal_server_error, "broker_error");
                return;
            };
            defer self.alloc.free(body);
            const code: http.Status = if (std.mem.indexOf(u8, body, "\"code\":400") != null) .bad_request else .ok;
            try self.jsonResponse(req, code, body, &.{});
            return;
        }
        if (std.mem.eql(u8, path, "/api/schedules") and method == .GET) {
            const body = self.rest.schedules("[]") catch {
                try self.respondStatus(req, .internal_server_error, "sched_error");
                return;
            };
            defer self.alloc.free(body);
            try self.jsonResponse(req, .ok, body, &.{});
            return;
        }
        try self.respondStatus(req, .not_found, "not_found");
    }
};

test "bind parsing rejects bad input" {
    try std.testing.expectError(error.BadBind, Server.parseBind("noport"));
    try std.testing.expectError(error.BadBind, Server.parseBind("host:notaport"));
    const a = try Server.parseBind("127.0.0.1:9484");
    try std.testing.expectEqual(@as(u16, 9484), a.getPort());
}

test "query param extraction" {
    try std.testing.expectEqualStrings("abc", Server.queryParam("/x?code=abc&state=zz", "code").?);
    try std.testing.expectEqualStrings("zz", Server.queryParam("/x?code=abc&state=zz", "state").?);
    try std.testing.expect(Server.queryParam("/x?code=abc", "state") == null);
    try std.testing.expect(Server.queryParam("/x", "code") == null);
    try std.testing.expectEqualStrings("1", Server.queryParam("/x?v=1", "v").?);
}

test "oidc routes are absent when unconfigured" {
    const alloc = std.testing.allocator;
    var auth = auth_mod.Auth.init(alloc, "s", false);
    defer auth.deinit();
    // Without provider endpoints the auth layer reports OIDC as disabled, so
    // the router answers 404 for /auth/oidc and its callback.
    try std.testing.expect(!auth.oidcEnabled());

    auth.oidc = .{
        .authorize_endpoint = "https://idp.example.com/authorize",
        .token_endpoint = "https://idp.example.com/token",
        .client_id = "beanline",
    };
    try std.testing.expect(auth.oidcEnabled());

    var url_buf: [4096]u8 = undefined;
    const url = try auth.oidcStart(&url_buf);
    try std.testing.expect(std.mem.startsWith(u8, url, "https://idp.example.com/authorize?"));
}

test "token hex round trip" {
    var tok: [32]u8 = undefined;
    for (&tok, 0..) |*b, i| b.* = @intCast(i);
    var hex: [64]u8 = undefined;
    const hs = Server.hexToken(tok, &hex);
    try std.testing.expectEqual(@as(usize, 64), hs.len);
    var back: [32]u8 = undefined;
    try std.testing.expect(Server.parseHexToken(hs, &back));
    try std.testing.expectEqualSlices(u8, &tok, &back);
    try std.testing.expect(!Server.parseHexToken("zz", &back));
}
