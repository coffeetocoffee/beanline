const std = @import("std");
const auth_mod = @import("dash/auth.zig");

/// Beanline process configuration. Loaded from BEANLINE_* environment
/// variables (precedence: env > defaults; CLI flags are handled by the CLI).
/// Mirrors the architecture doc's §16.1 config block, kept intentionally thin:
/// a single shared decoder with fail-fast, path-pointing errors.
pub const Config = struct {
    /// "postgres" or "redis". Auto-detected from env vars if not set.
    backend: []const u8 = "",
    /// Postgres DSN (BEANLINE_DATABASE_URL).
    dsn: []const u8 = "",
    /// Redis URL (BEANLINE_REDIS_URL).
    redis_url: []const u8 = "",
    /// Per-queue concurrency: semicolon-separated "name:conc" pairs.
    /// Empty means the single default queue at `default_concurrency`.
    queues: []const []const u8 = &.{},
    default_concurrency: u32 = 4,
    lease_ms: u64 = 30_000,
    drain_timeout_ms: u64 = 30_000,
    retention_completed_ms: i64 = 72 * 60 * 60 * 1000,
    retention_events_ms: i64 = 7 * 24 * 60 * 60 * 1000,
    dashboard_bind: []const u8 = "127.0.0.1:9484",
    dashboard_enabled: bool = false,
    dashboard_auth_secret: []const u8 = "",
    dashboard_readonly: bool = false,
    dashboard_users: []const []const u8 = &.{},
    dashboard_keys: []const []const u8 = &.{},
    /// OIDC provider for dashboard SSO. Enabled when authorize, token, and
    /// client id are all set (BEANLINE_DASH_OIDC_*).
    oidc: auth_mod.Oidc = .{},
    otel_endpoint: []const u8 = "",
    log_payload: bool = false,
    /// Cardinality caps for metrics label values (doc §24c). Label values
    /// beyond the cap collapse into one `__other__` series.
    metrics_max_kinds: usize = 500,
    metrics_max_queues: usize = 200,

    /// Queue names plus the default concurrency, split from the "name:conc"
    /// config entries. Returns caller-owned slices.
    pub fn queueConcurrency(
        self: *const Config,
        out_names: *std.ArrayList([]const u8),
        out_conc: *std.ArrayList(u32),
    ) !void {
        out_names.clearRetainingCapacity();
        out_conc.clearRetainingCapacity();
        if (self.queues.len == 0) {
            try out_names.append("default");
            try out_conc.append(self.default_concurrency);
            return;
        }
        for (self.queues) |spec| {
            if (std.mem.indexOfScalar(u8, spec, ':')) |colon| {
                try out_names.append(spec[0..colon]);
                const conc = std.fmt.parseInt(u32, spec[colon + 1 ..], 10) catch self.default_concurrency;
                try out_conc.append(conc);
            } else {
                try out_names.append(spec);
                try out_conc.append(self.default_concurrency);
            }
        }
    }
};

fn envOwned(alloc: std.mem.Allocator, name: []const u8) !?[]const u8 {
    const v = std.process.getEnvVarOwned(alloc, name) catch |e| {
        if (e == error.EnvironmentVariableNotFound) return null;
        return e;
    };
    if (v.len == 0) {
        alloc.free(v);
        return null;
    }
    return v;
}

fn envNum(comptime T: type, name: []const u8, default: T) !T {
    const v = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return default;
    defer std.heap.page_allocator.free(v);
    if (v.len == 0) return default;
    return std.fmt.parseInt(T, v, 10) catch default;
}

fn envBool(name: []const u8, default: bool) bool {
    const v = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return default;
    defer std.heap.page_allocator.free(v);
    if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "yes")) return true;
    if (std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "no")) return false;
    return default;
}

/// Split a semicolon-separated list into caller-owned slices.
fn splitList(alloc: std.mem.Allocator, value: ?[]const u8) ![]const []const u8 {
    if (value == null) return &.{};
    var list = std.ArrayList([]const u8).init(alloc);
    errdefer list.deinit();
    var it = std.mem.splitScalar(u8, value.?, ';');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        try list.append(try alloc.dupe(u8, part));
    }
    return try list.toOwnedSlice();
}

/// Load configuration from the environment. The returned Config owns no heap
/// memory (all fields reference environment buffers or static strings).
pub fn load() Config {
    var c = Config{};

    // backend detection
    const db = std.process.getEnvVarOwned(std.heap.page_allocator, "BEANLINE_DATABASE_URL") catch null;
    const ru = std.process.getEnvVarOwned(std.heap.page_allocator, "BEANLINE_REDIS_URL") catch null;

    if (db) |d| {
        c.dsn = d;
        c.backend = "postgres";
    } else if (ru) |r| {
        c.redis_url = r;
        c.backend = "redis";
    }
    const explicit = std.process.getEnvVarOwned(std.heap.page_allocator, "BEANLINE_BACKEND") catch null;
    if (explicit) |b| {
        c.backend = b;
    }
    if (explicit == null and db == null and ru != null) {
        c.backend = "redis";
    } else if (explicit == null and ru == null and db != null) {
        c.backend = "postgres";
    }

    const queues = std.process.getEnvVarOwned(std.heap.page_allocator, "BEANLINE_QUEUES") catch null;
    c.queues = splitList(std.heap.page_allocator, queues) catch &.{};

    c.default_concurrency = envNum(u32, "BEANLINE_QUEUE_CONCURRENCY", 4) catch 4;
    c.lease_ms = envNum(u64, "BEANLINE_LEASE_MS", 30_000) catch 30_000;
    c.drain_timeout_ms = envNum(u64, "BEANLINE_DRAIN_TIMEOUT_MS", 30_000) catch 30_000;
    c.retention_completed_ms = envNum(i64, "BEANLINE_RETENTION_COMPLETED_MS", 72 * 60 * 60 * 1000) catch 72 * 60 * 60 * 1000;
    c.retention_events_ms = envNum(i64, "BEANLINE_RETENTION_EVENTS_MS", 7 * 24 * 60 * 60 * 1000) catch 7 * 24 * 60 * 60 * 1000;

    const bind = std.process.getEnvVarOwned(std.heap.page_allocator, "BEANLINE_DASH_BIND") catch null;
    if (bind) |b| c.dashboard_bind = b;
    c.dashboard_enabled = envBool("BEANLINE_DASH_ENABLED", false);
    c.dashboard_readonly = envBool("BEANLINE_DASH_READONLY", false);
    const secret = std.process.getEnvVarOwned(std.heap.page_allocator, "BEANLINE_DASH_SECRET") catch null;
    if (secret) |s| c.dashboard_auth_secret = s;
    const users = std.process.getEnvVarOwned(std.heap.page_allocator, "BEANLINE_DASH_USERS") catch null;
    c.dashboard_users = splitList(std.heap.page_allocator, users) catch &.{};
    const keys = std.process.getEnvVarOwned(std.heap.page_allocator, "BEANLINE_DASH_KEYS") catch null;
    c.dashboard_keys = splitList(std.heap.page_allocator, keys) catch &.{};
    const otel = std.process.getEnvVarOwned(std.heap.page_allocator, "BEANLINE_OTEL_ENDPOINT") catch null;
    if (otel) |o| c.otel_endpoint = o;

    // OIDC SSO. Endpoints are explicit; there is no .well-known discovery.
    c.oidc = .{
        .issuer = envStr("BEANLINE_DASH_OIDC_ISSUER") orelse "",
        .authorize_endpoint = envStr("BEANLINE_DASH_OIDC_AUTHORIZE_ENDPOINT") orelse "",
        .token_endpoint = envStr("BEANLINE_DASH_OIDC_TOKEN_ENDPOINT") orelse "",
        .userinfo_endpoint = envStr("BEANLINE_DASH_OIDC_USERINFO_ENDPOINT") orelse "",
        .client_id = envStr("BEANLINE_DASH_OIDC_CLIENT_ID") orelse "",
        .client_secret = envStr("BEANLINE_DASH_OIDC_CLIENT_SECRET") orelse "",
        .redirect_uri = envStr("BEANLINE_DASH_OIDC_REDIRECT_URI") orelse "",
        .scope = envStr("BEANLINE_DASH_OIDC_SCOPE") orelse "openid profile email",
        .allowed_email_domains = envStr("BEANLINE_DASH_OIDC_EMAIL_DOMAINS") orelse "",
        .default_role = envStr("BEANLINE_DASH_OIDC_DEFAULT_ROLE") orelse "viewer",
    };

    c.log_payload = envBool("BEANLINE_LOG_PAYLOAD", false);
    c.metrics_max_kinds = envNum(usize, "BEANLINE_METRICS_MAX_KINDS", 500) catch 500;
    c.metrics_max_queues = envNum(usize, "BEANLINE_METRICS_MAX_QUEUES", 200) catch 200;
    return c;
}

fn envStr(name: []const u8) ?[]const u8 {
    const v = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return null;
    if (v.len == 0) return null;
    return v;
}

test "default config" {
    const c = Config{};
    var names = std.ArrayList([]const u8).init(std.testing.allocator);
    defer names.deinit();
    var conc = std.ArrayList(u32).init(std.testing.allocator);
    defer conc.deinit();
    try c.queueConcurrency(&names, &conc);
    try std.testing.expectEqual(@as(usize, 1), names.items.len);
    try std.testing.expectEqualStrings("default", names.items[0]);
    try std.testing.expectEqual(@as(u32, 4), conc.items[0]);
}

test "queue concurrency splits specs" {
    const c = Config{ .queues = &.{ "mailers:8", "import:1" } };
    var names = std.ArrayList([]const u8).init(std.testing.allocator);
    defer names.deinit();
    var conc = std.ArrayList(u32).init(std.testing.allocator);
    defer conc.deinit();
    try c.queueConcurrency(&names, &conc);
    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("mailers", names.items[0]);
    try std.testing.expectEqual(@as(u32, 8), conc.items[0]);
    try std.testing.expectEqualStrings("import", names.items[1]);
    try std.testing.expectEqual(@as(u32, 1), conc.items[1]);
}
