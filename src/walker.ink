module StudioWalker;

import "rig.ink" as rig;

record Tail {
    anchor: rig.Point,
    direction: rig.Point,
    segment: f64,
    links: u32,
    gravity: f64,
}

record Walker {
    hip: rig.Point,
    chest: rig.Point,
    hem: rig.Point,
    neck: rig.Point,
    sock: rig.Point,
    ankle: rig.Point,
    height: f64,
    walk_speed: f64,
    breath: f64,
    breath_rate: f64,
    sway: f64,
    sway_rate: f64,
    tails: List<Tail>,
}

record Motion {
    origin: rig.Point,
    velocity: rig.Point,
    floor_y: f64,
    face: f64,
    launch_age: f64,
    landing_speed: f64,
    grounded: Bool,
}

record Foot { x: f64, y: f64, angle: f64, }
record Springs { lean: f64, lean_velocity: f64, nod: f64, nod_velocity: f64, }

record Pose {
    stretch: f64,
    flare: f64,
    hip_offset: f64,
    bend: f64,
    twist: f64,
    feet: List<Foot>,
}

record TailMotion { current: List<rig.Point>, previous: List<rig.Point>, }

record WalkState {
    time: f64,
    phase: f64,
    move_mix: f64,
    run_mix: f64,
    air_mix: f64,
    yaw: f64,
    land_age: f64,
    land_strength: f64,
    springs: Springs,
    pose: Pose,
    hem: rig.Point,
    hem_velocity: rig.Point,
    tails: List<TailMotion>,
}

fn still_foot() -> Foot { return Foot { x: 0.0f64, y: 0.0f64, angle: 0.0f64 }; }

fn rest_tail(tail: Tail, joint: u32) -> rig.Point {
    return rig.add(tail.anchor, rig.scale(tail.direction, tail.segment * f64_from_u32(joint)));
}

fn spawn_tail(tail: Tail, origin: rig.Point) -> TailMotion {
    let joints = buffer_fill(tail.links + 1, 0).freeze();
    let rest = joints.map_indexed(fn(index) => fn(unused) => rig.add(origin, rest_tail(tail, index)));
    return TailMotion { current: rest, previous: rest };
}

pub fn begin_walk(spec: Walker, origin: rig.Point) -> WalkState {
    return WalkState {
        time: 0.0f64, phase: 0.0f64, move_mix: 0.0f64, run_mix: 0.0f64, air_mix: 0.0f64, yaw: 0.0f64,
        land_age: 9.0f64, land_strength: 0.0f64,
        springs: Springs { lean: 0.0f64, lean_velocity: 0.0f64, nod: 0.0f64, nod_velocity: 0.0f64 },
        pose: Pose { stretch: 1.0f64, flare: 1.0f64, hip_offset: 0.0f64, bend: 0.0f64,
            twist: 0.0f64, feet: [still_foot(), still_foot()] },
        hem: rig.add(spec.hem, origin), hem_velocity: rig.zero(),
        tails: spec.tails.map(fn(tail) => spawn_tail(tail, origin)),
    };
}

record Gait {
    phase: f64,
    move_mix: f64,
    run_mix: f64,
    air_mix: f64,
    pace: f64,
    sense: f64,
    period: f64,
    stride: f64,
}

fn gait(spec: Walker, old: WalkState, input: Motion, dt: f64) -> Gait {
    let vx = input.velocity.x;
    let vz = input.velocity.z;
    let pace = sqrt(vx * vx + vz * vz);
    let k = rig.min(1.0f64, dt * 14.0f64);
    let move_mix = rig.mix(old.move_mix, rig.smooth(pace / 0.8f64), k);
    let run_mix = rig.mix(old.run_mix, rig.smooth((pace - spec.walk_speed - 0.3f64) / 1.5f64), k);
    let air_mix = rig.mix(old.air_mix, if input.grounded { 0.0f64 } else { 1.0f64 }, rig.min(1.0f64, dt * 22.0f64));
    let sense = if vx * rig.cos(input.face) + vz * rig.sin(input.face) >= -0.05f64 { 1.0f64 } else { -1.0f64 };
    let period = rig.mix(0.62f64, 0.43f64, run_mix);
    let phase = if input.grounded && pace > 0.05f64 { old.phase + dt / period } else { old.phase };
    let stride = rig.mix(0.62f64, 0.36f64, run_mix);
    return Gait { phase: phase - floor(phase), move_mix: move_mix, run_mix: run_mix, air_mix: air_mix,
        pace: pace, sense: sense, period: period, stride: stride };
}

fn stepping_foot(phase: f64, cycle: Gait, leg: f64, stride: f64) -> Foot {
    let f = phase - floor(phase);
    let duty = cycle.stride;
    let run = cycle.run_mix;
    let amount = cycle.move_mix;
    if f < duty {
        let s = f / duty;
        return Foot { x: stride * (0.5f64 - s), y: 0.0f64,
            angle: rig.mix(0.3f64, -0.4f64, s) * amount * (0.4f64 + 0.6f64 * run) };
    }
    let s = (f - duty) / (1.0f64 - duty);
    let arc = rig.sin(rig.pi() * s);
    return Foot { x: stride * (-0.5f64 + rig.smooth(s)) - run * 0.17f64 * leg * arc,
        y: (0.16f64 + 0.36f64 * run) * leg * arc * amount,
        angle: (-0.7f64 * (1.0f64 - s) + 0.3f64 * s) * amount * (0.5f64 + 0.5f64 * run) };
}

record Air { blend: f64, up: f64, down: f64, apex: f64, }

fn foot(spec: Walker, cycle: Gait, air: Air, right: Bool) -> Foot {
    let leg = spec.sock.y - spec.ankle.y;
    let stride = rig.min(leg * 1.15f64, cycle.pace * cycle.period * cycle.stride) * cycle.sense;
    let walk = stepping_foot(cycle.phase + if right { 0.5f64 } else { 0.0f64 }, cycle, leg, stride);
    if air.blend <= 0.001f64 { return walk; }
    let side = if right { 1.0f64 } else { -1.0f64 };
    let tuck = if right { 0.12f64 } else { 0.0f64 };
    return Foot { x: rig.mix(walk.x, (-0.2f64 * air.up + 0.14f64 * air.down + side * 0.14f64 * air.apex) * leg, air.blend),
        y: rig.mix(walk.y, (0.07f64 * air.up + 0.48f64 * air.apex + tuck * air.apex) * leg, air.blend),
        angle: rig.mix(walk.angle, -0.7f64 * air.up + 0.35f64 * air.down, air.blend) };
}

record Target { lean: f64, nod: f64, pose: Pose, }

fn airborne(target: Target, air: Air) -> Target {
    if air.blend <= 0.001f64 { return target; }
    let mix = air.blend;
    let p = target.pose;
    return Target { lean: rig.mix(target.lean, target.lean * 0.6f64 + 0.06f64, mix),
        nod: rig.mix(target.nod, 0.12f64 * air.up - 0.2f64 * air.down, mix),
        pose: Pose { stretch: rig.mix(p.stretch, 1.0f64 + 0.17f64 * air.up + 0.09f64 * air.down - 0.05f64 * air.apex, mix),
            flare: p.flare + mix * (0.3f64 * air.down - 0.12f64 * air.up),
            hip_offset: p.hip_offset * (1.0f64 - mix), bend: p.bend, twist: p.twist, feet: p.feet } };
}

fn target_pose(spec: Walker, time: f64, cycle: Gait, vy: f64) -> Target {
    let air = Air { blend: cycle.air_mix, up: rig.sat(vy / 6.0f64), down: rig.sat(-vy / 6.0f64),
        apex: rig.exp_negative(-(vy * vy) / 14.0f64) };
    let run = cycle.run_mix;
    let amount = cycle.move_mix;
    let phase = cycle.phase;
    let leg = spec.sock.y - spec.ankle.y;
    let lean = (0.05f64 * amount + 0.15f64 * run) * cycle.sense
        + spec.sway * rig.sin(time * spec.sway_rate) * (1.0f64 - amount);
    let nod = -0.45f64 * lean + 0.035f64 * rig.sin(2.0f64 * rig.tau() * phase) * amount;
    let hips = -(0.042f64 + 0.07f64 * run) * leg * rig.cos(2.0f64 * rig.tau() * (phase - 0.07f64)) * amount
        - 0.012f64 * amount;
    let stretch = 1.0f64 + spec.breath * rig.sin(time * spec.breath_rate) * (1.0f64 - amount);
    return airborne(Target { lean: lean, nod: nod,
        pose: Pose { stretch: stretch, flare: 1.0f64, hip_offset: hips, bend: 0.05f64 * run,
            twist: rig.sin(rig.tau() * phase) * (0.1f64 + 0.16f64 * run) * amount,
            feet: [foot(spec, cycle, air, false), foot(spec, cycle, air, true)] } }, air);
}

fn settle(s: Springs, target: Target, dt: f64) -> Springs {
    let n = rig.max(1.0f64, ceil(dt / 0.009f64));
    let h = dt / n;
    let steps = buffer_fill(u32_from_f64(n).fold(fn(count) => count, fn(unit) => 1), 0).freeze();
    return foldl(steps, s, fn(unused) => fn(last) => spring_step(last, target, h));
}

fn spring_step(s: Springs, target: Target, h: f64) -> Springs {
    let lean_v = s.lean_velocity + ((target.lean - s.lean) * 520.0f64 - s.lean_velocity * 27.0f64) * h;
    let nod_v = s.nod_velocity + ((target.nod - s.nod) * 200.0f64 - s.nod_velocity * 13.0f64) * h;
    return Springs { lean: s.lean + lean_v * h, lean_velocity: lean_v,
        nod: s.nod + nod_v * h, nod_velocity: nod_v };
}

fn impact_pose(p: Pose, height: f64, land_age: f64, strength: f64, launch_age: f64) -> Pose {
    let land = rig.wave(land_age, 0.5f64, 3.1f64, 4.0f64) * (0.12f64 + 0.22f64 * strength);
    return Pose { stretch: p.stretch * (1.0f64 - land) *
        (1.0f64 + 0.2f64 * rig.wave(launch_age, 0.3f64, 2.5f64, 5.0f64)),
        flare: p.flare, hip_offset: p.hip_offset - land * 0.13f64 * height,
        bend: p.bend, twist: p.twist, feet: p.feet };
}

record Body { hip: rig.Transform, chest: rig.Transform, hem: rig.Transform, head: rig.Transform, }

fn body_frame(spec: Walker, pose: Pose, spring: Springs) -> Body {
    let width = 1.0f64 / sqrt(pose.stretch);
    let body = rig.multiply(rig.rotate_z(-spring.lean), rig.diagonal(width, pose.stretch, width));
    let hip = rig.pivot(body, spec.hip, rig.add(spec.hip, rig.point(0.0f64, pose.hip_offset, 0.0f64)));
    let chest_axes = rig.multiply(body, rig.multiply(rig.rotate_z(-pose.bend), rig.rotate_y(pose.twist)));
    let chest = rig.pivot(chest_axes, spec.chest, rig.place(hip, spec.chest));
    let hem = rig.pivot(rig.multiply(body, rig.diagonal(pose.flare, 1.0f64, pose.flare)), spec.hem, rig.place(hip, spec.hem));
    let head_y = rig.mix(1.0f64, pose.stretch, 0.6f64);
    let head_width = 1.0f64 / sqrt(head_y);
    let head_axes = rig.multiply(rig.multiply(rig.rotate_z(-spring.lean * 0.5f64 - pose.bend), rig.rotate_y(pose.twist * 0.4f64)),
        rig.multiply(rig.rotate_z(-spring.nod), rig.diagonal(head_width, head_y, head_width)));
    let head = rig.pivot(head_axes, spec.neck, rig.place(chest, spec.neck));
    return Body { hip: hip, chest: chest, hem: hem, head: head };
}

record Hem { point: rig.Point, velocity: rig.Point, delta: rig.Point, }

fn hem_delta(position: rig.Point, goal: rig.Point) -> rig.Point {
    let d = rig.sub(position, goal);
    return rig.point(d.x, rig.max(-0.05f64, d.y * 0.6f64), d.z);
}

fn follow_hem(old: WalkState, position: rig.Point, height: f64, dt: f64) -> Hem {
    let velocity = rig.add(old.hem_velocity, rig.scale(rig.sub(rig.scale(rig.sub(position, old.hem), 150.0f64),
        rig.scale(old.hem_velocity, 13.0f64)), dt));
    let current = rig.add(old.hem, rig.scale(velocity, dt));
    let offset = rig.sub(current, position);
    let length = rig.magnitude(offset);
    let limit = 0.15f64 * height;
    let point = if length > limit { rig.add(position, rig.scale(offset, limit / length)) } else { current };
    return Hem { point: point, velocity: velocity, delta: hem_delta(point, position) };
}

fn offset_by(t: rig.Transform, d: rig.Point) -> rig.Transform {
    return rig.Transform { axes: t.axes, offset: rig.add(t.offset, d) };
}

record RopeSolve { points: List<rig.Point>, last: rig.Point, }

fn constrain_rope(points: List<rig.Point>, root: rig.Point, segment: f64, floor_y: f64) -> List<rig.Point> {
    let result = foldl(points, RopeSolve { points: [root], last: root }, fn(point) => fn(built) => rope_link(point, built, segment, floor_y));
    return result.points;
}

fn rope_link(next: rig.Point, built: RopeSolve, segment: f64, floor_y: f64) -> RopeSolve {
    let step = rig.sub(next, built.last);
    let length = rig.magnitude(step);
    let scale = segment / if length > 0.0f64 { length } else { 0.0001f64 };
    let tip = rig.add(built.last, rig.scale(step, scale));
    let p = rig.point(tip.x, rig.max(floor_y + 0.04f64, tip.y), tip.z);
    return RopeSolve { points: built.points.concat([p]), last: p };
}

fn rope_points(tail: Tail, old: TailMotion, root: rig.Point, floor_y: f64, dt: f64, wind: f64) -> TailMotion {
    let joints = buffer_fill(tail.links, 0).freeze();
    let next = joints.map_indexed(fn(index) => fn(unused) => drift_link(tail, old, index + 1, dt, wind));
    // Each pass visits links in order, with the same anchored first joint.
    let once = constrain_rope(next, root, tail.segment, floor_y);
    let indices = joints.map_indexed(fn(index) => fn(unused) => index + 1);
    let current = repeat(2, once, fn(pass) => fn(points) =>
        constrain_rope(indices.map(fn(index) => points.at_or(index, root)), root, tail.segment, floor_y));
    return TailMotion { current: current, previous: old.current };
}

fn drift_link(tail: Tail, old: TailMotion, index: u32, dt: f64, wind: f64) -> rig.Point {
    let point = old.current.at_or(index, rig.zero());
    let previous = old.previous.at_or(index, point);
    let velocity = rig.scale(rig.sub(point, previous), 0.9f64);
    return rig.add(point, rig.add(velocity,
        rig.point(wind * 0.5f64 * dt * dt * f64_from_u32(index), -tail.gravity * dt * dt, 0.0f64)));
}

record Secondary { hem: Hem, tails: List<TailMotion>, }

fn secondary(spec: Walker, old: WalkState, input: Motion, frame: Body, yaw: f64, dt: f64) -> Secondary {
    let world_hem = rig.world(frame.hem, rig.rotate_y(-yaw), input.origin);
    let hem = follow_hem(old, rig.place(world_hem, spec.hem), spec.height, dt);
    let anchor = offset_by(world_hem, hem.delta);
    let wind = 0.5f64 * rig.sin(old.time * 1.7f64) + 0.3f64 * rig.sin(old.time * 2.9f64);
    let tails = spec.tails.zip(old.tails, fn(tail) => fn(history) =>
        rope_points(tail, history, rig.place(anchor, tail.anchor), input.floor_y, dt, wind));
    return Secondary { hem: hem, tails: tails };
}

fn follow_yaw(old: f64, face: f64, dt: f64) -> f64 {
    let raw = face - old;
    let delta = rig.wrap_angle(raw);
    let turn = if delta == -rig.pi() && raw > 0.0f64 { rig.pi() } else { delta };
    return old + turn * rig.min(1.0f64, dt * 18.0f64);
}

pub fn step_walk(spec: Walker, old: WalkState, input: Motion, dt: f64) -> WalkState {
    let cycle = gait(spec, old, input, dt);
    let target = target_pose(spec, old.time, cycle, input.velocity.y);
    let falling = input.landing_speed >= 0.0f64;
    let land_age = if falling { dt } else { old.land_age + dt };
    let strength = if falling { rig.sat(input.landing_speed / 9.0f64) } else { old.land_strength };
    let pose = impact_pose(target.pose, spec.height, land_age, strength, input.launch_age);
    let spring = settle(old.springs, target, dt);
    let yaw = follow_yaw(old.yaw, input.face, dt);
    let follow = secondary(spec, old, input, body_frame(spec, pose, spring), yaw, dt);
    return WalkState { time: old.time + dt, phase: cycle.phase, move_mix: cycle.move_mix, run_mix: cycle.run_mix,
        air_mix: cycle.air_mix, yaw: yaw, land_age: land_age, land_strength: strength, springs: spring,
        pose: pose, hem: follow.hem.point, hem_velocity: follow.hem.velocity, tails: follow.tails };
}

fn leg_rest(point: rig.Point, right: Bool) -> rig.Point {
    return rig.point(point.x, point.y, if right { point.z } else { -point.z });
}
record Leg { leg: rig.Transform, foot: rig.Transform, }

fn moving_leg(spec: Walker, body: Body, step: Foot, right: Bool) -> Leg {
    let sock = leg_rest(spec.sock, right);
    let ankle = leg_rest(spec.ankle, right);
    let tip = rig.add(ankle, rig.point(step.x, step.y, 0.0f64));
    return Leg { leg: rig.stretch(sock, ankle, rig.place(body.hip, sock), tip),
        foot: rig.pivot(rig.rotate_z(step.angle), ankle, tip) };
}

fn tail_bones(tail: Tail, points: TailMotion) -> List<rig.Transform> {
    let joints = buffer_fill(tail.links, 0).freeze();
    return joints.map_indexed(fn(index) => fn(unused) => tail_bone(tail, points, index));
}

fn tail_bone(tail: Tail, points: TailMotion, index: u32) -> rig.Transform {
    let base = points.current.at_or(index, rig.zero());
    let tip = points.current.at_or(index + 1, base);
    let m = rig.turn(tail.direction, rig.unit(rig.sub(tip, base)));
    return rig.pivot(m, rest_tail(tail, index), base);
}

pub fn palette(spec: Walker, walk: WalkState, origin: rig.Point) -> List<rig.Bone> {
    let frame = body_frame(spec, walk.pose, walk.springs);
    let yaw = rig.rotate_y(-walk.yaw);
    let hem = rig.world(frame.hem, yaw, origin);
    let offset = hem_delta(walk.hem, rig.place(hem, spec.hem));
    let left = moving_leg(spec, frame, walk.pose.feet.at_or(0, still_foot()), false);
    let right = moving_leg(spec, frame, walk.pose.feet.at_or(1, still_foot()), true);
    let spare = rig.pivot(rig.identity(), rig.zero(), rig.zero());
    let body = [frame.hip, frame.chest, frame.hem, frame.head, left.leg, right.leg, left.foot, right.foot, spare, spare];
    let bones = body.map_indexed(fn(index) => fn(transform) =>
        if index == 2 { rig.pack(offset_by(hem, offset)) } else { rig.pack(rig.world(transform, yaw, origin)) });
    let tails = spec.tails.zip(walk.tails, fn(tail) => fn(points) => tail_bones(tail, points));
    return foldl(tails, bones, fn(tail) => fn(collected) => collected.concat(tail.map(fn(transform) => rig.pack(transform))));
}
