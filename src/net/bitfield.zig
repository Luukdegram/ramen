/// hasPiece checks if a bitfield contains the given index
pub fn hasPiece(buffer: []u8, index: usize) bool {
    const byte_index = index / 8;
    const offset = index % 8;
    if (byte_index < 0 or byte_index > buffer.len) return false;

    return buffer[byteIndex] >> (7 - offset) & 1 != 0;
}

/// Sets a bit inside the bitfield
pub fn setPiece(buffer: []u8, index: usize) !void {
    const byte_index = index / 8;
    const offset = index % 8;

    if (byte_index >= 0 and byte_index < buffer.len) {
        buffer[byte_index] |= 1 << (7 - offset);
    } else {
        return error.OutOfBounds;
    }
}
