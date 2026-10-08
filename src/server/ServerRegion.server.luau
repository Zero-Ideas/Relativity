--!strict
--[[
	Where this server is running, for the topbar's region bubble (UiMode):
	looks up the server's public IP location once and publishes it as the
	ReplicatedStorage attribute "ServerRegion" (e.g. "US · Virginia"). Needs
	HTTP requests enabled; in Studio the "server" is your own machine, so it
	is labelled "Studio".
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local LOOKUP_URL = "http://ip-api.com/json/?fields=status,countryCode,regionName,city"
local ATTEMPTS = 3

ReplicatedStorage:SetAttribute("ServerRegion", "Locating…")

task.spawn(function()
	local label = nil
	for attempt = 1, ATTEMPTS do
		local ok, result = pcall(function()
			return HttpService:JSONDecode(HttpService:GetAsync(LOOKUP_URL))
		end)
		if ok and typeof(result) == "table" and result.status == "success" then
			local where = if result.regionName and result.regionName ~= "" then result.regionName else result.city
			label = `{result.countryCode or "??"} · {where or "?"}`
			break
		end
		if attempt < ATTEMPTS then
			task.wait(2 * attempt)
		end
	end
	if RunService:IsStudio() then
		label = if label then `Studio · {label}` else "Studio"
	end
	ReplicatedStorage:SetAttribute("ServerRegion", label or "Region unknown")
end)
