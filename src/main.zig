const std = @import("std");

const CsvParser = struct {
	data: []const u8,
	row_iterator: std.mem.TokenIterator(u8, .sequence),

	pub fn init(raw_data: []const u8) CsvParser {
		return .{
			.data = raw_data,
			.row_iterator = std.mem.tokenizeSequence(u8, raw_data, "\n"),
		};
	}

	pub fn nextRow(self: *CsvParser) ?Row {
		while (self.row_iterator.next()) |raw_line| {
			const clean_line = std.mem.trimEnd(u8, raw_line, "\r");
			if (clean_line.len == 0) continue;
			return Row{
				.cell_iterator = std.mem.splitScalar(u8, clean_line, ','),
			};
		}
		return null;
	}
};

const Row = struct {
	cell_iterator: std.mem.SplitIterator(u8, .scalar),

	pub fn nextCell(self: *Row) ?[]const u8 {
		return self.cell_iterator.next();
	}
};

const AreaCodeRecord = struct {
	code: []const u8,
	state: []const u8,
	location: []const u8,
};

const CountryCodeRecord = struct {
	code: []const u8,
	country: []const u8,
};

const area_code_csv = @embedFile("area_codes.csv");
const country_code_csv = @embedFile("country_codes.csv");

const usage =
	\\acode - quickly look up North American area codes or international country calling codes.
	\\
	\\Usage: acode [-c] <code>
	\\
	\\Arguments:
	\\  <code> The code to look up (digits only, leading + is ignored)
	\\
	\\Flags:
	\\  -c, --country Look up a country calling code instead of an area code
	\\  -h, --help Show this help and exit
	\\
	\\Examples:
	\\  acode 303 Look up area code 303 (Colorado)
	\\  acode --country 44 Look up country code +44 (United Kingdom)
	\\  acode 44 -c Same as above; flag can appear before or after the code
	\\  acode -c +1 Leading + is accepted
	\\
;

fn printGrammarized(w: *std.Io.Writer, items: []const []const u8) !void {
	const total = items.len;
	for (items, 0..) |item, i| {
		try w.writeAll(item);
		if (i + 1 == total) {
			try w.writeAll(".\n");
		} else if (total == 2 and i == 0) {
			try w.writeAll(" and ");
		} else if (i + 1 == total - 1) {
			try w.writeAll(", and ");
		} else {
			try w.writeAll(", ");
		}
	}
}

pub fn main(init: std.process.Init) !void {
	const allocator = init.gpa;
	var args = try init.minimal.args.iterateAllocator(allocator);
	defer args.deinit();
	if (!args.skip()) return error.MissingProgramName;
	var country_mode = false;
	var input: ?[]const u8 = null;
	while (args.next()) |arg| {
		if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--country")) {
			country_mode = true;
		} else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
			std.debug.print("{s}", .{usage});
			return;
		} else if (input == null) {
			input = arg;
		}
	}
	const code = input orelse {
		std.debug.print("{s}", .{usage});
		std.process.exit(1);
	};
	const query = if (code.len > 0 and code[0] == '+') code[1..] else code;
	var stdout_buf: [4096]u8 = undefined;
	var stdout_fw = std.Io.File.stdout().writer(init.io, &stdout_buf);
	const stdout = &stdout_fw.interface;
	if (country_mode) {
		var parser = CsvParser.init(country_code_csv);
		var matches: std.ArrayList([]const u8) = .empty;
		defer matches.deinit(allocator);
		while (parser.nextRow()) |captured_row| {
			var row = captured_row;
			const record = CountryCodeRecord{
				.code = row.nextCell() orelse continue,
				.country = row.nextCell() orelse continue,
			};
			if (std.mem.eql(u8, record.code, query)) {
				try matches.append(allocator, record.country);
			}
		}
		if (matches.items.len == 0) {
			std.debug.print("Country code '+{s}' not found.\n", .{query});
		} else {
			try stdout.print("Country code +{s} is used by: ", .{query});
			try printGrammarized(stdout, matches.items);
			try stdout_fw.flush();
		}
	} else {
		var parser = CsvParser.init(area_code_csv);
		var found = false;
		while (parser.nextRow()) |captured_row| {
			var row = captured_row;
			const record = AreaCodeRecord{
				.code = row.nextCell() orelse continue,
				.state = row.nextCell() orelse continue,
				.location = row.nextCell() orelse continue,
			};
			if (std.mem.eql(u8, record.code, query)) {
				var cities: std.ArrayList([]const u8) = .empty;
				defer cities.deinit(allocator);
				var loc_iter = std.mem.splitSequence(u8, record.location, "; ");
				while (loc_iter.next()) |city| try cities.append(allocator, city);
				try stdout.print("The {s} area code is used in the following parts of {s}:\n", .{ record.code, record.state });
				try printGrammarized(stdout, cities.items);
				try stdout_fw.flush();
				found = true;
				break;
			}
		}
		if (!found) std.debug.print("Area code '{s}' not found.\n", .{query});
	}
}
