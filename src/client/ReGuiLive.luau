--!strict
--[[
	Live updates for ReGui windows: instead of tearing a whole window down
	and rebuilding it on every change (losing its scroll position, flashing,
	and costing a full redraw), a window is made once and split into
	Sections. Each section is a ReGui Group that can rebuild just its own
	contents, in place, and only when what it shows actually changed:

	  local section = ReGuiLive.Section(tab)        -- a slot in the tab
	  section:Render(key, function(canvas) ... end) -- (re)builds into canvas
	                                                   when `key` differs from
	                                                   the last render's
	  section:Render(nil, build)                    -- always rebuilds
	  ReGuiLive.Key(value)                          -- a key from any table

	Dropdowns (CollapsingHeaders) keep their open / closed state across
	rebuilds through section:Header(canvas, id, config): the same id
	reopens the same way.
]]

local HttpService = game:GetService("HttpService")

local ReGuiLive = {}

export type Section = {
	canvas: any,
	object: Instance,
	key: string?,
	headers: { [string]: any },
	open: { [string]: boolean },
	Render: (self: Section, key: string?, build: (canvas: any) -> ()) -> boolean,
	Header: (self: Section, canvas: any, id: string, config: { [string]: any }) -> any,
	Clear: (self: Section) -> (),
}

-- A stable string for a plain table of values (for Render keys).
function ReGuiLive.Key(value: any): string
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, value)
	return if ok then encoded else tostring(math.random())
end

local Section = {}
Section.__index = Section

-- Remembers which dropdowns were open, before their instances go.
local function captureHeaders(self: any)
	for id, header in self.headers do
		local ok, collapsed = pcall(function()
			return header.Collapsed
		end)
		if ok and typeof(collapsed) == "boolean" then
			self.open[id] = not collapsed
		end
	end
	table.clear(self.headers)
end

function Section.Clear(self: any)
	captureHeaders(self)
	for _, child in self.object:GetChildren() do
		-- (keep the group's own layout objects)
		if not child:IsA("UIComponent") then
			child:Destroy()
		end
	end
	self.key = nil
end

function Section.Render(self: any, key: string?, build: (canvas: any) -> ()): boolean
	if key ~= nil and key == self.key then
		return false
	end
	self:Clear()
	self.key = key
	build(self.canvas)
	return true
end

-- A CollapsingHeader that reopens the way it was left (default: config's
-- Collapsed, or closed).
function Section.Header(self: any, canvas: any, id: string, config: { [string]: any }): any
	local remembered = self.open[id]
	if remembered ~= nil then
		config.Collapsed = not remembered
	end
	local header = canvas:CollapsingHeader(config)
	self.headers[id] = header
	return header
end

function ReGuiLive.Section(parent: any): Section
	local canvas, object = parent:Group()
	return setmetatable({
		canvas = canvas,
		object = object,
		key = nil,
		headers = {},
		open = {},
	}, Section) :: any
end

return ReGuiLive
