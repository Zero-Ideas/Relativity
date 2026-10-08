-- Studio client. Mocks local selection only; never changes saved cards.
local player = game.Players.LocalPlayer
local client = player.PlayerScripts.Client
local Hud = require(client.GameHud)
local Editor = require(client.SpellAssemblerGui)
local Decoration = require(client.SpellCardDecoration)
local Compiler = require(game.ReplicatedStorage.Shared.SpellCompiler)
local gui = player.PlayerGui:WaitForChild("GameHud")
local originalSelection, originalEnabled = Editor.GetSelectedSlot, gui.Enabled
local state = Editor.GetState()
local loadDeadline = os.clock() + 10
while (not state.slots or next(state.slots) == nil) and os.clock() < loadDeadline do
	task.wait(0.1)
	state = Editor.GetState()
end
local slot, record
for index = 1, 5 do
	local candidate = state.slots and (state.slots[index] or state.slots[tostring(index)])
	if candidate then slot, record = index, candidate; break end
end
assert(slot and record, "This layout test needs an existing spell card")
local function refresh()
	Hud.SetEnabled(false); Hud.SetEnabled(true)
end
local ok, err = pcall(function()
	Editor.GetSelectedSlot = function() return slot end
	refresh()
	task.wait()
	local heading = gui.EquippedSpellHeading
	assert(heading.Visible and heading.SpellName.Text == record.name, "Missing equipped spell name")
	local compiled = Compiler.Compile(record.graph)
	assert(heading.TierUnderline.BackgroundColor3 == Decoration.GetColor(compiled.manaCost), "Underline tier mismatch")
	local sequence = heading.TierUnderline.UIGradient.Transparency.Keypoints
	assert(sequence[1].Value == 1 and sequence[#sequence].Value == 1, "Underline ends must fade out")
	assert(heading.AbsolutePosition.Y + heading.AbsoluteSize.Y < gui.SpellCards.AbsolutePosition.Y, "Heading must sit above cards")
	for _, holder in gui.SpellCards:GetChildren() do
		if not holder:IsA("Frame") then continue end
		local card = holder.Card
		assert(card.AbsoluteSize.X == card.AbsoluteSize.Y, "Card is not square")
		assert(not card:FindFirstChild("SpellName"), "Name still appears inside the card")
	end
	Editor.GetSelectedSlot = function() return nil end
	refresh()
	assert(not heading.Visible, "Heading remains after deselection")
end)
Editor.GetSelectedSlot = originalSelection
refresh(); Hud.SetEnabled(originalEnabled)
assert(ok, err)
print("[SpellCardLayoutRegression] PASS: square cards, no card names, equipped heading, tier underline, fading ends, deselection")
