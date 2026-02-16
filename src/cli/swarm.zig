const std = @import("std");
const swarm_init = @import("swarm_init.zig");
const swarm_generate = @import("swarm_generate.zig");
const swarm_simulate = @import("swarm_simulate.zig");
const swarm_clean = @import("swarm_clean.zig");
const swarm_status = @import("swarm_status.zig");

pub const SwarmCmd = union(enum) {
    init: swarm_init.SwarmInitCmd,
    @"generate-appliances": swarm_generate.GenerateAppliancesCmd,
    @"generate-devices": swarm_generate.GenerateDevicesCmd,
    simulate: swarm_simulate.SwarmSimulateCmd,
    clean: swarm_clean.SwarmCleanCmd,
    status: swarm_status.SwarmStatusCmd,

    pub const meta = .{
        .description = "Swarm management - fleet/device simulation tools",
    };
};
