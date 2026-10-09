--!strict
-- Which sustained-beam implementation runs. BeamChain (lightweight samples,
-- one replicated stream per channel) is the default. The original
-- BeamProjectileHandler (every packet and joiner a full projectile) is kept
-- as a backup: set the attribute LegacyBeams = true on ServerScriptService
-- before the server starts to run it instead (e.g. to A/B a benchmark).
-- Only the chosen one is required -- each installs the beam span step.
local legacy = game:GetService("ServerScriptService"):GetAttribute("LegacyBeams") == true
return require(script.Parent:WaitForChild(if legacy then "BeamProjectileHandler" else "BeamChain")) :: any
