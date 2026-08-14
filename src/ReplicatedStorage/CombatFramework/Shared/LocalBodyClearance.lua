--!strict
--[[
    LocalBodyClearance.lua

    Purely local, purely cosmetic: TorsoTiltController computes wall clearance for the
    LOCAL PLAYER's own lean/look ONCE per axis (three throttled raycasts: Yaw, Pitch,
    Lateral) and publishes the results here. MovementClient's camera peek offset reads
    Lateral back to scale itself by the same value -- this avoids a second, redundant
    raycast for the same information every frame.

    Split into three axes rather than one combined value: a wall that's only in the way
    of one kind of motion (e.g. directly to the left, blocking a sideways lean) shouldn't
    also suppress an unrelated axis, like looking straight up, that isn't actually
    obstructed. See TorsoTiltController._updateBodyClearance for how each is sampled.

    Deliberately NOT a Character Attribute: attributes replicate, and no other client ever
    needs this value (remote players' torso lean clamps itself independently, per-observer,
    inside each observer's own TorsoTiltController instance -- see that file). A plain
    shared table is the cheapest correct scope here.
]]
return {
    Yaw = 1,     -- 1 = fully clear, 0 = flush against a wall
    Pitch = 1,
    Lateral = 1,
}