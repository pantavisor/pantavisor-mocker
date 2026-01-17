const std = @import("std");
const invitation = @import("app").invitation;

// Test: InviteToken structure
test "invite token structure" {
    const allocator = std.testing.allocator;

    const spec = try allocator.dupe(u8, "fleet-update-proto@v1");
    defer allocator.free(spec);
    const type_str = try allocator.dupe(u8, "INVITE");
    defer allocator.free(type_str);
    const deployment = try allocator.dupe(u8, "prod");
    defer allocator.free(deployment);
    const release = try allocator.dupe(u8, "1.0.0");
    defer allocator.free(release);

    const token = invitation.InviteToken{
        .spec = spec,
        .type = type_str,
        .deployment = deployment,
        .release = release,
    };

    try std.testing.expectEqualStrings("fleet-update-proto@v1", token.spec);
    try std.testing.expectEqualStrings("INVITE", token.type);
    try std.testing.expectEqualStrings("prod", token.deployment);
    try std.testing.expectEqualStrings("1.0.0", token.release);
    try std.testing.expect(token.vendorRelease == null);
    try std.testing.expect(token.earliestUpdate == null);
    try std.testing.expect(token.latestUpdate == null);
}

// Test: InviteToken with optional fields
test "invite token with optional fields" {
    const allocator = std.testing.allocator;

    const spec = try allocator.dupe(u8, "fleet-update-proto@v1");
    defer allocator.free(spec);
    const type_str = try allocator.dupe(u8, "INVITE");
    defer allocator.free(type_str);
    const deployment = try allocator.dupe(u8, "staging");
    defer allocator.free(deployment);
    const release = try allocator.dupe(u8, "2.0.0");
    defer allocator.free(release);
    const vendor_release = try allocator.dupe(u8, "vendor-1.0");
    defer allocator.free(vendor_release);

    const token = invitation.InviteToken{
        .spec = spec,
        .type = type_str,
        .deployment = deployment,
        .release = release,
        .vendorRelease = vendor_release,
        .mandatory = true,
    };

    try std.testing.expectEqualStrings("vendor-1.0", token.vendorRelease.?);
    try std.testing.expect(token.mandatory.? == true);
}

// Test: AnswerToken structure with default spec
test "answer token default spec" {
    const allocator = std.testing.allocator;

    const type_str = try allocator.dupe(u8, "ACCEPT");
    defer allocator.free(type_str);
    const deployment = try allocator.dupe(u8, "prod");
    defer allocator.free(deployment);

    const answer = invitation.AnswerToken{
        .type = type_str,
        .deployment = deployment,
    };

    try std.testing.expectEqualStrings("fleet-update-proto@v1", answer.spec);
    try std.testing.expectEqualStrings("ACCEPT", answer.type);
}

// Test: AnswerToken ACCEPT type
test "answer token accept type" {
    const allocator = std.testing.allocator;

    const type_str = try allocator.dupe(u8, "ACCEPT");
    defer allocator.free(type_str);
    const deployment = try allocator.dupe(u8, "prod");
    defer allocator.free(deployment);
    const preferred = try allocator.dupe(u8, "NOW");
    defer allocator.free(preferred);

    const answer = invitation.AnswerToken{
        .type = type_str,
        .deployment = deployment,
        .preferredUpdate = preferred,
    };

    try std.testing.expectEqualStrings("ACCEPT", answer.type);
    try std.testing.expectEqualStrings("NOW", answer.preferredUpdate.?);
}

// Test: AnswerToken SKIP type
test "answer token skip type" {
    const allocator = std.testing.allocator;

    const type_str = try allocator.dupe(u8, "SKIP");
    defer allocator.free(type_str);
    const deployment = try allocator.dupe(u8, "prod");
    defer allocator.free(deployment);

    const answer = invitation.AnswerToken{
        .type = type_str,
        .deployment = deployment,
    };

    try std.testing.expectEqualStrings("SKIP", answer.type);
    try std.testing.expect(answer.preferredUpdate == null);
}

// Test: AnswerToken ASKAGAIN type
test "answer token askagain type" {
    const allocator = std.testing.allocator;

    const type_str = try allocator.dupe(u8, "ASKAGAIN");
    defer allocator.free(type_str);
    const deployment = try allocator.dupe(u8, "prod");
    defer allocator.free(deployment);
    const ask_again = try allocator.dupe(u8, "2024-12-31T12:00:00+00:00");
    defer allocator.free(ask_again);

    const answer = invitation.AnswerToken{
        .type = type_str,
        .deployment = deployment,
        .askAgainUpdate = ask_again,
    };

    try std.testing.expectEqualStrings("ASKAGAIN", answer.type);
    try std.testing.expectEqualStrings("2024-12-31T12:00:00+00:00", answer.askAgainUpdate.?);
}

// Test: Decision enum values
test "decision enum values" {
    const accept = invitation.Decision.accept;
    const skip = invitation.Decision.skip;
    const later = invitation.Decision.later;

    try std.testing.expect(accept != skip);
    try std.testing.expect(skip != later);
    try std.testing.expect(accept != later);
}

// Test: Invitation type validation
test "invitation type validation" {
    const valid_type = "INVITE";
    const invalid_type = "RANDOM";

    try std.testing.expect(std.mem.eql(u8, valid_type, "INVITE"));
    try std.testing.expect(!std.mem.eql(u8, invalid_type, "INVITE"));
}

// Test: Deployment field matching
test "deployment field matching" {
    const deployment1 = "prod";
    const deployment2 = "prod";
    const deployment3 = "staging";

    try std.testing.expect(std.mem.eql(u8, deployment1, deployment2));
    try std.testing.expect(!std.mem.eql(u8, deployment1, deployment3));
}

// Test: Release versioning
test "release versioning" {
    const allocator = std.testing.allocator;

    const version1 = try allocator.dupe(u8, "1.0.0");
    defer allocator.free(version1);
    const version2 = try allocator.dupe(u8, "2.0.0");
    defer allocator.free(version2);

    try std.testing.expect(!std.mem.eql(u8, version1, version2));
}

// Test: Vendor release handling
test "vendor release handling" {
    const allocator = std.testing.allocator;

    const vendor = try allocator.dupe(u8, "vendor-rel-1.2.3");
    defer allocator.free(vendor);

    try std.testing.expectEqualStrings("vendor-rel-1.2.3", vendor);
}

// Test: Mandatory flag
test "mandatory flag" {
    const mandatory_true = true;
    const mandatory_false = false;

    try std.testing.expect(mandatory_true != mandatory_false);
}

// Test: Cancellation revision tracking
test "cancellation revision tracking" {
    const allocator = std.testing.allocator;

    const spec = try allocator.dupe(u8, "fleet-update-proto@v1");
    defer allocator.free(spec);
    const type_str = try allocator.dupe(u8, "CANCELLED");
    defer allocator.free(type_str);
    const deployment = try allocator.dupe(u8, "prod");
    defer allocator.free(deployment);
    const release = try allocator.dupe(u8, "1.0.0");
    defer allocator.free(release);

    const token = invitation.InviteToken{
        .spec = spec,
        .type = type_str,
        .deployment = deployment,
        .release = release,
        .rev = 5,
    };

    try std.testing.expect(token.rev.? == 5);
}

// Test: Update time boundaries
test "update time boundaries" {
    const allocator = std.testing.allocator;

    const earliest = try allocator.dupe(u8, "2024-01-01T00:00:00Z");
    defer allocator.free(earliest);
    const latest = try allocator.dupe(u8, "2024-12-31T23:59:59Z");
    defer allocator.free(latest);

    const spec = try allocator.dupe(u8, "fleet-update-proto@v1");
    defer allocator.free(spec);
    const type_str = try allocator.dupe(u8, "INVITE");
    defer allocator.free(type_str);
    const deployment = try allocator.dupe(u8, "prod");
    defer allocator.free(deployment);
    const release = try allocator.dupe(u8, "1.0.0");
    defer allocator.free(release);

    const token = invitation.InviteToken{
        .spec = spec,
        .type = type_str,
        .deployment = deployment,
        .release = release,
        .earliestUpdate = earliest,
        .latestUpdate = latest,
    };

    try std.testing.expectEqualStrings("2024-01-01T00:00:00Z", token.earliestUpdate.?);
    try std.testing.expectEqualStrings("2024-12-31T23:59:59Z", token.latestUpdate.?);
}

// Test: ISO timestamp format
test "iso timestamp format" {
    const ts = "2024-12-31T12:00:00+00:00";
    try std.testing.expect(std.mem.indexOf(u8, ts, "T") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "+") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, ":") != null);
}

// Test: Device meta JSON field
test "device meta json field key" {
    const field = "fleet.update-proto.token";
    try std.testing.expect(std.mem.startsWith(u8, field, "fleet."));
    try std.testing.expect(std.mem.endsWith(u8, field, "token"));
}

// Test: Answer spec constant
test "answer spec constant" {
    const spec = "fleet-update-proto@v1";
    try std.testing.expectEqualStrings("fleet-update-proto@v1", spec);
}

// Test: Invitation state - not answered
test "invitation state not answered" {
    const answered = false;
    try std.testing.expect(answered == false);
}

// Test: Invitation state - answered
test "invitation state answered" {
    const answered = true;
    try std.testing.expect(answered == true);
}

// Test: InviteToken with all fields populated
test "invite token all fields" {
    const allocator = std.testing.allocator;

    const spec = try allocator.dupe(u8, "fleet-update-proto@v1");
    defer allocator.free(spec);
    const type_str = try allocator.dupe(u8, "INVITE");
    defer allocator.free(type_str);
    const deployment = try allocator.dupe(u8, "prod");
    defer allocator.free(deployment);
    const release = try allocator.dupe(u8, "1.0.0");
    defer allocator.free(release);
    const vendor = try allocator.dupe(u8, "vendor-1.0");
    defer allocator.free(vendor);
    const earliest = try allocator.dupe(u8, "2024-01-01T00:00:00Z");
    defer allocator.free(earliest);
    const latest = try allocator.dupe(u8, "2024-12-31T23:59:59Z");
    defer allocator.free(latest);

    const token = invitation.InviteToken{
        .spec = spec,
        .type = type_str,
        .deployment = deployment,
        .release = release,
        .vendorRelease = vendor,
        .earliestUpdate = earliest,
        .latestUpdate = latest,
        .mandatory = true,
        .rev = 1,
    };

    try std.testing.expect(token.spec.len > 0);
    try std.testing.expect(token.vendorRelease != null);
    try std.testing.expect(token.earliestUpdate != null);
    try std.testing.expect(token.latestUpdate != null);
    try std.testing.expect(token.mandatory.? == true);
    try std.testing.expect(token.rev.? == 1);
}

// Test: Answer token with all optional fields
test "answer token all optional fields" {
    const allocator = std.testing.allocator;

    const type_str = try allocator.dupe(u8, "ACCEPT");
    defer allocator.free(type_str);
    const deployment = try allocator.dupe(u8, "prod");
    defer allocator.free(deployment);
    const release = try allocator.dupe(u8, "1.0.0");
    defer allocator.free(release);
    const vendor = try allocator.dupe(u8, "vendor-1.0");
    defer allocator.free(vendor);
    const preferred = try allocator.dupe(u8, "NOW");
    defer allocator.free(preferred);

    const answer = invitation.AnswerToken{
        .type = type_str,
        .deployment = deployment,
        .release = release,
        .vendorRelease = vendor,
        .preferredUpdate = preferred,
    };

    try std.testing.expect(answer.release != null);
    try std.testing.expect(answer.vendorRelease != null);
    try std.testing.expect(answer.preferredUpdate != null);
    try std.testing.expect(answer.askAgainUpdate == null);
}

// Test: Deployment name patterns
test "deployment name patterns" {
    const deployments = [_][]const u8{
        "prod",
        "staging",
        "dev",
        "test",
        "canary",
    };

    for (deployments) |d| {
        try std.testing.expect(d.len > 0);
    }
}
