--!strict
--[[
    LookIKTuning.lua  (Ch 2.9 Camera / Ch 9 Animation — ALL look/lean body-posing tuning)

    Single place to tune every joint this "look direction" system touches:
        Head/Neck        -> owned by IKLegController.lua (native IKControl LookAt + Offset)
        Waist (upper body) and Root (lower body/hips) -> owned by TorsoTiltController.lua
        (direct Motor6D.C0 writes)

    REVERSAL, NOT DISENGAGE: past Look.BehindDisengageDegrees off body-forward, tracked
    yaw folds back toward 0 instead of continuing to grow or snapping to a hardcoded
    forward pose -- see LookIKMath.lua for the actual math, shared by all three joints so
    they can never disagree with each other.

    SIGN CONVENTIONS / INVERT SWITCHES: both look-yaw and lean direction were previously
    inverted (camera-left produced a rightward head/torso turn; pressing Lean-Left rolled
    the body right). The underlying math is fixed by default in both consuming modules.
    The two InvertYaw/InvertDirection flags below are an escape hatch ONLY -- flip one if
    your specific rig/camera setup still comes out backwards; leave both false otherwise.
]]

export type JointTiltConfig = {
    Enabled: boolean,             -- hard override: false silences this joint's look-follow
                                   -- entirely (and, for Waist, BaseForwardTilt too)
    MaxYawTiltDegrees: number,    -- how far this joint may twist toward the look direction (yaw axis)
    YawFollowFraction: number,    -- how strongly it follows the folded yaw before hitting the cap (1.0 = 1:1)
    MaxPitchTiltDegrees: number,  -- how far this joint may pitch toward the look direction (0 disables pitch-follow)
    PitchFollowFraction: number,  -- 0 = fully off
}

export type StanceTiltConfig = {
    IdleOnly: boolean,               -- if true, yaw/pitch follow only runs while NOT moving
    BaseForwardTilt: number,         -- degrees, always-on constant forward lean (smoothed via ForwardTiltLerpSpeed); gated by Waist.Enabled
    Waist: JointTiltConfig,          -- upper body (UpperTorso via the Waist Motor6D)
    Root: JointTiltConfig,           -- lower body/hips (LowerTorso via the Root Motor6D) -- keep caps modest;
                                      -- Root drives the legs too (see TorsoTiltController's CAUTION comment)
    LeanTranslateMultiplier: number, -- scale on Lean.RootTranslateStuds for this stance (0 = no sideways hip shift)
    LeanRollMultiplier: number,      -- scale on Lean.RootRollDegrees / Lean.HeadTiltDegrees for this stance (0 = no lean roll/head-tilt at all)
}

local LookIKTuning = {
    -- === Waist + Root (TorsoTiltController) — one entry per Stances.lua name =========
    Stances = {
        Standing = {
			Enabled = true,
            IdleOnly = true,
            BaseForwardTilt = 0,
            Waist = {
				MaxYawTiltDegrees = 35, -- Left/Right
				YawFollowFraction = 0.2,
				MaxPitchTiltDegrees = 25, -- Up/Down
				PitchFollowFraction = 0.5
			},
			Root = {
				MaxYawTiltDegrees = 15,
				YawFollowFraction = 0.2,
				MaxPitchTiltDegrees = 8,
				PitchFollowFraction = 0.3
			},
            LeanTranslateMultiplier = 1,
			LeanRollMultiplier = 1,
        } :: StanceTiltConfig,

        TacticalWalk = {
			Enabled = true,
            IdleOnly = false,
            BaseForwardTilt = 23,
            Waist = {
				MaxYawTiltDegrees = 22,
				YawFollowFraction = 1.0,
				MaxPitchTiltDegrees = 10,
				PitchFollowFraction = 0.3
			},
			Root = {
				MaxYawTiltDegrees = 8,
				YawFollowFraction = 0.4,
				MaxPitchTiltDegrees = 4,
				PitchFollowFraction = 0.25
			},
            LeanTranslateMultiplier = 1.0,
			LeanRollMultiplier = 1.0,
        } :: StanceTiltConfig,

        Crouching = {
			Enabled = true,
            IdleOnly = true,
            BaseForwardTilt = 4,
            Waist = {
				MaxYawTiltDegrees = 15,
				YawFollowFraction = 1.0,
				MaxPitchTiltDegrees = 6,
				PitchFollowFraction = 0.4
			},
            Root = {
				MaxYawTiltDegrees = 5,
				YawFollowFraction = 0.3,
				MaxPitchTiltDegrees = 3,
				PitchFollowFraction = 0.2
			},
            LeanTranslateMultiplier = 0.7,
			LeanRollMultiplier = 0.8,
        } :: StanceTiltConfig,

        Prone = {
			Enabled = true,
            IdleOnly = true,
            BaseForwardTilt = 0,
            Waist = {
				MaxYawTiltDegrees = 10,
				YawFollowFraction = 0.8,
				MaxPitchTiltDegrees = 4,
				PitchFollowFraction = 0.3
			},
            Root = {
				MaxYawTiltDegrees = 0,
				YawFollowFraction = 0,
				MaxPitchTiltDegrees = 0,
				PitchFollowFraction = 0
			},
            LeanTranslateMultiplier = 0, -- lying flat; a sideways hip shift doesn't read as a "lean"
			LeanRollMultiplier = 0,
        } :: StanceTiltConfig,
    },
    TiltLerpSpeed = 8,          -- yaw/pitch follow smoothing (both Waist and Root)
    ForwardTiltLerpSpeed = 10,  -- NEW: BaseForwardTilt used to snap instantly on a stance change; now eases in/out

    -- === Head/Neck (IKLegController) ====================================================
    Head = {
        MaxYawDegrees = 75,
        MaxPitchDegrees = 75,
        EngageAngleDegrees = -1, -- degrees off body-forward before the head visibly turns at all (pure anti-jitter deadzone)
        AimDistance = 5,        -- studs; how far ahead the LookAt target attachment is placed
    },

    -- === Shared look-direction fold point (Head, Waist, AND Root all read this) ========
    Look = {
        BehindDisengageDegrees = 90, -- past this angle off body-forward, tracked yaw REVERSES back toward
                                      -- center instead of continuing to grow or snapping to neutral forward.
                                      -- See LookIKMath.FoldYawDegrees for the exact math.
    },

    -- === Lean (roll + translate on Root/Waist, head tilt on Head) ======================
    -- NOTE: Neck sits inside IKLegController's active HeadLookIK chain, and Roblox locks
    -- C0 for any Motor6D inside an active IKControl chain -- a direct write throws
    -- "Unable to assign property C0. Property is read only." Head lean-tilt is therefore
    -- applied via IKControl.Offset in IKLegController, NOT a Motor6D write here.
    Lean = {
        RootRollDegrees = 6,       -- LowerTorso: full roll amount at a full lean, before stance scaling
        WaistFollowFraction = 4.5,   -- UpperTorso: fraction of Root's (already-scaled) roll it follows
        LerpSpeed = 10,
        RootTranslateStuds = 0.65,  -- sideways hip shift at a full lean, before stance scaling
        HeadTiltDegrees = 10,       -- head roll at a full lean, before stance scaling -- applied via a
                                    -- rolled Target up-vector in IKLegController, NOT IKControl.Offset
                                    -- (Offset's rotation is ignored by LookAt-type controls).
    },
}

return LookIKTuning