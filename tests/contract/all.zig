const std = @import("std");
const harness = @import("harness.zig");
const contract = @import("contract.zig");

test "contract suite: postgres" {
    try harness.runAll(.postgres, &contract.contract_cases, &contract.divergence_probes);
}

test "contract suite: redis" {
    try harness.runAll(.redis, &contract.contract_cases, &contract.divergence_probes);
}
