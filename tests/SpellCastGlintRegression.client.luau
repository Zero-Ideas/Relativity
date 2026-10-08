-- Studio client: no casts, mana deductions, or saved cards are changed.
local player = game.Players.LocalPlayer
local Glint = require(player.PlayerScripts.Client.SpellCastGlint)
local character = player.Character or player.CharacterAdded:Wait()
local head = character:WaitForChild("Head")
Glint.Play(character, 0, head.Position + head.CFrame.LookVector * 100)
local screen = player.PlayerGui:WaitForChild("SpellCastIndicators")
local simple = screen:FindFirstChild("Tier0")
assert(simple and simple:IsA("CanvasGroup"), "Indicator must use ScreenGui glyphs")
local simpleCount = #simple:GetDescendants()
task.wait(0.5)
assert(not simple.Visible, "Pulse did not finish")
Glint.Play(character, 0)
assert(screen:FindFirstChild("Tier0") == simple, "Pulse did not reuse retained UI")
Glint.Play(character, 1000)
local ornate = screen:FindFirstChild("Tier5")
assert(ornate and #ornate:GetDescendants() > simpleCount, "Higher tier must be more ornate")
for _, item in screen:GetDescendants() do
	assert(not item:IsA("BasePart"), "Indicator created physical geometry")
end
task.wait(0.5)
assert(not ornate.Visible, "Ornate pulse did not finish")
print("[SpellCastGlintRegression] PASS: ScreenGui, retained glyphs, increasing ornament, pulse cleanup")
