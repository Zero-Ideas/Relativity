--!strict
--[[
	SpatialAudio (client, purely cosmetic)
	Sounds that travel: each plays at a world point after distance /
	SPEED_OF_SOUND seconds (1225 studs/s), so a far-off blast is seen before
	it is heard. Which sound plays and how loud is chosen here from distance
	and power; the engine's own distance rolloff is switched off on these
	clones (only its 3D panning is kept), so it doesn't attenuate twice.
	Templates live in ReplicatedStorage.audio.

	 - Explosion(position, intensity): layered by distance and power
	   (intensity 0..1, ExplosionVFX's log curve over its power range).
	 - PassBy(point, speed, missDistance): a projectile went past the camera
	   (ProjectileClient's pass-by handler, registered below): the sonic crack
	   at >= 1225 studs/s, the bullet whizz at >= 800, within PASS_RADIUS.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ProjectileClient = require(Shared:WaitForChild("Projectile"):WaitForChild("Client"))
local ClientAudio = require(script.Parent.ClientAudio)

local SpatialAudio = {}

local SPEED_OF_SOUND = 1225 -- studs per second
SpatialAudio.SpeedOfSound = SPEED_OF_SOUND

local CRACK_SPEED = 1225 -- supersonic: the sonic crack
local WHIZZ_SPEED = 800 -- fast enough to whizz past
local PASS_RADIUS = 250 -- studs from the camera a projectile must pass within

local EXPLOSIONS = "Explosions"
local CLOSE_SMALL = "impact_explosion_03"
local CLOSE_BIG = "grenade explosion"
local CLOSE_CRUNCH = "Explosion against hard terrain (could work as an extra if the player is close)"
local CLOSE_HUGE = "Shockwave Hit"
local MID_SMALL = "firecracker (sounds distant)"
local MID_BIG = "Distant Explosion sound (v1)"
local FAR_BIG = "distant shockwave"

local PROJECTILES = "projectile sounds"
local CRACK = "sonic crack"
local WHIZZ = "Bullet Miss"

-- Spam guards: the same sound no more often than MIN_GAP, and at most
-- MAX_LIVE travelling or playing at once.
local MIN_GAP = 0.05
local MAX_LIVE = 24
local NO_ROLLOFF = 1e6

local lastPlayed: { [string]: number } = {}
local live = 0

local function template(folderName: string, name: string): Sound?
	local audio = ReplicatedStorage:FindFirstChild("audio")
	local folder = audio and audio:FindFirstChild(folderName)
	local sound = folder and folder:FindFirstChild(name)
	return if sound and sound:IsA("Sound") then sound else nil
end

local function listener(): Vector3
	local camera = workspace.CurrentCamera
	return if camera then camera.CFrame.Position else Vector3.zero
end

-- Plays folder/name at `position` after `delay` seconds at `gain` x its
-- authored volume.
local function emit(folderName: string, name: string, position: Vector3, gain: number, delay: number)
	local source = template(folderName, name)
	local now = os.clock()
	if not source or live >= MAX_LIVE or (lastPlayed[name] and now - lastPlayed[name] < MIN_GAP) then
		return
	end
	lastPlayed[name] = now
	live += 1
	task.delay(delay, function()
		local attachment = Instance.new("Attachment")
		attachment.Name = "SpatialSound"
		attachment.Position = position -- Terrain sits at the origin
		attachment.Parent = workspace.Terrain
		local sound = source:Clone()
		ClientAudio.Route(sound, if folderName == EXPLOSIONS then "Impact" else "Spell")
		sound.Volume = source.Volume * math.clamp(gain, 0, 2)
		sound.RollOffMode = Enum.RollOffMode.Linear
		sound.RollOffMaxDistance = NO_ROLLOFF
		sound.RollOffMinDistance = NO_ROLLOFF
		sound.Parent = attachment
		local finished = false
		local function done()
			if finished then
				return
			end
			finished = true
			live -= 1
			attachment:Destroy()
		end
		sound.Ended:Once(done)
		sound:Play()
		-- backstop for a sound that never loads (Ended would never fire)
		task.delay(math.max(sound.TimeLength, 0) + 10, done)
	end)
end

-- Layers by how far away it is and how strong:
--  close:  a sharp blast (small or big), plus a ground crunch right next to
--          a decent one and a shockwave slam for huge ones;
--  middle: the muffled "distant" version;
--  far:    only a big one's rolling shockwave (or a faint pop).
-- Big blasts carry further: audible out to 250 (weakest) .. 3000 studs.
function SpatialAudio.Explosion(position: Vector3, intensity: number)
	local distance = (listener() - position).Magnitude
	local range = 250 + 2750 * intensity
	if distance > range then
		return
	end
	local delay = distance / SPEED_OF_SOUND
	local loud = 0.55 + 0.45 * intensity
	local closeness = 1 - distance / range -- 1 at the blast, 0 at the edge of hearing
	local near = 60 + 140 * intensity
	if distance <= near then
		local gain = loud * (0.75 + 0.25 * closeness)
		emit(EXPLOSIONS, if intensity < 0.35 then CLOSE_SMALL else CLOSE_BIG, position, gain, delay)
		if intensity >= 0.25 and distance <= 25 + 35 * intensity then
			emit(EXPLOSIONS, CLOSE_CRUNCH, position, gain * 0.8, delay)
		end
		if intensity >= 0.7 then
			emit(EXPLOSIONS, CLOSE_HUGE, position, gain, delay)
		end
	elseif distance <= range * 0.45 then
		emit(EXPLOSIONS, if intensity < 0.4 then MID_SMALL else MID_BIG, position, loud * (0.4 + 0.6 * closeness), delay)
	else
		emit(EXPLOSIONS, if intensity >= 0.5 then FAR_BIG else MID_SMALL, position, loud * (0.25 + 0.75 * closeness), delay)
	end
end

-- A projectile passed the camera at `point` (its closest approach),
-- `missDistance` studs away, moving `speed` studs/s.
function SpatialAudio.PassBy(point: Vector3, speed: number, missDistance: number)
	if missDistance > PASS_RADIUS then
		return
	end
	local delay = missDistance / SPEED_OF_SOUND
	local proximity = 1 - missDistance / PASS_RADIUS
	if speed >= CRACK_SPEED then
		emit(PROJECTILES, CRACK, point, 0.35 + 0.65 * proximity, delay)
	end
	if speed >= WHIZZ_SPEED then
		emit(PROJECTILES, WHIZZ, point, 0.25 + 0.75 * proximity * proximity, delay)
	end
end

ProjectileClient.SetPassByHandler(SpatialAudio.PassBy, WHIZZ_SPEED, PASS_RADIUS)

return SpatialAudio
