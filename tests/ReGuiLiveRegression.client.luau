-- Studio client regression: no remotes, saved data, or gameplay mutations.
local client = game.Players.LocalPlayer.PlayerScripts.Client
local Live = require(client.ReGuiLive)
local ReGui = require(client.ReGuiLoader).Get()
assert(ReGui, "ReGui failed to load")
local window = ReGui:Window({
	Title = "Retained UI regression", NoWindowRegistor = true,
	CloseCallback = function(self) self:SetVisible(false); return false end,
})
local section = Live.Section(window)
local rows, calls, echoes = {}, 0, 0
local function render(order, text, value, multiplier)
	section:Render(nil, function(canvas)
		for _, id in order do
			local row, object = canvas:Row({ LiveKey = id })
			local label = row:Label({ Text = text .. id })
			row:SmallButton({ Text = "Action", Callback = function() calls += id * multiplier end })
			local box = row:Checkbox({ Label = "Enabled", Value = value, Callback = function() echoes += 1 end })
			local input = row:InputText({ Label = "", Value = "initial" })
			rows[id] = { object = object, label = label, box = box, input = input }
		end
	end)
end
local added, removed = 0, 0
local connections = {}
local ok, err = pcall(function()
	render({ 1, 2 }, "Before", false, 1)
	local one, two = rows[1], rows[2]
	one.input:SetValue("unsaved draft")
	table.insert(connections, window.WindowFrame.DescendantAdded:Connect(function() added += 1 end))
	table.insert(connections, window.WindowFrame.DescendantRemoving:Connect(function() removed += 1 end))
	render({ 2, 1 }, "After", true, 10)
	assert(rows[1].object == one.object and rows[2].object == two.object, "Rows were recreated or lost identity")
	assert(one.label.Text == "After1" and one.box.Value, "Properties did not update")
	assert(one.input.Value == "unsaved draft", "Unchanged server value erased draft input")
	assert(echoes == 0, "Programmatic updates fired callbacks")
	for _, row in section.node.children do
		for _, child in row.children do if child.method == "SmallButton" then child.config.Callback() end end
	end
	assert(calls == 30, "Retained buttons used stale callbacks")
	window:Close()
	assert(window.WindowFrame.Parent and not window.Visible, "Close destroyed the window")
	window:SetVisible(true)
	assert(added == 0 and removed == 0, "Update/reorder/hide/show caused instance churn")
	render({ 2 }, "Remaining", false, 1)
	assert(one.object.Parent == nil and two.object.Parent ~= nil, "Removal affected the wrong row")
	local sameNameA, sameNameB = Instance.new("Folder"), Instance.new("Folder")
	sameNameA.Name, sameNameB.Name = "Same", "Same"
	section:Render(nil, function(canvas)
		local _, a = canvas:Row({ LiveKey = sameNameA })
		local _, b = canvas:Row({ LiveKey = sameNameB })
		assert(a ~= b, "Instance keys collided by name")
	end)
	sameNameA:Destroy(); sameNameB:Destroy()
	local header
	local function renderHeader(count)
		section:Render(nil, function(canvas)
			header = section:Header(canvas, "liveHeader", { Title = "Live rows", Collapsed = false })
			for index = 1, count do header:Label({ Text = "Row " .. index }) end
		end)
	end
	renderHeader(2)
	task.wait(0.35)
	local content, before = header.ParentCanvas, header.ParentCanvas.AbsoluteSize.Y
	renderHeader(10)
	task.wait(0.1)
	assert(header.ParentCanvas == content and content.AbsoluteSize.Y > before, "Retained open header did not resize")
	header:SetCollapsed(true)
	task.wait(0.35)
	renderHeader(12)
	assert(header.Collapsed, "Updating a header lost its collapsed state")
end)
for _, connection in connections do connection:Disconnect() end
window:Remove()
assert(ok, err)
print("[ReGuiLiveRegression] PASS: identity, zero-churn updates, latest callbacks, no echoes, drafts, hide/show, removal, unique keys, live headers")
