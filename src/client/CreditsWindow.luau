--!strict
-- Menu > Credits. Build lazily once and retain the window while hidden.
local ReGuiLoader = require(script.Parent.ReGuiLoader)

local CreditsWindow = {}
local window: any = nil
local open = false
local loading = false

function CreditsWindow.Close()
	open = false
	if window then window:SetVisible(false) end
end

local function build(ReGui: any)
	window = ReGui:Window({
		Title = "Credits",
		Size = UDim2.fromOffset(420, 280),
		NoCollapse = true,
		NoWindowRegistor = true,
		CloseCallback = function()
			CreditsWindow.Close()
			return false -- Hide rather than destroy; reopening reuses the UI.
		end,
	})
	window.WindowFrame.Position = UDim2.fromOffset(16, 70)
	for _, credit in {
		{ Name = "powdxred", Work = "Backend work, optimizations, and Menu 1" },
		{ Name = "TheBiggestFloppyDoge", Work = "Menu 2" },
		{ Name = "Depthso", Work = "ReGUI UI library" },
	} do
		window:Separator({ Text = credit.Name })
		window:Label({ Text = credit.Work, TextWrapped = true })
	end
end

function CreditsWindow.Open()
	open = true
	if window then
		window:SetVisible(true)
		return
	end
	if loading then return end
	loading = true
	task.spawn(function()
		local ReGui = ReGuiLoader.Get()
		if ReGui and open then build(ReGui) end
		loading = false
		if not ReGui then open = false end
	end)
end

function CreditsWindow.Toggle()
	if open then CreditsWindow.Close() else CreditsWindow.Open() end
end


function CreditsWindow.IsOpen(): boolean
	return open
end

return CreditsWindow
