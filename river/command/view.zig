// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 - 2023 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const assert = std.debug.assert;

const globber = @import("globber");
const server = &@import("../main.zig").server;
const util = @import("../util.zig");
const wlr = @import("wlroots");

const View = @import("../View.zig");
const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");

fn match(s: []const u8, glob: []const u8) bool {
    globber.validate(glob) catch return std.mem.eql(u8, s, glob);
    return globber.match(s, glob);
}

fn viewById(id: []const u8) ?*View {
    var it = server.root.views.iterator(.forward);
    while (it.next()) |view| {
        if (std.mem.eql(u8, id, view.id)) return view;
    }
    return null;
}

const SearchField = enum {
    @"app-id",
    title,
    id,
};

fn viewByTitle(title: []const u8) ?*View {
    var it = server.root.views.iterator(.forward);
    while (it.next()) |view| {
        // we only want to know about the view that have and output
        if (view.current.output == null) continue;

        // we should never be searching for a view that doesn't have a title.
        const v_title = std.mem.span(view.getTitle()) orelse continue;

        if (match(v_title, title)) return view;
    }
    return null;
}

fn viewByAppId(app_id: []const u8) ?*View {
    var it = server.root.views.iterator(.forward);
    while (it.next()) |view| {
        // we only want to know about the view that have and output
        if (view.current.output == null) continue;

        // we should never be searching for a view that doesn't have a title.
        const v_app_id = std.mem.span(view.getAppId()) orelse continue;

        if (std.mem.eql(u8, v_app_id, app_id)) return view;
    }
    return null;
}

pub fn focusViewById(seat: *Seat, args: []const [:0]const u8, _: *?[]const u8) Error!void {
    if (args.len < 3) return Error.NotEnoughArguments;
    if (args.len > 3) return Error.TooManyArguments;

    // If the fallback pseudo-output is focused, there is nowhere to send the view
    if (seat.focused_output == null) {
        assert(server.root.active_outputs.empty());
        return;
    }

    const arg = std.meta.stringToEnum(SearchField, args[1]) orelse return Error.InvalidValue;

    const view = switch (arg) {
        .@"app-id" => viewByAppId(args[2]),
        .title => viewByTitle(args[2]),
        .id => viewById(args[2]),
    } orelse return Error.InvalidValue;

    var output = view.current.output orelse return;

    // if (output.pending.tags != view.pending.tags) {
    //     output.previous_tags = output.pending.tags;
    //     output.pending.tags = view.pending.tags;
    // }

    if (output.pending.tags & view.pending.tags == 0) {
        return;
    }

    if (seat.focused_output == null or seat.focused_output.? != output) {
        seat.focusOutput(output);
    }
    seat.focus(view);
    server.root.applyPending();
}

pub fn fetchViewById(seat: *Seat, args: []const [:0]const u8, _: *?[]const u8) Error!void {
    if (args.len < 3) return Error.NotEnoughArguments;
    if (args.len > 3) return Error.TooManyArguments;

    // If the fallback pseudo-output is focused, there is nowhere to send the view
    if (seat.focused_output == null) {
        assert(server.root.active_outputs.empty());
        return;
    }

    const arg = std.meta.stringToEnum(SearchField, args[1]) orelse return Error.InvalidValue;

    const view = switch (arg) {
        .@"app-id" => viewByAppId(args[2]),
        .title => viewByTitle(args[2]),
        .id => viewById(args[2]),
    } orelse return Error.InvalidValue;

    const output = seat.focused_output orelse return;

    const new_tags = output.pending.tags;
    if (new_tags != 0) {
        view.pending.tags = new_tags;
    }

    if (output != view.current.output) {
        view.setPendingOutput(output);
    }
    seat.focus(view);
    server.root.applyPending();
}

pub fn listViews(_: *Seat, _: []const [:0]const u8, out: *?[]const u8) Error!void {
    const T = struct {
        id: []const u8,
        @"app-id": []const u8,
        title: []const u8,
        output: []const u8,
        tags: u32,
        float: bool,
        fullscreen: bool,
        urgent: bool,
        mapped: bool,
        focused: bool,
        box: wlr.Box,
    };

    var list = std.ArrayList(T).init(util.gpa);

    var it = server.root.views.iterator(.forward);
    while (it.next()) |view| {
        if (view.destroying) {
            continue;
        }
        // we only want to know about the view that have and output
        const title = std.mem.span(view.getTitle()) orelse "";
        const appId = std.mem.span(view.getAppId()) orelse "";

        const name = if (view.current.output) |output| std.mem.span(output.wlr_output.name) else "";
        var focused = false;

        var seat_it = server.input_manager.seats.first;
        while (seat_it) |seat_node| : (seat_it = seat_node.next) {
            if (seat_node.data.focused == .view and seat_node.data.focused.view == view) {
                focused = true;
            }
        }

        const tags = view.current.tags;
        try list.append(.{
            .id = view.id,
            .@"app-id" = appId,
            .title = title,
            .output = name,
            .tags = tags,
            .float = view.current.float,
            .fullscreen = view.current.fullscreen,
            .urgent = view.current.urgent,
            .mapped = view.mapped,
            .focused = focused,
            .box = view.current.box,
        });
    }

    var buffer = std.ArrayList(u8).init(util.gpa);
    var arr = try list.toOwnedSlice();
    try std.json.stringify(arr, .{}, buffer.writer());
    out.* = try buffer.toOwnedSlice();
}
