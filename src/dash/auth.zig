const std = @import("std");
const argon2 = std.crypto.pwhash.argon2;

pub const Error = error{
    Unauthorized,
    Forbidden,
    BadRequest,
    LockedOut,
    Unconfigured,
    OidcDisabled,
    OidcStateMismatch,
    OidcProviderError,
    OidcDomainNotAllowed,
};

/// Permission scopes for API keys. Sessions created by a password login carry
/// all scopes.
pub const Scope = enum { jobs_read, jobs_write, queues_control };

/// A dashboard user. Passwords are never stored; only the argon2id PHC hash.
pub const User = struct {
    name: []const u8,
    hash: []const u8,
    /// "admin" or "viewer" (viewer is denied mutations).
    role: []const u8,
};

/// An API key with a set of scopes.
pub const ApiKey = struct {
    prefix: []const u8,
    key: []const u8,
    scopes: [3]bool,

    pub fn has(self: *const ApiKey, s: Scope) bool {
        return self.scopes[@intFromEnum(s)];
    }
};

const Session = struct {
    token: [32]u8,
    csrf: [32]u8,
    user_idx: usize,
    created_ms: i64,
    last_seen_ms: i64,
};

const LoginAttempt = struct {
    failures: u32 = 0,
    locked_until_ms: i64 = 0,
};

/// OIDC provider settings (authorization code flow, public client with PKCE).
/// Every endpoint is explicit rather than discovered from the issuer's
/// .well-known document, so the dashboard makes no unconfigured outbound calls.
pub const Oidc = struct {
    issuer: []const u8 = "",
    authorize_endpoint: []const u8 = "",
    token_endpoint: []const u8 = "",
    userinfo_endpoint: []const u8 = "",
    client_id: []const u8 = "",
    client_secret: []const u8 = "",
    redirect_uri: []const u8 = "",
    scope: []const u8 = "openid profile email",
    /// Comma-separated email domains allowed to sign in. Empty = any
    /// authenticated identity from the provider is accepted.
    allowed_email_domains: []const u8 = "",
    /// Role assigned to identities that are not already a local user.
    default_role: []const u8 = "viewer",
};

/// True when the three fields required for the code flow are present.
pub fn oidcConfigured(o: Oidc) bool {
    return o.authorize_endpoint.len > 0 and o.token_endpoint.len > 0 and o.client_id.len > 0;
}

/// A login attempt that has been started but not yet redeemed. The state value
/// is the CSRF binding for the callback; the verifier is the PKCE secret.
const PendingAuth = struct {
    state: [32]u8 = [_]u8{0} ** 32,
    verifier: [43]u8 = [_]u8{0} ** 43,
    created_ms: i64 = 0,
};

/// Lifetime of a pending authorization request. Anything older is treated as
/// abandoned and can no longer be redeemed.
const pending_ttl_ms: i64 = 10 * 60 * 1000;
const max_pending: usize = 32;

/// base64url-encode without padding.
fn base64Url(out: []u8, bytes: []const u8) []const u8 {
    const enc = std.base64.standard.Encoder;
    var tmp: [128]u8 = undefined;
    const n = enc.calcSize(bytes.len);
    if (n > tmp.len) return out[0..0];
    _ = enc.encode(tmp[0..n], bytes);
    var len: usize = 0;
    for (tmp[0..n]) |c| {
        const v: u8 = switch (c) {
            '+' => '-',
            '/' => '_',
            '=' => break, // padding: end of the base64url value
            else => c,
        };
        if (len >= out.len) break;
        out[len] = v;
        len += 1;
    }
    return out[0..len];
}

/// PKCE S256 challenge: base64url(sha256(verifier)).
fn pkceChallenge(out: []u8, verifier: []const u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    return base64Url(out, &digest);
}

fn percentEncode(out: []u8, s: []const u8) []const u8 {
    var len: usize = 0;
    for (s) |c| {
        const unreserved = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '.' or c == '_' or c == '~';
        if (unreserved) {
            out[len] = c;
            len += 1;
        } else {
            _ = std.fmt.bufPrint(out[len .. len + 3], "%{X:0>2}", .{c}) catch return out[0..0];
            len += 3;
        }
    }
    return out[0..len];
}

pub const Auth = struct {
    alloc: std.mem.Allocator,
    secret: []const u8,
    readonly: bool = false,
    oidc: Oidc = .{},
    pending: [max_pending]PendingAuth = @splat(.{}),
    users: std.ArrayListUnmanaged(User) = .{},
    keys: std.ArrayListUnmanaged(ApiKey) = .{},
    sessions: std.ArrayListUnmanaged(Session) = .{},
    attempts: std.StringHashMap(LoginAttempt) = undefined,
    mutex: std.Thread.Mutex = .{},

    pub fn init(alloc: std.mem.Allocator, secret: []const u8, readonly: bool) Auth {
        return .{
            .alloc = alloc,
            .secret = secret,
            .readonly = readonly,
            .users = .{},
            .keys = .{},
            .sessions = .{},
            .attempts = std.StringHashMap(LoginAttempt).init(alloc),
        };
    }

    pub fn deinit(self: *Auth) void {
        for (self.users.items) |u| {
            self.alloc.free(u.name);
            self.alloc.free(u.hash);
            self.alloc.free(u.role);
        }
        self.users.deinit(self.alloc);
        for (self.keys.items) |k| {
            self.alloc.free(k.prefix);
            self.alloc.free(k.key);
        }
        self.keys.deinit(self.alloc);
        self.sessions.deinit(self.alloc);
        var ait = self.attempts.keyIterator();
        while (ait.next()) |k| self.alloc.free(k.*);
        self.attempts.deinit();
    }

    /// Register a user from plaintext spec pieces. `spec` is "name:password:role".
    pub fn addUser(self: *Auth, spec: []const u8) !void {
        var it = std.mem.splitScalar(u8, spec, ':');
        const name = it.next() orelse return error.BadRequest;
        const password = it.next() orelse return error.BadRequest;
        const role = it.next() orelse "admin";
        var out: [256]u8 = undefined;
        const hash = try argon2.strHash(password, .{
            .allocator = self.alloc,
            .params = argon2.Params.owasp_2id,
        }, &out);
        const owned_hash = try self.alloc.dupe(u8, hash);
        errdefer self.alloc.free(owned_hash);
        const owned_name = try self.alloc.dupe(u8, name);
        try self.users.append(self.alloc, .{ .name = owned_name, .hash = owned_hash, .role = try self.alloc.dupe(u8, role) });
    }

    /// Register an API key from spec "prefix:secret:scope1,scope2".
    pub fn addKey(self: *Auth, spec: []const u8) !void {
        var it = std.mem.splitScalar(u8, spec, ':');
        const prefix = it.next() orelse return error.BadRequest;
        const secret = it.next() orelse return error.BadRequest;
        const scope_s = it.next() orelse "jobs_read";
        var k = ApiKey{
            .prefix = try self.alloc.dupe(u8, prefix),
            .key = try self.alloc.dupe(u8, secret),
            .scopes = .{ false, false, false },
        };
        errdefer self.alloc.free(k.prefix);
        errdefer self.alloc.free(k.key);
        var sit = std.mem.splitScalar(u8, scope_s, ',');
        while (sit.next()) |s| {
            if (std.mem.eql(u8, s, "jobs_read")) k.scopes[@intFromEnum(Scope.jobs_read)] = true;
            if (std.mem.eql(u8, s, "jobs_write")) k.scopes[@intFromEnum(Scope.jobs_write)] = true;
            if (std.mem.eql(u8, s, "queues_control")) k.scopes[@intFromEnum(Scope.queues_control)] = true;
        }
        try self.keys.append(self.alloc, k);
    }

    fn findUser(self: *Auth, name: []const u8) ?usize {
        for (self.users.items, 0..) |u, i| {
            if (std.mem.eql(u8, u.name, name)) return i;
        }
        return null;
    }

    pub fn verifyPassword(self: *Auth, name: []const u8, password: []const u8) bool {
        const idx = self.findUser(name) orelse return false;
        argon2.strVerify(self.users.items[idx].hash, password, .{ .allocator = self.alloc }) catch return false;
        return true;
    }

    /// Attempt login. Returns the session token on success, or an error.
    /// Rate limited: after 5 consecutive failures the account is locked for
    /// 60 seconds.
    pub fn login(self: *Auth, name: []const u8, password: []const u8, out_token: *[32]u8, out_csrf: *[32]u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = std.time.milliTimestamp();
        // The attempts map owns its keys; duplicate on first sight.
        const owned: []const u8 = if (self.attempts.contains(name)) name else blk: {
            const d = try self.alloc.dupe(u8, name);
            errdefer self.alloc.free(d);
            break :blk d;
        };
        const gop = try self.attempts.getOrPut(owned);
        if (!gop.found_existing) {
            gop.key_ptr.* = owned;
            gop.value_ptr.* = .{};
        }
        if (now < gop.value_ptr.locked_until_ms) return error.LockedOut;

        if (!self.verifyPassword(name, password)) {
            gop.value_ptr.failures += 1;
            if (gop.value_ptr.failures >= 5) {
                gop.value_ptr.locked_until_ms = now + 60_000;
                gop.value_ptr.failures = 0;
            }
            return error.Unauthorized;
        }
        gop.value_ptr.failures = 0;

        const idx = self.findUser(name) orelse return error.Unauthorized;
        var token: [32]u8 = undefined;
        var csrf: [32]u8 = undefined;
        std.crypto.random.bytes(&token);
        std.crypto.random.bytes(&csrf);
        try self.sessions.append(self.alloc, .{
            .token = token,
            .csrf = csrf,
            .user_idx = idx,
            .created_ms = now,
            .last_seen_ms = now,
        });
        out_token.* = token;
        out_csrf.* = csrf;
    }

    pub fn logout(self: *Auth, token: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < self.sessions.items.len) {
            if (self.sessions.items[i].token.len == token.len and std.crypto.timing_safe.eql([32]u8, self.sessions.items[i].token, token[0..32].*)) {
                _ = self.sessions.swapRemove(i);
                return;
            }
            i += 1;
        }
    }

    /// Validate a session token. Returns the user index and csrf token.
    pub fn checkSession(self: *Auth, token: []const u8, out_csrf: *[32]u8) !usize {
        if (token.len != 32) return error.Unauthorized;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.sessions.items) |*s| {
            if (std.crypto.timing_safe.eql([32]u8, s.token, token[0..32].*)) {
                if (std.time.milliTimestamp() - s.created_ms > 24 * 60 * 60 * 1000) return error.Unauthorized;
                s.last_seen_ms = std.time.milliTimestamp();
                out_csrf.* = s.csrf;
                return s.user_idx;
            }
        }
        return error.Unauthorized;
    }

    pub fn checkCsrf(self: *Auth, token: []const u8, csrf: []const u8) bool {
        if (csrf.len == 0) return false;
        var expected: [32]u8 = undefined;
        const idx = self.checkSession(token, &expected) catch return false;
        _ = idx;
        return std.mem.eql(u8, &expected, csrf);
    }

    /// Look up an API key by Authorization header. Format:
    /// "Bearer <prefix>.<secret>".
    fn findKey(self: *Auth, header: []const u8) ?*const ApiKey {
        if (!std.mem.startsWith(u8, header, "Bearer ")) return null;
        const rest = header["Bearer ".len..];
        const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
        const prefix = rest[0..dot];
        const secret = rest[dot + 1 ..];
        for (self.keys.items) |*k| {
            if (std.mem.eql(u8, k.prefix, prefix) and std.mem.eql(u8, k.key, secret)) return k;
        }
        return null;
    }

    /// Scopes granted by the key in `header`, or null when no key matches.
    /// Returned by value so callers can hold it across list mutations.
    pub fn keyScopes(self: *Auth, header: []const u8) ?[3]bool {
        const k = self.findKey(header) orelse return null;
        return k.scopes;
    }

    /// Validate an API key from the Authorization header. `jobs_write` implies
    /// `jobs_read`; no scope implies `queues_control`.
    pub fn checkKey(self: *Auth, header: []const u8, need: Scope) !void {
        const k = self.findKey(header) orelse return error.Unauthorized;
        if (k.has(need)) return;
        if (need == .jobs_read and k.has(.jobs_write)) return;
        return error.Forbidden;
    }

    /// Can this user perform mutations? Viewers are read-only regardless of
    /// the global readonly flag.
    pub fn canMutate(self: *Auth, user_idx: usize) bool {
        if (self.readonly) return false;
        if (user_idx >= self.users.items.len) return false;
        return std.mem.eql(u8, self.users.items[user_idx].role, "admin");
    }

    /// Whether OIDC login is available to this server.
    pub fn oidcEnabled(self: *Auth) bool {
        return oidcConfigured(self.oidc);
    }

    /// Begin an OIDC login: mint a state + PKCE verifier, record them, and
    /// return the provider authorize URL the browser should be sent to.
    /// `out` must be large enough for the URL (2 KiB is ample).
    pub fn oidcStart(self: *Auth, out: []u8) ![]const u8 {
        if (!self.oidcEnabled()) return error.OidcDisabled;
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.milliTimestamp();
        var slot: ?*PendingAuth = null;
        for (&self.pending) |*p| {
            if (p.created_ms == 0 or now - p.created_ms > pending_ttl_ms) {
                slot = p;
                break;
            }
        }
        // All slots busy: reuse the oldest rather than dropping the login.
        if (slot == null) slot = &self.pending[0];

        var verifier_raw: [32]u8 = undefined;
        std.crypto.random.bytes(&verifier_raw);
        // 32 random bytes encode to exactly 43 base64url characters.
        var verifier_b64: [48]u8 = undefined;
        @memcpy(&slot.?.verifier, base64Url(&verifier_b64, &verifier_raw)[0..43]);
        std.crypto.random.bytes(&slot.?.state);
        slot.?.created_ms = now;

        const state_hex = std.fmt.bytesToHex(&slot.?.state, .lower);
        var challenge: [64]u8 = undefined;
        const ch = pkceChallenge(&challenge, &slot.?.verifier);

        var eb: [1024]u8 = undefined;
        var ec: [2048]u8 = undefined;
        var es: [512]u8 = undefined;
        const cid = percentEncode(&eb, self.oidc.client_id);
        const ruri = percentEncode(&ec, self.oidc.redirect_uri);
        const scope = percentEncode(&es, self.oidc.scope);
        return std.fmt.bufPrint(
            out,
            "{s}?response_type=code&client_id={s}&redirect_uri={s}&scope={s}&state={s}&code_challenge={s}&code_challenge_method=S256",
            .{ self.oidc.authorize_endpoint, cid, ruri, scope, state_hex, ch },
        ) catch error.OidcProviderError;
    }

    /// Redeem an authorization code. Validates the state binding, exchanges the
    /// code at the token endpoint, resolves the identity via userinfo, then
    /// creates a local session for a matching or auto-provisioned user.
    pub fn oidcCallback(
        self: *Auth,
        code: []const u8,
        state_hex: []const u8,
        out_token: *[32]u8,
        out_csrf: *[32]u8,
    ) !void {
        if (!self.oidcEnabled()) return error.OidcDisabled;
        if (code.len == 0 or code.len > 2048) return error.BadRequest;

        // Consume the pending entry atomically so a state can never be
        // redeemed twice.
        const now = std.time.milliTimestamp();
        const verifier = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            var found: ?*PendingAuth = null;
            for (&self.pending) |*p| {
                if (p.created_ms == 0) continue;
                if (now - p.created_ms > pending_ttl_ms) continue;
                const hex = std.fmt.bytesToHex(&p.state, .lower);
                if (std.mem.eql(u8, &hex, state_hex)) {
                    found = p;
                    break;
                }
            }
            const pending = found orelse return error.OidcStateMismatch;
            const v = self.alloc.dupe(u8, &pending.verifier) catch return error.OutOfMemory;
            pending.created_ms = 0;
            break :blk v;
        };
        defer self.alloc.free(verifier);

        const access_token = try self.oidcFetchToken(code, verifier);
        defer self.alloc.free(access_token);

        const identity = try self.oidcFetchUserinfo(access_token);
        defer identity.deinit();

        if (!self.emailAllowed(identity.email)) return error.OidcDomainNotAllowed;

        const idx = self.userForOidc(identity.email);
        var token: [32]u8 = undefined;
        var csrf: [32]u8 = undefined;
        std.crypto.random.bytes(&token);
        std.crypto.random.bytes(&csrf);
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.sessions.append(self.alloc, .{
            .token = token,
            .csrf = csrf,
            .user_idx = idx,
            .created_ms = now,
            .last_seen_ms = now,
        });
        out_token.* = token;
        out_csrf.* = csrf;
    }

    /// POST the code to the token endpoint and return the access token.
    fn oidcFetchToken(self: *Auth, code: []const u8, verifier: []const u8) ![]u8 {
        var code_buf: [2048]u8 = undefined;
        var ruri_buf: [2048]u8 = undefined;
        var cid_buf: [1024]u8 = undefined;
        var secret_buf: [2048]u8 = undefined;
        var ver_buf: [128]u8 = undefined;
        const body = std.fmt.allocPrint(self.alloc, "grant_type=authorization_code&code={s}&redirect_uri={s}&client_id={s}&client_secret={s}&code_verifier={s}", .{
            percentEncode(&code_buf, code),
            percentEncode(&ruri_buf, self.oidc.redirect_uri),
            percentEncode(&cid_buf, self.oidc.client_id),
            percentEncode(&secret_buf, self.oidc.client_secret),
            percentEncode(&ver_buf, verifier),
        }) catch return error.OidcProviderError;
        defer self.alloc.free(body);

        var resp = std.ArrayList(u8).init(self.alloc);
        defer resp.deinit();
        var client = std.http.Client{ .allocator = self.alloc };
        defer client.deinit();
        const result = client.fetch(.{
            .location = .{ .url = self.oidc.token_endpoint },
            .method = .POST,
            .payload = body,
            .response_storage = .{ .dynamic = &resp },
            .max_append_size = 64 * 1024,
            .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
        }) catch return error.OidcProviderError;
        if (result.status != .ok) return error.OidcProviderError;

        return self.parseAccessToken(resp.items);
    }

    /// Extract `access_token` from a token endpoint response. Public for testing.
    pub fn parseAccessToken(self: *Auth, body: []const u8) ![]u8 {
        const parsed = std.json.parseFromSlice(struct {
            access_token: ?[]const u8 = null,
            oauth_error: ?[]const u8 = null,
        }, self.alloc, body, .{ .ignore_unknown_fields = true }) catch return error.OidcProviderError;
        defer parsed.deinit();
        if (parsed.value.oauth_error != null) return error.OidcProviderError;
        const tok = parsed.value.access_token orelse return error.OidcProviderError;
        if (tok.len == 0 or tok.len > 8192) return error.OidcProviderError;
        return self.alloc.dupe(u8, tok);
    }

    const Identity = struct {
        email: []const u8,
        sub: []const u8,
        allocator: std.mem.Allocator,

        fn deinit(self: Identity) void {
            self.allocator.free(self.email);
            self.allocator.free(self.sub);
        }
    };

    /// Resolve the signed-in identity through the userinfo endpoint. The
    /// access token is an opaque bearer token presented to the provider over
    /// TLS, so no local signature verification of an id_token is required.
    fn oidcFetchUserinfo(self: *Auth, access_token: []const u8) !Identity {
        var resp = std.ArrayList(u8).init(self.alloc);
        defer resp.deinit();
        var client = std.http.Client{ .allocator = self.alloc };
        defer client.deinit();
        var auth_buf: [8192]u8 = undefined;
        const hdr = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{access_token}) catch return error.OidcProviderError;
        const result = client.fetch(.{
            .location = .{ .url = self.oidc.userinfo_endpoint },
            .method = .GET,
            .response_storage = .{ .dynamic = &resp },
            .max_append_size = 64 * 1024,
            .extra_headers = &.{.{ .name = "authorization", .value = hdr }},
        }) catch return error.OidcProviderError;
        if (result.status != .ok) return error.OidcProviderError;

        const parsed = std.json.parseFromSlice(struct {
            sub: ?[]const u8 = null,
            email: ?[]const u8 = null,
            preferred_username: ?[]const u8 = null,
        }, self.alloc, resp.items, .{ .ignore_unknown_fields = true }) catch return error.OidcProviderError;
        defer parsed.deinit();
        const sub = parsed.value.sub orelse return error.OidcProviderError;
        const email = parsed.value.email orelse parsed.value.preferred_username orelse return error.Unauthorized;
        if (email.len == 0 or email.len > 320) return error.Unauthorized;
        return .{
            .email = self.alloc.dupe(u8, email) catch return error.OidcProviderError,
            .sub = self.alloc.dupe(u8, sub) catch return error.OidcProviderError,
            .allocator = self.alloc,
        };
    }

    /// Enforce the optional email-domain allowlist.
    pub fn emailAllowed(self: *Auth, email: []const u8) bool {
        if (self.oidc.allowed_email_domains.len == 0) return true;
        const at = std.mem.lastIndexOfScalar(u8, email, '@') orelse return false;
        const domain = email[at + 1 ..];
        var it = std.mem.splitScalar(u8, self.oidc.allowed_email_domains, ',');
        while (it.next()) |d| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, d, " "), domain)) return true;
        }
        return false;
    }

    /// Map an OIDC identity to a local user index, provisioning a viewer on
    /// first sight. An existing local user keeps its configured role.
    fn userForOidc(self: *Auth, email: []const u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.findUser(email)) |idx| return idx;
        const name = self.alloc.dupe(u8, email) catch return 0;
        const role = self.alloc.dupe(u8, self.oidc.default_role) catch return 0;
        self.users.append(self.alloc, .{ .name = name, .hash = "", .role = role }) catch return 0;
        return self.users.items.len - 1;
    }

    /// Cost-safety: sessions older than 24h are pruned lazily.
    pub fn prune(self: *Auth) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = std.time.milliTimestamp();
        var i: usize = 0;
        while (i < self.sessions.items.len) {
            if (now - self.sessions.items[i].created_ms > 24 * 60 * 60 * 1000) {
                _ = self.sessions.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

test "login and session round trip" {
    var a = Auth.init(std.testing.allocator, "secret", false);
    defer a.deinit();
    try a.addUser("ops:hunter2:admin");
    try std.testing.expect(a.verifyPassword("ops", "hunter2"));
    try std.testing.expect(!a.verifyPassword("ops", "wrong"));
    try std.testing.expect(!a.verifyPassword("nobody", "hunter2"));

    var tok: [32]u8 = undefined;
    var csrf: [32]u8 = undefined;
    try a.login("ops", "hunter2", &tok, &csrf);
    var expected: [32]u8 = undefined;
    const idx = try a.checkSession(&tok, &expected);
    try std.testing.expectEqual(@as(usize, 0), idx);
    try std.testing.expectEqualSlices(u8, &csrf, &expected);
    try std.testing.expect(a.canMutate(idx));
    a.logout(&tok);
    try std.testing.expectError(error.Unauthorized, a.checkSession(&tok, &expected));
}

test "lockout after repeated failures" {
    var a = Auth.init(std.testing.allocator, "s", false);
    defer a.deinit();
    try a.addUser("ops:hunter2:admin");
    var tok: [32]u8 = undefined;
    var csrf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try std.testing.expectError(error.Unauthorized, a.login("ops", "nope", &tok, &csrf));
    }
    try std.testing.expectError(error.LockedOut, a.login("ops", "hunter2", &tok, &csrf));
}

test "api key scopes" {
    var a = Auth.init(std.testing.allocator, "s", false);
    defer a.deinit();
    try a.addKey("k1:sekret:jobs_read");
    try a.checkKey("Bearer k1.sekret", .jobs_read);
    try std.testing.expectError(error.Forbidden, a.checkKey("Bearer k1.sekret", .queues_control));
    try std.testing.expectError(error.Unauthorized, a.checkKey("Bearer k1.nope", .jobs_read));
    try std.testing.expectError(error.Unauthorized, a.checkKey("nope", .jobs_read));
}

test "jobs_write implies read but not queue control" {
    var a = Auth.init(std.testing.allocator, "s", false);
    defer a.deinit();
    try a.addKey("w:sekret:jobs_write");
    try a.checkKey("Bearer w.sekret", .jobs_read);
    try a.checkKey("Bearer w.sekret", .jobs_write);
    try std.testing.expectError(error.Forbidden, a.checkKey("Bearer w.sekret", .queues_control));
    try std.testing.expect(a.keyScopes("Bearer w.sekret") != null);
    try std.testing.expect(a.keyScopes("Bearer w.nope") == null);
}

test "viewer cannot mutate" {
    var a = Auth.init(std.testing.allocator, "s", false);
    defer a.deinit();
    try a.addUser("ro:pw:viewer");
    var tok: [32]u8 = undefined;
    var csrf: [32]u8 = undefined;
    try a.login("ro", "pw", &tok, &csrf);
    const idx = try a.checkSession(&tok, &csrf);
    try std.testing.expect(!a.canMutate(idx));
}

const test_oidc = Oidc{
    .issuer = "https://idp.example.com",
    .authorize_endpoint = "https://idp.example.com/authorize",
    .token_endpoint = "https://idp.example.com/token",
    .userinfo_endpoint = "https://idp.example.com/userinfo",
    .client_id = "beanline",
    .client_secret = "s3cret",
    .redirect_uri = "http://127.0.0.1:9484/auth/oidc/callback",
};

test "oidc disabled without endpoints" {
    try std.testing.expect(!oidcConfigured(.{}));
    try std.testing.expect(oidcConfigured(test_oidc));
}

test "pkce challenge is base64url sha256" {
    var out: [64]u8 = undefined;
    // RFC 7636 appendix B test vector.
    const ch = pkceChallenge(&out, "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk");
    try std.testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", ch);
    try std.testing.expect(std.mem.indexOfScalar(u8, ch, '=') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, ch, '+') == null);
}

test "percent encoding escapes reserved characters" {
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a%2Fb%20c%40d", percentEncode(&out, "a/b c@d"));
}

test "oidc authorize url carries state and pkce" {
    var a = Auth.init(std.testing.allocator, "s", false);
    defer a.deinit();
    a.oidc = test_oidc;
    try std.testing.expect(a.oidcEnabled());

    var url_buf: [4096]u8 = undefined;
    const url = try a.oidcStart(&url_buf);
    try std.testing.expect(std.mem.startsWith(u8, url, "https://idp.example.com/authorize?"));
    try std.testing.expect(std.mem.indexOf(u8, url, "response_type=code") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "client_id=beanline") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "scope=openid%20profile%20email") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "state=") != null);

    // The state embedded in the URL is accepted (it reaches the token
    // exchange), but is single-use: a replay no longer matches.
    const s_at = std.mem.indexOf(u8, url, "state=").? + "state=".len;
    const s_end = std.mem.indexOfScalarPos(u8, url, s_at, '&').?;
    const state = url[s_at..s_end];

    var tok: [32]u8 = undefined;
    var csrf: [32]u8 = undefined;
    // Token endpoint points at a closed local port, so the exchange fails
    // fast without leaving the machine.
    a.oidc.token_endpoint = "http://127.0.0.1:1/token";
    try std.testing.expectError(error.OidcProviderError, a.oidcCallback("the-code", state, &tok, &csrf));
    try std.testing.expectError(error.OidcStateMismatch, a.oidcCallback("the-code", state, &tok, &csrf));

    // An unknown state is rejected before any network call.
    try std.testing.expectError(error.OidcStateMismatch, a.oidcCallback("c", "f" ** 64, &tok, &csrf));
}

test "oidc rejects empty code and mismatched state" {
    var a = Auth.init(std.testing.allocator, "s", false);
    defer a.deinit();
    var tok: [32]u8 = undefined;
    var csrf: [32]u8 = undefined;
    try std.testing.expectError(error.OidcDisabled, a.oidcCallback("c", "state", &tok, &csrf));

    a.oidc = test_oidc;
    try std.testing.expectError(error.BadRequest, a.oidcCallback("", "state", &tok, &csrf));
    try std.testing.expectError(error.OidcStateMismatch, a.oidcCallback("code", "deadbeef", &tok, &csrf));
}

test "oidc email domain allowlist" {
    var a = Auth.init(std.testing.allocator, "s", false);
    defer a.deinit();
    a.oidc = test_oidc;
    try std.testing.expect(a.emailAllowed("anyone@anywhere.test"));

    a.oidc.allowed_email_domains = "example.com, corp.test";
    try std.testing.expect(a.emailAllowed("ops@example.com"));
    try std.testing.expect(a.emailAllowed("ops@CORP.TEST"));
    try std.testing.expect(!a.emailAllowed("ops@evil.test"));
    try std.testing.expect(!a.emailAllowed("no-at-sign"));
}

test "oidc auto-provisions a viewer and keeps local roles" {
    var a = Auth.init(std.testing.allocator, "s", false);
    defer a.deinit();
    a.oidc = test_oidc;

    const idx = a.userForOidc("new@corp.test");
    try std.testing.expectEqualStrings("new@corp.test", a.users.items[idx].name);
    try std.testing.expectEqualStrings("viewer", a.users.items[idx].role);
    try std.testing.expect(!a.canMutate(idx));

    // Same identity again resolves to the same row.
    try std.testing.expectEqual(idx, a.userForOidc("new@corp.test"));

    try a.addUser("admin@corp.test:pw:admin");
    const aidx = a.userForOidc("admin@corp.test");
    try std.testing.expectEqualStrings("admin", a.users.items[aidx].role);
    try std.testing.expect(a.canMutate(aidx));
}

test "oidc token response parsing" {
    var a = Auth.init(std.testing.allocator, "s", false);
    defer a.deinit();

    const tok = try a.parseAccessToken("{\"access_token\":\"abc123\",\"token_type\":\"Bearer\"}");
    defer a.alloc.free(tok);
    try std.testing.expectEqualStrings("abc123", tok);

    try std.testing.expectError(error.OidcProviderError, a.parseAccessToken("{\"error\":\"invalid_grant\"}"));
    try std.testing.expectError(error.OidcProviderError, a.parseAccessToken("not json"));
    try std.testing.expectError(error.OidcProviderError, a.parseAccessToken("{\"token_type\":\"Bearer\"}"));
}
