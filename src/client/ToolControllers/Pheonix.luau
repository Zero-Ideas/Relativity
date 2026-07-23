--!optimize 2
-- Railgun tool controller. Matched by Tool.Name == "Railgun" (see
-- ToolManager.luau). Plain shooting weapon -- see _ShootingWeapon.luau.
-- Fires the RailgunRod effect because "Railgun" is registered in
-- src/server/Weapons/Railgun.luau (-> ReplicatedStorage.Effects.RailgunRod).
return require(script.Parent._ShootingWeapon)
