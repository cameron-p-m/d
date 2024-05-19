const std = @import("std");
const rank = @import("rank.zig");

const help: []const u8 =
    \\usage:
    \\  d <command> [options]
    \\commands:
    \\  cd      navigate
    \\  clone   clone repo
    \\options:
    \\  -v      verbose output
    \\
;

const Command = enum {
    cd,
    clone,
};

const Args = struct { cmd: Command, homePath: []const u8, srcPath: []const u8, hostPath: []const u8, destination: []const u8, verbose: bool };

const ErrInvalidPath = error{};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const args = try parseArgs(arena.allocator());

    const command = switch (args.cmd) {
        .cd => try handleCdCommand(arena.allocator(), args),
        .clone => try handleCloneCommand(arena.allocator(), args),
    } orelse {
        std.debug.print("no match found\n", .{});
        std.process.exit(1);
    };

    const stdout = std.io.getStdOut().writer();
    _ = try stdout.write(command);
}

fn parseArgs(allocator: std.mem.Allocator) !Args {
    var desiredPath: [:0]const u8 = "";
    var verbose = false;
    var invalidArgs = false;
    var command: Command = .cd;

    const args = try std.process.argsAlloc(allocator);

    for (args, 0..) |arg, i| {
        // binary is first arg
        if (i == 0) {
            continue;
        }
        if (i == 1) {
            command = std.meta.stringToEnum(Command, arg) orelse {
                invalidArgs = true;
                break;
            };
            continue;
        }

        if (std.mem.eql(u8, arg, "-v")) {
            verbose = true;
            continue;
        }

        desiredPath = arg;
    }

    if (std.mem.eql(u8, desiredPath, "")) {
        invalidArgs = true;
    }
    if (invalidArgs) {
        std.debug.print(help, .{});
        std.process.exit(1);
    }

    const HOME = "HOME";

    // should support more hosts
    const srcPath = "src";
    const hostPath = "github.com";

    const homePath = std.process.getEnvVarOwned(allocator, HOME) catch |err| {
        std.debug.print("no HOME env var found {any}", .{err});
        std.process.exit(2);
    };

    if (verbose) {
        std.debug.print("desired: {s}\n\n", .{desiredPath});
    }

    return Args{ .cmd = command, .homePath = homePath, .srcPath = srcPath, .hostPath = hostPath, .destination = desiredPath, .verbose = verbose };
}

fn handleCdCommand(allocator: std.mem.Allocator, args: Args) !?[]const u8 {
    var dir = try createOrOpenDir(allocator, args);
    defer dir.close();

    var candidates = try getCandidates(allocator, dir, args);
    defer candidates.deinit();

    const filtered = try rank.rankCandidates(allocator, candidates.items, args.destination, true);

    if (filtered.len > 0) {
        if (args.verbose) {
            printDebugInfo(filtered);
        }
        return try std.mem.concat(allocator, comptime u8, &[_][]const u8{ "cd ", filtered[0].str });
    }

    return null;
}

// hadles https://github.com/cameron-p-m/dotfiles.git
// git clone git@github.com:cameron-p-m/dotfiles.git /Users/cameronmorgan/src/github.com/cameron-p-m/dotfiles-test && cd /Users/cameronmorgan/src/github.com/cameron-p-m/dotfiles-test
fn handleCloneCommand(allocator: std.mem.Allocator, args: Args) !?[]const u8 {
    const partsCleaned = std.mem.trimRight(u8, args.destination, "/");
    var parts = std.mem.splitSequence(u8, partsCleaned, "/");

    var owner: []const u8 = "";
    var path: []const u8 = "";

    var prevPart: ?[]const u8 = null;
    var currentPart: ?[]const u8 = null;

    while (parts.next()) |part| {
        prevPart = currentPart;
        currentPart = part;
    }

    owner = prevPart orelse return try std.mem.concat(allocator, comptime u8, &[_][]const u8{ "git clone ", args.destination });
    path = currentPart orelse return try std.mem.concat(allocator, comptime u8, &[_][]const u8{ "git clone ", args.destination });

    // Trim ".git" suffix if present
    const gitSuffix = ".git";
    if (std.mem.endsWith(u8, path, gitSuffix)) {
        path = path[0 .. path.len - gitSuffix.len];
    }

    var newOwner = std.mem.splitSequence(u8, owner, ":");
    while (newOwner.next()) |part| {
        owner = part;
    }

    const destinationPath = try std.mem.join(allocator, "/", &[_][]const u8{ args.homePath, args.srcPath, args.hostPath, owner, path });
    defer allocator.free(destinationPath);
    const concatenated = try std.mem.concat(allocator, comptime u8, &[_][]const u8{ "git clone ", args.destination, " ", destinationPath, " && cd ", destinationPath });
    return concatenated;
}

test "handle clone" {
    const alloc = std.testing.allocator;

    var args = Args{
        .cmd = .clone,
        .destination = "",
        .homePath = "/Users/testuser",
        .hostPath = "github.com",
        .srcPath = "src",
        .verbose = false,
    };

    const testCases = [_]struct {
        destination: []const u8,
        expected: []const u8,
    }{
        .{ .destination = "git@github.com:cameron-p-m/test.git", .expected = "git clone git@github.com:cameron-p-m/test.git /Users/testuser/src/github.com/cameron-p-m/test && cd /Users/testuser/src/github.com/cameron-p-m/test" },
        .{ .destination = "https://github.com/cameron-p-m/test.git", .expected = "git clone https://github.com/cameron-p-m/test.git /Users/testuser/src/github.com/cameron-p-m/test && cd /Users/testuser/src/github.com/cameron-p-m/test" },
        .{ .destination = "git@github.com:cameron-p-m/test", .expected = "git clone git@github.com:cameron-p-m/test /Users/testuser/src/github.com/cameron-p-m/test && cd /Users/testuser/src/github.com/cameron-p-m/test" },
        .{ .destination = "git@github.com/", .expected = "git clone git@github.com/" },
        .{ .destination = "https://github.com/cameron-p-m/subdir/test.git", .expected = "git clone https://github.com/cameron-p-m/subdir/test.git /Users/testuser/src/github.com/subdir/test && cd /Users/testuser/src/github.com/subdir/test" },
        .{ .destination = "https://github.com/cameron-p-m/test.git/", .expected = "git clone https://github.com/cameron-p-m/test.git/ /Users/testuser/src/github.com/cameron-p-m/test && cd /Users/testuser/src/github.com/cameron-p-m/test" },
        .{ .destination = "https://github.com/cameron-p-m/test.repo.git", .expected = "git clone https://github.com/cameron-p-m/test.repo.git /Users/testuser/src/github.com/cameron-p-m/test.repo && cd /Users/testuser/src/github.com/cameron-p-m/test.repo" },
        .{ .destination = "git@github.com:another-user/test.git", .expected = "git clone git@github.com:another-user/test.git /Users/testuser/src/github.com/another-user/test && cd /Users/testuser/src/github.com/another-user/test" },
        .{ .destination = "https://github.com:another-user/test.git", .expected = "git clone https://github.com:another-user/test.git /Users/testuser/src/github.com/another-user/test && cd /Users/testuser/src/github.com/another-user/test" },
    };

    for (testCases) |testCase| {
        args.destination = testCase.destination;
        const out = try handleCloneCommand(alloc, args) orelse return try std.testing.expect(false);
        defer alloc.free(out);
        try std.testing.expectEqualStrings(testCase.expected, out);
    }
}

fn printDebugInfo(cadidates: []rank.Candidate) void {
    std.debug.print("top:\n", .{});
    const size = @min(cadidates.len, 5);
    for (cadidates[0..size]) |elem| {
        std.debug.print("{d} {s}\n", .{ elem.rank, elem.str });
    }
    std.debug.print("command:\n cd {s}\n", .{cadidates[0].str});
}

fn createOrOpenDir(allocator: std.mem.Allocator, args: Args) !std.fs.Dir {
    const slicePath = &[_][]const u8{ args.homePath, args.srcPath, args.hostPath };
    const result = try std.mem.join(allocator, "/", slicePath);

    const fileDir = std.fs.openDirAbsolute(result, .{}) catch |e|
        switch (e) {
        error.FileNotFound => {
            std.log.info("first run, creating {s}", .{result});

            std.fs.makeDirAbsolute(result) catch |err2|
                switch (err2) {
                error.FileNotFound => {
                    const absoluteSrcPath = try std.mem.join(allocator, "/", slicePath[0..2]);
                    try std.fs.makeDirAbsolute(absoluteSrcPath);

                    try std.fs.makeDirAbsolute(result);
                },
                else => return err2,
            };
            return try std.fs.openDirAbsolute(result, .{});
        },
        else => return e,
    };

    return fileDir;
}

pub fn getCandidates(allocator: std.mem.Allocator, dir: std.fs.Dir, args: Args) !std.ArrayList([]const u8) {
    var candidates = try std.ArrayList([]const u8).initCapacity(allocator, 50);

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != std.fs.File.Kind.directory) {
            continue;
        }
        const newPath = try std.mem.join(allocator, "/", &[_][]const u8{ args.homePath, args.srcPath, args.hostPath, entry.name });
        var entryDir = try std.fs.openDirAbsolute(newPath, .{});
        defer entryDir.close();
        var entryIterator = entryDir.iterate();
        while (try entryIterator.next()) |subEntry| {
            if (subEntry.kind != std.fs.File.Kind.directory) {
                continue;
            }
            const subPath = try std.mem.join(allocator, "/", &[_][]const u8{ args.homePath, args.srcPath, args.hostPath, entry.name, subEntry.name });
            try candidates.append(subPath);
        }
    }

    return candidates;
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
