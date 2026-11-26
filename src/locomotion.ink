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

record Wall { normal: math.Point, contact: f64, last: math.Point, lock: f64, }
record WallStep { wall: Wall, kick: Bool, slide: Bool, }

pub fn wall_idle() -> Wall {
    return Wall { normal: math.zero(), contact: 0.0f64, last: math.zero(), lock: 0.0f64 };
}

pub fn wall_step(old: Wall, contact: math.Point, drive: math.Point, grounded: Bool, coyote: f64, jump: Bool, dt: f64) -> WallStep {
    if grounded { return WallStep { wall: wall_idle(), kick: false, slide: false }; }
    let touching = math.dot(contact, contact) > 0.0f64;
    let normal = if touching { contact } else { old.normal };
    let lasting = if touching { 0.16f64 } else { math.max(0.0f64, old.contact - dt) };
    let lock = math.max(0.0f64, old.lock - dt);
    let fresh = math.dot(normal, old.last) < 0.71f64;
    let kick = jump && coyote <= dt && lasting > 0.0f64 && lock <= 0.0f64 && fresh;
    let wall = Wall { normal: normal, contact: if kick { 0.0f64 } else { lasting },
        last: if kick { normal } else { old.last }, lock: if kick { 0.16f64 } else { lock } };
    return WallStep { wall: wall, kick: kick, slide: !kick && lasting > 0.0f64 && math.dot(drive, normal) < -0.3f64 };
}

pub fn wall_impulse(normal: math.Point, jump_speed: f64) -> math.Point {
    return math.point(normal.x * 7.6f64, jump_speed * 0.97f64, normal.z * 7.6f64);
}

record Ledge { top: f64, time: f64, grabbed: Bool, }
record ClimbStep { ledge: Ledge, y: f64, vy: f64, climbing: Bool, }

pub fn ledge_idle() -> Ledge {
    return Ledge { top: 0.0f64, time: 0.0f64, grabbed: false };
}

// A catch needs both a solid face ahead and space above the current body.
pub fn ledge_candidate(y: f64, top: f64, above: f64, foot: f64) -> Bool {
    return top < 1e8f64 && top > y + 0.45f64 && above < top - 0.3f64 && foot > y + 0.4f64;
}

pub fn ledge_step(old: Ledge, candidate: Option<f64>, y: f64, vy: f64, grounded: Bool, driving: Bool, dt: f64) -> ClimbStep {
    let active = old.time > 0.0f64;
    let grabbed = old.grabbed && !grounded;
    let ledge = candidate.fold(fn(top) =>
        if !driving { Ledge { ..old, grabbed: grabbed } } else {
            if active {
                Ledge { ..old, time: if math.max(top - old.top, old.top - top) < 0.3f64 { 0.25f64 } else { old.time }, grabbed: grabbed }
            } else {
                if !grabbed && (if grounded { top - y <= 0.92f64 } else { top - y > 0.5f64 }) {
                    Ledge { top: top, time: 0.25f64, grabbed: true }
                } else { Ledge { ..old, grabbed: grabbed } }
            }
        }, fn(unit) => Ledge { ..old, grabbed: grabbed });
    if ledge.time > 0.0f64 {
        return ClimbStep { ledge: Ledge { ..ledge, time: math.max(0.0f64, ledge.time - dt) },
            y: math.min(ledge.top + 0.05f64, y + 3.6f64 * dt), vy: 0.0f64, climbing: true };
    }
    return candidate.fold(fn(top) =>
        if driving && !grounded && top > y && top - y <= 0.5f64 {
            ClimbStep { ledge: ledge, y: top + 0.02f64, vy: math.max(0.0f64, vy), climbing: false }
        } else { ClimbStep { ledge: ledge, y: y, vy: vy, climbing: false } },
        fn(unit) => ClimbStep { ledge: ledge, y: y, vy: vy, climbing: false });
}
