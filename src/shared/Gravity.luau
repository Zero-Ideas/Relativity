--!optimize 2
--[[
	Gravity.luau
	Applies dilated gravity to an entity. The integration runs on the entity's
	OnUpdate loop, whose dt is already scaled by global * chunk * entity time.
	Because both the velocity gain and the displacement use that same dilated
	dt, acceleration effectively scales with time²:

	    inside a 0.2x chunk -> 0.2² = 0.04x the fall acceleration ("floaty")

	This only manually integrates entities the engine is NOT already simulating
	(anchored parts, part-less/data entities). A free Humanoid rig is left to
	Roblox physics — overriding its position every frame would fight the engine —
	but its :SetTimeScale-driven WalkSpeed/JumpPower dilation still applies via
	the Entity system.

	API:
	 Gravity.Apply(entity, options?) -> { Disconnect }
	 options = {
	     Acceleration = 196.2,   -- studs/s² (Roblox default workspace.Gravity)
	     GroundY = nil,          -- rest/bounce plane; nil = fall forever
	     Restitution = 0,        -- bounciness at GroundY (0..1)
	     Terminal = nil,         -- optional max fall speed (studs/s)
	 }
]]

local Gravity = {}
Gravity.Acceleration = 196.2 -- matches Roblox's default workspace.Gravity

function Gravity.Apply(entity, options)
	options = options or {}
	local acceleration = options.Acceleration or Gravity.Acceleration
	local restitution = options.Restitution or 0
	local groundY = options.GroundY
	local terminal = options.Terminal

	entity._gravityVelocity = entity._gravityVelocity or Vector3.zero

	return entity:OnUpdate(function(dt, self)
		if dt <= 0 then
			return
		end

		-- A rig the engine is actively simulating owns its own motion.
		local root = self._root
		if root and self.Humanoid and not root.Anchored then
			return
		end

		local velocity = self._gravityVelocity - Vector3.new(0, acceleration * dt, 0)
		if terminal and velocity.Y < -terminal then
			velocity = Vector3.new(velocity.X, -terminal, velocity.Z)
		end

		local position = self:GetPosition() + velocity * dt

		if groundY and position.Y <= groundY then
			position = Vector3.new(position.X, groundY, position.Z)
			if restitution > 0 and velocity.Y < 0 then
				velocity = Vector3.new(velocity.X, -velocity.Y * restitution, velocity.Z)
				-- kill tiny residual bounces so it settles
				if velocity.Y < acceleration * dt then
					velocity = Vector3.new(velocity.X, 0, velocity.Z)
				end
			else
				velocity = Vector3.new(velocity.X, 0, velocity.Z)
			end
		end

		self._gravityVelocity = velocity
		self:SetPosition(position)
	end)
end

-- Adds an instantaneous velocity impulse (e.g. a jump or knockback) that the
-- integrator will then decay under gravity.
function Gravity.Impulse(entity, velocity: Vector3)
	entity._gravityVelocity = (entity._gravityVelocity or Vector3.zero) + velocity
end

return Gravity
