module Frost;

record SeasonIce {
    current: f64,
    published: f64,
    dirty: Bool,
}

// This state advances every tick. The material grid refreshes when ice has
// moved by more than 0.03 or reaches an endpoint.
pub fn step_season(current: f64, published: f64, dt: f64, winter: f64) -> SeasonIce {
    let rate = if winter > 0.5f64 { 1.0f64 / 12.0f64 } else { -1.0f64 / 8.0f64 };
    let next = current + dt * rate;
    let ice = if next < 0.0f64 { 0.0f64 } else { if next > 1.0f64 { 1.0f64 } else { next } };
    let difference = ice - published;
    let dirty = difference > 0.03f64 || difference < -0.03f64
        || ((ice == 0.0f64 || ice == 1.0f64) && ice != published);
    return SeasonIce {
        current: ice,
        published: if dirty { ice } else { published },
        dirty: dirty,
    };
}

// Positive timers freeze a cell. Negative timers melt it even in winter.
// Legacy cell timers are rounded to binary32 only when written back.
pub fn step_timer(timer: f32, dt: f64) -> f32 {
    let value = f64_from_f32(timer);
    if value > 0.0f64 && value > dt { return f32_from_f64(value - dt); }
    if value < 0.0f64 && -value > dt { return f32_from_f64(value + dt); }
    return 0.0;
}

pub fn frozen_at(timer: f32, seasonal_ice: f64) -> Bool {
    return timer > 0.0 || (timer == 0.0 && seasonal_ice > 0.6f64);
}

fn frost_byte(timer: f32, seasonal_byte: u32) -> u32 {
    if timer > 0.0 { return 255; }
    if timer < 0.0 { return 0; }
    return seasonal_byte;
}

// Pixel words are RGBA in increasing byte order. The ice field is blue.
// Each row retains the fire, heat and ground-height channels.
pub fn pack_ice(colors: List<u32>, timers: List<f32>, seasonal_byte: u32) -> List<u32> {
    return colors.zip(timers, fn(color) => fn(timer) =>
        word_and(color, 4278255615) + frost_byte(timer, word_and(seasonal_byte, 255)) * 65536);
}
