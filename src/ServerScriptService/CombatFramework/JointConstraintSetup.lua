--!strict
--[[
	JointConstraintsSetup.lua

	Adds the physical joint constraints Roblox's IKControl guide describes (elbow
	HingeConstraint, wrist BallSocketConstraint) generalized to all six requested joints,
	both sides: Hip, Knee, Ankle, Shoulder, Elbow, Wrist.

	--------------------------------------------------------------------------------
	THIS IS A RIG-AUTHORING SCRIPT, NOT A RUNTIME SYSTEM.

	Constraints + their attachments are static skeletal limits -- they belong on the rig
	ASSET (e.g. your DOGU15 template, Ch 17.6), built once and saved, the same way the
	guide's own manual Explorer steps are a one-time authoring workflow, not something
	redone on every CharacterAdded. Run this against a rig sitting in Workspace in its
	normal REST POSE (arms/legs relaxed, not mid-animation), then save that rig as the
	template your game actually spawns -- do NOT wire this into CharacterAdded.

	WHY REST POSE MATTERS: the hinge/twist axis for each joint is derived from the rig's
	OWN current world orientation at the moment this runs (see getWorldAxis below), then
	baked into a fixed local Attachment.CFrame. If the rig is mid-animation (e.g. an arm
	already swung forward) when this runs, the baked axis will be wrong and permanent
	until you delete and re-run this against a properly-posed rig.
	--------------------------------------------------------------------------------

	PATTERN (mirrors the guide's manual elbow/wrist steps exactly, generalized):
	  - rig attachment name is always "<Side><JointName>RigAttachment", present on BOTH
	    the proximal and distal part (e.g. "LeftElbowRigAttachment" exists on both
	    LeftUpperArm and LeftLowerArm) -- standard R15 rig convention.
	  - Attachment0 (new) is parented under the PROXIMAL part's existing RigAttachment.
	  - Attachment1 (new) is parented under the DISTAL part's existing RigAttachment.
	  - the Constraint itself is parented on the DISTAL part (matches guide: elbow
	    constraint lives on LeftLowerArm, wrist constraint lives on LeftHand).
	  - Attachment0/Attachment1 world CFrames must match exactly except for which
	    Constraint-relevant axis they encode -- guaranteed here because rest-pose R15
	    parts share the rig's overall orientation with no rotation baked into Motor6D
	    C0/C1 (true for stock R15 and rebuilds like DOGU15 that keep the standard rig
	    convention), so computing both attachments' local axis from the SAME world vector
	    produces attachments that already agree, without needing the guide's manual
	    "copy CFrameOrientation across" step.

	AXIS CHOICE PER JOINT:
	  - Knee / Elbow (Hinge): axis = the character's LATERAL (Right) vector -- these
	    joints flex/extend in the sagittal plane, rotating about a left-right axis.
	  - Hip / Shoulder / Wrist (BallSocket): axis = world DOWN -- at rest these limbs
	    hang straight down, so "the direction the limb points" (the guide's "primary
	    axis points toward the model's fingertips" instruction for the wrist) is world
	    down for all three.
	  - Ankle (BallSocket): axis = the character's FORWARD vector -- the foot points
	    forward at rest, not down, so its cone should be centered on "straight ahead."

	CAVEAT: because Left/Right parts are typically mirrored meshes, a hinge's "positive"
	rotation direction can come out flipped between the two sides even though the
	computed world axis is identical. If a knee or elbow visibly bends the wrong way in
	Studio, that side's HingeConstraint.LowerAngle/UpperAngle need to be swapped/negated
	-- this is the scripted equivalent of the guide's own "red arrow means mismatched
	orientation" troubleshooting note.
--------------------------------------------------------------------------------
]]

type AxisKind = "Lateral" | "Down" | "Forward"
type ConstraintKind = "Hinge" | "BallSocket"

export type JointDef = {
	Name: string, -- e.g. "Knee" -> rig attachment name becomes "<Side>KneeRigAttachment"
	Part0Pattern: string, -- "%s" placeholder for side; literal name (e.g. "UpperTorso") if shared
	Part1Pattern: string,
	ConstraintType: ConstraintKind,
	Axis: AxisKind,
	Sign: number?, -- 1 (default) or -1. Flip this if the cone/hinge points the wrong way in
	               -- Studio (e.g. a shoulder cone opening UP instead of down) -- cheaper than
	               -- re-deriving the axis math, and survives re-running Setup().

	-- BallSocketConstraint fields
	UpperAngle: number?,
	TwistEnabled: boolean?,
	TwistLower: number?,
	TwistUpper: number?,

	-- HingeConstraint fields
	HingeLimitsEnabled: boolean?,
	HingeLower: number?,
	HingeUpper: number?,
}

-- Reasonable anatomical defaults -- treat these as a starting point, not gospel; verify
-- visually per joint per side in Studio and retune (see CAVEAT above for the sign flip).
local JOINTS: { JointDef } = {
	{
		Name = "Hip",
		Part0Pattern = "LowerTorso",
		Part1Pattern = "%sUpperLeg",
		ConstraintType = "BallSocket",
		Axis = "Down",
		UpperAngle = 75,
		TwistEnabled = true,
		TwistLower = -20,
		TwistUpper = 45,
	},
	{
		Name = "Knee",
		Part0Pattern = "%sUpperLeg",
		Part1Pattern = "%sLowerLeg",
		ConstraintType = "Hinge",
		Axis = "Lateral",
		HingeLimitsEnabled = true,
		HingeLower = -140, -- knee bends one way only; if it bends the wrong way for a
		HingeUpper = 0,     -- given side, swap these two values and negate both.
	},
	{
		Name = "Ankle",
		Part0Pattern = "%sLowerLeg",
		Part1Pattern = "%sFoot",
		ConstraintType = "BallSocket",
		Axis = "Forward",
		UpperAngle = 45,
	},
	{
		Name = "Shoulder",
		Part0Pattern = "UpperTorso",
		Part1Pattern = "%sUpperArm",
		ConstraintType = "BallSocket",
		Axis = "Down",
		UpperAngle = 100,
		TwistEnabled = true,
		TwistLower = -45,
		TwistUpper = 45,
	},
	{
		Name = "Elbow",
		Part0Pattern = "%sUpperArm",
		Part1Pattern = "%sLowerArm",
		ConstraintType = "Hinge",
		Axis = "Lateral",
		HingeLimitsEnabled = true,
		HingeLower = 0,
		HingeUpper = 145, -- same swap-and-negate note as Knee if a side bends backward.
	},
	{
		Name = "Wrist",
		Part0Pattern = "%sLowerArm",
		Part1Pattern = "%sHand",
		ConstraintType = "BallSocket",
		Axis = "Down",
		UpperAngle = 80, -- matches the guide's own wrist example exactly.
	},
}

local function resolvePart(model: Model, pattern: string, side: string?): BasePart?
	local name = if side and string.find(pattern, "%s", 1, true) then string.format(pattern, side) else pattern
	local inst = model:FindFirstChild(name)
	if inst and inst:IsA("BasePart") then
		return inst
	end
	return nil
end

local function getWorldAxis(kind: AxisKind, referencePart: BasePart): Vector3
	if kind == "Lateral" then
		return referencePart.CFrame.RightVector
	elseif kind == "Down" then
		return -referencePart.CFrame.UpVector
	else -- "Forward"
		return referencePart.CFrame.LookVector
	end
end

--- Builds a CFrame (relative to `baseAttachment`) whose local Z axis, once composed with
--- baseAttachment's WorldCFrame, points along `worldAxis`. Right/Up are arbitrary
--- orthonormal fill vectors -- only the Z axis (the constraint's hinge/twist axis) is
--- functionally meaningful for a symmetric HingeConstraint or an UpperAngle-only
--- BallSocketConstraint cone.
local function computeLocalAxisCFrame(baseAttachment: Attachment, worldAxis: Vector3): CFrame
	local localZ = baseAttachment.WorldCFrame:VectorToObjectSpace(worldAxis)
	if localZ.Magnitude < 1e-4 then
		localZ = Vector3.zAxis
	else
		localZ = localZ.Unit
	end

	local hint = if math.abs(localZ.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis
	local localRight = hint:Cross(localZ)
	if localRight.Magnitude < 1e-4 then
		localRight = Vector3.zAxis:Cross(localZ)
	end
	localRight = localRight.Unit
	local localUp = localZ:Cross(localRight).Unit

	return CFrame.fromMatrix(Vector3.zero, localRight, localUp, localZ)
end

local function buildJoint(model: Model, def: JointDef, side: string?): boolean
	local jointLabel = if side then side .. def.Name else def.Name
	local rigAttachmentName = jointLabel .. "RigAttachment"

	local part0 = resolvePart(model, def.Part0Pattern, side)
	local part1 = resolvePart(model, def.Part1Pattern, side)
	if not (part0 and part1) then
		warn(`JointConstraintsSetup: missing parts for {jointLabel} (looked for "{def.Part0Pattern}"/"{def.Part1Pattern}") -- skipping`)
		return false
	end

	local base0 = part0:FindFirstChild(rigAttachmentName) :: Attachment?
	local base1 = part1:FindFirstChild(rigAttachmentName) :: Attachment?
	if not (base0 and base1) then
		warn(`JointConstraintsSetup: missing "{rigAttachmentName}" on {part0.Name}/{part1.Name} -- is this an R15-family rig? Skipping {jointLabel}`)
		return false
	end

	-- Idempotent re-run: clear anything this script built for this joint last time before
	-- rebuilding, so you can safely re-run after adjusting JOINTS above.
	local existingConstraint = part1:FindFirstChild(jointLabel .. "Constraint")
	if existingConstraint then
		existingConstraint:Destroy()
	end
	local existingAttach0 = base0:FindFirstChild(jointLabel .. "ConstraintAttachment0")
	if existingAttach0 then
		existingAttach0:Destroy()
	end
	local existingAttach1 = base1:FindFirstChild(jointLabel .. "ConstraintAttachment1")
	if existingAttach1 then
		existingAttach1:Destroy()
	end

	local referencePart = (model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("LowerTorso") or part0) :: BasePart
	local worldAxis = getWorldAxis(def.Axis, referencePart) * (def.Sign or 1)

	local attach0 = Instance.new("Attachment")
	attach0.Name = jointLabel .. "ConstraintAttachment0"
	attach0.CFrame = computeLocalAxisCFrame(base0, worldAxis)
	attach0.Parent = base0

	local attach1 = Instance.new("Attachment")
	attach1.Name = jointLabel .. "ConstraintAttachment1"
	attach1.CFrame = computeLocalAxisCFrame(base1, worldAxis)
	attach1.Parent = base1

	if def.ConstraintType == "Hinge" then
		local hinge = Instance.new("HingeConstraint")
		hinge.Name = jointLabel .. "Constraint"
		hinge.Attachment0 = attach0
		hinge.Attachment1 = attach1
		hinge.ActuatorType = Enum.ActuatorType.None -- free hinge -- this is a joint LIMIT, not a motor
		if def.HingeLimitsEnabled then
			hinge.LimitsEnabled = true
			hinge.LowerAngle = def.HingeLower or -90
			hinge.UpperAngle = def.HingeUpper or 0
		end
		hinge.Parent = part1
		return true
	else
		local ball = Instance.new("BallSocketConstraint")
		ball.Name = jointLabel .. "Constraint"
		ball.Attachment0 = attach0
		ball.Attachment1 = attach1
		ball.LimitsEnabled = true
		ball.UpperAngle = def.UpperAngle or 45
		if def.TwistEnabled then
			ball.TwistLimitsEnabled = true
			ball.TwistLowerAngle = def.TwistLower or -30
			ball.TwistUpperAngle = def.TwistUpper or 30
		end
		ball.Parent = part1
		return true
	end
end

local JointConstraintsSetup = {}

--- Dumps the model's hierarchy so you can see what naming/structure it actually uses --
--- specifically looking for BaseParts (classic R15/Motor6D rig), Bones (mesh-deformation
--- skinning -- NOT compatible with Hinge/BallSocket constraints, which need real
--- Attachments on real BaseParts), and Motor6Ds (confirms a classic rig either way).
function JointConstraintsSetup.Diagnose(model: Model)
	print(`--- JointConstraintsSetup diagnostic: "{model:GetFullName()}" ({model.ClassName}) ---`)

	local baseParts, bones, motor6Ds = 0, 0, 0

	local function walk(inst: Instance, depth: number)
		if depth > 6 then
			return
		end
		for _, child in ipairs(inst:GetChildren()) do
			local tag = ""
			if child:IsA("BasePart") then
				tag = "  <- BasePart"
				baseParts += 1
			elseif child:IsA("Bone") then
				tag = "  <- Bone (skinning -- NOT usable by Hinge/BallSocketConstraint)"
				bones += 1
			elseif child:IsA("Motor6D") then
				tag = `  <- Motor6D (Part0={child.Part0 and child.Part0.Name}, Part1={child.Part1 and child.Part1.Name})`
				motor6Ds += 1
			elseif child:IsA("Attachment") then
				tag = "  <- Attachment"
			end
			print(string.rep("    ", depth) .. child.ClassName .. " \"" .. child.Name .. "\"" .. tag)

			-- Recurse into anything that could plausibly contain rig structure.
			if child:IsA("Model") or child:IsA("Folder") or child:IsA("BasePart") or child:IsA("Bone") then
				walk(child, depth + 1)
			end
		end
	end

	walk(model, 0)

	print(`--- summary: {baseParts} BasePart(s), {bones} Bone(s), {motor6Ds} Motor6D(s) found ---`)
	if bones > 0 and baseParts <= 2 then
		warn("JointConstraintsSetup: this looks like a Bone-skinned deformation rig, not a classic per-limb R15 rig. HingeConstraint/BallSocketConstraint cannot attach to Bones -- run this against the classic (non-Deform) DOGU15 rig variant instead, if one exists, or the underlying skeleton rig this mesh was generated from.")
	end
end

--- Run this ONCE against a rig sitting in its rest pose. See the file header for why this
--- must not be wired into CharacterAdded. Auto-runs Diagnose() if every joint fails, so a
--- structural mismatch is visible immediately instead of six silent warnings.
function JointConstraintsSetup.Setup(model: Model)
	local successCount = 0
	for _, def in ipairs(JOINTS) do
		local needsSide = string.find(def.Part0Pattern, "%s", 1, true) ~= nil
			or string.find(def.Part1Pattern, "%s", 1, true) ~= nil

		if needsSide then
			if buildJoint(model, def, "Left") then
				successCount += 1
			end
			if buildJoint(model, def, "Right") then
				successCount += 1
			end
		else
			if buildJoint(model, def, nil) then
				successCount += 1
			end
		end
	end

	if successCount == 0 then
		warn("JointConstraintsSetup: every joint failed -- running a structural diagnostic automatically:")
		JointConstraintsSetup.Diagnose(model)
		return
	end

	print(`JointConstraintsSetup: {successCount} joint(s) built on "{model.Name}". Save this rig as your template before shipping.`)
end

return JointConstraintsSetup

--[[
	--------------------------------------------------------------------------------
	HOW TO RUN THIS IN STUDIO

	Option A -- Command Bar (fastest for a one-off pass on a rig already in Workspace):

		local JointConstraintsSetup = require(path.to.this.module)
		local rig = game:GetService("Selection"):Get()[1]
		assert(rig and rig:IsA("Model"), "Select the rig Model in Explorer first")
		JointConstraintsSetup.Setup(rig)

	Option B -- temporary Script under ServerScriptService, rig placed in Workspace:

		local JointConstraintsSetup = require(ReplicatedStorage.CombatFramework.RigTools.JointConstraintsSetup)
		JointConstraintsSetup.Setup(workspace:WaitForChild("DOGU15_Template"))

	Either way: once it's run and you've eyeballed each joint's range of motion in
	Studio (rotate the constraint's Attachment0 with the Rotate tool if a cone is aimed
	wrong, per the original guide), right-click the rig -> Save as... and point your
	DOGU15 template / StarterCharacter at the saved version. Delete the temporary Script
	afterward -- this is a one-time authoring pass, not something that should ship
	running in ServerScriptService.
	--------------------------------------------------------------------------------
]]