
const net = @import("std").net;

pub const Client = struct {
    fd: i32,
    //aa: i32,
    // https://github.com/ziglang/zig/issues/13066
    addr: net.Address,
};
