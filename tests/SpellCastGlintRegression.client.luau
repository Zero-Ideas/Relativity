-- Studio client: no casts, mana deductions, or saved cards are changed.
local player = game.Players.LocalPlayer
local Glint = require(player.PlayerScripts.Client.SpellCastGlint)
local wasEnabled = Glint.IsEnabled()
Glint.SetEnabled(true) -- (glints are off by default)
local character = player.Character or player.CharacterAdded:Wait()
local head = character:WaitForChild("Head")

-- faces the cast direction
local target = head.Position + Vector3.new(100, 0, 0)
Glint.Play(character, 0, target)
local folder = workspace:WaitForChild("SpellCastGlints")
local simple = folder:FindFirstChildWhichIsA("BasePart")
assert(simple, "Glint must be a world-space part")
-- (each stroke fades itself: the ring's bright core is fully shown at 0.05)
local core = nil
for _, item in simple:GetDescendants() do
	if item:IsA("UIStroke") and item.Thickness == 1 then core = item; break end
end
assert(core and core.Transparency > 0.9, "Glint must flare in, not pop into existence")
local look = simple.CFrame.LookVector
assert(look:Dot((target - head.Position).Unit) > 0.95, "Glint must face the cast direction")
task.wait(0.1)
assert(core.Transparency < 0.5, "Glint did not flare in")
local simpleCount = #simple:GetDescendants()
task.wait(0.7)
assert(simple.Parent == nil, "Glint did not finish")

-- pooled per tier; higher tiers are more ornate
Glint.Play(character, 0)
assert(folder:FindFirstChildWhichIsA("BasePart") == simple, "Glint did not reuse its pooled part")
Glint.Play(character, 1000)
local ornate = nil
for _, part in folder:GetChildren() do
	if part ~= simple then ornate = part end
end
assert(ornate and #ornate:GetDescendants() > simpleCount, "Higher tier must be more ornate")
task.wait(1.3) -- (higher tiers linger longer)
assert(#folder:GetChildren() == 0, "Ornate glint did not finish")
Glint.SetEnabled(false)
assert(Glint.Play(character, 0) == nil, "A disabled glint must not play")
Glint.SetEnabled(wasEnabled)
print("[SpellCastGlintRegression] PASS: world-space, faces the cast, flares in, pooled, increasing ornament, cleanup")
