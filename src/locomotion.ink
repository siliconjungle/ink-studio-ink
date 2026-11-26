module CharacterLocomotion;

import "rig.ink" as math;

// Low traction preserves momentum while the control pulls toward its target.
fn traction(current: f64, target: f64) -> f64 {
    if target * current < 0.0f64 { return 10.0f64; }
    return if math.max(target, -target) > math.max(current, -current) { 8.0f64 } else { 4.5f64 };
}

pub fn axis_velocity(current: f64, target: f64, seconds: f64, grounded: Bool, slippery: Bool, air: f64) -> f64 {
    let acceleration = if !grounded { air } else { if slippery { traction(current, target) } else { 42.0f64 } };
    let limit = seconds * acceleration;
    return current + math.min(limit, math.max(-limit, target - current));
}
