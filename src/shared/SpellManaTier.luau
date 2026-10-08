--!strict
-- Shared palette for card borders and publicly visible cast expenditure.
local Tier = {}
Tier.Colors = {
	Color3.fromRGB(151, 157, 170), Color3.fromRGB(91, 211, 132),
	Color3.fromRGB(91, 164, 255), Color3.fromRGB(187, 120, 255),
	Color3.fromRGB(255, 100, 112), Color3.fromRGB(255, 204, 99),
}
function Tier.GetTier(cost: number): number
	return math.clamp(math.floor(math.max(cost, 0) / 200), 0, 5)
end
function Tier.GetColor(cost: number): Color3
	return Tier.Colors[Tier.GetTier(cost) + 1]
end
return Tier
