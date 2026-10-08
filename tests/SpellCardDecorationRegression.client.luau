-- Studio client; no saved cards or gameplay state are changed.
local Decoration = require(game.Players.LocalPlayer.PlayerScripts.Client.SpellCardDecoration)
local expected = { { 0, 0 }, { 199, 0 }, { 200, 1 }, { 399, 1 }, { 400, 2 },
	{ 599, 2 }, { 600, 3 }, { 799, 3 }, { 800, 4 }, { 999, 4 }, { 1000, 5 }, { 10000, 5 } }
for _, pair in expected do assert(Decoration.GetTier(pair[1]) == pair[2], "Wrong mana threshold") end
local card = Instance.new("Frame")
local border = Decoration.new(card)
local ok, err = pcall(function()
	local previous = -1
	for tier = 0, 5 do
		border:Update(tier * 200, false)
		local count = #border.Groups[tier]:GetDescendants()
		assert(count > previous, "Border did not get more ornate")
		previous = count
	end
	border:Update(800, false)
	assert(border.Border.Color.R > border.Border.Color.B, "800-999 tier must be red")
	local added, removed = 0, 0
	local a = card.DescendantAdded:Connect(function() added += 1 end)
	local b = card.DescendantRemoving:Connect(function() removed += 1 end)
	border:Update(850, true)
	border:Update(800, false)
	border:Update(1000, true)
	border:Update(200, false)
	a:Disconnect(); b:Disconnect()
	assert(added == 0 and removed == 0, "Cached border/selection update caused instance churn")
	local count = #card:GetDescendants()
	border:Flash(850)
	assert(border.Glint.Visible, "Cast glint must show immediately")
	assert(border.Glint.BackgroundColor3 == Decoration.GetColor(850):Lerp(Color3.new(1, 1, 1), 0.35), "Glint must use actual expenditure tier")
	border:Flash(1000)
	assert(border.Glint.Visible, "Replacing a flash must not hide the new flash")
	task.wait(0.4)
	assert(not border.Glint.Visible and border.GlintTween == nil, "Glint must finish and release its tween")
	assert(#card:GetDescendants() == count, "Cast flashes must reuse UI instances")
	border:Update(nil, false)
	assert(not border.Root.Visible, "Empty card border remained visible")
end)
border:Destroy(); card:Destroy()
assert(ok, err)
print("[SpellCardDecorationRegression] PASS: thresholds, ornament, retained updates, cast glint, empty state")
