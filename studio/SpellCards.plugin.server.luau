-- Local Studio plugin, built separately from the game. No HTTP, cloud
-- DataStores, player kicks or production writes. Plugin settings survive
-- stopping play and closing Studio. Only this server-only bridge can use it.
local RunService = game:GetService("RunService")
if not plugin or not RunService:IsStudio() or RunService:IsClient() or RunService:IsEdit() then return end
local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")
local bridge = ServerStorage:FindFirstChild("RelativityStudioSpellStore")
if bridge and not bridge:IsA("BindableFunction") then return end
if not bridge then
	bridge = Instance.new("BindableFunction")
	bridge.Name = "RelativityStudioSpellStore"
	bridge.Parent = ServerStorage
end

local function key(userId)
	assert(typeof(userId) == "number" and userId == userId and userId % 1 == 0 and math.abs(userId) < 1e15, "Invalid Studio player key")
	return "RelativitySpellCardsV3_" .. string.format("%.0f", game.PlaceId) .. "_" .. string.format("%.0f", userId)
end

local function encode(data)
	local json = HttpService:JSONEncode(data)
	assert(#json <= 500000, "Studio spell book is too large")
	-- Plugin settings have restrictions on escaped quotes/backslashes in
	-- values. Hex encoding avoids those restrictions, including in names.
	return (json:gsub(".", function(char) return string.format("%02x", string.byte(char)) end))
end

local function decode(value)
	if value == nil then return nil end
	assert(typeof(value) == "string" and #value <= 1000000 and #value % 2 == 0 and not value:find("[^%da-f]"), "Stored Studio spell book is malformed; refusing to overwrite it")
	local json = value:gsub("%x%x", function(byte) return string.char(tonumber(byte, 16)) end)
	return HttpService:JSONDecode(json)
end

bridge.OnInvoke = function(action, userId, snapshot, expectedRevision)
	local setting = key(userId)
	local current = decode(plugin:GetSetting(setting))
	if action == "Load" then return current end
	assert(action == "Save" and typeof(snapshot) == "table", "Invalid Studio spell operation")
	if current and current.saveId == snapshot.saveId then return current end
	if (current and current.revision or 0) ~= expectedRevision then return nil end
	if current and typeof(current.schemaVersion) == "number" and current.schemaVersion > snapshot.schemaVersion then return nil end
	local encoded = encode(snapshot)
	plugin:SetSetting(setting, encoded)
	assert(plugin:GetSetting(setting) == encoded, "Studio spell write could not be verified")
	return snapshot
end
bridge:SetAttribute("Ready", true)
plugin.Unloading:Connect(function() if bridge then bridge:Destroy() end end)
print("[SpellStore] Local Studio spell-card persistence ready.")
