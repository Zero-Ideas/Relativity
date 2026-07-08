--[[
	Server bootstrap: wires up time-scale replication (so clients can mirror
	dilation for visuals) and, optionally, chunk auto-loading around players.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local ChunkManager = require(Shared.ChunkManager)

ChunkManager.EnableReplication()

-- Optional: freeze simulation in chunks with no players nearby.
-- ChunkManager.ConfigureAutoLoad({ Enabled = true, Radius = 256, Interval = 0.5 })
