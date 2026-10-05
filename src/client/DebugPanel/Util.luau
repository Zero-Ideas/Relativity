--!optimize 2
-- Small helpers shared by the debug panel's tabs.
local Stats = game:GetService("Stats")

local Util = {}

-- Real seconds between panel ticks (and between server stat/watch pushes).
Util.STATS_INTERVAL = 0.5

function Util.readStat(name: string): number?
	local ok, value = pcall(function()
		return (Stats :: any)[name]
	end)
	return if ok and typeof(value) == "number" then value else nil
end

function Util.fmt(pattern: string, value: number?): string
	return if value == nil then "-" else string.format(pattern, value)
end

-- A label whose text is only written when it changes (avoids re-layout).
function Util.statLine(canvas, name: string)
	local label = canvas:Label({ Text = name .. ": -" })
	local last = ""
	return function(value: string)
		if value ~= last then
			last = value
			label.Text = `{name}: {value}`
		end
	end
end

-- Grows a pool of GuiObjects on demand; hide() parks everything past `used`.
function Util.pool(parent: GuiObject, make: () -> GuiObject)
	local items: { GuiObject } = {}
	local used = 0
	local self = {}
	function self.take(): GuiObject
		used += 1
		local item = items[used]
		if not item then
		item = make()
		item.Parent = parent
		items[used] = item
		end
		item.Visible = true
		return item
	end
	function self.reset()
		used = 0
	end
	function self.hide()
		for index = used + 1, #items do
		items[index].Visible = false
		end
	end
	return self
end

return Util
