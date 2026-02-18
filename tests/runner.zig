const std = @import("std");

test {
    _ = @import("client_tests.zig");
    _ = @import("integration_tests.zig");
    _ = @import("invitation_tests.zig");
    _ = @import("meta_tests.zig");
    _ = @import("update_flow_tests.zig");
    _ = @import("validation_tests.zig");
    _ = @import("pvcontrol_tests.zig");
    _ = @import("app");
}
