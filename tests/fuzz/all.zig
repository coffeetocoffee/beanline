//! Aggregates the fuzz targets' own unit tests into one test binary so
//! `zig build test` covers both the library and the fuzz harness.
test {
    _ = @import("harness.zig");
    _ = @import("resp_decode.zig");
    _ = @import("cron_parse.zig");
    _ = @import("args_json.zig");
}
