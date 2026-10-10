--!strict
--[[
	CastAim (server)
	Relays where each caster is aiming, so everyone can draw their casting
	pose (client/CastPose: arm pointed at it, head turned toward it). A
	client sends its aim point while casting and nil when done; it goes on
	the character's "CastTarget" attribute, which replicates to everyone.
	Rate-limited (a burst of BURST, then RATE a second) and checked: a
	finite point within MAX_RANGE studs of the character.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RATE, BURST = 20, 10
local MAX_RANGE = 10000

local remote = Instance.new("RemoteEvent")
remote.Name = "CastAim"
remote.Parent = ReplicatedStorage

local tokens: { [Player]: number } = {}
local refilled: { [Player]: number } = {}

remote.OnServerEvent:Connect(function(player: Player, target: any)
	if target == nil then
		-- (stopping is never rate-limited: a dropped stop would leave the pose up)
		local character = player.Character
		if character then
			character:SetAttribute("CastTarget", nil)
		end
		return
	end
	local now = os.clock()
	local available = math.min(BURST, (tokens[player] or BURST) + (now - (refilled[player] or now)) * RATE)
	refilled[player] = now
	if available < 1 then
		tokens[player] = available
		return
	end
	tokens[player] = available - 1

	local character = player.Character
	if not character then
		return
	end
	if typeof(target) ~= "Vector3" or target ~= target or target.Magnitude == math.huge then
		return
	end
	local origin = character:GetPivot().Position
	if (target - origin).Magnitude > MAX_RANGE then
		target = origin + (target - origin).Unit * MAX_RANGE
	end
	character:SetAttribute("CastTarget", target)
end)

Players.PlayerRemoving:Connect(function(player)
	tokens[player] = nil
	refilled[player] = nil
end)
