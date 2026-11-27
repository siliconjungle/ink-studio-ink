export function packRun(y, x, length) {
  return (y << 18) + (x << 9) + length - 1;
}

export function unpackRun(word) {
  return [word >>> 18, (word >>> 9) & 511, (word & 511) + 1];
}
