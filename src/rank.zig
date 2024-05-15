const std = @import("std");

// below code all copied from https://github.com/natecraddock/zf/blob/0ed0e341a862017af077ccd366d1f23612e4bc35/src/filter.zig#L75
pub const Candidate = struct {
    str: []const u8,
    rank: f64 = 0,
};

const ScanResult = struct { rank: f64, index: usize };

pub fn FixedArrayList(comptime T: type) type {
    return struct {
        buffer: []T,
        len: usize = 0,

        const This = @This();

        pub fn init(buffer: []T) This {
            return .{ .buffer = buffer };
        }

        pub fn append(list: *This, data: T) void {
            if (list.len >= list.buffer.len) return;
            list.buffer[list.len] = data;
            list.len += 1;
        }

        pub fn clear(list: *This) void {
            list.len = 0;
        }

        pub fn slice(list: This) []const T {
            return list.buffer[0..list.len];
        }
    };
}

const IndexIterator = struct {
    str: []const u8,
    char: u8,
    index: usize = 0,
    case_sensitive: bool,

    pub fn init(str: []const u8, char: u8, case_sensitive: bool) @This() {
        return .{ .str = str, .char = char, .case_sensitive = case_sensitive };
    }

    pub fn next(self: *@This()) ?usize {
        const index = if (self.case_sensitive)
            indexOf(u8, self.str, self.index, self.char, true)
        else
            indexOf(u8, self.str, self.index, self.char, false);

        if (index) |i| self.index = i + 1;
        return index;
    }
};

fn sort(_: void, a: Candidate, b: Candidate) bool {
    // first by rank
    if (a.rank < b.rank) return true;
    if (a.rank > b.rank) return false;

    // then by length
    if (a.str.len < b.str.len) return true;
    if (a.str.len > b.str.len) return false;

    // then alphabetically
    for (a.str, 0..) |c, i| {
        if (c < b.str[i]) return true;
        if (c > b.str[i]) return false;
    }
    return false;
}

pub fn rankCandidates(
    allocator: std.mem.Allocator,
    candidates: []const []const u8,
    input: []const u8,
    case_sensitive: bool,
) ![]Candidate {
    const ranked = try allocator.alloc(Candidate, candidates.len);

    if (input.len == 0) {
        for (candidates, 0..) |candidate, index| {
            ranked[index] = .{ .str = candidate };
        }
        return ranked;
    }

    var index: usize = 0;
    for (candidates) |candidate| {
        if (rankCandidate(candidate, input, case_sensitive)) |rank| {
            ranked[index] = .{ .str = candidate, .rank = rank };
            index += 1;
        }
    }

    std.sort.block(Candidate, ranked[0..index], {}, sort);

    return ranked[0..index];
}

pub fn rankCandidate(
    candidate: []const u8,
    query_tokens: []const u8,
    case_sensitive: bool,
) ?f64 {
    // the candidate must contain all of the characters (in order) in each token.
    // each tokens rank is summed. if any token does not match the candidate is ignored
    var rank: f64 = 0;
    if (rankToken(candidate, query_tokens, case_sensitive)) |r| {
        rank += r;
    } else return null;

    // all tokens matched and the best ranks for each tokens are summed
    return rank;
}

pub fn rankToken(
    str: []const u8,
    token: []const u8,
    case_sensitive: bool,
) ?f64 {
    if (str.len == 0 or token.len == 0) return null;

    // iterates over the string performing a match starting at each possible index
    // the best (minimum) overall ranking is kept and returned
    var best_rank: ?f64 = null;
    // perform search on the full string if requested or if no match was found on the filename
    var it = IndexIterator.init(str, token[0], case_sensitive);
    while (it.next()) |start_index| {
        if (scanToEnd(str, token[1..], start_index, 0, null, case_sensitive, false)) |scan| {
            if (best_rank == null or scan.rank < best_rank.?) best_rank = scan.rank;
        } else break;
    }

    return best_rank;
}

pub fn hasSeparator(str: []const u8) bool {
    for (str) |byte| {
        if (byte == std.fs.path.sep) return true;
    }
    return false;
}

// this is the core of the ranking algorithm. special precedence is given to
// filenames. if a match is found on a filename the candidate is ranked higher
fn scanToEnd(
    str: []const u8,
    token: []const u8,
    start_index: usize,
    offset: usize,
    matched_indices: ?*FixedArrayList(usize),
    case_sensitive: bool,
    strict_path: bool,
) ?ScanResult {
    var rank: f64 = 1;
    var last_index = start_index;
    var last_sequential = false;

    // penalty for not starting on a word boundary
    if (start_index > 0 and !isStartOfWord(str[start_index - 1])) {
        rank += 2.0;
    }

    for (token) |c| {
        const index = if (case_sensitive)
            indexOf(u8, str, last_index + 1, c, true)
        else
            indexOf(u8, str, last_index + 1, c, false);

        if (index) |idx| {
            // did the match span a slash in strict path mode?
            if (strict_path and hasSeparator(str[last_index .. idx + 1])) return null;

            if (matched_indices != null) matched_indices.?.append(idx + offset);

            if (idx == last_index + 1) {
                // sequential matches only count the first character
                if (!last_sequential) {
                    last_sequential = true;
                    rank += 1.0;
                }
            } else {
                // penalty for not starting on a word boundary
                if (!isStartOfWord(str[idx - 1])) {
                    rank += 2.0;
                }

                // normal match
                last_sequential = false;
                rank += @floatFromInt(idx - last_index);
            }

            last_index = idx;
        } else return null;
    }

    return ScanResult{ .rank = rank, .index = last_index + 1 };
}

inline fn isStartOfWord(byte: u8) bool {
    return switch (byte) {
        std.fs.path.sep, '_', '-', '.', ' ' => true,
        else => false,
    };
}

// fn getCandidatesSubDir(allocator: std.mem.Allocator, first: []const u8, second: []const u8, third: []const u8, fouth: []const u8) ![]const []const u8 {
//     const newPath = try std.mem.join(allocator, "/", &[_][]const u8{ first, second, third, fourth });
//     var fileDir = try std.fs.openIterableDirAbsolute(newPath, .{});
//     defer fileDir.close();
//     var iterator = fileDir.iterate();
//     var list = try std.ArrayList(u8).initCapacity(allocator, 50);
//     defer list.deinit();
//     while (try iterator.next()) |entry| {
//         const entryPath = try std.mem.join(allocator, "/", &[_][]const u8{ first, second, third, entry.name });
//     }

//     return list;
// }

fn indexOf(
    comptime T: type,
    slice: []const T,
    start_index: usize,
    value: T,
    comptime case_sensitive: bool,
) ?usize {
    var i: usize = start_index;
    while (i < slice.len) : (i += 1) {
        if (case_sensitive) {
            if (slice[i] == value) return i;
        } else {
            if (std.ascii.toLower(slice[i]) == value) return i;
        }
    }
    return null;
}
