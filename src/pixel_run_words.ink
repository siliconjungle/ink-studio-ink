module StudioPixelRunWords;

// 9 bits each for the native row, column and length minus one.
fn pack(y: u32, x: u32, count: u32) -> u32 { return wrapping_shl(y, 18) + wrapping_shl(x, 9) + count - 1; }
fn unpack(word: u32) -> Vec3<u32> {
    return vec3(wrapping_shr(word, 18), word_and(wrapping_shr(word, 9), 511), word_and(word, 511) + 1);
}
