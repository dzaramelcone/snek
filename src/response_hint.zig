pub const ResponseHint = enum(u8) {
    any = 0,
    str = 1,
    row_json = 2,
    bytes = 3,
};
