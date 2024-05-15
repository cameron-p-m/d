const std = @import("std");
const rank = @import("rank.zig");

const Args = struct { homePath: []const u8, srcPath: []const u8, hostPath: []const u8, destination: []const u8, verbose: bool };

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const args = try parseArgs(arena.allocator());

    var dir = try createOrOpenDir(arena.allocator(), args);
    defer dir.close();

    var candidates = try getCandidates(arena.allocator(), dir, args);
    defer candidates.deinit();

    const filtered = try rank.rankCandidates(arena.allocator(), candidates.items, args.destination, true);

    if (filtered.len > 0) {
        if (args.verbose) {
            printDebugInfo(filtered);
        }
        _ = try std.io.getStdOut().writer().print("cd {s}", .{filtered[0].str});
    } else {
        std.debug.print("no match found\n", .{});
    }
}

fn parseArgs(allocator: std.mem.Allocator) !Args {
    var desiredPath: [:0]const u8 = "";
    var verbose = false;
    var invalidArgs = false;

    var args = try std.process.argsAlloc(allocator);

    for (args, 0..) |arg, i| {
        // binary is first arg
        if (i == 0) {
            continue;
        }
        if (i == 1) {
            if (!std.mem.eql(u8, arg, "cd")) {
                invalidArgs = true;
                break;
            } else {
                continue;
            }
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
        std.debug.print("usage: \n d cd [desired] [optional_flags]\n   -v verbose output\n", .{});
        std.process.exit(2);
    }

    const HOME = "HOME";

    // should support more hosts
    const srcPath = "src";
    const hostPath = "github.com";

    var homePath = std.os.getenv(HOME) orelse {
        std.debug.print("no HOME env var found", .{});
        std.process.exit(2);
    };

    if (verbose) {
        std.debug.print("desired: {s}\n\n", .{desiredPath});
    }

    return Args{ .homePath = homePath, .srcPath = srcPath, .hostPath = hostPath, .destination = desiredPath, .verbose = verbose };
}

fn printDebugInfo(cadidates: []rank.Candidate) void {
    std.debug.print("top:\n", .{});
    const size = @min(cadidates.len, 5);
    for (cadidates[0..size]) |elem| {
        std.debug.print("{d} {s}\n", .{ elem.rank, elem.str });
    }
    std.debug.print("command:\n cd {s}\n", .{cadidates[0].str});
}

fn createOrOpenDir(allocator: std.mem.Allocator, args: Args) !std.fs.IterableDir {
    const slicePath = &[_][]const u8{ args.homePath, args.srcPath, args.hostPath };
    const result = try std.mem.join(allocator, "/", slicePath);

    var fileDir = std.fs.openIterableDirAbsolute(result, .{}) catch |e|
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
            return try std.fs.openIterableDirAbsolute(result, .{});
        },
        else => return e,
    };

    return fileDir;
}

pub fn getCandidates(allocator: std.mem.Allocator, path: std.fs.IterableDir, args: Args) !std.ArrayList([]const u8) {
    var candidates = try std.ArrayList([]const u8).initCapacity(allocator, 50);

    var iterator = path.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != std.fs.File.Kind.directory) {
            continue;
        }
        const newPath = try std.mem.join(allocator, "/", &[_][]const u8{ args.homePath, args.srcPath, args.hostPath, entry.name });
        var entryDir = try std.fs.openIterableDirAbsolute(newPath, .{});
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
