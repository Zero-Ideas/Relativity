--!strict
--[[
	Live updates for ReGui windows: instead of tearing a whole window down
	and rebuilding it on every change (losing its scroll position, flashing,
	and costing a full redraw), a window is made once and split into
	Sections. Each section retains its controls and reconciles their
	properties/callbacks when what it shows changes. LiveKey identifies
	dynamic rows independently of their position. Only removed nodes die.

	  local section = ReGuiLive.Section(tab)        -- a slot in the tab
	  section:Render(key, function(canvas) ... end) -- updates when key changes
	  section:Render(nil, build)                    -- always reconciles
	  ReGuiLive.Key(value)                          -- a key from any table

	Dropdowns keep their open / closed state through section:Header.
	Use LiveKey on dynamic rows/groups; unkeyed static controls are matched
	by element type and ordinal within their parent. Input state is retained.
]]

local HttpService = game:GetService("HttpService")

local ReGuiLive = {}

local CONTAINERS = { Row = true, Group = true, CollapsingHeader = true }
local ELEMENTS = {
	Row = true, Group = true, CollapsingHeader = true, Label = true,
	Separator = true, Button = true, SmallButton = true, Checkbox = true,
	InputText = true, Console = true,
}
local identities: { [any]: number } = setmetatable({}, { __mode = "k" }) :: any
local nextIdentity = 0
local function identity(value: any): string
	if typeof(value) == "Instance" or typeof(value) == "table" then
		if not identities[value] then nextIdentity += 1; identities[value] = nextIdentity end
		return "object:" .. identities[value]
	end
	return typeof(value) .. ":" .. tostring(value)
end

local function begin(node: any)
	node.counts = {}
	node.order = 0
	for _, child in node.children do child.seen = false; begin(child) end
end

local function finish(node: any)
	for key, child in node.children do
		if child.seen then finish(child) else child.object:Destroy(); node.children[key] = nil end
	end
end

local function update(node: any, config: any)
	local previous = node.config or {}
	node.config = table.clone(config)
	node.syncing = true -- setters can fire ReGui callbacks; never echo updates
	local object, class = node.object, node.class
	if config.Text ~= nil and config.Text ~= previous.Text then
		if object:IsA("TextLabel") or object:IsA("TextButton") then
			object.Text = config.Text
		elseif node.method == "Separator" then
			local label = object:FindFirstChildWhichIsA("TextLabel", true)
			if label then label.Text = config.Text end
		end
	end
	if config.Title ~= nil and config.Title ~= previous.Title then class:SetTitle(config.Title) end
	if config.Value ~= nil then
		if node.method == "Checkbox" then
			if class.Value ~= config.Value then class:SetTicked(config.Value, true) end
		elseif config.Value ~= previous.Value then
			class:SetValue(config.Value)
		end
	end
	if config.Disabled ~= nil and config.Disabled ~= previous.Disabled then class:SetDisabled(config.Disabled) end
	node.syncing = false
end

local proxy: (node: any) -> any
proxy = function(node: any): any
	return setmetatable({}, {
		__index = function(_, method)
			if not ELEMENTS[method] then
				local value = node.class[method]
				return if typeof(value) == "function" then function(_, ...) return value(node.class, ...) end else value
			end
			return function(_, supplied)
				local config = supplied or {}
				node.counts[method] = (node.counts[method] or 0) + 1
				node.order += 1
				local key = method .. (if config.LiveKey ~= nil then ":key:" .. identity(config.LiveKey) else ":ordinal:" .. node.counts[method])
				local child = node.children[key]
				assert(not child or not child.seen, "Duplicate ReGuiLive key: " .. key)
				if not child then
					child = { method = method, children = {}, counts = {}, order = 0, config = table.clone(config), syncing = true }
					local initial = table.clone(config)
					initial.LiveKey = nil
					initial.Callback = function(...)
						local callback = child.config.Callback
						if not child.syncing and callback then return callback(...) end
					end
					local class, object = node.class[method](node.class, initial)
					child.class, child.object = class, object or class
					assert(typeof(child.object) == "Instance", "ReGuiLive requires a GUI element for " .. method)
					child.proxy = if CONTAINERS[method] then proxy(child) else class
					child.config = {}
					update(child, config)
					node.children[key] = child
				else
					update(child, config)
				end
				child.seen = true
				child.object.LayoutOrder = node.order
				return child.proxy, child.object
			end
		end,
		__newindex = function(_, key, value) node.class[key] = value end,
	})
end

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
	table.clear(self.node.children)
	self.key = nil
end

function Section.Render(self: any, key: string?, build: (canvas: any) -> ()): boolean
	if key ~= nil and key == self.key then
		return false
	end
	captureHeaders(self)
	begin(self.node)
	build(self.canvas)
	finish(self.node)
	self.key = key
	return true
end

-- A CollapsingHeader that reopens the way it was left (default: config's
-- Collapsed, or closed).
function Section.Header(self: any, canvas: any, id: string, config: { [string]: any }): any
	config.LiveKey = id
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
	local node = { class = canvas, object = object, children = {}, counts = {}, order = 0 }
	return setmetatable({
		canvas = proxy(node),
		node = node,
		object = object,
		key = nil,
		headers = {},
		open = {},
	}, Section) :: any
end

return ReGuiLive
