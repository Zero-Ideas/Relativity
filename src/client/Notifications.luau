--!strict
--[[
	Messages: every notification goes into one list, shown in a ReGui
	"Messages" window opened from the topbar's Notifications icon (see
	UiMode, which badges it with how many arrived while it was closed).
	Newest first; each one has its own buttons (Accept / Decline ...) and
	Dismiss, and the window has Clear all. A notification with an ExpiresIn
	(e.g. a party invite) loses its buttons and is marked expired once that
	runs out; all stay until dismissed.

	  Notifications.Push({
	      Title = "Party invite",
	      Text = "Bob invited you to their party.",
	      ExpiresIn = 30,                      -- seconds (optional)
	      Buttons = {                          -- optional; each one dismisses
	          { Text = "Accept", Callback = function() ... end },
	          { Text = "Decline", Callback = function() ... end },
	      },
	  }) -> dismiss()

	Added fires on every Push; Changed whenever the list changes.
]]

local Signal = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Signal"))
local ReGuiLoader = require(script.Parent.ReGuiLoader)
local ReGuiLive = require(script.Parent.ReGuiLive)

export type Button = { Text: string, Callback: (() -> ())? }
export type Options = {
	Title: string?,
	Text: string,
	ExpiresIn: number?,
	Buttons: { Button }?,
}
type Entry = { options: Options, id: number, expired: boolean, time: string }

local WIDTH = 320
local MAX_KEPT = 50

local Notifications = {}
local addedEvent = Signal.new()
Notifications.Added = addedEvent
local changedEvent = Signal.new()
Notifications.Changed = changedEvent

local entries: { Entry } = {} -- oldest first
local nextId = 0
local window: any = nil
local section: any = nil
local open = false
local building = false
local updateQueued = false
local lastPosition: UDim2? = nil
local lastSize: UDim2? = nil

local update: () -> ()

local function remove(entry: Entry)
	local index = table.find(entries, entry)
	if index then
		table.remove(entries, index)
		changedEvent:Fire()
		update()
	end
end

local function clearAll()
	table.clear(entries)
	changedEvent:Fire()
	update()
end

local function closeWindow()
	if window then
		lastPosition = window.WindowFrame.Position
		lastSize = window.WindowFrame.Size
		window:SetVisible(false)
	end
end

-- Reconciles retained controls; coalesces bursts of changes into one update.
function update()
	if not open then
		return
	end
	if building then
		updateQueued = true
		return
	end
	building = true
	task.spawn(function()
		local ReGui = ReGuiLoader.Get()
		while ReGui and open do
			updateQueued = false
			if not window then
				window = ReGui:Window({
					Title = `Messages ({#entries})`,
					Size = lastSize or UDim2.fromOffset(WIDTH, 420),
					NoCollapse = true,
					NoWindowRegistor = true,
					CloseCallback = function()
						open = false
						lastPosition = window and window.WindowFrame.Position
						lastSize = window and window.WindowFrame.Size
						closeWindow()
						changedEvent:Fire()
						return false
					end,
				})
				local frame = window.WindowFrame
				-- (top-left anchor, which ReGui's resize handle assumes: placed at
				-- the right edge by its width instead)
				frame.Position = lastPosition or UDim2.new(1, -16 - frame.Size.X.Offset, 0, 70)
				section = ReGuiLive.Section(window)
			end
			window:SetTitle(`Messages ({#entries})`)
			section:Render(nil, function(window)
				-- interactable ones (buttons, not expired) get their own area on
				-- top; everything else is a line in the text box below it
				local actionable, plain = {}, {}
				for _, entry in entries do
					if entry.options.Buttons and #entry.options.Buttons > 0 and not entry.expired then
						table.insert(actionable, entry)
					else
						table.insert(plain, entry)
					end
				end
				if #entries > 0 then
					window:Button({ Text = "Clear all", Callback = clearAll })
				end
				window:Separator({ Text = `Requests ({#actionable})` })
				if #actionable == 0 then
					window:Label({ Text = "Nothing to answer." })
				end
				for index = #actionable, 1, -1 do
					local entry = actionable[index]
					local options = entry.options
					local request = window:Group({ LiveKey = "request:" .. entry.id })
					local label = request:Label({ Text = `{options.Title or "Notice"}: {options.Text}` })
					pcall(function()
						label.TextWrapped = true
						label.AutomaticSize = Enum.AutomaticSize.Y
						label.Size = UDim2.new(1, 0, 0, 0)
					end)
					local row = request:Row()
					for _, button in options.Buttons or {} do
						row:SmallButton({
							Text = button.Text,
							Callback = function()
								remove(entry)
								if button.Callback then
									button.Callback()
								end
							end,
						})
					end
					row:SmallButton({ Text = "Dismiss", Callback = function() remove(entry) end })
				end
				window:Separator({ Text = "Messages" })
				local lines = {}
				for _, entry in plain do -- (oldest first: the newest is at the bottom)
					local options = entry.options
					table.insert(lines, `[{entry.time}] {options.Title or "Notice"}{if entry.expired then " (expired)" else ""}: {options.Text}`)
				end
				window:Console({
					ReadOnly = true,
					TextWrapped = true,
					Fill = true,
					AutoScroll = true,
					Value = if #lines > 0 then table.concat(lines, "\n") else "No messages.",
				})
			end)
			if not updateQueued then
				break
			end
		end
		building = false
	end)
end

function Notifications.Push(options: Options): () -> ()
	nextId += 1
	local entry: Entry = { options = options, id = nextId, expired = false, time = os.date("%H:%M") }
	table.insert(entries, entry)
	while #entries > MAX_KEPT do
		table.remove(entries, 1)
	end
	if options.ExpiresIn then
		-- (stays listed, marked expired and without its buttons)
		task.delay(options.ExpiresIn, function()
			if table.find(entries, entry) then
				entry.expired = true
				changedEvent:Fire()
				update()
			end
		end)
	end
	addedEvent:Fire(options)
	changedEvent:Fire()
	update()
	return function()
		remove(entry)
	end
end

function Notifications.Count(): number
	return #entries
end

function Notifications.IsOpen(): boolean
	return open
end

function Notifications.SetOpen(value: boolean)
	if open == value then
		return
	end
	open = value
	if open then
		if window then window:SetVisible(true) end
		update()
	else
		closeWindow()
	end
	changedEvent:Fire()
end

function Notifications.Toggle()
	Notifications.SetOpen(not open)
end

return Notifications
