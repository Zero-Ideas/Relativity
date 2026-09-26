--!optimize 2
--[[ MapGen/Furniture/TV.luau -- built facing +Z, floor at local Y=0. ]]

local FurnitureBase = require(script.Parent.FurnitureBase)
local part = FurnitureBase.part

local TV = {}

export type TVConfig = {
	frameColor: Color3?,
}

function TV.generate(cframe: CFrame, config: TVConfig?): Model
	config = config or {}
	local frameColor = config.frameColor or Color3.fromRGB(35, 35, 38) -- lighter than screen, must actually contrast
	local screenColor = Color3.fromRGB(5, 5, 6) -- much darker, this contrast is the whole trick

	-- base footprint now close to panel width, not a third of it
	local base = part("Base", Vector3.new(2.6, 0.15, 1.1), CFrame.new(0, 0.075, 0), frameColor, Enum.Material.Metal)

	local stemHeight = 1.2 -- shorter, real TVs sit lower over the stand
	local stemBottomY = 0.15
	local stemCenterY = stemBottomY + stemHeight / 2

	local frameDepth = 0.15
	local frameFrontZ = frameDepth / 2

	-- bezel border: screen is visibly smaller than frame (real border width, not 0.02 studs)
	local bezel = 0.2
	local frameWidth, frameHeight = 3.4, 2.0
	local screenWidth, screenHeight = frameWidth - bezel * 2, frameHeight - bezel * 2

	local screenDepth = 0.03
	local recess = 0.05 -- visible recess, not imperceptible
	local screenFrontZ = frameFrontZ - recess
	local screenCenterZ = screenFrontZ - screenDepth / 2

	local parts = {
		part("Stem", Vector3.new(0.3, stemHeight, frameDepth), CFrame.new(0, stemCenterY, 0), frameColor, Enum.Material.Metal),

		part("Frame", Vector3.new(frameWidth, frameHeight, frameDepth), CFrame.new(0, stemBottomY + stemHeight + frameHeight/2, 0), frameColor, Enum.Material.SmoothPlastic),

		part("Screen", Vector3.new(screenWidth, screenHeight, screenDepth), CFrame.new(0, stemBottomY + stemHeight + frameHeight/2, screenCenterZ), screenColor, Enum.Material.Glass),
	}

	return FurnitureBase.assemble("TV", base, parts, cframe)
end

return TV