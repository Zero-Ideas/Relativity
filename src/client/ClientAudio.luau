--!strict
-- Local mixer. Categorized groups keep authored sound volumes intact and
-- update already-playing sounds without scanning the world each frame.
local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local Audio = {}
local groups: {[string]: SoundGroup} = {}
local categories = {"Spell", "Impact", "UI", "Music"}
local started = false

local function group(category: string): SoundGroup
	local existing = groups[category]
	if existing then return existing end
	local created = Instance.new("SoundGroup")
	created.Name = "Relativity" .. category
	created.Parent = SoundService
	groups[category] = created
	return created
end

function Audio.Route(sound: Sound, category: string)
	local tagged = sound:GetAttribute("AudioCategory")
	if typeof(tagged) == "string" and table.find(categories, tagged) then category = tagged end
	sound.SoundGroup = group(category)
end

local function watch(root: Instance, fallback: string)
	local function route(instance: Instance)
		if not instance:IsA("Sound") then return end
		local category = fallback
		local node: Instance? = instance
		while node and node ~= root do
			if string.find(string.lower(node.Name), "music", 1, true) then category = "Music"; break end
			node = node.Parent
		end
		if root == SoundService and instance.Looped then category = "Music" end
		Audio.Route(instance, category)
	end
	root.DescendantAdded:Connect(route)
	for _, instance in root:GetDescendants() do route(instance) end
end

function Audio.SetVolumes(master: number, spell: number, impact: number, ui: number, music: number)
	local levels = {Spell = spell, Impact = impact, UI = ui, Music = music}
	for category, level in levels do group(category).Volume = master * level end
	if started then return end
	started = true
	watch(SoundService, "UI")
	local player = Players.LocalPlayer
	watch(player:WaitForChild("PlayerGui"), "UI")
	watch(player:WaitForChild("PlayerScripts"), "UI")
end

return Audio
