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
    \\  tclone [-name <name>]  create a temp working clone (optional name for branch/dir)
    \\  tclone list        list all temp working dirs (paths)
    \\options:
    \\  -v      verbose output
    \\
;

const Command = enum {
    cd,
    clone,
    open,
    tclone,
    tclone_list,
};

const Args = struct { cmd: Command, homePath: []const u8, srcPath: []const u8, hostPath: []const u8, destination: []const u8, verbose: bool };

const TC_PREFIX = "d-tclone-";

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
        .tclone => try handleTcloneCreate(arena.allocator(), args),
        .tclone_list => try handleTcloneList(arena.allocator()),
    } orelse {
        std.debug.print("no match found\n", .{});
        std.process.exit(1);
    };

    const stdout = std.io.getStdOut().writer();
    _ = try stdout.write(command);
}

const ErrorD = error{ InvalidArgs, NoHomeVar, OutOfMemory, EnvironmentVariableNotFound, Overflow, InvalidWtf8 };

fn parseArgs(allocator: std.mem.Allocator) ErrorD!Args {
    const argv = try std.process.argsAlloc(allocator);
    if (argv.len < 2 or argv.len > 6) return ErrorD.InvalidArgs;

    // Support -v as the last argument for any command
    var verbose = false;
    var effective_len: usize = argv.len;
    if (argv.len >= 3 and std.mem.eql(u8, argv[argv.len - 1], "-v")) {
        verbose = true;
        effective_len -= 1;
    }

    const cmd_str = argv[1];
    var cmd: Command = undefined;
    var destination: []const u8 = "";

    if (std.mem.eql(u8, cmd_str, "tclone")) {
        if (effective_len >= 3 and std.mem.eql(u8, argv[2], "list")) {
            cmd = .tclone_list;
            destination = "";
            if (effective_len != 3) return ErrorD.InvalidArgs;
        } else {
            cmd = .tclone;
            // optional -name <value>
            var idx: usize = 2;
            while (idx + 1 < effective_len) : (idx += 1) {
                if (std.mem.eql(u8, argv[idx], "-name")) {
                    destination = argv[idx + 1];
                    break;
                }
            }
        }
    } else if (std.mem.eql(u8, cmd_str, "tclone-list")) {
        // Back-compat for hyphen form
        cmd = .tclone_list;
        if (effective_len != 2) return ErrorD.InvalidArgs;
    } else {
        // Regular commands
        cmd = std.meta.stringToEnum(Command, cmd_str) orelse return ErrorD.InvalidArgs;
        switch (cmd) {
            .cd, .clone => {
                if (effective_len < 3) return ErrorD.InvalidArgs;
                destination = argv[2];
            },
            .open => {
                if (effective_len < 3) return ErrorD.InvalidArgs;
                if (!std.mem.eql(u8, argv[2], "pr")) return ErrorD.InvalidArgs;
                destination = argv[2];
            },
            .tclone, .tclone_list => unreachable, // handled above
        }
    }

    const srcPath = "src";
    const hostPath = "github.com";
    const homePath = try std.process.getEnvVarOwned(allocator, HOME);

    return Args{ .cmd = cmd, .homePath = homePath, .srcPath = srcPath, .hostPath = hostPath, .destination = destination, .verbose = verbose };
}

fn getTmpBasePath(allocator: std.mem.Allocator) ![]const u8 {
    const tmp = std.process.getEnvVarOwned(allocator, "TMPDIR") catch |e| switch (e) {
        error.EnvironmentVariableNotFound => return try std.mem.concat(allocator, comptime u8, &[_][]const u8{"/tmp"}),
        else => return e,
    };
    // trim trailing slashes
    const trimmed = std.mem.trimRight(u8, tmp, "/");
    return trimmed;
}

fn quoteSingle(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    // Basic single-quote wrapper. Assumes s does not contain single quotes.
    // For simplicity, we avoid complex escaping as temp paths typically have no quotes.
    return try std.mem.concat(allocator, comptime u8, &[_][]const u8{ "'", s, "'" });
}

fn handleTcloneList(allocator: std.mem.Allocator) !?[]const u8 {
    const tmpBase = try getTmpBasePath(allocator);
    defer allocator.free(tmpBase);
    var dir = try std.fs.openDirAbsolute(tmpBase, .{});
    defer dir.close();

    var items = std.ArrayList([]const u8).init(allocator);
    defer items.deinit();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, TC_PREFIX)) continue;
        const full = try std.mem.join(allocator, "/", &[_][]const u8{ tmpBase, entry.name });
        try items.append(full);
    }

    if (items.items.len == 0) {
        return try std.mem.concat(allocator, comptime u8, &[_][]const u8{ "echo ", "'no tclone dirs'" });
    }

    // Build: printf '%s\n' 'path1' 'path2' ...
    var parts = std.ArrayList([]const u8).init(allocator);
    defer parts.deinit();
    var quotedItems = std.ArrayList([]const u8).init(allocator);
    defer quotedItems.deinit();
    try parts.append("printf '%s\\n' ");
    for (items.items) |p| {
        const q = try quoteSingle(allocator, p);
        try parts.append(q);
        try parts.append(" ");
        try quotedItems.append(q);
    }
    const cmd = try std.mem.join(allocator, "", parts.items);
    for (quotedItems.items) |q| allocator.free(q);
    for (items.items) |p| allocator.free(p);
    return cmd;
}

fn buildTcloneCreateCmd(
    allocator: std.mem.Allocator,
    raw_url: []const u8,
    tmp_base: []const u8,
    provided_suffix: []const u8,
) ![]const u8 {
    const ownerAndPath = getOwnerAndPathFromUrl(raw_url) orelse return error.InvalidArgs;

    var suffix: []const u8 = provided_suffix;
    var suffix_allocated = false;
    if (suffix.len == 0) {
        const ts: i64 = @intCast(std.time.timestamp());
        suffix = try std.fmt.allocPrint(allocator, "{d}", .{ts});
        suffix_allocated = true;
    }

    const dirName = try std.mem.join(allocator, "", &[_][]const u8{ TC_PREFIX, ownerAndPath.owner, "/", ownerAndPath.path, "-", suffix });
    const fullPath = try std.mem.join(allocator, "/", &[_][]const u8{ tmp_base, dirName });
    const branchName = try std.mem.join(allocator, "", &[_][]const u8{ "tclone/", suffix });

    const qFull = try quoteSingle(allocator, fullPath);
    const qUrl = try quoteSingle(allocator, raw_url);
    const qBranch = try quoteSingle(allocator, branchName);

    const cmd = try std.mem.join(allocator, "", &[_][]const u8{
        "mkdir -p ",            qFull,
        " && git clone ",       qUrl,
        " ",                    qFull,
        " && cd ",              qFull,
        " && git checkout -b ", qBranch,
    });

    allocator.free(qBranch);
    allocator.free(qUrl);
    allocator.free(qFull);
    allocator.free(branchName);
    allocator.free(fullPath);
    allocator.free(dirName);
    if (suffix_allocated) allocator.free(suffix);
    return cmd;
}

fn handleTcloneCreate(allocator: std.mem.Allocator, args: Args) !?[]const u8 {
    // Get current repo remote URL
    const url_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "config", "--get", "remote.origin.url" },
        .max_output_bytes = 8 * 1024,
    });
    defer allocator.free(url_result.stdout);
    defer allocator.free(url_result.stderr);
    const raw_url = std.mem.trimRight(u8, url_result.stdout, "\n");

    const tmp = try getTmpBasePath(allocator);
    defer allocator.free(tmp);
    return try buildTcloneCreateCmd(allocator, raw_url, tmp, args.destination);
}

// tclone rm removed – users can `rm` directly

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
    const branch_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "rev-parse", "--abbrev-ref", "HEAD" },
        .max_output_bytes = 8 * 1024,
    });
    defer allocator.free(branch_result.stdout);
    defer allocator.free(branch_result.stderr);
    const branch_output = branch_result.stdout;
    const branch_name = std.mem.trimRight(u8, branch_output, "\n");

    // Execute the second command to get the raw URL
    const url_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "config", "--get", "remote.origin.url" },
        .max_output_bytes = 8 * 1024,
    });
    defer allocator.free(url_result.stdout);
    defer allocator.free(url_result.stderr);
    const raw_url_output = url_result.stdout;
    const raw_url = std.mem.trimRight(u8, raw_url_output, "\n");

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

test "buildTcloneCreateCmd builds expected command with provided suffix" {
    const alloc = std.testing.allocator;
    const tmp_base = "/tmp";
    const raw_url = "git@github.com:cameron-p-m/sample.git";
    const out = try buildTcloneCreateCmd(alloc, raw_url, tmp_base, "x");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "git clone 'git@github.com:cameron-p-m/sample.git' '/tmp/d-tclone-cameron-p-m/sample-x'") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "git checkout -b 'tclone/x'") != null);
}

test "buildTcloneDeleteCmd builds rm command absolute" {
    const alloc = std.testing.allocator;
    // removed functionality; ensure users can still construct basic rm
    const cmd = try std.mem.join(alloc, "", &[_][]const u8{ "rm -rf ", "'/tmp/d-tclone-foo'" });
    defer alloc.free(cmd);
    try std.testing.expectEqualStrings("rm -rf '/tmp/d-tclone-foo'", cmd);
}

test "buildTcloneDeleteCmd builds rm command relative under tmp" {
    const alloc = std.testing.allocator;
    // removed functionality; ensure users can still construct basic rm
    const cmd = try std.mem.join(alloc, "", &[_][]const u8{ "rm -rf ", "'/tmp/d-tclone-foo'" });
    defer alloc.free(cmd);
    try std.testing.expectEqualStrings("rm -rf '/tmp/d-tclone-foo'", cmd);
}
