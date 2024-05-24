const std = @import("std");
const rank = @import("rank.zig");

const HOME = "HOME";

const help: []const u8 =
    \\usage:
    \\  d <command> [options]
    \\commands:
    \\  cd <target>      navigate
    \\  clone <target>   clone repo
    \\  open pr          open pr on github
    \\options:
    \\  -v      verbose output
    \\
;

const Command = enum {
    cd,
    clone,
    open,
};

const Args = struct { cmd: Command, homePath: []const u8, srcPath: []const u8, hostPath: []const u8, destination: []const u8, verbose: bool };

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const args = parseArgs(arena.allocator()) catch |e| {
        switch (e) {
            error.InvalidArgs => {
                std.debug.print(help, .{});
                std.process.exit(1);
            },
            else => return e,
        }
    };

    const command = switch (args.cmd) {
        .cd => try handleCdCommand(arena.allocator(), args),
        .clone => try handleCloneCommand(arena.allocator(), args),
        .open => try handleOpenPRCommand(arena.allocator()),
    } orelse {
        std.debug.print("no match found\n", .{});
        std.process.exit(1);
    };

    const stdout = std.io.getStdOut().writer();
    _ = try stdout.write(command);
}

const ErrorD = error{ InvalidArgs, NoHomeVar, OutOfMemory, EnvironmentVariableNotFound, Overflow, InvalidWtf8 };

fn parseArgs(allocator: std.mem.Allocator) ErrorD!Args {
    const args = try std.process.argsAlloc(allocator);
    if (args.len < 3 or args.len > 4) {
        return ErrorD.InvalidArgs;
    }
    const command = std.meta.stringToEnum(Command, args[1]) orelse {
        return ErrorD.InvalidArgs;
    };

    const destination = args[2];
    if (command == .open and !std.mem.eql(u8, destination, "pr")) {
        return ErrorD.InvalidArgs;
    }

    var verbose = false;
    if (args.len == 4) {
        verbose = std.mem.eql(u8, args[3], "-v");
        if (!verbose) {
            return ErrorD.InvalidArgs;
        }
    }
    // static for now
    const srcPath = "src";
    const hostPath = "github.com";

    const homePath = try std.process.getEnvVarOwned(allocator, HOME);

    return Args{ .cmd = command, .homePath = homePath, .srcPath = srcPath, .hostPath = hostPath, .destination = destination, .verbose = verbose };
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

fn getOwnerAndPathFromUrl(url: []const u8) ?struct { owner: []const u8, path: []const u8 } {
    const partsCleaned = std.mem.trimRight(u8, url, "/");
    var parts = std.mem.splitSequence(u8, partsCleaned, "/");

    var owner: []const u8 = "";
    var path: []const u8 = "";

    var prevPart: ?[]const u8 = null;
    var currentPart: ?[]const u8 = null;

    while (parts.next()) |part| {
        prevPart = currentPart;
        currentPart = part;
    }

    owner = prevPart orelse return null;
    path = currentPart orelse return null;

    // Trim ".git" suffix if present
    const gitSuffix = ".git";
    if (std.mem.endsWith(u8, path, gitSuffix)) {
        path = path[0 .. path.len - gitSuffix.len];
    }

    var newOwner = std.mem.splitSequence(u8, owner, ":");
    while (newOwner.next()) |part| {
        owner = part;
    }

    return .{ .owner = owner, .path = path };
}

fn handleCloneCommand(allocator: std.mem.Allocator, args: Args) !?[]const u8 {
    const ownerAndPath = getOwnerAndPathFromUrl(args.destination) orelse return try std.mem.concat(allocator, comptime u8, &[_][]const u8{ "git clone ", args.destination });

    const destinationPath = try std.mem.join(allocator, "/", &[_][]const u8{ args.homePath, args.srcPath, args.hostPath, ownerAndPath.owner, ownerAndPath.path });
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

// branch=`git rev-parse --abbrev-ref HEAD`
// rawUrl=`git config --get remote.origin.url | awk '{sub(/:/,"/")}1' | awk '{sub(/git@/,"https://")}1' | sed 's/.git$//'`
// finalUrl="${rawUrl}/compare/${branch}?expand=1"

fn handleOpenPRCommand(allocator: std.mem.Allocator) !?[]const u8 {

    // Execute the first command to get the branch name
    var branch_cmd = std.ChildProcess.init(&[_][]const u8{ "git", "rev-parse", "--abbrev-ref", "HEAD" }, allocator);
    branch_cmd.stdout_behavior = .Pipe;
    try branch_cmd.spawn();
    const file = branch_cmd.stdout orelse {
        return null;
    };
    const branch_output = try file.reader().readAllAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(branch_output);
    _ = try branch_cmd.wait();

    // Strip the newline character from the branch name
    const branch_name = branch_output[0 .. branch_output.len - 1];

    // Execute the second command to get the raw URL
    var url_cmd = std.ChildProcess.init(&[_][]const u8{ "git", "config", "--get", "remote.origin.url" }, allocator);
    url_cmd.stdout_behavior = .Pipe;
    try url_cmd.spawn();
    var raw_url_output = try url_cmd.stdout.?.reader().readAllAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(raw_url_output);
    _ = try url_cmd.wait();

    // Strip the newline character from the branch name
    const raw_url = raw_url_output[0 .. raw_url_output.len - 1];

    const ownerAndPath = getOwnerAndPathFromUrl(raw_url) orelse return null;
    const rawUrl = try std.mem.join(allocator, "/", &[_][]const u8{ "https://github.com", ownerAndPath.owner, ownerAndPath.path });

    // const final_url = try allocator.alloc(u8, raw_url.len + compare_str.len + branch_name.len + expand_str.len);
    const final_url = try std.mem.join(allocator, "", &[_][]const u8{ "open \"", rawUrl, "/compare/", branch_name, "?expand=1\"" });

    return final_url;
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
    defer allocator.free(result);
    const fileDir = std.fs.cwd().openDir(result, .{}) catch |e|
        switch (e) {
        error.FileNotFound => {
            std.log.info("first run, creating {s}", .{result});

            std.fs.cwd().makeDir(result) catch |err2|
                switch (err2) {
                error.FileNotFound => {
                    const absoluteSrcPath = try std.mem.join(allocator, "/", slicePath[0..2]);
                    try std.fs.cwd().makeDir(absoluteSrcPath);

                    try std.fs.cwd().makeDir(result);
                },
                else => return err2,
            };
            return try std.fs.cwd().openDir(result, .{});
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
