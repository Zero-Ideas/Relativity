-- Script Path: game:GetService("Players").powdxred.Backpack["'Grace' Service Revolver"].toolScript
-- Took 3.94s to decompile.
-- Executor: Potassium (v2.4.7)

-- Decompiled by Sabre (https://www.decompiler.lol/) - bytecode v9 types v3
local Parent_2 = script.Parent
local LocalPlayer = game.Players.LocalPlayer
local Character = LocalPlayer.Character
local CurrentCamera = workspace.CurrentCamera
local Jolt = require(game.ReplicatedStorage.shared.Jolt)
local bFunctions = require(game.ReplicatedStorage.shared.bFunctions)
local localization = require(game.ReplicatedStorage.shared.localization)
local localize = localization.localize
local localize_formatted = localization.localize_formatted
local action = Character:WaitForChild("action", 100)
local RenderStepped = game:GetService("RunService").RenderStepped
local UserInputService = game:GetService("UserInputService")
local visualEffects = require(game.ReplicatedStorage.shared.visualEffects)
local weaponEffects = require(game.ReplicatedStorage.shared.weaponEffects)
local r15 = false
local Mouse = LocalPlayer:GetMouse()
local Value_2 = Parent_2:WaitForChild("weapon", 100).Value
local r18 = ""
local Value_3 = Parent_2:WaitForChild("model", 100).Value
local r20 = bFunctions:deepCopy(require(game.ReplicatedStorage.weapon_modules:FindFirstChild(Value_2)))
local core_game = LocalPlayer.PlayerGui:FindFirstChild("main").core_game
local base = require(game.ReplicatedStorage.shared.base)
local Humanoid = Character:WaitForChild("Humanoid", 100)
if r20.variant ~= "" then
    r18 = Value_2
    r20 = bFunctions:deepCopy(require(game.ReplicatedStorage.weapon_modules:FindFirstChild(r18)))
    Value_2 = r20.variant
end
local events = _G.events
local r25 = {}
local r26 = {}
local function get_string_reference(r0) -- Line: 40 | Name: get_string_reference | Upvalues: ("localize_formatted" (copy), "localize" (copy))
    if _G.localizationdebug == true then return r0 end
    if string.sub(r0, 1, 2) == "f#" and string.len(r0) >= 3 then
        return localize_formatted(string.sub(r0, 3))
    end
    if string.sub(r0, 1, 1) ~= "#" or string.len(r0) < 2 then return r0 end
    return localize(string.sub(r0, 2))
end
local core_checkers = _G.core_checkers
local r29 = {
    draw = tick(),
    firing_ticker = tick(), aim_sound = false, equipped = false, fire_buffer = 0, fire_buffer_type = false,
    state = "normal", interrupt_reload = false, shorted = false, alt_mode = false, alt_cd = tick(),
    construction_mode = false, constructing = "Barricade", construct_ready = false, construct_cd = tick(),
    construct_constructions = {"Barricade"}, slide_locked = false, alt_slide_locked = false, no_steady_acc = false,
    dual_wield_active = false, dropped = false
}
if r20.tooltype == "stims" or r20.tooltype == "firstaid" then
    r29.stimulants = require(game.ReplicatedStorage.shared.stimulants)
    if r20.tooltype == "stims" then
        spawn(function() -- Line: 96 | Upvalues: ("core_checkers" (copy), "r29" (copy))
            for i_0 = 1, 6 do
                core_checkers.create_selectionbox("#stim_" .. r29.stimulants[i_0].int, i_0, r29.stimulants[i_0].icon, nil, i_0)
            end
        end)
    end
end
if r20.tooltype == "whistle" then
    if _G.whistle_at == nil then _G.whistle_at = "advance" end
    core_checkers.create_selectionbox("#whistle_order_advance", "advance", 81453171147177, "1advance", 1)
    core_checkers.create_selectionbox("#whistle_order_defend", "defend", 110211160912800, "2defend", 2)
    core_checkers.create_selectionbox("#whistle_order_focus", "focus", 138309011037793, "3focus", 3)
end
local event = Instance.new("BindableEvent")
event.Name = "event"
event.Parent = Parent_2
local r31 = false
local r32 = tick()
local bipod
if Value_2 == "lewis" or Value_2 == "enfield" and r18 == "enfieldvariant" then
    if Value_2 == "lewis" then r29.no_steady_acc = true end
    bipod = Instance.new("NumberValue")
    bipod.Name = "bipod"
    bipod.Value = 0
    bipod.Parent = Parent_2
end
if Value_2 == "pickaxe" then
    r29.durability_max = 40
    r29.sharpening_stones = 1
    local bipod_2 = Instance.new("IntValue")
    bipod_2.Name = "durability"
    bipod_2.Value = r29.durability_max
    bipod_2.Parent = Parent_2
end
if Value_2 ~= "mosin" and Value_2 ~= "binocs" or r18 ~= "" then
else
    local bipod_2 = Instance.new("BoolValue")
    bipod_2.Name = "scoped"
    bipod_2.Value = true
    bipod_2.Parent = Parent_2
    if Value_2 == "mosin" and core_checkers.mosin_scope == nil and _G.get_settings("disablevolkscope") ~= true then
        core_checkers.mosin_scope = game.ReplicatedStorage.misc.mosinscope:Clone()
    end
end
local shield_supplies
if Value_2 == "vanguardshield" then
    local bipod_2 = Instance.new("BoolValue")
    bipod_2.Name = "guarding"
    bipod_2.Value = false
    bipod_2.Parent = Parent_2
    shield_supplies = Instance.new("IntValue")
    shield_supplies.Name = "shield_supplies"
    shield_supplies.Value = 2
    shield_supplies.Parent = Parent_2
    if Character.perk.Value == "extrainv" then shield_supplies.Value = 3 end
    local max_2 = Instance.new("IntValue")
    max_2.Name = "max"
    max_2.Value = shield_supplies.Value
    max_2.Parent = shield_supplies
end
local bipod = r20.ammo_give
if core_checkers[bipod .. "_reserves"] then
    core_checkers[bipod .. "_max"] = core_checkers[bipod .. "_max"] + r20.capacity * math.floor(math.clamp(r20.ammo_reserves_max * Character.extra_ammo.Value - 1, 1, 10))
    core_checkers[bipod .. "_reserves"] = core_checkers[bipod .. "_reserves"] + r20.capacity * math.floor(math.clamp(r20.ammo_reserves * Character.extra_ammo.Value - 1, 1, 10))
else
    core_checkers[bipod .. "_max"] = r20.capacity * math.floor(r20.ammo_reserves_max * Character.extra_ammo.Value)
    core_checkers[bipod .. "_reserves"] = r20.capacity * math.floor(r20.ammo_reserves * Character.extra_ammo.Value)
end
if r20.ammo_reserves_max == 200 then
    core_checkers[bipod .. "_max"] = 20000
    core_checkers[bipod .. "_reserves"] = 20000
end
if Character.perk.Value == "vet" then
    core_checkers[bipod .. "_reserves"] = core_checkers[bipod .. "_max"]
end
local max
if workspace.serverStuff.values.gamemode.Value == "train" and workspace.serverStuff:FindFirstChild("game_setup") then
    max = workspace.serverStuff.game_setup:FindFirstChild("trains")
end
shield_supplies = {
    ammo_mag = r20.capacity, force_block_fire = false, alt_extra = false, need_bolt = false
}
if workspace.serverStuff.trainingmode.Value == true and Value_2 == "lebel" then
    core_checkers[bipod .. "_reserves"] = 0
    shield_supplies.ammo_mag = 0
end
if Character.perk.Value == "vet" and r20.chamber == true then shield_supplies.ammo_mag += 1 end
if r20.emplacement == true or Value_2 == "browningmg" then
    r29.no_steady_acc = true
    shield_supplies.ammo_mag = math.random(50, 70)
end
local empire_spawnroom = workspace.serverStuff:WaitForChild("empire_spawnroom", 100)
local nation_spawnroom = workspace.serverStuff:WaitForChild("nation_spawnroom", 100)
local empire_spawnprot = empire_spawnroom:FindFirstChild("empire_spawnprot")
if LocalPlayer.Team == game.Teams["Royal Nation"] then
    empire_spawnprot = nation_spawnroom:FindFirstChild("nation_spawnprot")
end
local r39 = {workspace.notarget, workspace.evacs, workspace.throwables, workspace.bodies, Character, Character.Parent, CurrentCamera, empire_spawnprot}
local r40 = {workspace.notarget, workspace.evacs, workspace.throwables, Character, Character.Parent, CurrentCamera, empire_spawnprot}
if _G.get_settings and _G.get_settings("disablebodyshoot") == true then
    table.insert(r40, workspace.bodies)
end
local r41 = {workspace.notarget, workspace.evacs, workspace.bodies, workspace.throwables, Character, CurrentCamera, empire_spawnprot}
local r42 = {workspace.notarget, workspace.evacs, workspace.bodies, workspace.throwables, Character, CurrentCamera, workspace.nation_team, workspace.empire_team, empire_spawnprot}
local r43 = {workspace.notarget, workspace.evacs, workspace.bodies, workspace.throwables, Character, CurrentCamera, workspace.nation_team, workspace.empire_team, empire_spawnprot, workspace.constructions}
local r44
local r45
local r46 = {
    Barricade = "130926719066828",
    Palisade = "131075569490508",
    Sandbags = "129709621621618",
    ["Barbed Wire"] = "92239986631707",
    Cache = "106638603044659",
    ["Tin Bomb"] = "89266402201210",
    ["Gas Shell"] = "81547229510246",
    Mantrap = "134767166459938",
    ["Dynamite Stack"] = "114916851365951",
    ["Shotshell Trap"] = "91573950154593",
    ["Light Lure"] = "81497413008362"
}
local r47
local r48, r49, r51
if r20.tooltype == "hammer" or r20.tooltype == "jaegerkit" then
    r48 = "nation_spawnroom"
    if LocalPlayer.Team == game.Teams["Golden Empire"] then r48 = "empire_spawnroom" end
    r49 = {workspace.notarget, Character, Character.Parent, CurrentCamera, empire_spawnprot, workspace.bodies, workspace.empire_team, workspace.nation_team, workspace.pings}
    if r20.tooltype == "hammer" then table.insert(r42, workspace.constructions) end
    for r53, pistol in ipairs(workspace.serverStuff.objectives:GetChildren()) do
        if pistol:FindFirstChild("capture") then table.insert(r49, pistol.capture) end
    end
    r47 = OverlapParams.new()
    r47.FilterDescendantsInstances = r49
    r47.FilterType = Enum.RaycastFilterType.Exclude
    r47.MaxParts = 10
    local constructionbb = game.ReplicatedStorage.misc.constructionbb:Clone()
    constructionbb.bb.Enabled = false
    constructionbb.Parent = CurrentCamera
    r29.extra_bb = constructionbb
    for pistol, empty_ammo in pairs(base.base_constructs) do
        if pistol ~= "Barricade" then table.insert(r29.construct_constructions, pistol) end
    end
    if r20.tooltype == "jaegerkit" then
        r29.los_tripwire = Instance.new("Part")
        r29.los_tripwire.Anchored = true
        r29.los_tripwire.Color = Color3.new(0.9, 0.9, 0.9)
        r29.los_tripwire.Material = Enum.Material.SmoothPlastic
        r29.los_tripwire.Transparency = 0.5
        r29.los_tripwire.CanCollide = false
        r29.los_tripwire.CanQuery = false
        r29.construction_mode = true
        r29.constructing = "Mantrap"
        r29.construct_constructions = {"Mantrap", "Tin Bomb", "Gas Shell", "Dynamite Stack", "Shotshell Trap", "Light Lure"}
    end
    r51 = r20.tooltype == "jaegerkit" and "trap" or "construct"
    for empty_ammo, left_aiming in ipairs(r29.construct_constructions) do
        if core_game.selectionboxes.selections:FindFirstChild(left_aiming) == nil then
            core_checkers.create_selectionbox("#" .. r51 .. "_" .. left_aiming, left_aiming, r46[left_aiming], nil, empty_ammo)
        end
    end
end
if r20.tooltype == "flamer" then
    local empire_team = workspace.empire_team
    if LocalPlayer.Team == game.Teams["Golden Empire"] then empire_team = workspace.nation_team end
    local r49 = {empire_team}
    r47 = OverlapParams.new()
    r47.FilterDescendantsInstances = r49
    r47.FilterType = Enum.RaycastFilterType.Include
    r47.MaxParts = 20
    r29.flamer_fuel = 650
    r29.flamer_fuel_max = r29.flamer_fuel
end
local r53
if Value_2 == "mpistol" then
    r53 = Value_2
    if r18 ~= "" then r53 = r18 end
    weaponEffects("m_mag_update", {
        main = {
            char = Character,
            originweapon = r53,
            weapon = Value_2,
            model = Value_3,
            module = r20,
            core = shield_supplies
        }
    })
end
local r52
if Value_2 == "walker" then
    r29.no_steady_acc = true
    if _G["walkerstate" .. Parent_2.slot.Value] == nil or _G["walkercylinder" .. Parent_2.slot.Value] == nil then
        _G["walkerstate" .. Parent_2.slot.Value] = {
            {cap = false, ball = false, powder = false}, {cap = false, ball = false, powder = false},
            {cap = false, ball = false, powder = false}, {cap = false, ball = false, powder = false},
            {cap = false, ball = false, powder = false}, {cap = false, ball = false, powder = false}
        }
        _G["walkercylinder" .. Parent_2.slot.Value] = 1
    end
    local r53 = Value_2
    if r18 ~= "" then r53 = r18 end
    r52 = {
        char = Character,
        originweapon = r53,
        weapon = Value_2,
        model = Value_3,
        module = r20,
        core = shield_supplies
    }
    weaponEffects("walker_setallstates", {main = r52, walker_states = _G["walkerstate" .. Parent_2.slot.Value]})
    local r51 = {}
    r53 = Value_2
    if r18 ~= "" then r53 = r18 end
    r52 = {
        char = Character,
        originweapon = r53,
        weapon = Value_2,
        model = Value_3,
        module = r20,
        core = shield_supplies
    }
    r51.main = r52
    r51.cylinder_state = _G["walkercylinder" .. Parent_2.slot.Value]
    weaponEffects("walker_setcylinder", r51)
end
local r49
local pistol, empty_ammo, left_aiming
if r20.tooltype == "gun" then
    local muzzle = Value_3:WaitForChild("special", 100):WaitForChild("muzzle", 100)
    r49 = game.ReplicatedStorage.misc.barrelwarning:Clone()
    r49.Parent = CurrentCamera
    local Attachment = Instance.new("Attachment")
    Attachment.Parent = muzzle
    local Attachment_2 = Instance.new("Attachment")
    Attachment_2.Parent = r49
    r49.warningbeam.Attachment0 = Attachment
    r49.warningbeam.Attachment1 = Attachment_2
    pistol = Instance.new("BoolValue")
    pistol.Name = "pistol"
    pistol.Parent = Parent_2
    if r20.size == 1 then pistol.Value = true end
    empty_ammo = Instance.new("BoolValue")
    empty_ammo.Name = "empty_ammo"
    empty_ammo.Value = false
    empty_ammo.Parent = Parent_2
    left_aiming = Instance.new("BoolValue")
    left_aiming.Name = "left_aiming"
    left_aiming.Value = false
    left_aiming.Parent = Parent_2
    if core_checkers[bipod .. "_reserves"] <= 0 then empty_ammo.Value = true end
end
local keysheld = _G.keysheld
local function updateCharacterTransparency() -- Line: 445 | Name: updateCharacterTransparency | Upvalues: ("r15" (ref), "Value_2" (ref), "core_checkers" (copy), "LocalPlayer" (copy), "r29" (copy), "CurrentCamera" (copy), "Value_3" (copy), "Character" (copy))
    if r15 == true then return end
    local r0 = 0
    if Value_2 == "binocs" and core_checkers.aiming == true and LocalPlayer.CameraMode == Enum.CameraMode.LockFirstPerson then
        r0 = 0.9
    end
    if Value_2 == "vanguardshield" and (core_checkers.aiming == true or r29.alt_mode == true) then
        r0 = 0.75
    end
    if _G.get_settings("disabletransparent") == true then r0 = 0 end
    if core_checkers.mosin_scope ~= nil and core_checkers.mosin_scope.Parent == CurrentCamera then
        r0 = 1
    end
    for r4, r5 in ipairs(Value_3:GetDescendants()) do
        if r5:IsA("BasePart") then r5.LocalTransparencyModifier = r0 end
    end
    if r29.dual_wield_tool and r29.dual_wield_tool:FindFirstChild("model") then
        for r4, r5 in ipairs(r29.dual_wield_tool.model.Value:GetDescendants()) do
            if r5:IsA("BasePart") then r5.LocalTransparencyModifier = 0 end
        end
    end
    if Character and Character:FindFirstChild("Left Arm") and Character:FindFirstChild("Right Arm") then
        local r1_p3 = Character["Left Arm"]:FindFirstChild(Value_2 .. "_round") or Character["Right Arm"]:FindFirstChild(Value_2 .. "_round")
        local r2, bullet2
        if r1_p3 then
            r1_p3.LocalTransparencyModifier = 0
            r2 = r1_p3:FindFirstChild("bullet")
            if r2 then r2.LocalTransparencyModifier = 0 end
            bullet2 = r1_p3:FindFirstChild("bullet2")
            if bullet2 then bullet2.LocalTransparencyModifier = 0 end
            local int = r1_p3:FindFirstChild("int")
            if int then int.LocalTransparencyModifier = 0 end
        end
        if Value_2 == "walker" then
            local walkercapper = Character["Left Arm"]:FindFirstChild("walkercapper")
            if walkercapper and walkercapper:FindFirstChild("cap") then
                walkercapper.LocalTransparencyModifier = 0
                walkercapper.cap.LocalTransparencyModifier = 0
            end
            local walkergunpowder = Character["Left Arm"]:FindFirstChild("walkergunpowder")
            if not walkergunpowder or not walkergunpowder:FindFirstChild("brass") then return end
            walkergunpowder.LocalTransparencyModifier = 0
            walkergunpowder.brass.LocalTransparencyModifier = 0
        end
    end
end
local function r53(r0_p6, r1, r2) -- Line: 531 | Upvalues: ("Value_2" (ref), "r25" (copy), "Humanoid" (copy), "bFunctions" (copy), "Character" (copy), "weaponEffects" (copy), "r18" (ref), "Value_3" (copy), "r20" (ref), "shield_supplies" (ref), "visualEffects" (copy), "r29" (copy), "Parent_2" (copy), "events" (copy), "core_checkers" (copy), "bipod" (copy))
    local r3 = r0_p6
    local __up0_2 = Value_2
    if r1 then __up0_2 = r1 end
    if r0_p6:IsA("ObjectValue") then r3 = r0_p6.Value end
    local Name = r0_p6.Name
    if r2 then Name = r2 end
    r25[Name] = Humanoid:LoadAnimation(r3)
    r25[Name].KeyframeReached:connect(function(r0_arg1) -- Line: 546 | Upvalues: ("Value_2" (upval), "__up0_2" (ref), "bFunctions" (upval), "Character" (upval), "weaponEffects" (upval), "r18" (upval), "Value_3" (upval), "r20" (upval), "shield_supplies" (upval), "visualEffects" (upval), "r29" (upval), "r25" (upval), "Parent_2" (upval), "events" (upval), "core_checkers" (upval), "bipod" (upval))
        if string.sub(r0_arg1, 1, 3) == "sfx" then
            if Value_2 == "mausercarbine" then __up0_2 = "mauser" end
            if Value_2 == "mares" then __up0_2 = "lever" end
            bFunctions:soundHandler({
                directory = {"tools", __up0_2, "sfx"},
                soundfile = string.sub(r0_arg1, 5, 100), pitchvariation = 0.1,
                location = Character.HumanoidRootPart
            })
            return
        end
        if string.sub(r0_arg1, 1, 3) == "vfx" then
            local __up0 = Value_2
            if r18 ~= "" then __up0 = r18 end
            weaponEffects(string.sub(r0_arg1, 5, 100), {
                main = {
                    char = Character,
                    originweapon = __up0,
                    weapon = Value_2,
                    model = Value_3,
                    module = r20,
                    core = shield_supplies
                }
            })
            return
        end
        local r1
        if string.sub(r0_arg1, 1, 4) == "gsfx" then
            r1 = game.ReplicatedStorage.sound_library.tools.shared.gsfx:FindFirstChild(string.sub(r0_arg1, 6, 100)):GetChildren()
            bFunctions:soundHandler({
                pitchvariation = 0.1,
                directory = {"tools", "shared", "gsfx", string.sub(r0_arg1, 6, 100)},
                soundfile = string.sub(r0_arg1, 6, 100) .. math.random(1, #r1),
                location = Character.HumanoidRootPart
            })
            if string.sub(r0_arg1, 6, 100) == "sharpen" then
                visualEffects("sharpening_spark", {part = Character["Left Arm"]})
                return
            end
        elseif r0_arg1 == "lock_start" then
            r29.slide_locked = true
            r1 = r25.locked
            if Parent_2:FindFirstChild("akimbo") and Parent_2.akimbo.Value == false and r29.dual_wield_active == true then
                r1 = r25.akimbo_locked
            end
            if r1 then
                r1:Play(0.1)
                return
            end
        elseif r0_arg1 == "lock_end" then
            r29.slide_locked = false
            r25.locked:Stop(0.05)
            if r25.akimbo_locked then
                r25.akimbo_locked:Stop(0.05)
                return
            end
        else
            if r0_arg1 == "alt_lock_start" then
                r29.alt_slide_locked = true
                r25.locked_alt:Play(0.1)
                return
            end
            if r0_arg1 == "alt_lock_end" then
                r29.alt_slide_locked = false
                r25.locked_alt:Stop(0.05)
                return
            end
            if r0_arg1 ~= "crossbow_update_quiver" or Value_2 ~= "crossbow" then return end
            events.game_handler:Fire("update_quiver", core_checkers[bipod .. "_reserves"])
        end
    end)
    r25[Name].Priority = Enum.AnimationPriority.Action3
end
for r57, r58 in ipairs(game.ReplicatedStorage.animations.tools:FindFirstChild(Value_2):GetChildren()) do
    r53(r58)
end
if Value_2 == "lever" and r18 == "levervariant" then
    r25.aim = r25.alt_changeaim
    r25.aim_left = r25.alt_changeaim_left
    r25.fire = r25.alt_changefire
    r25.fire_empty = r25.alt_changefire_empty
    r25.fire_empty_left = r25.alt_changefire_empty_left
    r25.fire_last = r25.alt_changefire_last
    r25.fire_last_left = r25.alt_changefire_last_left
    r25.fire_left = r25.alt_changefire_left
    r29.no_steady_acc = true
end
if Value_2 == "autosg" and r18 == "autosgvariant" then
    r25.aim = r25.alt_changeaim
    r25.aim_left = r25.alt_changeaim_left
    r25.fire = r25.alt_changefire
    r25.fire_last = r25.alt_changefire_last
    r25.fire_last_left = r25.alt_changefire_last_left
    r25.fire_left = r25.alt_changefire_left
end
if Value_2 == "remington" and r18 == "remingtonvariant" then
    r25.draw = r25.long_draw
    r25.aim = r25.long_aim
    r25.aim_left = r25.long_aim_left
    r25.held = r25.long_held
    r25.fire = r25.long_fire
    r25.fire_left = r25.long_fire_left
    r25.melee1 = r25.long_melee1
    r25.melee2 = r25.long_melee2
    r25.short = r25.long_short
    r25.check = r25.long_check
    r25.sprint = r25.long_sprint
    r25.sprint_greyhound = nil
end
if Value_2 == "dbgun" and r18 == "dbgunvariant" then
    r25.sprint_greyhound = r25.sprint_alt_greyhound
end
if Value_2 == "steyr" and r18 == "steyrvariant" then
    r29.no_steady_acc = true
    r25.draw = r25.steyrdraw
    r25.aim = r25.alt_changeaim
    r25.aim_left = r25.alt_changeaim_left
    r25.fire = r25.alt_changefire
    r25.fire_left = r25.alt_changefire_left
end
if Value_2 == "saa" and r18 == "saavariant" then
    r25.draw = r25.stock_draw
    r25.aim = r25.stock_aim
    r25.aim_left = r25.stock_aim_left
    r25.fire = r25.stock_fire
    r25.fire_left = r25.stock_fire_left
    r25.fire_empty = r25.stock_fire_empty
    r25.fire_empty_left = r25.stock_fire_empty_left
end
local r57, r58
if Value_2 == "springfield" and r18 == "" and _G.get_settings("pedersenstart") == true then
    if r29.pedersen_mag == nil then
        r29.pedersen_mag = 0
        if r29.extra_mag == nil then r29.extra_mag = false end
        r29.initial_mag = true
    end
    if r29.pedersen_mag == 0 then
        if r29.initial_mag == false then r29.extra_mag = false end
        r29.initial_mag = false
        r29.pedersen_mag = 40
    end
    r58 = Value_2
    if r18 ~= "" then r58 = r18 end
    r57 = {
        char = Character,
        originweapon = r58,
        weapon = Value_2,
        model = Value_3,
        module = r20,
        core = shield_supplies
    }
    weaponEffects("springfield_pedersen_on", {main = r57})
    local left_aiming_2 = {}
    r58 = Value_2
    if r18 ~= "" then r58 = r18 end
    r57 = {
        char = Character,
        originweapon = r58,
        weapon = Value_2,
        model = Value_3,
        module = r20,
        core = shield_supplies
    }
    left_aiming_2.main = r57
    weaponEffects("springfield_bolt_off", left_aiming_2)
    left_aiming_2 = {}
    r58 = Value_2
    if r18 ~= "" then r58 = r18 end
    r57 = {
        char = Character,
        originweapon = r58,
        weapon = Value_2,
        model = Value_3,
        module = r20,
        core = shield_supplies
    }
    left_aiming_2.main = r57
    weaponEffects("springfield_pedersen_mag_on", left_aiming_2)
    r29.jam_count = math.random(7, 18)
    r20.fire_rate = 0.333
    r20.recoil = 1
    r29.last_mag = shield_supplies.ammo_mag
    shield_supplies.pedersen_device = true
    shield_supplies.ammo_mag = r29.pedersen_mag
    r29.alt_mode = not r29.alt_mode
end
if Character:FindFirstChild("perk") and Character.perk.Value == "akimbo" and r20.size == 1 and r20.tooltype == "gun" and Character:FindFirstChild("validforakimbo") then
    r25.held_normal = r25.held
    r25.aim_normal = r25.aim
    for r57, r58 in ipairs(game.ReplicatedStorage.animations.tools.akimbo:GetChildren()) do
        r53(r58)
    end
    r25.draw_dual.Priority = Enum.AnimationPriority.Action3
    r25.akimbo_held.Priority = Enum.AnimationPriority.Action
    r25.akimbo_right.Priority = Enum.AnimationPriority.Action3
    r25.akimbo_left.Priority = Enum.AnimationPriority.Action3
    r25.akimbo_right_empty.Priority = Enum.AnimationPriority.Action3
    r25.akimbo_left_empty.Priority = Enum.AnimationPriority.Action3
    local pistol_2 = Instance.new("BoolValue")
    pistol_2.Name = "akimbo"
    pistol_2.Value = false
    pistol_2.Parent = Parent_2
    local empty_ammo_2 = Instance.new("BoolValue")
    empty_ammo_2.Name = "akimbo_aiming"
    empty_ammo_2.Value = false
    empty_ammo_2.Parent = Parent_2
    r25.short = r25.akimbo_short
    local left_aiming_2 = Instance.new("BoolValue")
    left_aiming_2.Name = "mag_empty"
    left_aiming_2.Value = false
    left_aiming_2.Parent = Parent_2
    r29.flipflop = false
    if Value_2 == "pieper" and _G.pieper_alt and _G.pieper_alt == true then _G.pieper_alt = false end
end
r25.draw.Priority = Enum.AnimationPriority.Action2
if r25.unequip then r25.unequip.Priority = Enum.AnimationPriority.Action end
if r25.short then r25.short.Priority = Enum.AnimationPriority.Action3 end
if r25.short_alt then r25.short_alt.Priority = Enum.AnimationPriority.Action3 end
if r25.locked then r25.locked.Priority = Enum.AnimationPriority.Action4 end
if r25.akimbo_locked then r25.akimbo_locked.Priority = Enum.AnimationPriority.Action4 end
if r25.locked_alt then r25.locked_alt.Priority = Enum.AnimationPriority.Action4 end
r25.held.Priority = Enum.AnimationPriority.Action
if r25.sprint then r25.sprint.Priority = Enum.AnimationPriority.Action end
if r25.sprint_greyhound then r25.sprint_greyhound.Priority = Enum.AnimationPriority.Action end
if r25.sprint_alt_greyhound then
    r25.sprint_alt_greyhound.Priority = Enum.AnimationPriority.Action
end
if r25.sprint_dual then r25.sprint_dual.Priority = Enum.AnimationPriority.Action end
if r25.sprint_normal then r25.sprint_normal.Priority = Enum.AnimationPriority.Action end
r25.aim.Priority = Enum.AnimationPriority.Action2
if r25.aim_left then r25.aim_left.Priority = Enum.AnimationPriority.Action2 end
if r25.bipod_aim then r25.bipod_aim.Priority = Enum.AnimationPriority.Action2 end
if r25.alt_changeaim then r25.alt_changeaim.Priority = Enum.AnimationPriority.Action2 end
if r25.alt_changeaim_left then r25.alt_changeaim_left.Priority = Enum.AnimationPriority.Action2 end
if r25.blocked1 then r25.blocked1.Priority = Enum.AnimationPriority.Action2 end
if r25.blocked2 then r25.blocked2.Priority = Enum.AnimationPriority.Action2 end
if r25.fire then r25.fire.Priority = Enum.AnimationPriority.Action end
if r25.akimbo_fire then r25.akimbo_fire.Priority = Enum.AnimationPriority.Action end
if r25.fire_left then r25.fire_left.Priority = Enum.AnimationPriority.Action end
if r25.alt_changefire then r25.alt_changefire.Priority = Enum.AnimationPriority.Action end
if r25.fire_last then r25.fire_last.Priority = Enum.AnimationPriority.Action end
if r25.alt_changefire_last then r25.alt_changefire_last.Priority = Enum.AnimationPriority.Action end
if r25.fire_empty then r25.fire_empty.Priority = Enum.AnimationPriority.Action end
if r25.akimbo_fire_empty then r25.akimbo_fire_empty.Priority = Enum.AnimationPriority.Action end
if r25.fire_empty_left then r25.fire_empty_left.Priority = Enum.AnimationPriority.Action end
if r25.alt_changefire_empty then
    r25.alt_changefire_empty.Priority = Enum.AnimationPriority.Action
end
if r25.alt_changefire_left then r25.alt_changefire_left.Priority = Enum.AnimationPriority.Action end
if r25.alt_changefire_last_left then
    r25.alt_changefire_last_left.Priority = Enum.AnimationPriority.Action
end
if r25.alt_changefire_empty_left then
    r25.alt_changefire_empty_left.Priority = Enum.AnimationPriority.Action
end
if Value_2 == "pieper" then
    if _G.pieper_alt == nil then _G.pieper_alt = false end
    r29.slide_locked = true
    r25.locked:Play(0.1)
elseif Value_2 == "whistle" and _G.whistle_long == nil then
    _G.whistle_long = true
end
if Value_2 == "crossbow" then
    local left_aiming_2 = {transp = 0}
    local r58 = Value_2
    if r18 ~= "" then r58 = r18 end
    left_aiming_2.main = {
        char = Character,
        originweapon = r58,
        weapon = Value_2,
        model = Value_3,
        module = r20,
        core = shield_supplies
    }
    weaponEffects("crossbow_bolt_visibility", left_aiming_2)
    r29.slide_locked = true
    r25.locked:Play(0.01)
    if (not Character:FindFirstChild("crossbow2") or Parent_2.slot.Value ~= 1) and (Character:FindFirstChild("crossbow1") and Parent_2.slot.Value == 2) then
        r25.locked:Stop(0.01)
    end
end
local pistol
r26.interaction_handler = events.interaction_handler:Connect(function(r0_p7, r1) -- Line: 898 | Upvalues: ("core_checkers" (copy), "bipod" (copy), "r20" (ref), "shield_supplies" (ref), "Parent_2" (copy), "r29" (copy), "Value_2" (ref), "r25" (copy), "r18" (ref), "Value_3" (copy), "CurrentCamera" (copy), "Character" (copy), "action" (copy), "visualEffects" (copy))
    if r0_p7 == "ammo_restock" then
        core_checkers[bipod .. "_reserves"] = core_checkers[bipod .. "_max"] + math.clamp(r20.capacity - shield_supplies.ammo_mag, 0, r20.capacity)
        if r20.require_full_load and r20.require_full_load == true and shield_supplies.ammo_mag < r20.capacity then
            core_checkers[bipod .. "_reserves"] = core_checkers[bipod .. "_max"] + r20.capacity
        end
        if Parent_2:FindFirstChild("durability") and r29.durability_max and r1 == "restock_player_full" then
            r29.sharpening_stones = 1
        end
        if r1 == "cache_restock" or r1 == "restock_player_full" then
            if Parent_2:FindFirstChild("shield_supplies") and Parent_2.shield_supplies:FindFirstChild("max") then
                Parent_2.shield_supplies.Value = Parent_2.shield_supplies.max.Value
            end
            if Parent_2:FindFirstChild("client_inactive") then
                if Value_2 == "remington" then
                    shield_supplies.ammo_mag = 1
                    r29.slide_locked = false
                    r25.locked:Stop(0.05)
                end
                Parent_2.client_inactive:Destroy()
            end
            if Parent_2:FindFirstChild("use_count") and Parent_2.use_count:FindFirstChild("max") then
                Parent_2.use_count.Value = Parent_2.use_count.max.Value
            end
            if r1 == "restock_player_full" then
                if Value_2 == "mauser" and r18 == "mauservariant" then shield_supplies.ammo_mag = r20.capacity end
                if Parent_2:FindFirstChild("gl_uses") and Parent_2.gl_uses:FindFirstChild("max") then
                    Parent_2.gl_uses.Value = Parent_2.gl_uses.max.Value
                end
                if Value_2 == "springfield" then r29.extra_mag = true end
                if Value_2 == "bottle" and not Value_3:FindFirstChild("glassbottle") and Value_3:FindFirstChild("amount") and Value_3:FindFirstChild("body") and Value_3.body:FindFirstChild("liquid") then
                    Value_3.amount.Value = 15
                    Value_3.body.liquid.Transparency = 0
                end
            end
        end
        if Parent_2:FindFirstChild("empty_ammo") then
            Parent_2.empty_ammo.Value = false
            return
        end
    elseif r0_p7 == "stopaction" then
        core_checkers.charging = false
        if CurrentCamera:FindFirstChild("charge_heartbeat") then
            CurrentCamera.charge_heartbeat:Destroy()
            return
        end
    else
        if r0_p7 == "playtoolanimation" then
            if not r1 or not r1.animation or not r25[r1.animation] then return end
            if r1.tool and (not core_checkers.equipped or Value_2 ~= r1.tool) then return end
            if r1.delay then task.wait(r1.delay) end
            r25[r1.animation]:Play(r1.fadein or 0.1, r1.weight or 1, r1.speed or 1)
            return
        end
        if r0_p7 == "stoptoolanimation" then
            if not r1 or not r1.animation or not r25[r1.animation] then return end
            if r1.tool and (not core_checkers.equipped or Value_2 ~= r1.tool) then return end
            if r1.delay then task.wait(r1.delay) end
            r25[r1.animation]:Stop(r1.fadeout or 0.1)
            return
        end
        if r0_p7 == "shieldparry" and Value_2 == "vanguardshield" then
            if Character == nil or Character:FindFirstChild("Torso") == nil then return end
            if action.Value == false then r25["blocked" .. math.random(1, 2)]:Play(0.1, 1, 2) end
            visualEffects("mine_impact", {point = Character.HumanoidRootPart.Position + Character.HumanoidRootPart.CFrame.lookVector})
            return
        end
        if r0_p7 == "retrieve_vanguardshield" then
            if Parent_2:FindFirstChild("client_inactive") and Value_2 == "vanguardshield" then
                Parent_2.client_inactive:Destroy()
                return
            end
        elseif r0_p7 == "drop_weapon" then
            if r1 ~= Parent_2 then return end
            Parent_2.event:Fire("drop_weapon", true)
        end
    end
end)
local function left_aiming(r0) -- Line: 1040 | Upvalues: ("Humanoid" (copy), "core_checkers" (copy), "r29" (copy), "events" (copy), "Character" (copy), "r20" (ref), "action" (copy), "shield_supplies" (ref), "r25" (copy), "visualEffects" (copy), "LocalPlayer" (copy), "bFunctions" (copy), "r15" (ref), "keysheld" (copy), "RenderStepped" (copy), "weaponEffects" (copy), "Value_2" (ref), "r18" (ref), "Value_3" (copy))
    if Humanoid:FindFirstChild("burning_light") or Humanoid:FindFirstChild("burning_heavy") then
        return
    end
    local heal_target
    if core_checkers.aiming == true and r29.heal_target and r29.heal_target:FindFirstChild("Humanoid") and r29.heal_target:FindFirstChild("Torso") and r0 ~= true then
        if r29.heal_target.Humanoid.Health >= 100 then
            if tick() - r29.firing_ticker > 0.2 then
                r29.firing_ticker = tick()
                _G.popupmsg("targetwarn_surgery", "#firstaid_deny", 1)
            end
            return
        end
        events.medical_handler:Fire("sendhealmessage", r29.heal_target)
        if (r29.heal_target.Torso.Position - Character.Torso.Position).magnitude > 6 then
            if tick() - r29.firing_ticker > 0.2 then
                r29.firing_ticker = tick()
                _G.popupmsg("target_warnrange", "#firstaid_deny_far", 1)
            end
            return
        end
        if r29.heal_target.Humanoid:FindFirstChild("burning_light") or r29.heal_target.Humanoid:FindFirstChild("burning_heavy") then
            if tick() - r29.firing_ticker > 0.2 then
                r29.firing_ticker = tick()
                _G.popupmsg("target_warnburn", "#firstaid_deny_burning", 1)
            end
            return
        end
        if r29.heal_target:FindFirstChild("dreadnought") then
            if tick() - r29.firing_ticker > 0.2 then
                r29.firing_ticker = tick()
                _G.popupmsg("target_warndread", "#firstaid_deny_dread", 1)
            end
            return
        end
        heal_target = r29.heal_target
    end
    local r3 = tick() - r29.draw
    if r3 < r20.draw_speed / core_checkers.draw_modifier and heal_target == nil then return end
    if (Character:FindFirstChild("class") and Character.class.Value == "conscript") and (heal_target == nil or r0 == true) then
        return
    end
    if Humanoid.Health >= 100 and heal_target == nil and r0 ~= true then
        r3 = tick() - r29.firing_ticker
        if r3 > 0.2 then
            r29.firing_ticker = tick()
            _G.popupmsg("heal_warn", "#firstaid_deny_self", 2)
        end
        return
    end
    action.Value = true
    core_checkers.sprint_block = true
    if heal_target == nil then core_checkers.healing_anim_self = true end
    r3 = 0.6
    local r4 = 5
    local Children = Character.wounds:GetChildren()
    shield_supplies.surgery_extra = nil
    local Torso = Character.Torso
    local r7 = "_tweezer"
    if #Children > 0 then Torso = Children[math.random(1, #Children)] end
    if Torso:IsA("StringValue") then r7 = Torso.Value end
    if Torso:FindFirstChild("extra") then shield_supplies.surgery_extra = Torso.extra.Value end
    local r8 = Torso.Name .. r7
    if Character:FindFirstChild("medical_expertise") then
        if heal_target then r3 = 1.1 end
        r4 = 0
    end
    if Character.perk.Value == "hippocratic" and heal_target then
        if r3 < 1 then r3 = 1 end
        r3 *= 1.1
    end
    if Character:FindFirstChild("buff_defend") or Character:FindFirstChild("buff_elite") then
        r3 *= 1.25
    end
    if Character:FindFirstChild("flagbuff") then r3 *= 1.2 end
    if Character:FindFirstChild("vanguardbuff") then r3 *= 1.2 end
    local r9 = false
    if Character.perk.Value == "healing" and heal_target == nil then
        r9 = true
        r3 *= 1.1
        if r0 == true then r9 = false end
    end
    if Torso.Name ~= "Left Leg" and Torso.Name ~= "Right Leg" or heal_target ~= nil then
    elseif r0 ~= true then
        r4 = 100
    end
    local r10_p8 = true
    if r25[r8] == nil then r8 = "Torso_tweezer" end
    if heal_target then
        r4 = 0
        r8 = "tweezer_others"
        if heal_target:FindFirstChild("wounds") then
            local Children_2 = heal_target.wounds:GetChildren()
            local knock
            if #Children_2 > 0 then knock = Children_2[math.random(1, #Children_2)] end
            if knock ~= nil and knock:IsA("StringValue") then
                if knock.Value == "_suture" then r8 = "suture_others" end
                if knock:FindFirstChild("extra") then shield_supplies.surgery_extra = knock.extra.Value end
            end
        end
        r3 *= 1.1
    end
    local r11_p8 = false
    local knock = Character:FindFirstChild("helmet") and Character.helmet:FindFirstChild("knock") or Character:FindFirstChild("extralift")
    if heal_target == nil and r9 == false then
        r11_p8 = true
        visualEffects("helmet_adjusting", {char = Character, val = "helmetoff"})
        knock = "helmet_remove"
        if Character:FindFirstChild("class") and Character.class.Value == "lancer" and LocalPlayer.Team == game.Teams["Golden Empire"] then
            knock = "helmet_remove_lancer"
        end
        r25[knock]:Play(0.05, 1, 1.5)
        events.game_handler:Fire("helmet_lift", true)
        bFunctions:s_wait(0.33)
    end
    knock = nil
    local r13_p8 = tick()
    local r14_p8, r15_p8
    if heal_target == nil and r9 == false and r0 ~= true then
        r14_p8 = {"afterheal_water"}
        knock = r14_p8[math.random(1, #r14_p8)]
        r25[knock]:Play(0.3, 1, r3)
        repeat
            if Humanoid.Health >= 100 or r15 == true then
                r10_p8 = false
                break
            end
            r15_p8 = tick() - core_checkers.fall_damage_interrupt
            if r15_p8 <= 0 then
                r10_p8 = false
                break
            end
            r15_p8 = tick() - r13_p8
            if r15_p8 >= 0.1 and tick() - r13_p8 < 2.5 / r3 - 1 and keysheld.m1 == nil then
                r10_p8 = false
                break
            end
            RenderStepped:Wait()
            r15_p8 = tick() - r13_p8
        until 2.5 / r3 <= r15_p8
    end
    if r10_p8 == true then
        local r14_p8 = false
        core_checkers.int_speed -= r4
        if r0 == true then r8 = "afterheal_item" end
        r25[r8]:Play(0.1, 1, r3)
        r13_p8 = tick()
        repeat
            if r4 == 100 then
                core_checkers.crouching_cd = tick()
                core_checkers.crouching = false
            end
            local r15_p8
            if heal_target then
                if heal_target == nil then
                    r10_p8 = false
                    break
                end
                if heal_target:FindFirstChild("Humanoid") == nil or heal_target:FindFirstChild("Torso") == nil or heal_target.Humanoid.Health >= 100 or heal_target.Humanoid.Health <= 0 then
                    r10_p8 = false
                    break
                end
                if (heal_target.Torso.Position - Character.Torso.Position).magnitude > 6 then
                    r10_p8 = false
                    break
                end
                r15_p8 = tick() - r13_p8
                if 1.3 / r3 <= r15_p8 then
                    r10_p8 = true
                    break
                end
            else
                if Humanoid.Health >= 100 and r0 ~= true and r14_p8 ~= true or r15 == true then
                    r10_p8 = false
                    break
                end
                r15_p8 = r25[r8]
                if r15_p8 and r15_p8:GetTimeOfKeyframe("healing_done") then
                    r15_p8 = r15_p8:GetTimeOfKeyframe("healing_done") / r3
                end
                if r15_p8 == nil then r15_p8 = 2 / r3 end
                if r15_p8 <= tick() - r13_p8 and r10_p8 == true then
                    r14_p8 = true
                    if Torso ~= Character.Torso then Torso:Destroy() end
                    if r0 == true then
                        events.medical_handler:Fire("remove_sickness")
                    else
                        if Torso ~= Character.Torso then Torso:Destroy() end
                        events.medical_handler:Fire("healself")
                    end
                    r10_p8 = false
                end
            end
            r15_p8 = tick() - core_checkers.fall_damage_interrupt
            if r15_p8 <= 0 then
                r10_p8 = false
                break
            end
            r15_p8 = tick() - r13_p8
            if r15_p8 >= 0.1 and tick() - r13_p8 < 2.5 / r3 - 1 and keysheld.m1 == nil and keysheld[_G.get_keybinds("alt")] == nil and r14_p8 == false then
                r10_p8 = false
                break
            end
            RenderStepped:Wait()
            r15_p8 = tick() - r13_p8
        until 2.5 / r3 <= r15_p8
        core_checkers.int_speed += r4
    end
    local r14_p8 = true
    if r10_p8 == true then
        if heal_target then
            r14_p8 = false
            events.medical_handler:Fire("healtarget", heal_target)
        elseif r0 == true then
            events.medical_handler:Fire("remove_sickness")
        else
            if Torso ~= Character.Torso then Torso:Destroy() end
            events.medical_handler:Fire("healself")
        end
    end
    events.game_handler:Fire("helmet_lift", false)
    if r11_p8 == true then
        visualEffects("helmet_adjusting", {char = Character, val = "helmet"})
        local r15_p8 = "helmet_place"
        if Character:FindFirstChild("class") and Character.class.Value == "lancer" and LocalPlayer.Team == game.Teams["Golden Empire"] then
            r15_p8 = "helmet_place_lancer"
        end
        r25[r15_p8]:Play(0.05, 1, 1.5)
        bFunctions:s_wait(0.33)
    end
    local __up16 = Value_2
    if r18 ~= "" then __up16 = r18 end
    weaponEffects("firstaid_reset", {
        main = {
            char = Character,
            originweapon = __up16,
            weapon = Value_2,
            model = Value_3,
            module = r20,
            core = shield_supplies
        }
    })
    if knock then r25[knock]:Stop(0.05) end
    if r14_p8 == true then r25[r8]:Stop(0.05) end
    core_checkers.healing_anim_self = false
    core_checkers.sprint_block = false
    action.Value = false
end
local function r57() -- Line: 1417 | Upvalues: ("Character" (copy), "r29" (copy), "Value_2" (ref), "action" (copy), "core_checkers" (copy), "r20" (ref), "r25" (copy), "bFunctions" (copy), "CurrentCamera" (copy), "events" (copy), "Humanoid" (copy), "r39" (copy), "r42" (copy), "Parent_2" (copy), "RenderStepped" (copy))
    if workspace.serverStuff.values.gamemode.Value == "truce" and Character:FindFirstChild("engage") == nil then
        return
    end
    if r29.bayo_cd == nil then r29.bayo_cd = 0 end
    local r0_p10 = 3
    local r1 = 3
    local r2 = false
    if Character:FindFirstChild("class") and Character:FindFirstChild("perk") and Character.class.Value == "lancer" then
        if Character.perk.Value == "butcher" then
            r0_p10 = 5
            r1 = 2
        end
        if Character.perk.Value == "vet" then
            r0_p10 = 5
            r2 = true
        end
    end
    if Value_2 == "trench" and Character:FindFirstChild("class") and Character.class.Value == "lancer" then
        r0_p10 = 5
        r1 = 2
        r2 = true
    end
    if tick() - r29.bayo_cd <= r1 then return end
    if action.Value == true or core_checkers.sprint_block == true then return end
    if tick() - r29.draw < r20.draw_speed / core_checkers.draw_modifier then return end
    local r3_p10 = tick() - core_checkers.fall_damage_interrupt
    if r3_p10 <= 0 then return end
    if core_checkers.sprinting == true and core_checkers.sprinting_max_speed == true then
        action.Value = true
        r25.charge:Stop(0.5)
        r25.charge:Play(0.5, 1, 1.5)
        core_checkers.charging_direction = Character.HumanoidRootPart.CFrame.lookVector
        core_checkers.charging = true
        r3_p10 = tick()
        bFunctions:soundHandler({directory = {"misc"}, soundfile = "chargestart", location = CurrentCamera}, true)
        delay(0.1, function() -- Line: 1479 | Upvalues: ("events" (upval))
            events.game_handler:Fire("languageline", "charge")
        end)
        local charge_heartbeat = game.ReplicatedStorage.sound_library.misc.charge_heartbeat:Clone()
        charge_heartbeat.Parent = CurrentCamera
        charge_heartbeat:Play()
        game:GetService("Debris"):AddItem(charge_heartbeat, 10)
        local r5_p10 = {}
        local r6 = 0
        local r7 = false
        repeat
            if not (Humanoid == nil or Humanoid.Health <= 0) then
                local r8 = tick() - r3_p10
                if r8 >= 0.2 then
                    local r8, r9, r10_p10, r11_p10 = bFunctions:raycastline({
                        point = Character.Head.Position,
                        destination = Character.Head.CFrame.LookVector, range = 4,
                        layermask = r39
                    })
                    local r12, r13
                    if r8 == nil then
                        r12 = Character.Head.Position + Character.Head.CFrame.LookVector * 4
                        r13 = workspace.empire_team
                        if Character.Parent == r13 then r13 = workspace.nation_team end
                        for r17_p10, r18 in ipairs(r13:GetChildren()) do
                            if not (not r18:FindFirstChild("HumanoidRootPart") or not r18:FindFirstChild("Torso") or not r18:FindFirstChild("Humanoid") or r18.Humanoid.Health <= 0) then
                                if not ((r18.HumanoidRootPart.Position - r12).Magnitude > 3.5 or (not bFunctions:raycastline({
                                    point = Character.Head.Position,
                                    destination = CFrame.new(Character.Head.Position, r18.Torso.Position).LookVector,
                                    range = 10, layermask = r42
                                }) or false) ~= true) then
                                    r8 = r18.Torso
                                end
                            end
                        end
                    end
                    repeat
                        if not r8 or not r8.Parent or r5_p10[r8.Parent.Name] ~= nil then break end
                        if r8.Parent and r8.Parent:FindFirstChild("Humanoid") and r8.Parent:FindFirstChild("HumanoidRootPart") and r8.Parent.Humanoid.Health > 0 and r8.Parent:FindFirstChild("Torso") then
                            if r8.Name == "HeadHitbox" or r8.Name == "Head" then r8 = r8.Parent.Torso end
                            r5_p10[r8.Parent.Name] = true
                            r6 += 1
                            if r6 >= 3 then r2 = false end
                            local r12 = "bayonet"
                            if r2 == true then r12 = "skewer" end
                            if tick() - r3_p10 < 0.5 and r8 and r8.Parent and r8.Parent:FindFirstChild("Bulwark's Shield") == nil then
                                r12 = "melee"
                                r2 = false
                            end
                            events.damage_handler:Fire(r8, Parent_2, r12, r20)
                            if r2 ~= false then break end
                            continue
                        end
                        r7 = true
                        continue
                    until true
                    if Character.HumanoidRootPart.Velocity.Magnitude <= 5 and tick() - r3_p10 >= 1 or tick() - core_checkers.fall_damage_interrupt <= 0 then
                        break
                    end
                    r8 = tick() - core_checkers.in_air_timer
                    if r8 > 0.5 then break end
                    RenderStepped:Wait()
                    if r0_p10 > tick() - r3_p10 and core_checkers.charging ~= false then continue end
                    break
                end
            end
        until core_checkers.charging == false
        if r7 == true then
            events.game_handler:Fire("hurtline", Character.gender.Value .. "_hurt" .. math.random(1, 10))
            _G.knockdownproc(true)
        end
        charge_heartbeat:Destroy()
        bFunctions:soundHandler({directory = {"misc"}, soundfile = "chargeend", location = CurrentCamera}, true)
        r25.charge:Stop(0.5)
        r25.charge_stop:Play(0.2, 1, 1.5)
        local r8 = 1.5
        if Value_2 == "lance" or Value_2 == "trench" then r8 = 1 end
        if r7 == true then r8 = 2 end
        core_checkers.fall_damage_interrupt = tick() + r8
        r29.bayo_cd = tick()
        action.Value = false
        core_checkers.charging = false
        return
    end
end
local r58 = 1
local r59 = 0
local r60 = 0
local r61 = 0
local r62 = 0
local r63_0 = false
local function r64_0(r0_p12) -- Line: 1645 | Upvalues: ("Character" (copy), "Parent_2" (copy), "Value_2" (ref), "r29" (copy), "r63_0" (ref), "action" (copy), "core_checkers" (copy), "Value_3" (copy), "shield_supplies" (ref), "r25" (copy), "r18" (ref), "r58" (ref), "r20" (ref), "bFunctions" (copy), "CurrentCamera" (copy), "r39" (copy), "visualEffects" (copy), "events" (copy), "r42" (copy), "r59" (ref), "r60" (ref), "base" (copy), "r61" (ref), "r62" (ref), "RenderStepped" (copy), "keysheld" (copy))
    if workspace.serverStuff.values.gamemode.Value == "truce" and Character:FindFirstChild("engage") == nil then
        return
    end
    if Parent_2:FindFirstChild("client_inactive") then return end
    if Character:FindFirstChild("oathbroken") and Value_2 ~= "pick" and Value_2 ~= "pickaxe" and Value_2 ~= "hammer" then
        _G.popupmsg("brokenoath", "#message_brokenoath", 1)
        return
    end
    if Value_2 == "lewis" then return end
    if r29.equipped == false and r0_p12 ~= true then return end
    if Parent_2:FindFirstChild("mounted_weapon") or Value_2 == "browningmg" or r63_0 == true then
        return
    end
    r63_0 = true
    action.Value = true
    local r1 = "melee"
    local r2 = "swing"
    if Value_2 == "lance" and core_checkers.aiming == true then
        r1 = "stab"
        r2 = "stab"
    end
    if Value_2 == "cavsword" and r0_p12 == true then r1 = "melee_alt" end
    if Value_2 == "lebel" and Value_3:FindFirstChild("bayonet") then
        r1 = "altmelee"
        r2 = "stab"
    end
    if Value_2 == "crossbow" and shield_supplies.ammo_mag > 0 then
        r1 = "altmelee"
        r2 = "stab"
    end
    if Value_2 == "bottle" and Value_3:FindFirstChild("glassbottle") and Value_3:FindFirstChild("body") and Value_3.body:FindFirstChild("blade") then
        r1 = "altmelee"
    end
    r25[r1 .. "1"]:Stop(0)
    r25[r1 .. "2"]:Stop(0)
    if r25.mine then r25.mine:Stop(0) end
    if r18 == "dbgunvariant" and r58 == 1 then r1 = "meleealt" end
    if r18 == "henryvariant" then r1 = "meleealt" end
    r25[r1 .. r58]:Play(0.1, 1, 1)
    r58 = r58 == 1 and 2 or 1
    core_checkers.jump_tick = tick()
    local r3_p12 = 0
    local r4
    local melee_swing_speed = r20.melee_swing_speed
    if Character.perk.Value == "tunnelrat" and (Value_2 == "pickaxe" or Value_2 == "pick") then
        r3_p12 = -0.5
        r4 = 10
    end
    if Value_2 ~= "pickaxe" and Value_2 ~= "pick" or workspace.serverStuff.restorationmode.Value ~= true then
    else
        melee_swing_speed *= 1.25
    end
    if Character.perk.Value == "tunnelrat" and (Value_2 == "pickaxe" or Value_2 == "pick") then
        melee_swing_speed *= 0.75
    end
    if Character.perk.Value == "quickdraw" and Value_2 == "lance" then melee_swing_speed *= 0.85 end
    if Value_2 == "saa" and Character:FindFirstChild("elitekit") and Character.elitekit.Value == "ocelot" then
        melee_swing_speed *= 0.4
    end
    if Character.chems:FindFirstChild("mep") and core_checkers.sick == false then
        melee_swing_speed *= 0.75
    end
    bFunctions:soundHandler({
        directory = {"melee_sounds", r20.melee_sound}, soundfile = "ready",
        location = Character.HumanoidRootPart,
        volume_adjust = r3_p12,
        force_max_dist = r4
    })
    if Value_2 == "lance" then
        bFunctions:soundHandler({
            directory = {"tools", "shared", "gsfx", "flag"},
            soundfile = "flag" .. math.random(1, 4),
            location = Character.HumanoidRootPart,
            force_max_dist = r4
        })
    end
    local r6 = 0.2
    if (r20.tooltype ~= "melee" and (Value_2 ~= "henry" or r18 == "henryvariant")) and Value_2 == "trench" then
        r6 = 0.1
    end
    if core_checkers.aiming == true then core_checkers.aim_time = tick() end
    bFunctions:s_wait(r6)
    if r29.equipped == false and r0_p12 ~= true then
        r63_0 = false
        return
    end
    local r7 = true
    local r9 = CurrentCamera.CFrame.Position + CurrentCamera.CFrame.LookVector * ((CurrentCamera.CFrame.Position - Character.HumanoidRootPart.Position).Magnitude - 2)
    if Value_2 == "pick" or Value_2 == "pickaxe" then
        r9 = (Character.Head.CFrame - CurrentCamera.CFrame.LookVector * 0.5).Position
    end
    local r10_p12 = true
    local melee_range = r20.melee_range
    local r12
    if Value_2 == "lance" or Value_2 == "trench" then r10_p12 = false end
    if r1 == "stab" then
        r10_p12 = nil
        melee_range += 3
        r12 = "lancestab"
    end
    local r13_p12, r14, r15, r16_0 = bFunctions:raycastline({
        point = r9,
        destination = CurrentCamera.CFrame.LookVector,
        range = melee_range + 1,
        layermask = r39
    })
    local r17_p12 = {}
    local r18_p12 = false
    if (r13_p12 and r13_p12.Material == Enum.Material.Glass) and (r13_p12.Name == "WindowBreakable" or r13_p12.Name == "GlassWindow") then
        visualEffects("wood_impact", {
            point = r14,
            part_hit = r13_p12,
            partcol = r13_p12.Color, pellets = 1, glass = true
        })
        if r13_p12.Name == "WindowBreakable" then
            visualEffects("bullet_hole", {
                pos = r14,
                normal = r15, glass = true,
                forceparent = r13_p12
            }, true)
            events.game_handler:Fire("window_impact", r13_p12, 2)
        end
    end
    if r13_p12 and (r13_p12.Parent:FindFirstChild("Humanoid") or r13_p12.Parent.Parent:FindFirstChild("health")) then
        table.insert(r17_p12, r13_p12)
    end
    if (r13_p12 and (r13_p12.Name == "leftshield" or r13_p12.Name == "rightshield" or r13_p12.Name == "mainshield" or r13_p12.Name == "topshield")) and (r13_p12.Parent and r13_p12.Parent.Parent and r13_p12.Parent.Parent.Parent and r13_p12.Parent.Parent.Parent:FindFirstChild("Torso")) then
        table.insert(r17_p12, r13_p12.Parent.Parent.Parent.Torso)
    end
    local r20_p12, r27
    if r10_p12 ~= nil and (r13_p12 == nil or r13_p12.Parent:FindFirstChild("Humanoid") == nil or r10_p12 == false) then
        local empire_team = workspace.empire_team
        if Character.Parent == empire_team then empire_team = workspace.nation_team end
        r20_p12 = r20.melee_range
        local r21 = r9 + CurrentCamera.CFrame.LookVector * (r20_p12 / 2)
        r20_p12 /= 1.5
        for r25_p12, r26 in ipairs(empire_team:GetChildren()) do
            if not (not r26:FindFirstChild("HumanoidRootPart") or not r26:FindFirstChild("Torso") or not r26:FindFirstChild("Humanoid") or r26.Humanoid.Health <= 0) then
                r27 = true
                if r13_p12 and r13_p12.Parent == r26 then r27 = false end
                if not ((r26.HumanoidRootPart.Position - r21).Magnitude > r20_p12 or r27 ~= true) then
                    table.insert(r17_p12, r26:FindFirstChild("Torso"))
                end
            end
        end
    end
    local function stop_swing() -- Line: 1885 | Name: stop_swing | Upvalues: ("r25" (upval), "r1" (ref), "r7" (ref))
        if r25[r1 .. "1"] then r25[r1 .. "1"]:Stop(0.3) end
        if r25[r1 .. "2"] then r25[r1 .. "2"]:Stop(0.3) end
        r7 = false
    end
    local r26
    if #r17_p12 > 0 then
        local r20_p12 = {}
        for r24_p12, r25_p12 in ipairs(r17_p12) do
            if r25_p12.Parent:FindFirstChild("Humanoid") and r25_p12.Parent.Humanoid.Health > 0 and r20_p12[r25_p12.Parent.Name] == nil then
                if Character:FindFirstChild("oathbroken") then
                    if r25[r1 .. "1"] then r25[r1 .. "1"]:Stop(0.3) end
                    if r25[r1 .. "2"] then r25[r1 .. "2"]:Stop(0.3) end
                    r7 = false
                    melee_swing_speed *= 1.25
                    _G.popupmsg("brokenoath", "#message_brokenoath", 1)
                    break
                end
                if workspace.serverStuff.trainingmode.Value == true and r25_p12.Parent:FindFirstChild("rank") and r25_p12.Parent:FindFirstChild("enemy") == nil then
                    if r25[r1 .. "1"] then r25[r1 .. "1"]:Stop(0.3) end
                    if r25[r1 .. "2"] then r25[r1 .. "2"]:Stop(0.3) end
                    r7 = false
                    melee_swing_speed *= 1.25
                    break
                end
                r26 = true
                local r27 = true
                if Value_2 == "pickaxe" or Value_2 == "lance" and r1 == "stab" then r26 = false end
                if r25_p12.Name == "HeadHitbox" and r26 == true then r25_p12 = r25_p12.Parent.Torso end
                if r25_p12.Name == "Left Leg" or r25_p12.Name == "Right Leg" then r25_p12 = r25_p12.Parent.Torso end
                if bFunctions:raycastline({
                    point = Character.Head.Position,
                    destination = CFrame.new(Character.Head.Position, r25_p12.Parent.Torso.Position).LookVector,
                    range = (Character.Head.Position - r25_p12.Parent.Torso.Position).magnitude,
                    layermask = r42
                }) then
                    r27 = false
                end
                if r27 ~= true then continue end
                r20_p12[r25_p12.Parent.Name] = true
                r18_p12 = true
                events.damage_handler:Fire(r25_p12, Parent_2, "melee", r20, r12)
                if r10_p12 == true then break end
            elseif not r25_p12.Parent or not r25_p12.Parent.Parent or not r25_p12.Parent.Parent:FindFirstChild("health") or r25_p12.Parent.Parent.health.Value <= 0 then
            else
                if Character:FindFirstChild("oathbroken") and (r25_p12.Parent.Parent.Name == "Dynamite Stack" or r25_p12.Parent.Parent.Name == "Gas Shell" or r25_p12.Parent.Parent.Name == "Light Lure") then
                    if r25[r1 .. "1"] then r25[r1 .. "1"]:Stop(0.3) end
                    if r25[r1 .. "2"] then r25[r1 .. "2"]:Stop(0.3) end
                    r7 = false
                    melee_swing_speed *= 1.25
                    _G.popupmsg("brokenoath", "#message_brokenoath", 1)
                    break
                end
                events.construction_handler:Fire("damage", r25_p12.Parent.Parent, Parent_2, "melee")
            end
        end
    end
    local r22_p12
    if r7 then
        r22_p12 = {directory = {"melee_sounds", r20.melee_sound}, pitchvariation = 0.1}
        r22_p12.soundfile = r2 .. math.random(1, 2)
        r22_p12.location = Character.HumanoidRootPart
        r22_p12.volume_adjust = r3_p12
        r22_p12.force_max_dist = r4
        bFunctions:soundHandler(r22_p12)
    end
    local r20_p12 = false
    local r21 = r16_0 == Enum.Material.Rock or r16_0 == Enum.Material.Mud
    if workspace.serverStuff.values:FindFirstChild("miningrestrictions") then
        local r22_p12 = true
        if r16_0 ~= Enum.Material.Grass then
            r22_p12 = true
            if r16_0 ~= Enum.Material.LeafyGrass then r22_p12 = r16_0 == Enum.Material.Ground end
        end
        r21 = r22_p12
    end
    if r13_p12 and r21 then r20_p12 = true end
    if r13_p12 == workspace.Terrain and r16_0 == Enum.Material.Basalt then
        if Value_2 ~= "pick" and Value_2 ~= "pickaxe" or workspace.serverStuff.trainingmode.Value ~= false then
        else
            local r22_p12 = tick() - r59
            if r22_p12 >= 2 then r60 = 0 end
            r59 = tick()
            r60 += 1
            if r60 >= 2 then
                r60 = 0
                r22_p12 = "#message_hitbasalt"
                if Character and Character:FindFirstChild("perk") and Character.perk.Value == "tunnelrat" then
                    r22_p12 = "#message_hitbasalt_rat"
                end
                _G.popupmsg("basaltmine", r22_p12, 2)
            end
        end
    end
    if r13_p12 and r20_p12 == true and r20.tooltype == "pick" and workspace.serverStuff.modifier.Value == "heavyrocks" then
        melee_swing_speed *= 1.1
        local r22_p12
        if Character:FindFirstChild("perk") and Character.perk.Value == "tunnelrat" then r22_p12 = true end
        visualEffects("hardrock_hit", {pos = r14, quiet = r22_p12})
    end
    if r20_p12 and r14.Y <= base.mining_floor and workspace.serverStuff.trainingmode.Value == false then
        r20_p12 = false
        if Value_2 == "pick" or Value_2 == "pickaxe" then
            local r22_p12 = tick() - r61
            if r22_p12 >= 2 then r62 = 0 end
            r61 = tick()
            r62 += 1
            if r62 >= 2 then
                r62 = 0
                r22_p12 = "#message_hitfloor"
                if Character and Character:FindFirstChild("perk") and Character.perk.Value == "tunnelrat" then
                    r22_p12 = "#message_hitfloor_rat"
                end
                _G.popupmsg("floormine", r22_p12, 2)
            end
        end
    end
    if r18_p12 == true or r20.tooltype ~= "pick" then r20_p12 = false end
    local r22_p12 = false
    if r20_p12 == true then
        r22_p12 = true
        if Character.perk.Value == "tunnelrat" and (Value_2 == "pickaxe" or Value_2 == "pick") then
            local tunnelratbuff_3 = Instance.new("StringValue")
            game:GetService("Debris"):AddItem(tunnelratbuff_3, 4)
            tunnelratbuff_3.Name = "tunnelratbuff"
            tunnelratbuff_3.Parent = Character
        end
        local tunnelratbuff_2 = r29.alt_mode
        if Value_2 == "pickaxe" then
            bFunctions:soundHandler({
                directory = {"tools", "pickaxe"}, soundfile = "mine", pitchvariation = 0.1,
                volume_adjust = r3_p12,
                force_max_dist = r4,
                location = Character.HumanoidRootPart
            })
            if Parent_2.durability.Value >= 1 and r29.alt_mode == false and core_checkers.aiming == false then
                Parent_2.durability.Value = Parent_2.durability.Value - 1
            else
                tunnelratbuff_2 = true
            end
        end
        if Value_2 ~= "pick" and Value_2 ~= "pickaxe" or core_checkers.aiming ~= true then
        else
            tunnelratbuff_2 = "precise"
            melee_swing_speed = Value_2 == "pickaxe" and melee_swing_speed * 0.8 or melee_swing_speed * 0.85
        end
        bFunctions:soundHandler({
            directory = {"tools", "pick"},
            pitchvariation = 0.1,
            soundfile = "hit" .. math.random(1, 4),
            volume_adjust = r3_p12,
            force_max_dist = r4,
            location = Character.HumanoidRootPart
        })
        if Character.perk.Value ~= "tunnelrat" then visualEffects("mine_impact", {point = r14}) end
        r25.mine:Play(0.2, 1, 1)
        events.mine:Fire(CFrame.new(r14, Character.Head.Position), Parent_2, tunnelratbuff_2, r13_p12)
    elseif r13_p12 and r14 and r13_p12.Parent:FindFirstChild("Humanoid") == nil and r13_p12.Parent.Parent:FindFirstChild("health") == nil and r13_p12.Name ~= "leftshield" and r13_p12.Name ~= "rightshield" and r13_p12.Name ~= "mainshield" and r13_p12.Name ~= "topshield" then
        visualEffects("mine_impact", {point = r14})
        bFunctions:soundHandler({
            directory = {"impacts", "general", "melee_wall"},
            pitchvariation = 0.1,
            soundfile = "impact" .. math.random(1, 2),
            location = Character.HumanoidRootPart
        })
    end
    if r1 == "stab" then melee_swing_speed -= 0.1 end
    local tunnelratbuff = tick()
    local r24_p12 = false
    repeat
        if core_checkers.aiming == true then core_checkers.aim_time = tick() end
        if Character and Character:FindFirstChild("perk") and Character.perk.Value == "tunnelrat" then
            if Value_2 ~= "pickaxe" and Value_2 ~= "pick" or core_checkers.queue_inv == nil then
            elseif core_checkers.queue_inv ~= 4 and r22_p12 == true then
                r24_p12 = true
                break
            end
        end
        RenderStepped:wait()
    until melee_swing_speed <= tick() - tunnelratbuff
    if r20.tooltype ~= "pick" and r20.tooltype ~= "hammer" or r24_p12 ~= false then
        r63_0 = false
        action.Value = false
        return
    end
    if keysheld.m1 == true then r29.fire_buffer = tick() end
    r63_0 = false
    action.Value = false
end
local r65_0 = 0
local r66_0 = 0
local r67_0 = 0
local function r68_0(r0_p13) -- Line: 2194 | Upvalues: ("CurrentCamera" (copy), "localize" (copy), "Parent_2" (copy), "r20" (ref), "Character" (copy), "core_checkers" (copy), "bipod" (copy))
    CurrentCamera.ammo_check.bg.count.Visible = false
    CurrentCamera.ammo_check.bg.ammo.Visible = false
    CurrentCamera.ammo_check.bg.walkertext.Visible = true
    CurrentCamera.ammo_check.bg.Size = UDim2.new(0, 145, 0, 55)
    local r1 = localize("ammo_state_walker_cap_loaded")
    local r2 = localize("ammo_state_walker_ball_loaded")
    local r3_p13 = localize("ammo_state_walker_powder_loaded")
    local r4 = _G["walkerstate" .. Parent_2.slot.Value][r0_p13]
    if r4 then
        if r4.cap == false then
            r1 = localize("ammo_state_walker_cap_none")
        elseif r4.cap == "fired" then
            r1 = localize("ammo_state_walker_cap_spent")
        end
        if r4.ball == "half" then
            r2 = localize("ammo_state_walker_ball_unseated")
        elseif r4.ball == false then
            r2 = localize("ammo_state_walker_ball_none")
        end
        if r4.powder == false then
            r3_p13 = localize("ammo_state_walker_powder_none")
        elseif r4.powder <= 0.2 then
            r3_p13 = localize("ammo_state_walker_powder_little")
        elseif r4.powder < 0.5 then
            r3_p13 = localize("ammo_state_walker_powder_almost")
        elseif r4.powder >= 1 then
            r3_p13 = localize("ammo_state_walker_powder_excess")
        end
    end
    if Character.class.Value == "jaeger" then
        local r6 = r20.ammo_give .. " " .. localize("ammo_state_pox")
    end
    if CurrentCamera:FindFirstChild("ammo_check") then
        CurrentCamera.ammo_check.bg.walkertext.Text = r1 .. "\n" .. r2 .. "\n" .. r3_p13 .. "\n"
        CurrentCamera.ammo_check.bg.maxammo.Visible = true
        CurrentCamera.ammo_check.bg.maxammo.inner.bar.Size = UDim2.new(1, 0, math.clamp(core_checkers[bipod .. "_reserves"] / core_checkers[bipod .. "_max"], 0, 1), 0)
    end
    core_checkers.check_ammo = tick()
end
local r69
local function r70_0(r0_p14) -- Line: 2256 | Upvalues: ("Value_2" (ref), "r20" (ref), "Parent_2" (copy), "action" (copy), "r29" (copy), "r18" (ref), "Character" (copy), "weaponEffects" (copy), "events" (copy), "core_checkers" (copy), "Value_3" (copy), "shield_supplies" (ref), "core_game" (copy), "LocalPlayer" (copy), "r69" (ref), "Humanoid" (copy))
    if _G.ping_locked and _G.ping_locked == true then return end
    if Value_2 == "rooklauncher" or Value_2 == "browningmg" or Value_2 == "mgturret" or r20.tooltype ~= "gun" then
        return
    end
    if workspace.serverStuff.trainingmode.Value == true then return end
    local Value = Parent_2.slot.Value
    if action.Value == true and r29.state == "reload" or r0_p14 == true then
        if Value_2 == "walker" then
            _G["walkerstate" .. Value] = {
                {cap = false, ball = false, powder = false}, {cap = false, ball = false, powder = false},
                {cap = false, ball = false, powder = false}, {cap = false, ball = false, powder = false},
                {cap = false, ball = false, powder = false}, {cap = false, ball = false, powder = false}
            }
            _G["walkercylinder" .. Value] = 1
        end
        if r18 == "mauservariant" and Parent_2:FindFirstChild("akimbo") and Parent_2.akimbo.Value == true and r29.dual_wield_tool and r29.dual_wield_tool:FindFirstChild("weapon") and r29.dual_wield_tool.weapon.Value == "mauservariant" and _G.get_settings("disableakimboreloads") ~= true then
            r29.dual_wield_tool.event:Fire("reload_weapon_swap")
        end
        if r29.dual_wield_tool then
            r29.dual_wield_tool.event:Fire("dual_active", false)
            local size
            local r3
            if Value_2 == "cavsword" then size = true end
            if Character.perk.Value == "akimbo" and r20.size == 1 and r20.tooltype == "gun" then
                size = true
                r3 = true
            end
            weaponEffects("weapon_visibility", {
                main = r29.dual_wield_vfx(),
                slot = r29.dual_wield_tool.slot.Value, state = "holster",
                flipped = size,
                dual = r3
            }, true, nil, true)
            events.game_handler:Fire("weapon_visibility", {
                wep = r29.dual_wield_tool, state = "holster",
                flipped = size,
                dual = r3
            })
        end
        core_checkers.inv_block_reason = ""
        if Value_2 == "mauser" then core_checkers.inv_swapping = true end
        if Value_2 == "lewis" then core_checkers.sprint_block = false end
        local r4 = {state = "dropped", destroy = true}
        local __up0 = Value_2
        if r18 ~= "" then __up0 = r18 end
        r4.main = {
            char = Character,
            originweapon = __up0,
            weapon = Value_2,
            model = Value_3,
            module = r20,
            core = shield_supplies
        }
        r4.slot = Value
        local r5
        r5, __up0 = true, nil
        weaponEffects("weapon_visibility", r4, r5, __up0, true)
        if Value_2 == "henry" and Character.perk.Value == "vet" then
            r4 = {visibility = false}
            __up0 = Value_2
            if r18 ~= "" then __up0 = r18 end
            r5 = {
                char = Character,
                originweapon = __up0,
                weapon = Value_2,
                model = Value_3,
                module = r20,
                core = shield_supplies
            }
            r4.main = r5
            weaponEffects("henry_offhandround", r4)
        end
        events.game_handler:Fire("weapon_visibility", {wep = Parent_2, state = "dropped"})
        local size = r20.size
        if Value_2 == "walker" then size = 1 end
        core_checkers.remove_tool(nil, nil, size)
        local r3 = core_game.inventory:FindFirstChild(Value_2 .. Value) or core_game.inventory:FindFirstChild(r18 .. Value)
        if r3 then
            r3.Name = "empty" .. Value
            r3.icon.Image = "rbxassetid://17768266447"
            core_checkers.inventory_display = tick()
            r3.line.BackgroundColor3 = Color3.new(0, 0, 0)
            r3.icon.ImageColor3 = Color3.new(0, 0, 0)
            r3.num.TextColor3 = Color3.new(0, 0, 0)
        end
        if LocalPlayer.Character:FindFirstChild("cowboy") and LocalPlayer.Character:findFirstChild("elitekit") and LocalPlayer.Character.elitekit.Value == "ocelot" then
            events.game_handler:Fire("ocelot_reload", Value)
        end
        action.Value = false
        r29.dropped = true
        r29.state = "normal"
        r69()
        Humanoid:UnequipTools()
        Parent_2:Destroy()
    end
end
local r71 = tick()
local function r72_0() -- Line: 2394 | Upvalues: ("r67_0" (ref), "Parent_2" (copy), "action" (copy), "core_checkers" (copy), "r29" (copy), "r25" (copy), "bFunctions" (copy), "Character" (copy), "r68_0" (copy), "keysheld" (copy), "weaponEffects" (copy), "Value_2" (ref), "r18" (ref), "Value_3" (copy), "r20" (ref), "shield_supplies" (ref), "bipod" (copy), "events" (copy), "RenderStepped" (copy), "r70_0" (copy), "Humanoid" (copy))
    local r0_p21 = tick() - r67_0
    if r0_p21 < 0 then return end
    if _G["walkerstate" .. Parent_2.slot.Value] == nil or _G["walkercylinder" .. Parent_2.slot.Value] == nil then
        return
    end
    if action.Value == false then
        core_checkers.inv_swapping = false
        r29.state = "walker_reload"
        action.Value = true
        r67_0 = tick()
        r25.reload_idle:Play(0.1, 1, 0.5)
        r25.reload_start:Play(0.4, 1, 2)
        bFunctions:s_wait(0.5)
        r0_p21 = false
        local __up7 = Character
        if __up7 then
            __up7 = Character:FindFirstChild("perk")
            if __up7 then __up7 = Character.perk.Value == "vet" end
        end
        local r2 = 0.3
        local r3
        local r4
        local r5_0
        local r6_0
        local r7_0
        local function update_speeds() -- Line: 2429 | Name: update_speeds | Upvalues: ("r2" (ref), "r3" (ref), "r4" (ref), "r5_0" (ref), "r6_0" (ref), "r7_0" (ref), "Character" (upval))
            r2 = 0.3
            r3 = 0.75
            r4 = 0.75
            r5_0 = 1.5
            r6_0 = 1.5
            r7_0 = 1
            if Character.perk.Value == "vet" then
                r3 *= 0.8
                r4 *= 0.8
                r5_0 *= 0.8
                r6_0 *= 0.8
            elseif Character:FindFirstChild("morale") then
                r3 *= 0.9
                r4 *= 0.9
                r5_0 *= 0.9
                r6_0 *= 0.9
            end
            if Character:FindFirstChild("cowboy") then
                r3 *= 0.75
                r4 *= 0.75
                r5_0 *= 0.75
                r6_0 *= 0.75
            end
        end
        update_speeds()
        repeat
            local __G = _G["walkercylinder" .. Parent_2.slot.Value] - 1
            if __G <= 0 then __G = 6 end
            local r10_p21 = _G["walkerstate" .. Parent_2.slot.Value][__G]
            r68_0(__G)
            local r13, r15
            if keysheld[Enum.KeyCode.E] and game:GetService("RunService"):IsStudio() then
                _G["walkerstate" .. Parent_2.slot.Value] = {
                    {cap = true, ball = true, powder = 0.75}, {cap = true, ball = true, powder = 0.75},
                    {cap = true, ball = true, powder = 0.75}, {cap = true, ball = true, powder = 0.75},
                    {cap = true, ball = true, powder = 0.75}, {cap = true, ball = true, powder = 0.75}
                }
                r13 = {}
                r15 = Value_2
                if r18 ~= "" then r15 = r18 end
                r13.main = {
                    char = Character,
                    originweapon = r15,
                    weapon = Value_2,
                    model = Value_3,
                    module = r20,
                    core = shield_supplies
                }
                r13.walker_slot = __G
                r13.walker_state = r10_p21
                weaponEffects("walker_setstate", r13)
                r68_0(__G)
            end
            if keysheld[Enum.KeyCode.One] ~= true and keysheld[Enum.KeyCode.DPadLeft] ~= true or r0_p21 ~= false then
            elseif tick() - r67_0 > 0 then
                update_speeds()
                r0_p21 = true
                r67_0 = tick() + r3
                if r10_p21.cap ~= false then
                    r25.reload_cap_remove:Play(0.1, 1, 1 / r3)
                    delay(r3 / 2, function() -- Line: 2500 | Upvalues: ("weaponEffects" (upval), "Value_2" (upval), "r18" (upval), "Character" (upval), "Value_3" (upval), "r20" (upval), "shield_supplies" (upval), "__G" (ref), "r10_p21" (copy))
                        local __up1 = Value_2
                        if r18 ~= "" then __up1 = r18 end
                        weaponEffects("walker_dropcap", {
                            main = {
                                char = Character,
                                originweapon = __up1,
                                weapon = Value_2,
                                model = Value_3,
                                module = r20,
                                core = shield_supplies
                            },
                            cap_drop = __G
                        })
                        r10_p21.cap = false
                        local r2 = {}
                        __up1 = Value_2
                        if r18 ~= "" then __up1 = r18 end
                        r2.main = {
                            char = Character,
                            originweapon = __up1,
                            weapon = Value_2,
                            model = Value_3,
                            module = r20,
                            core = shield_supplies
                        }
                        r2.walker_slot = __G
                        r2.walker_state = r10_p21
                        weaponEffects("walker_setstate", r2)
                    end)
                else
                    r25.reload_cap_add:Play(0.1, 1, 1 / r3)
                    delay(r3 / 2, function() -- Line: 2520 | Upvalues: ("r10_p21" (copy), "weaponEffects" (upval), "Value_2" (upval), "r18" (upval), "Character" (upval), "Value_3" (upval), "r20" (upval), "shield_supplies" (upval), "__G" (ref))
                        r10_p21.cap = true
                        local __up2 = Value_2
                        if r18 ~= "" then __up2 = r18 end
                        weaponEffects("walker_setstate", {
                            main = {
                                char = Character,
                                originweapon = __up2,
                                weapon = Value_2,
                                model = Value_3,
                                module = r20,
                                core = shield_supplies
                            },
                            walker_slot = __G,
                            walker_state = r10_p21
                        })
                    end)
                end
            end
            local r11_p21
            if keysheld[_G.get_keybinds("alt")] == true and r0_p21 == false and tick() - r67_0 > 0 then
                if core_checkers[bipod .. "_reserves"] <= 0 then
                    r0_p21 = true
                    _G.popupmsg("noleadball", not __up7 and "#walker_noballs" or "#walker_noballs_vet", 1)
                else
                    r0_p21 = true
                    if r10_p21.ball == false then
                        r11_p21 = core_checkers
                        r11_p21[bipod .. "_reserves"] = r11_p21[bipod .. "_reserves"] - 1
                        if Parent_2:FindFirstChild("empty_ammo") and core_checkers[bipod .. "_reserves"] <= 0 then
                            Parent_2.empty_ammo.Value = false
                        end
                        update_speeds()
                        r67_0 = tick() + r4
                        r25.reload_add_ball:Play(0.1, 1, 1 / r4)
                        delay(r4 / 2, function() -- Line: 2562 | Upvalues: ("r10_p21" (copy), "weaponEffects" (upval), "Value_2" (upval), "r18" (upval), "Character" (upval), "Value_3" (upval), "r20" (upval), "shield_supplies" (upval), "__G" (ref))
                            r10_p21.ball = "half"
                            local __up2 = Value_2
                            if r18 ~= "" then __up2 = r18 end
                            weaponEffects("walker_setstate", {
                                main = {
                                    char = Character,
                                    originweapon = __up2,
                                    weapon = Value_2,
                                    model = Value_3,
                                    module = r20,
                                    core = shield_supplies
                                },
                                walker_slot = __G,
                                walker_state = r10_p21
                            })
                        end)
                        events.game_handler:Fire("reloaded_weapon")
                    else
                        r11_p21 = not __up7 and "#walker_ballloaded" or "#walker_ballloaded_vet"
                        if __up7 and (r10_p21.powder == false or r10_p21.powder >= 1) then
                            r11_p21 = "#walker_vet_messup"
                        end
                        _G.popupmsg("ballloaded" .. __G, r11_p21, 1)
                    end
                end
            end
            if keysheld[_G.get_keybinds("checkammo")] == true and r0_p21 == false and tick() - r67_0 > 0 then
                r0_p21 = true
                r67_0 = tick() + r7_0
                r25.reload_dump:Play(0.1, 1, 1 / r7_0)
                if r10_p21.ball == false then
                    bFunctions:soundHandler({
                        directory = {"tools", "walker", "sfx"}, soundfile = "powder_dump", pitchvariation = 0.1,
                        location = Character.HumanoidRootPart
                    })
                    delay(r7_0 / 2, function() -- Line: 2611 | Upvalues: ("r10_p21" (copy), "weaponEffects" (upval), "Value_2" (upval), "r18" (upval), "Character" (upval), "Value_3" (upval), "r20" (upval), "shield_supplies" (upval), "__G" (ref))
                        r10_p21.powder = false
                        local __up2 = Value_2
                        if r18 ~= "" then __up2 = r18 end
                        weaponEffects("walker_setstate", {
                            main = {
                                char = Character,
                                originweapon = __up2,
                                weapon = Value_2,
                                model = Value_3,
                                module = r20,
                                core = shield_supplies
                            },
                            walker_slot = __G,
                            walker_state = r10_p21
                        })
                    end)
                elseif __up7 and (r10_p21.powder == false or r10_p21.powder >= 1) then
                    _G.popupmsg("messup" .. __G, "#walker_vet_messup", 1)
                end
            end
            local r12
            if keysheld[Enum.KeyCode.Two] ~= true and keysheld[Enum.KeyCode.DPadRight] ~= true or r0_p21 ~= false then
            else
                local r11_p21 = tick() - r67_0
                if r11_p21 > 0 then
                    r0_p21 = true
                    if r10_p21.ball ~= false then
                        r11_p21 = not __up7 and "#walker_ballblock" or "#walker_ballblock_vet"
                        if __up7 and (r10_p21.powder == false or r10_p21.powder >= 1) then
                            r11_p21 = "#walker_vet_messup"
                        end
                        _G.popupmsg("ballblock" .. __G, r11_p21, 1)
                    elseif r10_p21.powder ~= false and r10_p21.powder >= 1 then
                        _G.popupmsg("toomuch" .. __G, not __up7 and "#walker_powder_toomuch" or "#walker_powder_toomuch_vet", 1)
                    else
                        update_speeds()
                        r67_0 = tick() + r6_0
                        r25.reload_powder:Play(0.1, 1, 1 / r6_0)
                        r11_p21 = tick()
                        repeat
                            r67_0 = tick() + r6_0 / 2
                            RenderStepped:Wait()
                            r12 = tick() - r11_p21
                        until r6_0 / 2 <= r12
                        r25.reload_powder:AdjustSpeed(0)
                        r25.reload_powder.TimePosition = 0.5
                        if r10_p21.powder == false then r10_p21.powder = 0 end
                        r12 = r10_p21.powder
                        local __up11 = Value_2
                        if r18 ~= "" then __up11 = r18 end
                        weaponEffects("walker_setstate", {
                            main = {
                                char = Character,
                                originweapon = __up11,
                                weapon = Value_2,
                                model = Value_3,
                                module = r20,
                                core = shield_supplies
                            },
                            walker_slot = __G,
                            walker_state = r10_p21
                        })
                        local powder_pour = game.ReplicatedStorage.sound_library.tools.walker.powder_pour:Clone()
                        game:GetService("Debris"):AddItem(powder_pour, 1)
                        powder_pour.TimePosition = math.random(0, 500) / 100
                        powder_pour.Parent = Character.HumanoidRootPart
                        powder_pour:Play()
                        r11_p21 = tick()
                        while true do
                            r68_0(__G)
                            r67_0 = tick() + r6_0 / 2
                            r10_p21.powder = r12 + (tick() - r11_p21)
                            RenderStepped:Wait()
                            if r10_p21.powder >= 1 then break end
                            if keysheld[Enum.KeyCode.Two] == true or keysheld[Enum.KeyCode.DPadRight] == true or tick() - r11_p21 < 0.1 then
                                continue
                            end
                            break
                        end
                        if powder_pour then powder_pour:Destroy() end
                        r25.reload_powder:AdjustSpeed(1 / r6_0)
                        r25.reload_powder.TimePosition = 0.5
                    end
                end
            end
            if keysheld[Enum.KeyCode.Three] ~= true and keysheld[Enum.KeyCode.DPadUp] ~= true or r0_p21 ~= false then
            elseif tick() - r67_0 > 0 then
                update_speeds()
                r0_p21 = true
                r67_0 = tick() + r5_0
                r25.reload_lever:Play(0.1, 1, 1 / r5_0)
                delay(0.5, function() -- Line: 2717 | Upvalues: ("__G" (ref), "Parent_2" (upval), "weaponEffects" (upval), "Value_2" (upval), "r18" (upval), "Character" (upval), "Value_3" (upval), "r20" (upval), "shield_supplies" (upval))
                    local r0_arg2 = __G - 1
                    if r0_arg2 <= 0 then r0_arg2 = 6 end
                    local r1 = _G["walkerstate" .. Parent_2.slot.Value][r0_arg2]
                    if r1 and r1.ball == "half" then
                        r1.ball = true
                        local __up3 = Value_2
                        if r18 ~= "" then __up3 = r18 end
                        weaponEffects("walker_setstate", {
                            main = {
                                char = Character,
                                originweapon = __up3,
                                weapon = Value_2,
                                model = Value_3,
                                module = r20,
                                core = shield_supplies
                            },
                            walker_slot = r0_arg2,
                            walker_state = r1
                        })
                    end
                end)
            end
            if keysheld[Enum.KeyCode.Four] ~= true and keysheld[Enum.KeyCode.DPadDown] ~= true or r0_p21 ~= false then
            elseif tick() - r67_0 > 0 then
                r0_p21 = true
                core_checkers.check_ammo = 0
                core_checkers.inv_swapping = true
                r70_0(true)
                return
            end
            if keysheld.m1 == true and r0_p21 == false and tick() - r67_0 > 0 then
                r0_p21 = true
                r67_0 = tick() + r2
                r25.reload_cylinder:Play(0.1, 1, 1 / r2 + 0.1)
                local __up11 = Value_2
                if r18 ~= "" then __up11 = r18 end
                weaponEffects("walker_cylinder_rotate", {
                    main = {
                        char = Character,
                        originweapon = __up11,
                        weapon = Value_2,
                        model = Value_3,
                        module = r20,
                        core = shield_supplies
                    }
                })
                local __G_2, r12 = _G, "walkercylinder" .. Parent_2.slot.Value
                __G_2[r12] += 1
                if _G["walkercylinder" .. Parent_2.slot.Value] > 6 then
                    _G["walkercylinder" .. Parent_2.slot.Value] = 1
                end
            end
            if keysheld.m1 ~= true and keysheld[Enum.KeyCode.One] ~= true and keysheld[Enum.KeyCode.Two] ~= true and keysheld[Enum.KeyCode.Three] ~= true and keysheld[Enum.KeyCode.Four] ~= true and keysheld[_G.get_keybinds("alt")] ~= true and keysheld[Enum.KeyCode.DPadLeft] ~= true and keysheld[Enum.KeyCode.DPadUp] ~= true and keysheld[Enum.KeyCode.DPadRight] ~= true and keysheld[Enum.KeyCode.DPadDown] ~= true then
                r0_p21 = false
            end
            RenderStepped:Wait()
            if r29.state == "walker_reload" and Humanoid ~= nil and Humanoid.Health > 0 and r29.equipped ~= false then
                continue
            end
            break
        until r29.equipped == false
        core_checkers.check_ammo = 0
        r29.state = "normal"
        core_checkers.inv_swapping = true
        if not Humanoid or Humanoid.Health <= 0 or r29.equipped ~= true then
            action.Value = false
            return
        end
        local __G, r10_p21 = _G, "walkercylinder" .. Parent_2.slot.Value
        __G[r10_p21] += 1
        if _G["walkercylinder" .. Parent_2.slot.Value] > 6 then
            _G["walkercylinder" .. Parent_2.slot.Value] = 1
        end
        r67_0 = tick() + 0.5
        r25.reload_idle:Stop(0.1)
        r25.reload_end:Play(0.1, 1, 2)
        bFunctions:s_wait(0.5)
        action.Value = false
        return
    end
    if r29.state == "walker_reload" and tick() - r67_0 > 0 then
        r67_0 = tick()
        r29.state = "normal"
    end
end
local r73_0 = false
local function r74_0(r0_p22) -- Line: 2817 | Upvalues: ("action" (copy), "Value_2" (ref), "r29" (copy), "r72_0" (copy), "core_checkers" (copy), "r18" (ref), "shield_supplies" (ref), "r20" (ref), "r70_0" (copy), "Character" (copy), "Parent_2" (copy), "bFunctions" (copy), "r25" (copy), "bipod" (copy), "Humanoid" (copy), "RenderStepped" (copy), "LocalPlayer" (copy), "r73_0" (ref), "weaponEffects" (copy), "Value_3" (copy), "r15" (ref), "events" (copy))
    if action.Value == true and Value_2 == "walker" and r29.state == "walker_reload" then
        r72_0()
        return
    end
    if action.Value == true or r29.state == "reload" then return end
    if core_checkers.queue_inv ~= nil then return end
    if Value_2 == "walker" then
        r72_0()
        return
    end
    if Value_2 == "mauser" and r18 == "mauservariant" and r29.equipped == true and shield_supplies.ammo_mag < r20.capacity then
        r70_0(true)
        return
    end
    if Value_2 == "saa" and Character:FindFirstChild("elitekit") and Character.elitekit.Value == "ocelot" and r29.equipped and not Character.action.Value and shield_supplies.ammo_mag < r20.capacity then
        r70_0(true)
        return
    end
    local ammo_mag = shield_supplies.ammo_mag
    local capacity = r20.capacity
    if Value_2 == "lebel" and r29.alt_mode == true then ammo_mag -= 1 end
    if Value_2 == "springfield" and r29.alt_mode == true then capacity = 40 end
    if Parent_2:FindFirstChild("mounted_weapon") or Value_2 == "browningmg" then return end
    if Value_2 == "rooklauncher" and Character:FindFirstChild("equipment") and Character.equipment.Value <= 0 then
        return
    end
    if capacity <= ammo_mag and Parent_2:FindFirstChild("akimbo") and Parent_2.akimbo.Value == true and r29.dual_wield_tool and _G.get_settings("disableakimboreloads") ~= true and r0_p22 ~= true then
        r29.dual_wield_tool.event:Fire("reload_weapon_swap")
    end
    if capacity <= ammo_mag or action.Value == true or tick() - r29.draw < r20.draw_speed / core_checkers.draw_modifier - 0.1 then
        return
    end
    if r29.dropped == true then return end
    local r3
    if Value_2 == "springfield" and r29.alt_mode == true then
        if r29.extra_mag == false then
            r3 = Character
            if r3 then
                r3 = Character:FindFirstChild("perk")
                if r3 then r3 = Character.perk.Value == "vet" end
            end
            _G.popupmsg("pedersen_nomags", not r3 and "#springfield_pedersen_empty" or "#springfield_pedersen_empty_vet", 1)
            return
        end
        action.Value = true
        r29.state = "reload"
        r29.extra_mag = false
        r3 = false
        if shield_supplies.ammo_mag >= 1 then r3 = true end
        bFunctions:soundHandler({
            directory = {"tools", "shared"}, soundfile = "reloadstart", pitchvariation = 0.1,
            location = Character.HumanoidRootPart
        })
        r25.pedersen_mag_eject:Play(0.1, 1, 0.5)
        bFunctions:s_wait(2)
        r25.pedersen_mag_in:Play(0.1, 1, 0.5)
        bFunctions:s_wait(2)
        shield_supplies.ammo_mag = 40
        if r3 == true then
            shield_supplies.ammo_mag += 1
        else
            r25.pedersen_charge:Play(0.1, 1, 1)
            bFunctions:s_wait(1)
        end
        bFunctions:soundHandler({
            directory = {"tools", "shared"}, soundfile = "reloadend", pitchvariation = 0.1,
            location = Character.HumanoidRootPart
        })
        r29.interrupt_reload = false
        r29.state = "normal"
        action.Value = false
        return
    end
    if Value_2 == "enfield" and r29.alt_mode == true then
        if r18 == "enfieldvariant" then return end
        if Parent_2:FindFirstChild("gl_uses") == nil then return end
        if Parent_2.gl_uses.Value <= 0 then
            local __up9 = Character
            if __up9 then
                __up9 = Character:FindFirstChild("perk")
                if __up9 then __up9 = Character.perk.Value == "vet" end
            end
            _G.popupmsg("nogl", not __up9 and "#enfield_grenades_empty" or "#enfield_grenades_empty_vet", 1)
            return
        end
        if shield_supplies.blank_round_loaded == nil or shield_supplies.blank_round_loaded == true then
            return
        end
        action.Value = true
        r29.state = "reload"
        r25.discard_grenade:Play(0.1, 1, 1)
        bFunctions:s_wait(1)
        r25.blank_reload:Play(0.1, 1, 1)
        bFunctions:s_wait(1)
        r25.reload_end:Play(0.1, 1, 2)
        bFunctions:s_wait(0.5)
        r25.load_grenade:Play(0.1, 1, 0.6666666666666666)
        bFunctions:s_wait(1.5)
        shield_supplies.ammo_mag += 1
        shield_supplies.blank_round_loaded = true
        r29.interrupt_reload = false
        r29.state = "normal"
        action.Value = false
        return
    end
    if core_checkers[bipod .. "_reserves"] <= 0 then
        if workspace.serverStuff.trainingmode.Value == false then
            local __up9 = Character
            if __up9 then
                __up9 = Character:FindFirstChild("perk")
                if __up9 then __up9 = Character.perk.Value == "vet" end
            end
            _G.popupmsg("insufficientammo", not __up9 and "#message_ammoinsufficient" or "#message_ammoinsufficient_vet", 1)
        end
        return
    end
    if r20.require_full_load and r20.require_full_load == true and core_checkers[bipod .. "_reserves"] < r20.capacity then
        local __up9 = Character
        if __up9 then
            __up9 = Character:FindFirstChild("perk")
            if __up9 then __up9 = Character.perk.Value == "vet" end
        end
        local r4 = not __up9 and "#message_ammoinsufficient_clip" or "#message_ammoinsufficient_clip_vet"
        if Value_2 == "mpistol" then
            r4 = not __up9 and "#message_ammoinsufficient_mag" or "#message_ammoinsufficient_mag_vet"
        end
        _G.popupmsg("insufficientammo", r4, 1)
        return
    end
    if Value_2 == "lebel" and r29.alt_mode == true and shield_supplies.force_block_fire == false and shield_supplies.ammo_mag > 0 then
        return
    end
    local r3 = tick() - core_checkers.fall_damage_interrupt
    if r3 <= 0 then return end
    if Parent_2:FindFirstChild("mag_empty") then Parent_2.mag_empty.Value = false end
    if r29.dropped == true then return end
    if r0_p22 == true then
        Humanoid:EquipTool(Parent_2)
        r3 = tick()
        repeat
            RenderStepped:Wait()
            if r29.equipped ~= true and tick() - r3 < 1 then continue end
            break
        until tick() - r3 >= 1
        if r29.equipped == false then return end
    end
    if r29.dropped == true then return end
    if r29.equipped == false then return end
    if Value_2 == "lewis" then core_checkers.sprint_block = true end
    bFunctions:soundHandler({
        directory = {"tools", "shared"}, soundfile = "reloadstart", pitchvariation = 0.1,
        location = Character.HumanoidRootPart
    })
    r29.state = "reload"
    r29.interrupt_reload = false
    action.Value = true
    r3 = r20.reload_start
    local r4 = "reload_start"
    local r5_p22 = false
    if (shield_supplies.ammo_mag > 0 or not r25.reload_empty) and (Value_2 == "lebel" and shield_supplies.ammo_mag <= 1) then
        if shield_supplies.ammo_mag <= 0 then r5_p22 = true end
        r3 = r20.reload_empty
        r4 = "reload_empty"
    end
    local r6 = false
    local r7 = false
    local r8 = false
    local r9 = false
    local r10_p22 = false
    if Character.perk.Value == "vet" then
        r10_p22 = true
        if Value_2 == "rooklauncher" or r18 == "springfieldvariant" then r10_p22 = false end
    elseif Value_2 == "scho" and Character:FindFirstChild("elitekit") and Character:FindFirstChild("class") and Character.class.Value == Character.elitekit.Value then
        r10_p22 = true
    end
    if r10_p22 == true and r25[r4 .. "_vet"] then
        r4 ..= "_vet"
        if Value_2 == "lebel" or Value_2 == "scho" then
            if shield_supplies.ammo_mag <= 0 then r4 = "reload_empty" end
            if Value_2 == "scho" and shield_supplies.ammo_mag <= 0 then r4 = "reload_start" end
            if r4 == "reload_start_vet" or r4 == "reload_empty_vet" then r3 *= 1.2 end
        end
    end
    if Value_2 ~= "lever" and Value_2 ~= "mares" and Value_2 ~= "autosg" and Value_2 ~= "trench" or shield_supplies.ammo_mag > 0 then
    else
        r6 = true
        if r10_p22 == true then r3 *= 0.9 end
    end
    if Value_2 == "enfield" or Value_2 == "mondragon" then
        r7 = true
        if shield_supplies.ammo_mag <= 1 then
            r6 = true
            r4 = "reload_empty"
        end
        if r10_p22 == true then
            r7 = false
            if shield_supplies.ammo_mag > 0 then
                r6 = false
                r4 = "reload_start_vet"
                r3 *= 1.2
            end
        end
        if Value_2 == "mondragon" then
            r7 = false
            r6 = false
            r4 = shield_supplies.ammo_mag > 0 and "reload_start" or "reload_empty"
        elseif (shield_supplies.ammo_mag <= 0 or shield_supplies.ammo_mag == 1 and r7 == true) and core_checkers[bipod .. "_reserves"] >= 5 then
            r6 = false
            r4 = "reload_clip_empty"
            r3 = r20.reload_start + r20.reload_full
        end
    end
    local r11_p22
    if Value_2 == "mpgun" or Value_2 == "pugsley" or Value_2 == "lewis" then
        r8 = true
        r9 = true
        if shield_supplies.ammo_mag <= 0 then
            r11_p22 = r20.reload_empty
            if Character:FindFirstChild("elitekit") and Character:FindFirstChild("class") and Character.class.Value == Character.elitekit.Value then
                r11_p22 *= 0.6
            end
            r25.reload_bolt:Play(0.1, 1, 1 / r11_p22)
            bFunctions:s_wait(r11_p22)
        end
        if Value_2 == "mpgun" and Character:FindFirstChild("elitekit") and Character:FindFirstChild("class") and Character.class.Value == Character.elitekit.Value then
            r3 *= 0.9
            r4 = "reload_start_soldat"
        end
    end
    if Value_2 == "mauser" or Value_2 == "mausercarbine" then
        r7 = true
        r8 = true
        r9 = true
        r3 = r20.reload_full
        r4 = "reload_full"
        if r10_p22 == true then r4 = "reload_full_vet" end
        if shield_supplies.ammo_mag > 0 then
            local r11_p22 = "reload_start"
            local reload_start = r20.reload_start
            if shield_supplies.ammo_mag == 1 then
                r11_p22 = "reload_one"
                reload_start = r20.reload_empty
            end
            if r10_p22 == true then r11_p22 ..= "_vet" end
            r25[r11_p22]:Play(0.1, 1, 1 / reload_start)
            bFunctions:s_wait(reload_start)
            if shield_supplies.ammo_mag > 0 and r10_p22 == false then shield_supplies.ammo_mag = 0 end
        end
    end
    if Value_2 == "remington" then r8 = true end
    if Value_2 == "lebel" then
        r6 = true
        r7 = true
        if r29.alt_mode == true then
            r5_p22 = false
            r8 = true
            r6 = false
            r7 = false
            r4 = "reload_alt"
            r3 = r20.reload_alt
            if shield_supplies.alt_extra == false then
                if shield_supplies.ammo_mag > 0 then r4 = "reload_alt_extra" end
                shield_supplies.alt_extra = true
            end
        else
            if shield_supplies.force_block_fire == true then
                r7 = false
                r4 = "reload_empty"
            end
            shield_supplies.alt_extra = false
        end
    end
    local r11_p22 = false
    if Value_2 == "steyr" then
        if r10_p22 ~= true then r7 = true end
        if r4 == "reload_empty" then r6 = true end
        if r10_p22 == true then
            r6 = false
            r3 *= 1.2
            if r20.capacity <= core_checkers[bipod .. "_reserves"] and shield_supplies.ammo_mag <= 1 then
                r4 = nil
                if shield_supplies.ammo_mag == 1 then
                    r4 = "reload_one_vet"
                    r3 = 0.8
                end
            elseif shield_supplies.ammo_mag <= 0 then
                r6 = true
                r4 = "reload_empty"
            end
            if r18 == "steyrvariant" and shield_supplies.ammo_mag <= 0 then
                r6 = true
                r4 = "reload_empty"
            end
        end
    end
    if Value_2 == "mosin" or Value_2 == "springfield" then
        if r10_p22 ~= true then r7 = true end
        if shield_supplies.ammo_mag <= 1 then
            r4 = "reload_empty"
            r6 = true
        end
        if r10_p22 == true then
            r6 = false
            if r20.capacity <= core_checkers[bipod .. "_reserves"] and shield_supplies.ammo_mag <= 1 and r18 ~= "springfieldvariant" then
                r3 = r20.reload_start
                if shield_supplies.ammo_mag <= 0 then
                    r4 = "reload_clip_start_empty"
                elseif shield_supplies.ammo_mag == 1 then
                    r4 = "reload_clip_start_one"
                    r3 *= 1.2
                end
            elseif shield_supplies.ammo_mag <= 0 then
                r6 = true
                r4 = "reload_empty"
            elseif shield_supplies.ammo_mag == 1 then
                r4 = "reload_empty_vet"
                if Value_2 == "springfield" then r4 = "reload_start_vet" end
                r3 *= 1.2
            else
                r3 *= 1.2
                r4 = "reload_start_vet"
            end
        end
    end
    if Value_2 == "mosin" and r18 == "mosinvariant" and r20.capacity <= core_checkers[bipod .. "_reserves"] and r10_p22 == false then
        if shield_supplies.ammo_mag == 0 then
            r3 = r20.reload_start
            r6 = false
            r4 = "reload_clip_start_empty"
        elseif shield_supplies.ammo_mag == 1 then
            r3 = r20.reload_start
            r6 = false
            r4 = "reload_clip_start_empty_novet"
        end
    end
    if Value_2 == "saa" then
        if r10_p22 == true then r3 *= 1.2 end
        if Value_2 == "saa" and Character:FindFirstChild("elitekit") and Character.elitekit.Value == "ocelot" then
            r3 *= 0.75
        end
        if Character:FindFirstChild("cowboy") then r4 = "reload_start_vet" end
        if r18 ~= "" then r4 = "reload_start" end
    end
    local r12 = false
    if Value_2 == "dbgun" and r10_p22 == true and shield_supplies.ammo_mag <= 0 and core_checkers[bipod .. "_reserves"] >= 2 then
        r6 = true
        r4 = "reload_empty_vet"
        if math.random(1, 100) == 1 or LocalPlayer:FindFirstChild("doomer") then
            r12 = true
            r4 = "reload_empty_doom"
        end
    end
    if Value_2 == "rooklauncher" or Value_2 == "henry" or Value_2 == "rsc" or Value_2 == "crossbow" then
        r8 = true
        if Value_2 == "rsc" then
            r9 = true
            if r10_p22 == true and shield_supplies.ammo_mag <= 1 then r4 = "reload_start" end
        end
    end
    if Value_2 == "mpistol" then
        r8 = true
        r9 = true
        if r10_p22 == true then
            if shield_supplies.ammo_mag <= 1 then
                r4 = "reload_start"
            else
                r3 *= 1.3
            end
        end
    end
    if Value_2 == "henry" and r10_p22 == true then
        if r29.alt_mode == true then
            r4 = "reload_start"
        else
            r3 *= 0.8
        end
    end
    if Value_2 == "pieper" and r4 == "reload_start_vet" then
        if shield_supplies.ammo_mag <= 0 then
            r4 = "reload_start"
        else
            r3 *= 1.3
        end
    end
    if Value_2 == "pieper" and r73_0 == false then
        r4 = "reload_partial"
        r3 *= 0.7
    end
    local r15_p22, r17_p22
    if Value_2 == "pieper" and r29.slide_locked == true then
        r29.slide_locked = false
        r25.hammer_lower:Play(0.1, 1, 2)
        r15_p22 = {otherdir = true}
        r17_p22 = Value_2
        if r18 ~= "" then r17_p22 = r18 end
        r15_p22.main = {
            char = Character,
            originweapon = r17_p22,
            weapon = Value_2,
            model = Value_3,
            module = r20,
            core = shield_supplies
        }
        weaponEffects("cylinder_rotate", r15_p22)
        bFunctions:s_wait(0.5)
    end
    if core_checkers.morale == true and Value_2 ~= "rooklauncher" then r3 *= 0.7 end
    if Character:FindFirstChild("elitekit") and Character:FindFirstChild("class") and Character.elitekit.Value == Character.class.Value then
        r3 *= 0.8
    end
    if r25.fire then r25.fire:Stop(0) end
    if r4 ~= nil then
        r25[r4]:Stop(0)
        r25[r4]:Play(0.1, 1, 1 / r3)
        bFunctions:s_wait(r3)
        if (Value_2 ~= "enfield" or r4 ~= "reload_clip_empty") and (Value_2 == "mondragon" and r4 == "reload_empty") then
            core_checkers[bipod .. "_reserves"] = core_checkers[bipod .. "_reserves"] - 5
            shield_supplies.ammo_mag += 5
        end
        if Value_2 == "pieper" and r73_0 == true then
            local __up1 = Value_2
            if r18 ~= "" then __up1 = r18 end
            weaponEffects("cylinder_forcecylinder", {
                main = {
                    char = Character,
                    originweapon = __up1,
                    weapon = Value_2,
                    model = Value_3,
                    module = r20,
                    core = shield_supplies
                }
            })
            if r10_p22 == true then
                local __up4, r14_p22 = core_checkers, bipod .. "_reserves"
                __up4[r14_p22] += shield_supplies.ammo_mag
                shield_supplies.ammo_mag = 0
            else
                shield_supplies.ammo_mag = 0
            end
        end
        if r29.dropped == true then return end
    end
    if r29.equipped == false then return end
    local r13
    local r14_p22
    local r15_p22
    local r16
    local r18_p22
    local r17_p22
    local r19_p22
    if r8 == false then
        if r7 == true and r5_p22 == false and r10_p22 == false then shield_supplies.ammo_mag -= 1 end
        r13 = 0
        if r6 == true then r13 -= 1 end
        if Value_2 ~= "scho" and Value_2 ~= "mauser" and Value_2 ~= "mausercarbine" or r10_p22 ~= false then
        else
            shield_supplies.ammo_mag = 0
        end
        if Value_2 == "saa" and shield_supplies.ammo_mag <= 4 and shield_supplies.ammo_mag > 0 then
            r14_p22 = shield_supplies.ammo_mag + 1
            r15_p22 = true
            r14_p22 /= 2
            if r14_p22 == math.ceil(r14_p22) then r15_p22 = false end
            if r14_p22 > 0.5 then
                for i_0 = 1, r14_p22 do
                    r3 = 0.25
                    r25.reload_loop_after_twice:Play(0.05, 1, 1 / r3)
                    bFunctions:s_wait(r3)
                end
            end
            if r29.dropped == true then return end
            if r15_p22 == true then
                r3 = 0.25
                r25.reload_loop_after:Play(0.05, 1, 1 / r3)
                bFunctions:s_wait(r3)
            end
            if r29.dropped == true then return end
        end
        if r25.reload_loop then r25.reload_loop.Looped = true end
        r13 += r20.capacity - shield_supplies.ammo_mag
        if Value_2 == "springfield" and Value_3:FindFirstChild("accessorypart") and Value_3.accessorypart:FindFirstChild("extra") and Value_3.accessorypart.extra:FindFirstChild("spareammo1A") and Value_3.accessorypart.extra:FindFirstChild("spareammo2A") then
            if Value_3.accessorypart.extra.spareammo1A.Transparency ~= 0 and Value_3.accessorypart.extra.spareammo2A.Transparency ~= 0 or r6 ~= true then
            elseif core_checkers[bipod .. "_reserves"] <= 2 then
                r16 = {}
                r18_p22 = Value_2
                if r18 ~= "" then r18_p22 = r18 end
                r17_p22 = {
                    char = Character,
                    originweapon = r18_p22,
                    weapon = Value_2,
                    model = Value_3,
                    module = r20,
                    core = shield_supplies
                }
                r16.main = r17_p22
                weaponEffects("springfield_ammoskin_check", r16)
            end
        end
        for i_1 = 1, r13 do
            if r15 == true or r29.equipped == false then return end
            if r29.dropped == true then return end
            if r6 == true then
                local r17_p22 = 1
                if Value_2 == "lebel" and r10_p22 == true then r17_p22 = 2 end
                if core_checkers[bipod .. "_reserves"] == r17_p22 then break end
            end
            if core_checkers[bipod .. "_reserves"] <= 0 then break end
            if r29.dropped == true then return end
            r3 = r20.reload_loop
            if core_checkers.morale == true then r3 *= 0.7 end
            if Character:FindFirstChild("elitekit") and Character:FindFirstChild("class") and Character.elitekit.Value == Character.class.Value then
                r3 *= 0.8
            end
            if Value_2 == "saa" and Character:FindFirstChild("elitekit") and Character.elitekit.Value == "ocelot" then
                r3 *= 0.5
            end
            local r17_p22 = "reload_loop"
            if r18 == "springfieldvariant" and Value_2 == "springfield" then
                if shield_supplies.ammo_mag >= 23 then
                    r25.reload_loop.Looped = false
                    r3 *= 1.4
                    r17_p22 = "reload_heavyloop"
                elseif shield_supplies.ammo_mag >= 21 then
                    r25.reload_loop.Looped = false
                    r3 *= 1.3
                    r17_p22 = "reload_heavyloop"
                elseif shield_supplies.ammo_mag >= 19 then
                    r25.reload_loop.Looped = false
                    r3 *= 1.2
                    r17_p22 = "reload_heavyloop"
                elseif shield_supplies.ammo_mag >= 17 then
                    r25.reload_loop.Looped = false
                    r3 *= 1.1
                end
            end
            if Value_2 == "dbgun" then
                if r10_p22 == true and r6 == true then
                    r3 *= 1.4
                    r17_p22 = "reload_dual_vet"
                    if r12 == true then r17_p22 = "reload_dual_doom" end
                else
                    if r29.db_othershell and r29.db_othershell == true then
                        r25[r17_p22]:Stop(0)
                        r17_p22 = "reload_loop_alt"
                        r29.db_othershell = false
                    end
                    r29.db_othershell = true
                end
            end
            local r18_p22 = 1
            r19_p22 = false
            if r18 == "mosinvariant" and r10_p22 == false then
                r19_p22 = true
                r18_p22 = 0
            end
            if r10_p22 == true then r19_p22 = true end
            if (Value_2 ~= "mosin" and (Value_2 ~= "steyr" or r18 ~= "")) and Value_2 == "springfield" and (r19_p22 == true and shield_supplies.ammo_mag <= r18_p22 and r20.capacity <= core_checkers[bipod .. "_reserves"] and r18 ~= "springfieldvariant") then
                core_checkers[bipod .. "_reserves"] = core_checkers[bipod .. "_reserves"] - (r20.capacity - 1 - shield_supplies.ammo_mag)
                shield_supplies.ammo_mag = r20.capacity - 1
                r17_p22 = "reload_clip"
                r3 = r20.reload_full
                if r18 == "mosinvariant" and r10_p22 == false then r3 *= 1.2 end
                r11_p22 = true
            end
            if Value_2 ~= "enfield" and Value_2 ~= "mondragon" or shield_supplies.ammo_mag + 5 > r20.capacity then
            elseif core_checkers[bipod .. "_reserves"] >= 5 then
                core_checkers[bipod .. "_reserves"] = core_checkers[bipod .. "_reserves"] - 4
                shield_supplies.ammo_mag += 4
                r17_p22 = "reload_clip"
                r3 = r20.reload_full
                if r10_p22 == true then r3 *= 0.7 end
            end
            local r20_p22 = 0.05
            if i_1 > 1 then r20_p22 = 0 end
            r25[r17_p22]:Play(r20_p22, 1, 1 / r3)
            bFunctions:s_wait(r3)
            shield_supplies.ammo_mag += 1
            if Value_2 ~= "saa" or not Character:FindFirstChild("elitekit") or Character.elitekit.Value ~= "ocelot" then
                core_checkers[bipod .. "_reserves"] = core_checkers[bipod .. "_reserves"] - 1
            end
            if (Value_2 == "springfield" and Value_3:FindFirstChild("accessorypart") and Value_3.accessorypart:FindFirstChild("extra") and Value_3.accessorypart.extra:FindFirstChild("spareammo1A") and Value_3.accessorypart.extra:FindFirstChild("spareammo2A")) and (Value_3.accessorypart.extra.spareammo1A.Transparency == 0 or Value_3.accessorypart.extra.spareammo2A.Transparency == 0) then
                local r21 = 1
                if r6 == true then r21 = 2 end
                if core_checkers[bipod .. "_reserves"] <= r21 then
                    local __up1 = Value_2
                    if r18 ~= "" then __up1 = r18 end
                    weaponEffects("springfield_ammoskin_check", {
                        main = {
                            char = Character,
                            originweapon = __up1,
                            weapon = Value_2,
                            model = Value_3,
                            module = r20,
                            core = shield_supplies
                        }
                    })
                end
            end
            if r29.interrupt_reload == true or core_checkers.queue_inv ~= nil then
                if Value_2 ~= "pieper" or core_checkers.queue_inv == nil then break end
                local r23_p22 = {otherdir = true}
                local __up1 = Value_2
                if r18 ~= "" then __up1 = r18 end
                r23_p22.main = {
                    char = Character,
                    originweapon = __up1,
                    weapon = Value_2,
                    model = Value_3,
                    module = r20,
                    core = shield_supplies
                }
                weaponEffects("cylinder_rotate", r23_p22)
                break
            end
            if r25.reload_loop_after then
                if core_checkers[bipod .. "_reserves"] <= 0 or r20.capacity <= shield_supplies.ammo_mag then
                    break
                end
                if core_checkers.queue_inv ~= nil then break end
                r3 = r20.reload_loop_after
                r25.reload_loop_after:Play(r3 / 2, 1, 1 / r3)
                bFunctions:s_wait(r3)
                if r29.equipped == false then return end
                if r20.capacity <= shield_supplies.ammo_mag or r11_p22 == true then break end
                if r29.dropped == true then return end
                break
            end
            if r29.equipped == false then return end
            if r20.capacity <= shield_supplies.ammo_mag or r11_p22 == true then break end
            if r29.dropped == true then return end
        end
        if r25.reload_loop then
            r25.reload_loop:Stop(0.1)
            r25.reload_loop.Looped = false
        end
        if Value_2 == "saa" and shield_supplies.ammo_mag < 6 then
            r14_p22 = 6 - shield_supplies.ammo_mag
            for i_2 = 1, r14_p22 do
                r3 = 0.3
                r25.reload_loop_after:Play(0.05, 1, 1 / r3)
                bFunctions:s_wait(r3)
            end
        end
        if (Value_2 == "pieper" and (core_checkers[bipod .. "_reserves"] <= 0 or r29.interrupt_reload == true)) and shield_supplies.ammo_mag < 7 then
            r3 = r20.reload_loop_after
            r25.reload_loop_after:Play(0.05, 1, 1 / r3)
            bFunctions:s_wait(r3)
        end
        r3 = r20.reload_end
        if core_checkers.morale == true then r3 *= 0.7 end
        if Character:FindFirstChild("elitekit") and Character:FindFirstChild("class") and Character.elitekit.Value == Character.class.Value then
            r3 *= 0.8
        end
        if Value_2 == "saa" and Character:FindFirstChild("elitekit") and Character.elitekit.Value == "ocelot" then
            r3 *= 0.5
        end
        r14_p22 = "reload_end"
        if Value_2 == "scho" and Value_3:FindFirstChild("parts") and Value_3.parts:FindFirstChild("break") and Value_3.parts["break"]:FindFirstChild("snubbarrel") and Value_3.parts["break"].snubbarrel.Transparency == 0 then
            r14_p22 = "reload_end_vet"
        end
        if r10_p22 == true and r25[r14_p22 .. "_vet"] then r14_p22 ..= "_vet" end
        if Value_2 == "dbgun" and r12 == true then r14_p22 = "reload_end_doom" end
        if r25[r14_p22] then
            r25[r14_p22]:Play(0.1, 1, 1 / r3)
            bFunctions:s_wait(r3)
        end
        if r29.dropped == true then return end
    else
        r13 = false
        if Value_2 == "mpistol" then
            r14_p22 = true
            if r10_p22 ~= true then
                shield_supplies.ammo_mag = 0
            elseif shield_supplies.ammo_mag > 0 then
                r14_p22 = false
                r13 = true
            end
            if r14_p22 == true then
                r3 = r20.reload_end
                r15_p22 = "reload_end"
                if shield_supplies.ammo_mag == 0 and r29.slide_locked == true then
                    r15_p22 = "reload_end_locked"
                    r3 *= 0.7
                    if r10_p22 == true then
                        r15_p22 = "reload_end_locked_vet"
                        r3 *= 0.6
                    end
                end
                if core_checkers.morale == true then r3 *= 0.7 end
                r25[r15_p22]:Play(0.1, 1, 1 / r3)
                bFunctions:s_wait(r3)
                if r29.dropped == true then return end
            end
        end
        if Value_2 == "rsc" then
            r14_p22 = true
            if r10_p22 == true then
                r13 = true
                if shield_supplies.ammo_mag >= 1 then
                    r14_p22 = false
                else
                    r13 = false
                end
            end
            if r14_p22 == true then
                r3 = r20.reload_end
                r15_p22 = "reload_end"
                if shield_supplies.ammo_mag == 0 and r29.slide_locked == true then
                    r15_p22 = "reload_end_locked"
                    r3 *= 0.5
                end
                if core_checkers.morale == true then r3 *= 0.7 end
                r25[r15_p22]:Play(0.1, 1, 1 / r3)
                bFunctions:s_wait(r3)
                if r10_p22 == false then shield_supplies.ammo_mag = 0 end
                if r29.dropped == true then return end
            end
        end
        if r9 == true then
            r14_p22 = r20.capacity - shield_supplies.ammo_mag
            shield_supplies.ammo_mag = r20.capacity
            r15_p22 = core_checkers
            r16 = bipod .. "_reserves"
            r15_p22[r16] -= r14_p22
            if r13 == true then shield_supplies.ammo_mag += 1 end
        else
            shield_supplies.ammo_mag += 1
            if r20.tooltype == "gun" then
                core_checkers[bipod .. "_reserves"] = core_checkers[bipod .. "_reserves"] - 1
            end
        end
        if Value_2 == "mpistol" then
            r16 = {}
            r18_p22 = Value_2
            if r18 ~= "" then r18_p22 = r18 end
            r17_p22 = {
                char = Character,
                originweapon = r18_p22,
                weapon = Value_2,
                model = Value_3,
                module = r20,
                core = shield_supplies
            }
            r16.main = r17_p22
            weaponEffects("m_mag_update", r16)
        end
    end
    if r29.dropped == true then return end
    if Value_2 == "henry" and r10_p22 == true then
        if r29.alt_mode == true and core_checkers[bipod .. "_reserves"] > 0 then r29.alt_mode = false end
        if core_checkers[bipod .. "_reserves"] <= 0 then r29.alt_mode = true end
        if r29.alt_mode == false then
            r25.vet_roundreplace:Play(0.1, 1, 2)
            bFunctions:s_wait(0.5)
        end
    end
    r13 = false
    if core_checkers[bipod .. "_reserves"] < core_checkers[bipod .. "_max"] and r20.tooltype == "gun" or workspace.serverStuff.trainingmode.Value == true then
        r13 = true
    end
    if Character:FindFirstChild("elitekit") and Value_2 ~= "snub" then r13 = false end
    if r13 == true then events.game_handler:Fire("reloaded_weapon") end
    if Value_2 == "crossbow" then events.game_handler:Fire("crossbow_state_handler", Parent_2, true) end
    if Value_2 == "lewis" then core_checkers.sprint_block = false end
    if r29.equipped == false then return end
    if Humanoid == nil or Humanoid.Health <= 0 then return end
    if r29.dropped == true then return end
    shield_supplies.force_block_fire = false
    bFunctions:soundHandler({
        directory = {"tools", "shared"}, soundfile = "reloadend", pitchvariation = 0.1,
        location = Character.HumanoidRootPart
    })
    if r6 == true then
        if Value_2 == "lebel" and r10_p22 == true then
            shield_supplies.ammo_mag += 1
            core_checkers[bipod .. "_reserves"] = core_checkers[bipod .. "_reserves"] - 1
        end
        shield_supplies.ammo_mag += 1
        core_checkers[bipod .. "_reserves"] = core_checkers[bipod .. "_reserves"] - 1
    end
    if Parent_2:FindFirstChild("empty_ammo") and core_checkers[bipod .. "_reserves"] <= 0 then
        Parent_2.empty_ammo.Value = true
    end
    if Value_2 == "enfield" and shield_supplies.blank_round_loaded == true then
        shield_supplies.blank_round_loaded = false
    end
    if r29.dropped == true then return end
    r73_0 = false
    r29.state = "normal"
    action.Value = false
    if core_checkers.queue_inv ~= nil and core_checkers.queue_inv ~= Parent_2.slot.Value then
        r29.equipped = false
    elseif r0_p22 == true then
        r14_p22 = LocalPlayer.Backpack:FindFirstChild("Bulwark's Shield") or LocalPlayer.Backpack:FindFirstChild("Cavalry Sword")
        if Character:FindFirstChild("perk") and Character.perk.Value == "akimbo" and Parent_2:FindFirstChild("akimbo") and Parent_2.akimbo.Value == true then
            for r18_p22, r19_p22 in ipairs(LocalPlayer.Backpack:GetChildren()) do
                if not r19_p22:FindFirstChild("akimbo") then continue end
                r14_p22 = r19_p22
                break
            end
        end
        if not r14_p22 or r29.interrupt_reload ~= false then
            r29.interrupt_reload = false
            return
        end
        Humanoid:EquipTool(r14_p22)
    else
        if not Parent_2:FindFirstChild("akimbo") or Parent_2.akimbo.Value ~= true or not r29.dual_wield_tool or _G.get_settings("disableakimboreloads") == true or r29.interrupt_reload ~= false then
            r29.interrupt_reload = false
            return
        end
        r29.dual_wield_tool.event:Fire("reload_weapon_swap")
    end
    r29.interrupt_reload = false
end
local function r75_0() -- Line: 4057 | Upvalues: ("action" (copy), "r29" (copy), "r20" (ref), "core_checkers" (copy), "Parent_2" (copy), "Value_2" (ref), "localize" (copy), "Character" (copy), "shield_supplies" (ref), "localization" (copy), "CurrentCamera" (copy), "bipod" (copy), "r68_0" (copy), "r25" (copy), "bFunctions" (copy))
    if action.Value == true or tick() - r29.draw < r20.draw_speed / core_checkers.draw_modifier - 0.1 or Parent_2:FindFirstChild("mounted_weapon") or Value_2 == "browningmg" then
        return
    end
    action.Value = true
    local r0_p23 = localize("ammo_state_full")
    if Value_2 == "saa" and Character:FindFirstChild("elitekit") and Character.elitekit.Value == "ocelot" then
        r0_p23 = localize("ammo_state_ocelot")
    end
    local r1 = 1.5
    if Value_2 == "mpgun" or Value_2 == "pugsley" then r1 = 2.5 end
    local capacity = r20.capacity
    local r3_p23 = localize("ammo_" .. r20.ammo_give, nil, r20.ammo_give)
    if Value_2 == "springfield" and r29.alt_mode == true then
        capacity = 40
        r3_p23 = localize("ammo_.30 Light", nil, "30 Light")
    end
    local r4 = shield_supplies.ammo_mag / capacity
    if Character.class.Value == "jaeger" and (Character:FindFirstChild("elitekit") == nil or Value_2 == "mondragon") then
        r3_p23 ..= " " .. localize("ammo_state_pox")
    end
    if (Value_2 ~= "enfield" or r29.alt_mode ~= true) and (shield_supplies.blank_round_loaded and shield_supplies.blank_round_loaded == true) then
        r3_p23 = localize("ammo_.303 Blank", nil, ".303 Blank")
    end
    if Value_2 == "lebel" and Character:FindFirstChild("class") and Character.class.Value == "conscript" then
        r3_p23 = localize("ammo_8mm Conscript", nil, "8mm Conscript")
    end
    if r4 <= 0.2 then
        r0_p23 = localize("ammo_state_almostempty")
    elseif r4 <= 0.45 then
        r0_p23 = localize("ammo_state_less")
    elseif r4 <= 0.55 then
        r0_p23 = localize("ammo_state_half")
    elseif r4 <= 0.75 then
        r0_p23 = localize("ammo_state_more")
    elseif r4 <= 0.99 then
        r0_p23 = localize("ammo_state_almostfull")
    end
    if (Value_2 ~= "scho" and Value_2 ~= "pieper" and Character.perk.Value ~= "vet") and (not Character:FindFirstChild("elitekit") or not Character:FindFirstChild("class") or Character.elitekit.Value ~= Character.class.Value) and (Value_2 == "saa" and Character:FindFirstChild("elitekit") and Character.elitekit.Value == "ocelot") and r4 <= 0.99 then
        local r5_p23 = localization.get("ammo_state_vet_precise")
        if r5_p23 and r5_p23[shield_supplies.ammo_mag] ~= nil then
            r0_p23 = r5_p23[shield_supplies.ammo_mag]
        end
    end
    if Character.perk.Value == "vet" and capacity < shield_supplies.ammo_mag then
        r0_p23 = localize("ammo_state_vet_chambered")
    end
    if shield_supplies.ammo_mag <= 1 then r0_p23 = localize("ammo_state_one") end
    if Value_2 == "henry" or Value_2 == "remington" then r0_p23 = localize("ammo_state_only") end
    if Value_2 == "crossbow" then
        r0_p23 = localize("ammo_state_crossbow")
        r1 = 1
    end
    if r4 == 0 then r0_p23 = localize("ammo_state_empty") end
    if CurrentCamera:FindFirstChild("ammo_check") then
        CurrentCamera.ammo_check.bg.ammo.Text = r3_p23
        CurrentCamera.ammo_check.bg.count.Text = r0_p23
        CurrentCamera.ammo_check.bg.count.Visible = true
        CurrentCamera.ammo_check.bg.ammo.Visible = true
        CurrentCamera.ammo_check.bg.walkertext.Visible = false
        CurrentCamera.ammo_check.bg.Size = game.ReplicatedStorage.misc.ammo_check.bg.Size
        CurrentCamera.ammo_check.bg.maxammo.Visible = true
        CurrentCamera.ammo_check.bg.maxammo.inner.bar.Size = UDim2.new(1, 0, math.clamp(core_checkers[bipod .. "_reserves"] / core_checkers[bipod .. "_max"], 0, 1), 0)
        if (r20.ammo_reserves_max < 200 and (Value_2 ~= "saa" or not Character:FindFirstChild("elitekit") or Character.elitekit.Value ~= "ocelot")) and r20.hidereserves then
            CurrentCamera.ammo_check.bg.maxammo.Visible = false
        end
    end
    if Value_2 == "walker" then r68_0(_G["walkercylinder" .. Parent_2.slot.Value]) end
    core_checkers.check_ammo = tick()
    local r5_p23 = "check"
    if r25.check_empty and shield_supplies.ammo_mag <= 0 then r5_p23 = "check_empty" end
    if Value_2 == "pieper" and r29.slide_locked == true then r5_p23 = "check_primed" end
    if Value_2 ~= "springfield" or r29.alt_mode ~= true then
        bFunctions:soundHandler({
            directory = {"tools", "shared"}, soundfile = "reloadstart", pitchvariation = 0.1,
            location = Character.HumanoidRootPart
        })
        r25[r5_p23]:Play(0.1, 1, 1 / r1)
        bFunctions:s_wait(r1)
        bFunctions:soundHandler({
            directory = {"tools", "shared"}, soundfile = "reloadend", pitchvariation = 0.1,
            location = Character.HumanoidRootPart
        })
        action.Value = false
        return
    end
    r5_p23 = "check_alt"
    bFunctions:soundHandler({
        directory = {"tools", "shared"}, soundfile = "reloadstart", pitchvariation = 0.1,
        location = Character.HumanoidRootPart
    })
    r25[r5_p23]:Play(0.1, 1, 1 / r1)
    bFunctions:s_wait(r1)
    bFunctions:soundHandler({
        directory = {"tools", "shared"}, soundfile = "reloadend", pitchvariation = 0.1,
        location = Character.HumanoidRootPart
    })
    action.Value = false
end
local function r76_0() -- Line: 4212 | Upvalues: ("r29" (copy), "action" (copy), "core_checkers" (copy), "r20" (ref), "Value_2" (ref), "shield_supplies" (ref), "r25" (copy), "Parent_2" (copy), "base" (copy), "r18" (ref), "Character" (copy), "bFunctions" (copy))
    r29.state = "cycling"
    action.Value = true
    core_checkers.sprint_block = true
    local r0_p24 = "cycle"
    local cycle = r20.cycle
    if Value_2 == "lebel" and r29.alt_mode == false and shield_supplies.alt_extra == true then
        r0_p24 = "alt_toggled_off"
        cycle = 1.75
    end
    if r25.cycle_left and core_checkers.flip_cam == true then r0_p24 = "cycle_left" end
    if Parent_2:FindFirstChild("bipod") and r25.bipod_cycle and tick() - Parent_2.bipod.Value <= base.bulwark_buffer then
        r0_p24 = "bipod_cycle"
        if Value_2 == "enfield" and r18 == "enfieldvariant" then cycle *= 0.8 end
    end
    if Character:FindFirstChild("vanguardbuff") then cycle *= 0.9 end
    if Character:FindFirstChild("buff_elite") then cycle *= 0.8 end
    if Character and Character:FindFirstChild("perk") and Character.perk.Value == "quickdraw" then
        cycle *= 0.955
    end
    if workspace.serverStuff.restorationmode.Value == true then cycle *= 1.2 end
    if Character:FindFirstChild("class") and Character.class.Value == "conscript" or workspace.serverStuff.trainingmode.Value == true then
        cycle *= 1.2
    end
    if Value_2 ~= "pugsley" or not Character:FindFirstChild("class") or Character.class.Value ~= "rook" then
        shield_supplies.alt_extra = false
        r25[r0_p24]:Stop(0)
        r25[r0_p24]:Play(0.1, 1, 1 / cycle)
        bFunctions:s_wait(cycle + r20.cycle_rest)
        core_checkers.sprint_block = false
        action.Value = false
        r29.state = "normal"
        return
    end
    cycle *= 0.85
    shield_supplies.alt_extra = false
    r25[r0_p24]:Stop(0)
    r25[r0_p24]:Play(0.1, 1, 1 / cycle)
    bFunctions:s_wait(cycle + r20.cycle_rest)
    core_checkers.sprint_block = false
    action.Value = false
    r29.state = "normal"
end
local r77
local function r78_0() -- Line: 4269 | Upvalues: ("r29" (copy), "r20" (ref), "core_checkers" (copy), "Character" (copy), "Parent_2" (copy), "action" (copy), "r25" (copy), "bFunctions" (copy), "visualEffects" (copy), "events" (copy), "CurrentCamera" (copy))
    if tick() - r29.draw < r20.draw_speed / core_checkers.draw_modifier then return end
    if workspace.serverStuff.values.gamemode.Value == "truce" and Character:FindFirstChild("engage") == nil then
        return
    end
    if Parent_2:FindFirstChild("flares") == nil then return end
    if Parent_2.flares.Value <= 0 then
        _G.popupmsg("flaregunnone", "#binocs_noflares", 1)
        return
    end
    if action.Value == true then return end
    action.Value = true
    Parent_2.flares.Value = Parent_2.flares.Value - 1
    local r0_p25 = "flaregun"
    local flip_cam = core_checkers.flip_cam
    if flip_cam == false then r0_p25 = "flaregun_right" end
    r25[r0_p25]:Play(0.1, 1, 1)
    bFunctions:soundHandler({directory = {"tools", "binocs"}, soundfile = "flare_equip", location = Character.HumanoidRootPart})
    bFunctions:s_wait(0.1)
    visualEffects("officer_flaregun", {char = Character, arm_use = flip_cam})
    bFunctions:s_wait(0.4)
    events.interaction_handler:Fire(Parent_2, "flaregun", CurrentCamera.CFrame.LookVector, flip_cam)
    bFunctions:s_wait(0.5)
    action.Value = false
end
local function r79_0() -- Line: 4326 | Upvalues: ("r29" (copy), "r20" (ref), "core_checkers" (copy), "Character" (copy), "action" (copy), "r25" (copy), "bFunctions" (copy), "events" (copy), "Parent_2" (copy))
    if tick() - r29.draw < r20.draw_speed / core_checkers.draw_modifier then return end
    if Character:FindFirstChild("lewisshield_cd") then
        _G.popupmsg("lewisshieldnone", "#lewis_noshield", 1)
        return
    end
    if action.Value == true then return end
    action.Value = true
    r25.shieldplace:Play(0.1, 1, 1.2)
    bFunctions:soundHandler({directory = {"constructs"}, soundfile = "shield_ready", location = Character.HumanoidRootPart})
    bFunctions:s_wait(0.2)
    events.interaction_handler:Fire(Parent_2, "lewisshield")
    bFunctions:s_wait(0.6)
    action.Value = false
end
local function r80_0() -- Line: 4359 | Upvalues: ("r29" (copy), "r20" (ref), "core_checkers" (copy), "Character" (copy), "action" (copy), "r25" (copy), "bFunctions" (copy), "events" (copy), "Parent_2" (copy))
    if tick() - r29.draw < r20.draw_speed / core_checkers.draw_modifier then return end
    if Character:FindFirstChild("telescope_cd") then
        _G.popupmsg("telescopenone", "#binocs_notelescope", 1)
        return
    end
    if action.Value == true then return end
    action.Value = true
    r25.telescope:Play(0.1, 1, 1.2)
    bFunctions:soundHandler({directory = {"constructs"}, soundfile = "telescope_ready", location = Character.HumanoidRootPart})
    bFunctions:s_wait(0.1)
    events.interaction_handler:Fire(Parent_2, "telescope")
    bFunctions:s_wait(0.7)
    action.Value = false
end
local function r81_0() -- Line: 4393 | Upvalues: ("r29" (copy), "r20" (ref), "core_checkers" (copy), "Parent_2" (copy), "action" (copy), "r25" (copy), "bFunctions" (copy), "Character" (copy), "keysheld" (copy), "RenderStepped" (copy), "events" (copy), "Humanoid" (copy))
    if tick() - r29.draw < r20.draw_speed / core_checkers.draw_modifier then return end
    if Parent_2:FindFirstChild("client_inactive") or Parent_2:FindFirstChild("inactive") then return end
    action.Value = true
    local r0_p28 = tick()
    local r1 = true
    r25.flag:Play(0.1, 1, 1)
    bFunctions:soundHandler({directory = {"tools", "shared"}, soundfile = "unready" .. math.random(1, 4), location = Character.HumanoidRootPart})
    keysheld.m1 = true
    repeat
        if keysheld.m1 ~= true and tick() - r0_p28 <= 1.3 then
            r1 = false
            break
        end
        RenderStepped:Wait()
        local client_inactive = tick() - r0_p28
    until client_inactive >= 1.5
    if r1 == true then
        local client_inactive = Instance.new("StringValue")
        game:GetService("Debris"):AddItem(client_inactive, 2)
        client_inactive.Name = "client_inactive"
        client_inactive.Parent = Parent_2
        events.interaction_handler:Fire(Parent_2, "flagplace")
        r25.throw_over:Play(0.1, 1, 1)
        action.Value = false
        Humanoid:UnequipTools()
        return
    end
    r25.flag:Stop(0.05)
    action.Value = false
end
local function r82_0() -- Line: 4445 | Upvalues: ("r29" (copy), "r20" (ref), "core_checkers" (copy), "action" (copy), "Character" (copy), "keysheld" (copy), "LocalPlayer" (copy), "Value_2" (ref), "bFunctions" (copy), "Value_3" (copy), "visualEffects" (copy), "r25" (copy), "RenderStepped" (copy), "CurrentCamera" (copy), "r42" (copy), "events" (copy), "Parent_2" (copy), "Humanoid" (copy))
    if tick() - r29.draw < r20.draw_speed / core_checkers.draw_modifier then return end
    if core_checkers.aiming == false then return end
    action.Value = true
    local r0_p29 = tick()
    local r1_p29 = 1
    if Character:FindFirstChild("class") and (Character.class.Value == "rook" or Character.class.Value == "engineer") then
        r1_p29 /= 1.5
    end
    local r2 = r1_p29 / 2
    keysheld.m1 = true
    local r3_p29 = workspace.throwables:FindFirstChild(LocalPlayer.Name .. "_welding")
    if Value_2 == "weldingtool" then
        bFunctions:soundHandler({
            directory = {"tools", "weldingtool"}, soundfile = "active", pitchvariation = 0.1,
            location = Character.HumanoidRootPart
        })
        if Value_3 and r3_p29 then visualEffects("weldingfx", {weldfx = r3_p29, state = "start"}) end
        r1_p29 = 3
    end
    r25.repair:Play(0.2, 1, 1 / r1_p29)
    while true do
        if not RenderStepped:Wait() then break end
        if r2 <= tick() - r0_p29 then
            r0_p29 = tick() + r2
            local r4 = bFunctions:raycastline({
                point = Character.Head.Position,
                destination = CurrentCamera.CFrame.LookVector, range = 3,
                layermask = r42
            })
            if not r4 or not r4.Parent or not r4.Parent.Parent or not r4.Parent.Parent.Parent then break end
            if r4.Parent.Parent.Name ~= "trains" and r4.Parent.Parent.Parent.Name ~= "trains" then break end
            if core_checkers.internal_sound and core_checkers.internal_sound.Volume <= 0.3 then
                if workspace.serverStuff.values.gamemode_specific.train_track_on.trainhealth.Value >= workspace.serverStuff.values.gamemode_specific.train_track_on.trainhealthmax.Value then
                    break
                end
                local Parent = r4.Parent
                if r4.Parent.Parent.Parent.Name == "trains" then Parent = r4.Parent.Parent end
                bFunctions:soundHandler({
                    directory = {"train_sounds"},
                    pitchvariation = 0.1,
                    soundfile = "repair" .. math.random(1, 4),
                    location = Character.HumanoidRootPart
                })
                events.interaction_handler:Fire(Parent_2, "repair_wrench", Parent)
                if Value_2 == "weldingtool" and Value_3 and r3_p29 and r3_p29:FindFirstChild("welding") and r3_p29.welding.flash.Enabled == false then
                    visualEffects("weldingfx", {weldfx = r3_p29, state = "weldfx"})
                end
                if Humanoid ~= nil and Humanoid.Health > 0 and keysheld.m1 == true then continue end
                break
            end
            _G.popupmsg("repairinside", "#message_train_repairinside", 1)
            break
        end
    end
    r25.repair:Stop(0.2)
    if Value_2 == "weldingtool" then
        bFunctions:soundHandler({
            directory = {"tools", "weldingtool"}, soundfile = "deactive", pitchvariation = 0.1,
            location = Character.HumanoidRootPart
        })
        if not Value_3 or not r3_p29 then
            bFunctions:s_wait(0.15)
            action.Value = false
            return
        end
        visualEffects("weldingfx", {weldfx = r3_p29, state = "end"})
    end
    bFunctions:s_wait(0.15)
    action.Value = false
end
local function r83_0() -- Line: 4573 | Upvalues: ("r29" (copy), "r20" (ref), "core_checkers" (copy), "Parent_2" (copy), "Value_2" (ref), "Character" (copy), "action" (copy), "r25" (copy), "bFunctions" (copy), "keysheld" (copy), "RenderStepped" (copy), "events" (copy), "Humanoid" (copy), "weaponEffects" (copy), "r18" (ref), "Value_3" (copy), "shield_supplies" (ref))
    if tick() - r29.draw < r20.draw_speed / core_checkers.draw_modifier then return end
    if Parent_2:FindFirstChild("client_inactive") then return end
    if Value_2 == "nebel" and Character:FindFirstChild("equipment") and Character.equipment.Value <= 0 then
        return
    end
    local equipment = Character:FindFirstChild("equipment")
    action.Value = true
    local fire_rate = r20.fire_rate
    local r2 = tick()
    local r3 = true
    r25.prime:Play(0.2, 1, 1 / fire_rate)
    bFunctions:soundHandler({directory = {"tools", "shared"}, soundfile = "unready" .. math.random(1, 4), location = Character.HumanoidRootPart})
    keysheld.m1 = true
    repeat
        if keysheld.m1 ~= true and tick() - r2 <= 0.2 then
            r3 = false
            break
        end
        RenderStepped:Wait()
    until fire_rate <= tick() - r2
    if r3 == true then
        if Value_2 == "nebel" then
            equipment.Value -= 1
            core_checkers.equipment_show_cd = tick()
        end
        bFunctions:soundHandler({directory = {"tools", "shared"}, soundfile = "throw", location = Character.HumanoidRootPart})
        local client_inactive = Instance.new("StringValue")
        game:GetService("Debris"):AddItem(client_inactive, 2)
        client_inactive.Name = "client_inactive"
        client_inactive.Parent = Parent_2
        local r5_p30 = "throw_under"
        if core_checkers.aiming ~= true then
            r5_p30 = "throw_over"
            bFunctions:soundHandler({
                directory = {"tools", "shared"},
                soundfile = "throw_far" .. math.random(1, 2),
                location = Character.HumanoidRootPart
            })
        end
        if Value_2 == "nebel" then
            events.equipment_handler:Fire({tool = Parent_2, hand_thrown = r5_p30, lookvector = Character.Head.CFrame.lookVector})
        else
            events.interaction_handler:Fire(Parent_2, "throw_grenade", Character.Head.CFrame.lookVector, r5_p30)
        end
        r25[r5_p30]:Play(0.1, 1, 2)
        action.Value = false
        Humanoid:UnequipTools()
        if Value_2 ~= "nebel" or equipment.Value <= 0 then return end
        local __up4 = Value_2
        if r18 ~= "" then __up4 = r18 end
        weaponEffects("grenade_pin_return", {
            main = {
                char = Character,
                originweapon = __up4,
                weapon = Value_2,
                model = Value_3,
                module = r20,
                core = shield_supplies
            }
        })
        return
    end
    r25.prime:Stop(0.05)
    action.Value = false
end
local function r84_0(r0_p31, r1, r2) -- Line: 4676 | Upvalues: ("r44" (ref), "Character" (copy), "CurrentCamera" (copy), "Value_2" (ref), "Value_3" (copy), "shield_supplies" (ref), "bFunctions" (copy), "visualEffects" (copy), "r39" (copy), "events" (copy), "Parent_2" (copy))
    if r44 == nil then return end
    local __up0 = r44
    local r4 = Character.Head.Position - CurrentCamera.CFrame.LookVector * 0.4
    if Value_2 == "enfield" or Value_2 == "rooklauncher" or Value_2 == "crossbow" then
        r4 = Value_3.special.muzzle.Position - Value_3.special.muzzle.CFrame.lookVector
    end
    local LookVector = CFrame.new(r4, __up0).LookVector
    local r6, r7, r8, r9
    local r11
    local stim_colour
    local __up4
    if Value_2 == "stimbottle" then
        stim_colour = shield_supplies.stim_colour
        r11 = bFunctions:deepCopy(shield_supplies.stim_content)
        shield_supplies.stim_content = {}
        shield_supplies.stim_colour = Color3.fromRGB(199, 199, 199)
    end
    if Value_2 == "remington" then __up4 = Value_3 end
    visualEffects("projectile_fire", {
        wep = Value_2,
        org = r4,
        orgface = LookVector,
        speed = r0_p31,
        drop = r1,
        amtdrop = r2,
        lm = r39,
        extra = __up4
    })
    local r14 = 0
    for i_0 = 1, 100 do
        local r10 = r7
        r6, r7, r8, r9 = bFunctions:raycastline({
            point = r4,
            destination = LookVector,
            range = r0_p31,
            layermask = r39
        })
        if _G.debugline == true then bFunctions:debugline(r4, r7) end
        if r6 ~= nil then break end
        r4 = r7
        if r1 <= i_0 then LookVector -= Vector3.new(0, r2, 0) end
        r14 += r0_p31
        bFunctions:s_wait(0.03)
    end
    if r6 then
        local r15
        if (r6 and r6.Material == Enum.Material.Glass) and (r6.Name == "WindowBreakable" or r6.Name == "GlassWindow") then
            r15 = 3
            if Value_2 == "rooklauncher" then r15 = 5 end
            visualEffects("wood_impact", {
                point = r7,
                part_hit = r6,
                partcol = r6.Color, pellets = 1, glass = true
            })
            if r6.Name == "WindowBreakable" and not r6:FindFirstChild("pugsleypen") then
                visualEffects("bullet_hole", {
                    pos = r7,
                    normal = r8, glass = true,
                    forceparent = r6
                }, true)
                events.game_handler:Fire("window_impact", r6, r15)
            end
        end
        if Value_2 == "rooklauncher" then
            local r15 = false
            local r16 = r9 == Enum.Material.Rock or r9 == Enum.Material.Mud
            if workspace.serverStuff.values:FindFirstChild("miningrestrictions") then
                local r17_p31 = true
                if r9 ~= Enum.Material.Grass then
                    r17_p31 = true
                    if r9 ~= Enum.Material.LeafyGrass then r17_p31 = r9 == Enum.Material.Ground end
                end
                r16 = r17_p31
            end
            if r6 and r16 then r15 = true end
            if r7.Y <= 34 then r15 = false end
            if r15 == true then visualEffects("mine_impact", {point = r7}) end
            events.interaction_handler:Fire(Parent_2, "rooknade", r7, r15, r6, CFrame.new(r7, r4))
            if r6.Name == "breakpiecetopmanufacturing" then
                events.game_handler:Fire("hit_destructible", r6)
                return
            end
        else
            if Value_2 == "enfield" then
                events.interaction_handler:Fire(Parent_2, "enfieldgrenade", r7, r6, r14)
                return
            end
            if Value_2 == "throwaxe" then
                events.equipment_handler:Fire({
                    tool = Parent_2,
                    hit = r6,
                    point = r7,
                    origin = r4
                })
                if r6 and r6.Parent and r6.Parent:FindFirstChild("Humanoid") and r6.Parent.Humanoid.Health > 0 and r6.Parent.Parent ~= Character.Parent and r6.Parent:FindFirstChild("dreadnought") == nil then
                    visualEffects("bloodhitmarker_fx", {position = CFrame.new(r6.Position)}, true)
                    return
                end
            elseif Value_2 == "crossbow" then
                events.game_handler:Fire("crossbow_hit", {
                    tool = Parent_2,
                    hit = r6,
                    hitframe = r6.CFrame,
                    point = r7,
                    origin = r4
                })
                if r6 and r6.Parent and r6.Parent:FindFirstChild("Humanoid") and r6.Parent.Humanoid.Health > 0 and r6.Parent.Parent ~= Character.Parent and r6.Parent:FindFirstChild("dreadnought") == nil then
                    visualEffects("bloodhitmarker_fx", {position = CFrame.new(r6.Position)}, true)
                    return
                end
            elseif Value_2 == "remington" then
                events.interaction_handler:Fire(Parent_2, "thrown_remington_hit", r6, r7, r4, __up4)
                if r6 and r6.Parent and r6.Parent:FindFirstChild("Humanoid") and r6.Parent.Humanoid.Health > 0 and r6.Parent.Parent ~= Character.Parent and r6.Parent:FindFirstChild("dreadnought") == nil then
                    visualEffects("bloodhitmarker_fx", {position = CFrame.new(r6.Position)}, true)
                    return
                end
            elseif Value_2 == "stimbottle" then
                events.interaction_handler:Fire(Parent_2, "stimbottle", r7, {stims = r11, color = stim_colour})
            end
        end
    end
end
local function r85_0() -- Line: 4879 | Upvalues: ("r29" (copy), "r20" (ref), "core_checkers" (copy), "Character" (copy), "Value_3" (copy), "bFunctions" (copy), "shield_supplies" (ref), "action" (copy), "visualEffects" (copy), "Value_2" (ref), "r84_0" (copy), "r25" (copy))
    if tick() - r29.draw < r20.draw_speed / core_checkers.draw_modifier then return end
    if workspace.serverStuff.values.gamemode.Value == "truce" and Character:FindFirstChild("engage") == nil then
        return
    end
    if Character:FindFirstChild("oathbroken") then
        _G.popupmsg("brokenoath", "#message_brokenoath", 1)
        return
    end
    if Value_3 == nil or Value_3:FindFirstChild("special") == nil or Value_3.special:FindFirstChild("muzzle") == nil then
        return
    end
    local equipment = Character:FindFirstChild("equipment")
    core_checkers.equipment_show_cd = tick()
    bFunctions:soundHandler({directory = {"tools", "shared"}, soundfile = "click" .. math.random(1, 2), location = Character.HumanoidRootPart})
    if shield_supplies.ammo_mag <= 0 then return end
    action.Value = true
    core_checkers.sprint_block = true
    if _G.firing_movement_handler then
        _G.firing_movement_handler(r20.firing_movement, r20.firing_movement_last)
    end
    shield_supplies.ammo_mag -= 1
    core_checkers.equipment_show_cd = tick()
    core_checkers.equipment_ticker = tick()
    Character.equipment.Value = Character.equipment.Value - 1
    visualEffects("muzzle_flash", {point = Value_3.special.muzzle.CFrame, weapon_name = "rooklauncher", noflash = true})
    bFunctions:soundHandler({
        directory = {"tools", Value_2}, soundfile = "fire", pitchvariation = 0.1,
        location = Character.HumanoidRootPart
    })
    bFunctions:fast_spawn(function() -- Line: 4934 | Upvalues: ("r84_0" (upval))
        r84_0(6, 5, 0.02)
    end)
    core_checkers.jump_tick = tick()
    r25.fire:Stop(0)
    r25.fire_left:Stop(0)
    if core_checkers.flip_cam == true then
        r25.fire_left:Play(0.01, 1, 1)
    else
        r25.fire:Play(0.01, 1, 1)
    end
    bFunctions:s_wait(r20.fire_rate)
    core_checkers.sprint_block = false
    action.Value = false
end
local r86
local function r87_0(r0_p34) -- Line: 4960 | Upvalues: ("r29" (copy), "r25" (copy), "bFunctions" (copy), "Character" (copy), "Parent_2" (copy), "action" (copy))
    if r29.anim_swaps == nil then
        r25.shieldraised_idle.Priority = Enum.AnimationPriority.Action
        r25.shieldraised_aimed.Priority = Enum.AnimationPriority.Action2
        r29.anim_swaps = {r25.shieldraised_shoot, r25.shieldraised_empty, r25.shieldraised_idle, r25.shieldraised_aimed, r25.shoot, r25.shoot_empty, r25.held, r25.aim}
    end
    r25.aim:Stop(0.3)
    r25.held:Stop(0.3)
    bFunctions:soundHandler({
        directory = {"tools", "shared", "gsfx", "readysound"},
        soundfile = "ready" .. math.random(1, 4),
        location = Character.HumanoidRootPart
    })
    local r3 = {directory = {"tools", "shared"}}
    r3.soundfile = "large" .. math.random(1, 3)
    r3.location = Character.HumanoidRootPart
    bFunctions:soundHandler(r3)
    if r29.alt_mode == true then
        Parent_2.guarding.Value = false
        r25.held = r29.anim_swaps[7]
    else
        Parent_2.guarding.Value = true
        r25.held = r29.anim_swaps[3]
    end
    if r29.equipped == true then r25.held:Play(0.3, 1, 0.25) end
    r29.alt_mode = not r29.alt_mode
    if r0_p34 == true then
        action.Value = true
        bFunctions:s_wait(0.25)
        action.Value = false
    end
end
local function r88_0() -- Line: 5023 | Upvalues: ("r29" (copy), "r20" (ref), "core_checkers" (copy), "action" (copy), "Parent_2" (copy), "Humanoid" (copy), "Character" (copy), "bFunctions" (copy), "r25" (copy), "r84_0" (copy), "events" (copy))
    if tick() - r29.draw < r20.draw_speed / core_checkers.draw_modifier then return end
    if action.Value == true then return end
    if Parent_2:FindFirstChild("client_inactive") then return end
    if Humanoid:FindFirstChild("burning_light") or Humanoid:FindFirstChild("burning_heavy") then
        return
    end
    if workspace.serverStuff.values.gamemode.Value == "truce" and Character:FindFirstChild("engage") == nil then
        return
    end
    if Character:FindFirstChild("oathbroken") then
        _G.popupmsg("brokenoath", "#message_brokenoath", 1)
        return
    end
    action.Value = true
    bFunctions:soundHandler({directory = {"tools", "shared"}, soundfile = "large" .. math.random(2, 3), location = Character.HumanoidRootPart})
    r25.fire:Play(0.1, 1, 8)
    local client_inactive = Instance.new("StringValue")
    client_inactive.Name = "client_inactive"
    client_inactive.Parent = Parent_2
    bFunctions:s_wait(0.125)
    bFunctions:soundHandler({
        directory = {"tools", "remington"},
        pitchvariation = 0.1,
        soundfile = "throw_gun" .. math.random(1, 3),
        location = Character.HumanoidRootPart
    })
    bFunctions:fast_spawn(function() -- Line: 5071 | Upvalues: ("r84_0" (upval))
        r84_0(8, 2, 0.02)
    end)
    r25.throw_over:Play(0.1, 1, 1)
    events.interaction_handler:Fire(Parent_2, "throw_remington")
    action.Value = false
    Humanoid:UnequipTools()
end
local function r89_0() -- Line: 5084 | Upvalues: ("r29" (copy), "r20" (ref), "core_checkers" (copy), "Character" (copy), "bFunctions" (copy), "shield_supplies" (ref), "action" (copy), "events" (copy), "Parent_2" (copy), "weaponEffects" (copy), "Value_2" (ref), "r18" (ref), "Value_3" (copy), "r25" (copy), "r84_0" (copy))
    if tick() - r29.draw < r20.draw_speed / core_checkers.draw_modifier then return end
    if workspace.serverStuff.values.gamemode.Value == "truce" and Character:FindFirstChild("engage") == nil then
        return
    end
    if Character:FindFirstChild("oathbroken") then
        _G.popupmsg("brokenoath", "#message_brokenoath", 1)
        return
    end
    bFunctions:soundHandler({directory = {"tools", "crossbow"}, soundfile = "trigger", location = Character.HumanoidRootPart})
    if shield_supplies.ammo_mag <= 0 then return end
    action.Value = true
    events.game_handler:Fire("crossbow_state_handler", Parent_2, false)
    bFunctions:soundHandler({directory = {"tools", "crossbow"}, soundfile = "fire", location = Character.HumanoidRootPart})
    local r2 = {transp = 1}
    local __up10 = Value_2
    if r18 ~= "" then __up10 = r18 end
    r2.main = {
        char = Character,
        originweapon = __up10,
        weapon = Value_2,
        model = Value_3,
        module = r20,
        core = shield_supplies
    }
    weaponEffects("crossbow_bolt_visibility", r2)
    shield_supplies.ammo_mag = 0
    core_checkers.sprint_block = true
    core_checkers.jump_tick = tick()
    r25.fire:Stop(0)
    r25.fire_left:Stop(0)
    r25.locked:Stop(0.03)
    r29.slide_locked = false
    local r0_p38 = 2
    local r1 = 0.02
    if Character:FindFirstChild("perk") and Character.perk.Value == "marksman" then
        r0_p38 = 6
        r1 = 0.01
    end
    bFunctions:fast_spawn(function() -- Line: 5141 | Upvalues: ("r84_0" (upval), "r0_p38" (ref), "r1" (ref))
        r84_0(8, r0_p38, r1)
    end)
    r25.speen:Play(0.1, 1, 1)
    r2 = "fire"
    if core_checkers.flip_cam == true then r2 = "fire_left" end
    r25[r2]:Play(0.01, 1, 3)
    bFunctions:s_wait(r20.fire_rate)
    core_checkers.sprint_block = false
    action.Value = false
end
local function r90_0() -- Line: 5162 | Upvalues: ("r29" (copy), "r20" (ref), "core_checkers" (copy), "Character" (copy), "Parent_2" (copy), "shield_supplies" (ref), "action" (copy), "weaponEffects" (copy), "Value_2" (ref), "r18" (ref), "Value_3" (copy), "visualEffects" (copy), "bFunctions" (copy), "r84_0" (copy), "r25" (copy))
    if tick() - r29.draw < r20.draw_speed / core_checkers.draw_modifier then return end
    if workspace.serverStuff.values.gamemode.Value == "truce" and Character:FindFirstChild("engage") == nil then
        return
    end
    if Character:FindFirstChild("oathbroken") then
        _G.popupmsg("brokenoath", "#message_brokenoath", 1)
        return
    end
    if Parent_2:FindFirstChild("gl_uses") == nil then return end
    if Parent_2.gl_uses.Value <= 0 then return end
    if shield_supplies.ammo_mag <= 0 or shield_supplies.blank_round_loaded == nil or shield_supplies.blank_round_loaded == false then
        return
    end
    action.Value = true
    Parent_2.gl_uses.Value = Parent_2.gl_uses.Value - 1
    core_checkers.sprint_block = true
    shield_supplies.ammo_mag -= 1
    shield_supplies.blank_round_loaded = false
    local __up8 = Value_2
    if r18 ~= "" then __up8 = r18 end
    weaponEffects("riflegrenade_fired", {
        main = {
            char = Character,
            originweapon = __up8,
            weapon = Value_2,
            model = Value_3,
            module = r20,
            core = shield_supplies
        }
    })
    visualEffects("muzzle_flash", {point = Value_3.special.muzzle.CFrame, weapon_name = "rooklauncher", noflash = true})
    bFunctions:soundHandler({
        directory = {"tools", Value_2}, soundfile = "blank", pitchvariation = 0.1,
        location = Character.HumanoidRootPart
    })
    bFunctions:fast_spawn(function() -- Line: 5213 | Upvalues: ("r84_0" (upval))
        r84_0(8, 5, 0.02)
    end)
    core_checkers.jump_tick = tick()
    r25.fire:Stop(0)
    r25.fire_left:Stop(0)
    local r0_p40 = "fire"
    if core_checkers.flip_cam == true then r0_p40 = "fire_left" end
    r25[r0_p40]:Play(0.01, 1, 1)
    bFunctions:s_wait(r20.fire_rate)
    core_checkers.sprint_block = false
    action.Value = false
end
local r91 = tick()
local r92
r92 = function(r0_p47) -- Line: 5239 | Upvalues: ("r29" (copy), "r20" (ref), "core_checkers" (copy), "r44" (ref), "Humanoid" (copy), "Character" (copy), "Value_2" (ref), "Parent_2" (copy), "bFunctions" (copy), "r90_0" (copy), "r89_0" (copy), "shield_supplies" (ref), "r76_0" (copy), "Value_3" (copy), "visualEffects" (copy), "weaponEffects" (copy), "r18" (ref), "action" (copy), "r25" (copy), "LocalPlayer" (copy), "r73_0" (ref), "r42" (copy), "base" (copy), "RenderStepped" (copy), "r66_0" (ref), "r40" (copy), "r91" (ref), "CurrentCamera" (copy), "events" (copy), "Mouse" (copy), "r70_0" (copy), "keysheld" (copy), "r92" (ref), "r77" (ref), "r71" (ref), "r74_0" (copy))
    if r29.shorted == true then return end
    if tick() - r29.draw < r20.draw_speed / core_checkers.draw_modifier then return end
    if r29.equipped == false and r0_p47 ~= true then return end
    if core_checkers.jumped_air == true then return end
    if r44 == nil then return end
    if Humanoid:FindFirstChild("burning_heavy") then return end
    local r1_p47 = tick() - core_checkers.fall_damage_interrupt
    if r1_p47 <= 0 then return end
    if workspace.serverStuff.values.gamemode.Value == "truce" and Character:FindFirstChild("engage") == nil then
        return
    end
    if workspace.serverStuff.medievalmode.Value == true and Value_2 ~= "crossbow" then
        _G.popupmsg("guninmedieval", "#message_deny_medieval", 1)
        return
    end
    if Character:FindFirstChild("oathbroken") then
        _G.popupmsg("brokenoath", "#message_brokenoath", 1)
        return
    end
    if Parent_2:FindFirstChild("client_inactive") or Parent_2:FindFirstChild("inactive") then return end
    local r3_p47
    if Value_2 ~= "crossbow" then
        r3_p47 = {directory = {"tools", "shared"}}
        r3_p47.soundfile = "click" .. math.random(1, 2)
        r3_p47.location = Character.HumanoidRootPart
        bFunctions:soundHandler(r3_p47)
    end
    r29.fire_buffer = 0
    if Value_2 == "enfield" and r29.alt_mode == true then
        r90_0()
        return
    end
    if Value_2 == "crossbow" then
        r89_0()
        return
    end
    if shield_supplies.force_block_fire == true then
        if Value_2 ~= "lebel" or r29.alt_mode ~= false or shield_supplies.ammo_mag <= 0 then return end
        r76_0()
        shield_supplies.force_block_fire = false
        return
    end
    repeat
        r1_p47 = nil
        local r2 = {}
        if Value_2 ~= "walker" then break end
        if not _G["walkerstate" .. Parent_2.slot.Value] or not _G["walkercylinder" .. Parent_2.slot.Value] then
            return
        end
        local r3_p47 = _G["walkerstate" .. Parent_2.slot.Value][_G["walkercylinder" .. Parent_2.slot.Value]]
        if not r3_p47 then break end
        r2[1] = r3_p47.cap
        r2[2] = r3_p47.ball
        r2[3] = r3_p47.powder
        local ball = r3_p47.ball
        if r3_p47.cap == true and r3_p47.powder ~= false then
            shield_supplies.ammo_mag = 1
            r3_p47.ball = false
        else
            shield_supplies.ammo_mag = 0
        end
        if r3_p47.cap == true then
            bFunctions:soundHandler({
                directory = {"tools", "walker"}, soundfile = "cap", pitchvariation = 0.1,
                location = Character.HumanoidRootPart
            })
            local __G = Value_3.parts.cylinder:FindFirstChild("round" .. _G["walkercylinder" .. Parent_2.slot.Value])
            if __G then
                local r6
                if r3_p47.powder ~= false then r6 = __G end
                visualEffects("muzzle_flash", {
                    point = Value_3.parts.cylinder.CFrame + Value_3.parts.cylinder.CFrame.lookVector * 0.5,
                    after_smoke = r6, weapon_size = 1, weapon_name = "lebel", noflash = true,
                    class_use = Character:FindFirstChild("class")
                })
            end
            if r3_p47.powder ~= false then
                if r3_p47.powder <= 0.2 then
                    r1_p47 = "veryweakload"
                elseif r3_p47.powder < 0.5 then
                    r1_p47 = "weakload"
                end
                if ball == false then r1_p47 = r1_p47 == nil and "noball" or r1_p47 .. "noball" end
                r3_p47.powder = false
            end
            r3_p47.cap = "fired"
        end
        local __up6 = Value_2
        if r18 ~= "" then __up6 = r18 end
        weaponEffects("walker_setstate", {
            main = {
                char = Character,
                originweapon = __up6,
                weapon = Value_2,
                model = Value_3,
                module = r20,
                core = shield_supplies
            },
            walker_slot = _G["walkercylinder" .. Parent_2.slot.Value],
            walker_state = r3_p47
        })
        local __G, r6 = _G, "walkercylinder" .. Parent_2.slot.Value
        __G[r6] += 1
        if _G["walkercylinder" .. Parent_2.slot.Value] <= 6 then break end
        _G["walkercylinder" .. Parent_2.slot.Value] = 1
        break
    until true
    local r3_p47 = r20.fire_rate * 0.9
    local r4 = true
    local r5_p47 = true
    if Value_2 == "lever" then
        r3_p47 = 0.725
        r5_p47 = false
        if Character.perk.Value == "vet" then
            r5_p47 = true
            r4 = false
        end
    end
    local r6 = false
    local r7 = (Parent_2:FindFirstChild("akimbo") and Parent_2.akimbo.Value == true) and true
    local r8 = "locked"
    if Parent_2:FindFirstChild("akimbo") and Parent_2.akimbo.Value == false and r29.dual_wield_active == true then
        r8 = "akimbo_locked"
    end
    local r9
    if Value_2 == "pieper" and r29.slide_locked == false then
        r9 = 0.15
        if _G.pieper_alt == true then r9 = 0.25 end
        action.Value = true
        bFunctions:soundHandler({directory = {"tools", Value_2, "sfx"}, soundfile = "hammer", location = Character.HumanoidRootPart})
        delay(r9 / 1.5, function() -- Line: 5462 | Upvalues: ("bFunctions" (upval), "Value_2" (upval), "Character" (upval))
            bFunctions:soundHandler({
                directory = {"tools", Value_2, "sfx"}, soundfile = "rotate_cylinder",
                location = Character.HumanoidRootPart
            })
        end)
        local __up6 = Value_2
        if r18 ~= "" then __up6 = r18 end
        weaponEffects("cylinder_rotate", {
            main = {
                char = Character,
                originweapon = __up6,
                weapon = Value_2,
                model = Value_3,
                module = r20,
                core = shield_supplies
            },
            speedval = r9
        })
        r29.slide_locked = true
        r25[r8]:Play(r9)
        if r7 == false then r25.hammer_pull:Play(0.1, 0.1, 3) end
        bFunctions:s_wait(r9)
        if _G.pieper_alt == true then
            action.Value = false
            return
        end
    end
    if Value_2 == "trench" and shield_supplies.ammo_mag <= 0 and r29.slide_locked == false then
        bFunctions:soundHandler({directory = {"tools", Value_2}, soundfile = "empty", location = Character.HumanoidRootPart})
        r29.slide_locked = true
        r25[r8]:Play(0.05)
        return
    end
    local size
    if shield_supplies.ammo_mag <= 0 then
        if not r25.fire_empty or r4 ~= true then return end
        bFunctions:soundHandler({directory = {"tools", Value_2}, soundfile = "empty", location = Character.HumanoidRootPart})
        action.Value = true
        local r9 = false
        if r0_p47 == true then
            local muzzle = Character:FindFirstChild("Bulwark's Shield") or Character:FindFirstChild("Cavalry Sword")
            if Character:FindFirstChild("perk") and Character.perk.Value == "akimbo" then
                size = Character:FindFirstChildOfClass("Tool")
                if size:FindFirstChild("akimbo") and size.akimbo.Value == true then
                    r9 = true
                    muzzle = size
                end
            end
            if muzzle and muzzle:FindFirstChild("event") then muzzle.event:Fire("dual_shoot_empty") end
        elseif Parent_2:FindFirstChild("akimbo") and Parent_2.akimbo.Value == true then
            r25.akimbo_right_empty:Play(0, 1, 1)
        end
        r25.fire:Stop(0)
        if r25.fire_left then r25.fire_left:Stop(0) end
        if r25.fire_empty_left then r25.fire_empty_left:Stop(0) end
        r25.fire_empty:Stop(0)
        if r25.akimbo_fire_empty then r25.akimbo_fire_empty:Stop(0) end
        if r25.cycle then r25.cycle:Stop(0) end
        if r25.cycle_left then r25.cycle_left:Stop(0) end
        if r25.fire_empty_left ~= nil and core_checkers.flip_cam == true and r0_p47 ~= true and r7 == false then
            r25.fire_empty.Priority = Enum.AnimationPriority.Action2
            r6 = true
        end
        local muzzle = "fire_empty"
        if r9 == true then muzzle = "akimbo_fire_empty" end
        r25[muzzle]:Play(0.01, 1, 1 / r3_p47)
        if r6 == true then
            r25.fire_empty_left:Play(0.01, 1, 1 / r3_p47)
            delay(r3_p47 * 0.8, function() -- Line: 5572 | Upvalues: ("r25" (upval))
                r25.fire_empty.Priority = Enum.AnimationPriority.Action3
                r25.fire_empty:Stop(0)
            end)
        end
        bFunctions:s_wait(r20.fire_rate)
        action.Value = false
        return
    end
    if Value_2 == "dbgun" then r29.db_othershell = false end
    action.Value = true
    if Value_2 == "mpgun" or Value_2 == "lewis" then
        r3_p47 = 0.5
        if r0_p47 ~= "autoshot" then
            bFunctions:soundHandler({
                directory = {"tools", "shared"},
                soundfile = "prefire" .. math.random(1, 2),
                location = Character.HumanoidRootPart
            })
            bFunctions:s_wait(0.08)
        end
    end
    core_checkers.force_jump_tick = tick()
    if not LocalPlayer.Character:FindFirstChild("cowboy") or not LocalPlayer.Character:FindFirstChild("elitekit") or LocalPlayer.Character.elitekit.Value ~= "ocelot" then
        core_checkers.sprint_block = true
    end
    if _G.firing_movement_handler then
        _G.firing_movement_handler(r20.firing_movement, r20.firing_movement_last, Value_2 == "lewis" and true)
    end
    shield_supplies.ammo_mag -= 1
    local muzzle = Value_3.special.muzzle
    local r15
    if Parent_2:FindFirstChild("mounted_weapon") and Parent_2.mounted_weapon.Value and Parent_2.mounted_weapon.Value:FindFirstChild("rig") and Parent_2.mounted_weapon.Value.rig:FindFirstChild("mg") and Parent_2.mounted_weapon.Value.rig.mg:FindFirstChild("muzzle") then
        muzzle = Parent_2.mounted_weapon.Value.rig.mg.muzzle
        if Parent_2.mounted_weapon.Value.rig.mg:FindFirstChild("ejection") then
            r15 = Value_2
            if r18 ~= "" then r15 = r18 end
            weaponEffects("eject_casing", {
                main = {
                    char = Character,
                    originweapon = r15,
                    weapon = Value_2,
                    model = Value_3,
                    module = r20,
                    core = shield_supplies
                },
                force_ejection_area = Parent_2.mounted_weapon.Value.rig.mg.ejection.CFrame
            })
        end
    end
    local size = r20.size
    if r18 == "steyrvariant" then size = 1 end
    local r12 = "fire"
    visualEffects("muzzle_flash", {
        point = muzzle.CFrame,
        after_smoke = muzzle,
        weapon_size = size,
        weapon_name = Value_2,
        class_use = Character:FindFirstChild("class")
    })
    local r17_p47
    if Value_3:FindFirstChild("cylinder") and Value_2 ~= "walker" then
        r17_p47 = Value_2
        if r18 ~= "" then r17_p47 = r18 end
        weaponEffects("cylinder_fire", {
            main = {
                char = Character,
                originweapon = r17_p47,
                weapon = Value_2,
                model = Value_3,
                module = r20,
                core = shield_supplies
            }
        })
    end
    local r13_p47 = "fire"
    local r16_p47, r18_p47
    if Value_2 == "walker" and r2[3] ~= false then
        if r2[3] < 0.5 then
            r12 = "fire_weak"
            r13_p47 = "fire_weak"
            if r2[3] <= 0.2 then size = 1 end
        else
            size = 3
        end
        if r2[3] >= 1 then
            r12 = "fire_break"
            bFunctions:soundHandler({directory = {"tools", "walker"}, soundfile = "walker_break", location = Character.HumanoidRootPart})
            r16_p47 = {}
            r18_p47 = Value_2
            if r18 ~= "" then r18_p47 = r18 end
            r16_p47.main = {
                char = Character,
                originweapon = r18_p47,
                weapon = Value_2,
                model = Value_3,
                module = r20,
                core = shield_supplies
            }
            weaponEffects("walker_cylinderbreak", r16_p47)
        end
    end
    if Value_2 == "scho" and Value_3:FindFirstChild("parts") and Value_3.parts:FindFirstChild("break") and Value_3.parts["break"]:FindFirstChild("snubbarrel") and Value_3.parts["break"].snubbarrel.Transparency == 0 then
        r13_p47 = "firesnub"
    end
    if r18 == "piepervariant" or r18 == "springfieldvariant" or r18 == "autosgvariant" or r18 == "dbgunvariant" or r18 == "henryvariant" or r18 == "levervariant" or r18 == "remingtonvariant" or r18 == "saavariant" then
        r13_p47 = "variantfire"
    end
    if Value_2 == "springfield" and r29.alt_mode == true then
        r13_p47 = "pedersen_fire"
        if r29.jam_count then r29.jam_count -= 1 end
        local r16_p47
        local r18_p47
        local r17_p47
        if r29.jam_count <= 0 then
            r29.jam_count = math.random(7, 18)
            r29.jammed = true
            r16_p47 = {}
            r18_p47 = Value_2
            if r18 ~= "" then r18_p47 = r18 end
            r17_p47 = {
                char = Character,
                originweapon = r18_p47,
                weapon = Value_2,
                model = Value_3,
                module = r20,
                core = shield_supplies
            }
            r16_p47.main = r17_p47
            weaponEffects("springfield_pedersen_jammed", r16_p47)
        else
            r16_p47 = {}
            r18_p47 = Value_2
            if r18 ~= "" then r18_p47 = r18 end
            r17_p47 = {
                char = Character,
                originweapon = r18_p47,
                weapon = Value_2,
                model = Value_3,
                module = r20,
                core = shield_supplies
            }
            r16_p47.main = r17_p47
            weaponEffects("eject_casing", r16_p47)
        end
    end
    if Value_2 == "lewis" then
        local __up6 = Value_2
        if r18 ~= "" then __up6 = r18 end
        weaponEffects("lewis_rotate", {
            main = {
                char = Character,
                originweapon = __up6,
                weapon = Value_2,
                model = Value_3,
                module = r20,
                core = shield_supplies
            }
        })
    end
    local r14_p47
    local r15 = 0.1
    if r0_p47 == "autoshot" then
        r14_p47 = -0.5
        r15 = 0.05
    end
    bFunctions:soundHandler({
        directory = {"tools", Value_2},
        soundfile = r13_p47,
        pitchvariation = r15, client_volume = 0.3, gun_volume = true,
        volume_adjust = r14_p47,
        location = Character.HumanoidRootPart
    })
    local r16_p47 = "medium"
    if r20.size == 1 or Value_2 == "lever" then r16_p47 = "small" end
    if r20.pellets > 1 then r16_p47 = "shotgun" end
    if Value_2 == "henry" or Value_2 == "pugsley" then r16_p47 = "large" end
    if r18 == "steyrvariant" or r18 == "saavariant" then r16_p47 = "small" end
    if r18 == "henryvariant" then r16_p47 = "medium" end
    if r20.special.suppressed == true then r16_p47 = "suppressor" end
    if Value_2 == "walker" and r2[3] ~= false then
        r16_p47 = r2[3] <= 0.2 and "small" or r2[3] >= 0.5 and "large" or "medium"
    end
    r73_0 = true
    bFunctions:soundHandler({
        directory = {"atmos", r16_p47},
        pitchvariation = 0.3,
        gun_volume = true,
        soundfile = "loud_" .. math.random(1, 3),
        volume_adjust = r14_p47,
        location = Character.HumanoidRootPart
    })
    local r19_p47 = {directory = {"atmos", r16_p47}, gun_volume = true, pitchvariation = 0.1}
    r19_p47.soundfile = "distant_" .. math.random(1, 3)
    r19_p47.location = Character.HumanoidRootPart
    bFunctions:soundHandler(r19_p47)
    if Value_2 == "pugsley" then
        r19_p47 = {directory = {"tools", Value_2}, pitchvariation = 0.1}
        r19_p47.soundfile = "echo" .. math.random(1, 3)
        r19_p47.location = Character.HumanoidRootPart
        bFunctions:soundHandler(r19_p47)
        if _G.ear_ring then _G.ear_ring(1000) end
        if Character.class.Value ~= "rook" and _G.knockback_effect then
            _G.knockback_effect(10, (Character.HumanoidRootPart.CFrame - Character.HumanoidRootPart.CFrame.lookVector * 5).Position)
        end
    end
    local r17_p47 = -1
    local r18_p47 = -1
    if r25.fire_last and shield_supplies.ammo_mag <= 0 and r5_p47 == true then r12 = "fire_last" end
    r19_p47 = false
    local r20_p47 = false
    if core_checkers.aiming == false and r25.hipfire then r19_p47 = true end
    if Value_2 == "saa" and r29.alt_mode == true then r19_p47 = true end
    local r22_p47, r23_p47
    if r19_p47 == true then
        r12 = "hipfire"
        r3_p47 = 1
        local pellets = Character["Right Arm"]
        if r20.lefthand == true then pellets = Character["Left Arm"] end
        r22_p47, r23_p47 = bFunctions:raycastline({
            point = pellets.Position - Character.HumanoidRootPart.CFrame.lookVector * 1,
            destination = Character.Head.CFrame.lookVector,
            range = r20.length,
            layermask = r42
        })
        if r22_p47 then r20_p47 = true end
    end
    local pellets = r20.pellets
    if Value_2 == "springfield" and r29.alt_mode == true then r1_p47 = "pedersen" end
    if r25.cycle and Value_2 ~= "enfield" then r3_p47 = 1 end
    if Value_2 == "springfield" and r29.alt_mode == true then r3_p47 = 0.5 end
    if Value_2 == "mares" and r29.alt_mode == true and r0_p47 ~= true and Character:FindFirstChild("perk") and Character.perk.Value ~= "akimbo" then
        r29.slide_locked = true
        local locked = r25.locked
        if Parent_2:FindFirstChild("akimbo") and Parent_2.akimbo.Value == false and r29.dual_wield_active == true then
            locked = r25.akimbo_locked
        end
        if locked then locked:Play(0.1) end
        if shield_supplies.ammo_mag > 0 then
            delay(0.25, function() -- Line: 5901 | Upvalues: ("r25" (upval))
                r25.spin_right:Play(0.1, 1, 2)
            end)
        end
    end
    local r22_p47
    local r24_p47
    if r0_p47 == true then
        r22_p47 = Character:FindFirstChild("Bulwark's Shield") or Character:FindFirstChild("Cavalry Sword")
        local r23_p47 = false
        if Character:FindFirstChild("perk") and Character.perk.Value == "akimbo" then
            r24_p47 = Character:FindFirstChildOfClass("Tool")
            if r24_p47:FindFirstChild("akimbo") and r24_p47.akimbo.Value == true then
                r23_p47 = true
                r22_p47 = r24_p47
            end
        end
        if r22_p47 and r22_p47:FindFirstChild("event") then
            if r23_p47 == true then r12 = "akimbo_fire" end
            r22_p47.event:Fire("dual_shoot", shield_supplies.ammo_mag, 0.6 / r3_p47)
        end
        if Value_2 == "mares" then
            r12 = ""
            r29.slide_locked = true
            r24_p47 = r25.locked
            if Parent_2:FindFirstChild("akimbo") and Parent_2.akimbo.Value == false and r29.dual_wield_active == true then
                r24_p47 = r25.akimbo_locked
            end
            if r24_p47 then r24_p47:Play(0.1) end
            if shield_supplies.ammo_mag > 0 then
                r24_p47 = "spin_left"
                if r22_p47 and r22_p47.Name == "Bulwark's Shield" then r24_p47 = "spin_right" end
                delay(0.25, function() -- Line: 5934 | Upvalues: ("r25" (upval), "r24_p47" (ref))
                    r25[r24_p47]:Play(0.1, 1, 2)
                end)
            end
        end
    elseif Parent_2:FindFirstChild("akimbo") and Parent_2.akimbo.Value == true then
        r25.akimbo_right:Play(0.01, 1, 0.6 / r3_p47)
        if Value_2 == "mares" then
            r12 = ""
            r29.slide_locked = true
            r22_p47 = r25.locked
            if Parent_2:FindFirstChild("akimbo") and Parent_2.akimbo.Value == false and r29.dual_wield_active == true then
                r22_p47 = r25.akimbo_locked
            end
            if r22_p47 then r22_p47:Play(0.1) end
            if shield_supplies.ammo_mag > 0 then
                delay(0.25, function() -- Line: 5947 | Upvalues: ("r25" (upval))
                    r25.spin_right:Play(0.1, 1, 2)
                end)
            end
        end
    end
    if r25[r12 .. "_left"] ~= nil and core_checkers.flip_cam == true and r0_p47 ~= true and r7 == false then
        r25[r12 .. "_left"]:Stop(0)
        r6 = true
        r25[r12].Priority = Enum.AnimationPriority.Action2
    end
    if Parent_2:FindFirstChild("bipod") and r25.bipod_fire and tick() - Parent_2.bipod.Value <= base.bulwark_buffer then
        r12 = "bipod_fire"
    end
    if r25[r12] then
        r25[r12]:Stop(0)
        r25[r12]:Play(0.01, 1, 1 / r3_p47)
    end
    if r6 == true and r25[r12 .. "_left"] then
        r25[r12 .. "_left"]:Play(0.01, 1, 1 / r3_p47)
        delay(r3_p47 * 0.8, function() -- Line: 5974 | Upvalues: ("r25" (upval), "r12" (ref))
            r25[r12].Priority = Enum.AnimationPriority.Action3
            r25[r12]:Stop(0)
        end)
        if r25.cycle then RenderStepped:Wait() end
    end
    r22_p47 = true
    for i_0 = 1, pellets do
        if Character:FindFirstChild("execing") or r44 == nil then break end
        if i_0 > 1 then r22_p47 = false end
        local ambi_penalty_2 = r20.accuracy / 10
        if tick() - core_checkers.moving_accuracy >= 0 or core_checkers.in_air == true then
            ambi_penalty_2 = r20.moving_accuracy / 10
        end
        if Value_2 == "walker" then
            if r2[3] <= 0.2 then ambi_penalty_2 = r20.moving_accuracy / 20 end
            if r2[2] == "half" then
                ambi_penalty_2 = r20.moving_accuracy / 10
            elseif r2[2] == false then
                ambi_penalty_2 = 0
            end
        end
        if r19_p47 == true then
            if Value_2 == "saa" then
                ambi_penalty_2 = Character.Humanoid.MoveDirection.Magnitude > 0.1 and 8 or 6
                if r29.alt_mode == true then
                    ambi_penalty_2 = 0
                    r1_p47 = "quickdraw"
                elseif Character:FindFirstChild("elitekit") and Character.elitekit.Value == "ocelot" then
                    ambi_penalty_2 = 2.75
                end
            end
        elseif Value_2 == "saa" and Character:FindFirstChild("elitekit") and Character.elitekit.Value == "ocelot" then
            ambi_penalty_2 = 0
        end
        r66_0 = tick()
        if pellets == 1 then ambi_penalty_2 /= core_checkers.accuracy_modifier end
        if Parent_2:FindFirstChild("bipod") and tick() - Parent_2.bipod.Value <= base.bulwark_buffer and tick() - core_checkers.moving_accuracy < 0 and core_checkers.in_air == false then
            ambi_penalty_2 = 0.2
        end
        ambi_penalty_2 *= 10
        local r27 = Value_3.special.muzzle.CFrame - Value_3.special.muzzle.CFrame.lookVector * r20.length
        if Parent_2:FindFirstChild("mounted_weapon") and Parent_2.mounted_weapon.Value and Parent_2.mounted_weapon.Value:FindFirstChild("rig") and Parent_2.mounted_weapon.Value.rig:FindFirstChild("mg") and Parent_2.mounted_weapon.Value.rig.mg:FindFirstChild("muzzle") then
            r27 = Parent_2.mounted_weapon.Value.rig.mg.muzzle.CFrame
        end
        if r20_p47 == true then r27 = Character.Head.CFrame - Character.Head.CFrame.lookVector * 1 end
        local r28_p47 = (r27.RightVector * math.random(-ambi_penalty_2, ambi_penalty_2) + r27.UpVector * math.random(-ambi_penalty_2, ambi_penalty_2)) / 1000
        if pellets > 1 then
            local r29_p47 = ambi_penalty_2 / 1000
            if pellets == 5 and r18 == "autosgvariant" then
                if i_0 == 1 then
                    r17_p47 = 0
                    r18_p47 = 0
                elseif i_0 == 2 then
                    r17_p47 = -2
                    r18_p47 = 0
                elseif i_0 == 3 then
                    r17_p47 = 2
                    r18_p47 = 0
                elseif i_0 == 4 then
                    r17_p47 = 0
                    r18_p47 = -2
                elseif i_0 == 5 then
                    r17_p47 = 0
                    r18_p47 = 2
                end
            end
            r28_p47 = r27.RightVector * r29_p47 * r17_p47 + r27.UpVector * r29_p47 * r18_p47
            r17_p47 += 1
            if r17_p47 >= 2 then
                r17_p47 = -1
                r18_p47 += 1
            end
        end
        if core_checkers.holding_breath == true and core_checkers.hold_breathaccuracy <= tick() - core_checkers.hold_breathtime and pellets == 1 and r29.no_steady_acc == false then
            r28_p47 = vector.create(0, 0, 0)
        end
        if Parent_2:FindFirstChild("scoped") and Parent_2.scoped.Value == true then
            r28_p47 = vector.create(0, 0, 0)
        end
        local r29_p47 = CFrame.new(r27.Position, r44).LookVector + r28_p47
        if Parent_2:FindFirstChild("mounted_weapon") and Parent_2.mounted_weapon.Value and Parent_2.mounted_weapon.Value:FindFirstChild("rig") and Parent_2.mounted_weapon.Value.rig:FindFirstChild("mg") and Parent_2.mounted_weapon.Value.rig.mg:FindFirstChild("muzzle") then
            r27 = Parent_2.mounted_weapon.Value.rig.mg.muzzle
            r29_p47 = Parent_2.mounted_weapon.Value.rig.mg.muzzle.CFrame.LookVector + r28_p47
        end
        local r30 = 3
        local r31 = math.min(5, 1 + r20.wallpen * 1)
        local r32 = math.min(70, 10 + r20.wallpen * 20)
        if r1_p47 == "pedersen" then
            r31 = 2
            r32 = 30
        end
        if Value_2 == "pugsley" then r30 = 4 end
        local r33 = 500
        if Value_2 == "walker" then
            if r2[3] < 0.5 then
                r31 = 2
                r32 = 30
            end
            if r2[2] == false then
                r33 = 3
                r31 = 0
                r32 = 0
            end
        end
        if workspace.serverStuff.trainingmode.Value == true then
            r31 = 0
            r32 = 0
        end
        local r34_p47 = false
        local r35
        for i_1 = 1, r30 do
            local r39, Position, r41, r42_p47 = bFunctions:raycastline({
                point = r27.Position,
                destination = r35 or r29_p47,
                range = r33, bullet = true,
                atmos = r16_p47,
                layermask = r40
            })
            if r27 == nil or Position == nil then break end
            if Character:FindFirstChild("bodyshield") and Character.bodyshield.Value:FindFirstChild("Humanoid") and Character.bodyshield.Value.Humanoid.Health > 0 and Character.bodyshield.Value:FindFirstChild("HeadHitbox") and core_checkers.aiming == false then
                r39 = Character.bodyshield.Value.HeadHitbox
                Position = Character.bodyshield.Value.HeadHitbox.Position
            end
            local magnitude = (r27.Position - Position).magnitude
            if (magnitude < 20 and i_1 < 2) and (r20.special and r20.special.incendiary and r20.special.incendiary == true) then
                visualEffects("bullet_tracer", {
                    startpoint = r27.Position,
                    endpoint = Position,
                    pelletsfired = pellets,
                    snap = r22_p47,
                    atmos_using = r16_p47
                })
            end
            if r20.special and r20.special.incendiary and r20.special.incendiary == true then
                if r39 then
                    visualEffects("phos_impact", {posat = CFrame.new(Position, Character.HumanoidRootPart.Position)})
                end
                visualEffects("phos_trail", {startpoint = Value_3.special.muzzle.Position, endpoint = Position})
            end
            local r44_p47 = false
            local r45 = false
            if r39 and r39.Parent:FindFirstChild("invuln") == nil then
                local r51
                local r48
                local r50_p47
                if r39.Parent:FindFirstChild("Humanoid") and (r39.Parent.Humanoid.Health > 0 or r39.Parent.Parent == workspace.bodies) then
                    r44_p47 = true
                    if r39.Parent:FindFirstChild("dreadnought") then
                        visualEffects("mine_impact", {
                            weapon = Value_2,
                            normal = r41,
                            from = Value_3.special.muzzle.Position,
                            point = r39.Position, headhit = true,
                            ricochet = math.random(1, 2)
                        })
                    else
                        if r39.Parent:FindFirstChild("helmet") and r39.Name == "HeadHitbox" and r39:FindFirstChild("helmet_lifted") == nil and r39.Parent.Parent ~= workspace.bodies and tick() - r91 >= 0.1 then
                            r91 = tick()
                            r51 = true
                            bFunctions:soundHandler({
                                directory = {"ui"}, soundfile = "headshot", pitchvariation = 0.1,
                                location = CurrentCamera
                            }, r51)
                        end
                        if r39.Name == "HeadHitbox" and r39.Parent:FindFirstChild("helmet") ~= nil or r39.Parent.Parent == workspace.bodies then
                        else
                            r51 = true
                            visualEffects("blood_impact", {
                                point = CFrame.new(r39.Position, Character.HumanoidRootPart.Position),
                                headshot = r39.Name == "HeadHitbox"
                            }, r51)
                            r48 = tick() - r91
                            if r48 >= 0.1 then
                                r51 = true
                                visualEffects("bloodhitmarker_fx", {position = CFrame.new(r39.Position)}, r51)
                            end
                            r91 = tick()
                        end
                    end
                    if r19_p47 == true and Value_2 == "saa" and shield_supplies.ammo_mag <= 0 and r1_p47 ~= "quickdraw" and Character:FindFirstChild("cowboy") == nil then
                        r1_p47 = "cowboy"
                    end
                    if r39.Parent.Parent ~= workspace.bodies then
                        events.damage_handler:Fire(r39, Parent_2, "gun", r20, r1_p47, r34_p47, i_0)
                    else
                        r48 = tick() - r91
                        if r48 >= 0.1 then
                            if r39.Name == "Head" and r39.Parent:FindFirstChild("helmet") then
                                visualEffects("mine_impact", {
                                    weapon = Value_2,
                                    normal = r41,
                                    from = Value_3.special.muzzle.Position,
                                    point = r39.Position, headhit = true,
                                    ricochet = math.random(1, 2)
                                })
                            else
                                visualEffects("blood_impact", {point = CFrame.new(r39.Position, Character.HumanoidRootPart.Position)})
                                r50_p47 = {directory = {"impacts", "bullets", "flesh"}, pitchvariation = 0.1}
                                r50_p47.soundfile = "flesh_" .. math.random(1, 4)
                                r50_p47.location = r39
                                bFunctions:soundHandler(r50_p47)
                                r50_p47 = {directory = {"impacts", "general", "blood"}, pitchvariation = 0.1}
                                r50_p47.soundfile = "blood_" .. math.random(1, 4)
                                r50_p47.location = r39
                                bFunctions:soundHandler(r50_p47)
                            end
                            events.game_handler:Fire("hit_body", r39)
                        end
                        r91 = tick()
                    end
                    if Value_2 ~= "pugsley" then break end
                else
                    local r49
                    if r39.Material == Enum.Material.Wood or r39.Material == Enum.Material.WoodPlanks then
                        visualEffects("wood_impact", {point = Position, pellets = pellets})
                        if r39.Name == "secretpartpiece" then events.game_handler:Fire("hit_secretpart", r39) end
                        if r39.Name == "lightbody_shoot" and r39.Parent.Name == "body" then
                            events.game_handler:Fire("hit_destructible", r39)
                        end
                        if r39.Name == "interactabledestroy" then events.game_handler:Fire("hit_interactablepiece", r39) end
                    elseif r39.Material == Enum.Material.Sand or r39.Material == Enum.Material.Ground then
                        visualEffects("wood_impact", {
                            point = Position,
                            partcol = r39.Color,
                            pellets = pellets, sand = true
                        })
                        if r39.Name == "targetrange" then
                            r51 = true
                            visualEffects("bullet_hole", {pos = Position, normal = r41, targetrange = true}, r51)
                            if workspace.serverStuff.trainingmode.Value == true then
                                events.game_handler:Fire("hit_target_range_training")
                            end
                        end
                    elseif r39.Material == Enum.Material.Glass and (r39.Name == "WindowBreakable" or r39.Name == "GlassWindow") then
                        visualEffects("wood_impact", {
                            point = Position,
                            part_hit = r39,
                            partcol = r39.Color,
                            pellets = pellets, glass = true
                        })
                        if r39.Name == "WindowBreakable" then
                            r51 = true
                            visualEffects("bullet_hole", {
                                pos = Position,
                                normal = r41, glass = true,
                                forceparent = r39
                            }, r51)
                            events.game_handler:Fire("window_impact", r39, math.clamp(r20.pen, 1, 5))
                        end
                    else
                        r48 = 0
                        if math.random(1, 3) == 1 and pellets == 1 then r48 = math.random(1, 3) end
                        visualEffects("mine_impact", {
                            weapon = Value_2,
                            normal = r41,
                            from = Value_3.special.muzzle.Position,
                            point = Position, bullet = true,
                            ricochet = r48,
                            hit_targ = r39.Name,
                            hit_mat = r39.Material,
                            pellets = pellets
                        })
                        r49 = true
                        if r42_p47 ~= Enum.Material.Rock then r49 = r42_p47 == Enum.Material.Mud end
                        if workspace.serverStuff.values:FindFirstChild("miningrestrictions") then
                            r50_p47 = true
                            if r42_p47 ~= Enum.Material.Grass then
                                r50_p47 = true
                                if r42_p47 ~= Enum.Material.LeafyGrass then r50_p47 = r42_p47 == Enum.Material.Ground end
                            end
                            r49 = r50_p47
                        end
                        if r42_p47 and r49 and Value_2 == "pugsley" then
                            events.mine:Fire(CFrame.new(Position + CurrentCamera.CFrame.LookVector * 2, Character.Head.Position), Parent_2, false, r39)
                        end
                    end
                    r48 = false
                    if r39.Name == "leftshield" or r39.Name == "rightshield" or r39.Name == "mainshield" or r39.Name == "topshield" then
                        events.interaction_handler:Fire(Parent_2, "damage_vanguardshield", r39, r1_p47)
                        if Value_2 ~= "pugsley" then break end
                        r48 = true
                        local r46 = true
                        local r47 = false
                        continue
                    end
                    if r39.Name == "protect" and r39.Parent.Name == "parts" then
                        if Value_2 ~= "pugsley" then break end
                        r48 = true
                        local r46 = true
                        local r47 = false
                        continue
                    end
                    if r39.Name == "flametank" then
                        if Value_2 == "pugsley" then
                            r48 = true
                            local r46 = true
                            local r47 = false
                        end
                    elseif (r39.Name == "main" or r39.Name == "shieldcover" or r39.Name == "shieldside" or r39.Name == "shieldbolts" or r39.Name == "click") and (r39.Parent.Parent.Name == "Vanguard Barrier" or r39.Parent.Name == "main") then
                        if Value_2 ~= "pugsley" then break end
                        r48 = true
                        local r46 = true
                        if r39.Parent.Name == "main" and r39.Parent.Parent.Parent:FindFirstChild("Torso") then
                            local r47 = false
                        end
                        if r39:FindFirstChild("pennable") then r45 = true end
                        if not r39.Anchored then r46 = true end
                        if r48 and not r45 then
                            r45 = true
                            r32 = 35
                            r31 = 3
                            r30 = 2
                            r1_p47 = "pugsleymetalpenetration"
                        end
                        if r39.Name == "flametank" then
                            events.interaction_handler:Fire(Parent_2, "damage_flametank", r39, r1_p47)
                            if not r45 then break end
                        end
                        if r39.Parent and r39.Parent.Parent and r39.Parent.Parent:FindFirstChild("health") and r39.Parent.Parent.health.Value > 0 then
                            events.construction_handler:Fire("damage", r39.Parent.Parent, Parent_2, r1_p47)
                            if not r45 then break end
                        end
                        if not r39.Parent or r39.Parent.Name ~= "frontcarriage" then
                            if r39.Parent.Parent and r39.Parent.Parent.Name == "frontcarriage" then
                                local Parent = r39.Parent
                                if r39.Parent.Parent.Name == "frontcarriage" then Parent = r39.Parent.Parent end
                                events.interaction_handler:Fire(Parent_2, "damage_frontcarriage", Parent, r1_p47)
                                break
                            end
                            if _G.debugline == true then
                                bFunctions:debugline(r27.Position, Position, 10)
                                r48 = Instance.new("Part")
                                r48.BrickColor = BrickColor.new("Really red")
                                r48.Material = Enum.Material.Neon
                                r48.Size = vector.create(0.100000001, 0.100000001, 0.100000001)
                                r48.CanCollide = false
                                r48.CanQuery = false
                                r48.Anchored = true
                                r48.CFrame = CFrame.new(Position)
                                r48.Parent = workspace.notarget
                            end
                            if pellets ~= 1 and (i_0 ~= 1 or Value_2 ~= "autosg" or r18 ~= "autosgvariant" or r39:FindFirstChild("nopen") or r39:FindFirstChild("pugsleypen") and Value_2 ~= "pugsley") then
                                break
                            end
                            r48 = false
                            if Value_2 == "pugsley" then
                                r48 = Position and r39 and (table.find(base.pugsley_pen_materials, r39.Material) or r39:FindFirstChild("pugsleypen") or r39.Parent:FindFirstChild("pugsleypen"))
                            end
                            if r48 and not r45 and r39.Material ~= Enum.Material.Glass then
                                r32 = 30
                                r31 = 2
                                r1_p47 = "pugsleymetalpenetration"
                            end
                            if r32 < magnitude then break end
                            if (Position and r39) and (r45 or r39.Material == Enum.Material.Wood or r39.Material == Enum.Material.WoodPlanks or r48 or r44_p47 == true) then
                                r50_p47 = r31
                                if i_1 >= 2 then r50_p47 /= 2 end
                                r45 = false
                                r51 = RaycastParams.new()
                                r51.FilterType = Enum.RaycastFilterType.Include
                                r51.FilterDescendantsInstances = {r39}
                                r51.IgnoreWater = true
                                local r52 = Position + r29_p47 * r50_p47
                                local r56 = CFrame.new(r52, Position).LookVector * (r50_p47 * 2)
                                local r53 = workspace:Raycast(r52, r56, r51)
                                if r53 and r53.Instance and r53.Position then
                                    local r54 = RaycastParams.new()
                                    r54.FilterType = Enum.RaycastFilterType.Include
                                    r54.FilterDescendantsInstances = {workspace.Terrain}
                                    r54.IgnoreWater = true
                                    local r55 = workspace:Raycast(Position, CFrame.lookAt(Position, r52).LookVector * ((Position - r52).Magnitude + 0.1), r54)
                                    if r55 and r55.Instance then
                                        r49 = false
                                        break
                                    end
                                    r49 = true
                                    r34_p47 = true
                                    r27 = CFrame.new(r53.Position)
                                    r56 = true
                                    if Mouse.Target ~= r53.Instance then r56 = (Mouse.Hit.Position - r53.Position).Magnitude <= 1 end
                                    r35 = r56 and workspace.CurrentCamera.CFrame.LookVector.Unit or r29_p47
                                    local r57 = 12
                                    if Value_2 == "pugsley" and r1_p47 ~= "pugsleymetalpenetration" then
                                        r57 *= 0.2
                                    elseif Value_2 == "henry" and r18 == "" or Value_2 == "browningmg" then
                                        r57 *= 0.8
                                    end
                                    r35 += (r27.RightVector * math.random(-r57, r57) + r27.UpVector * math.random(-r57, r57)) / 1000
                                    if r44_p47 == false then
                                        visualEffects("bullet_hole", {
                                            pos = Position,
                                            normal = r41,
                                            hit = r39,
                                            moving = false
                                        }, true)
                                        if r39.Material == Enum.Material.Wood or r39.Material == Enum.Material.WoodPlanks then
                                            visualEffects("wood_impact", {point = r27.Position})
                                        end
                                    end
                                    if false == false then break end
                                    continue
                                end
                            end
                        end
                    end
                end
            end
            r22_p47 = false
        end
    end
    if _G.debugline == false then
        local recoil_count = r20.recoil_count
        local recoil = r20.recoil
        if Value_2 == "walker" then
            if r2[3] ~= false then
                if r2[3] <= 0.2 then
                    recoil /= 3
                elseif r2[3] < 0.5 then
                    recoil /= 2
                end
            end
        elseif Value_2 == "saa" and Character:FindFirstChild("elitekit") and Character.elitekit.Value == "ocelot" then
            recoil *= 0.3
        end
        if Parent_2:FindFirstChild("bipod") and tick() - Parent_2.bipod.Value <= base.bulwark_buffer then
            recoil = 1
        end
        core_checkers.recoil_kick(recoil, recoil, recoil_count, true)
    end
    local r23_p47 = true
    if shield_supplies.ammo_mag <= 0 then
        if Parent_2:FindFirstChild("mag_empty") then Parent_2.mag_empty.Value = true end
        r23_p47 = false
    end
    if r29.alt_mode == true and Value_2 == "lebel" then
        r23_p47 = false
        shield_supplies.force_block_fire = true
    end
    local r24_p47 = false
    if Value_2 == "mauser" or Value_2 == "mausercarbine" or Value_2 == "steyr" or Value_2 == "mpistol" or Value_2 == "rsc" or Value_2 == "mpgun" or Value_2 == "lewis" then
        r24_p47 = true
        if Value_2 == "rsc" and math.random(1, 2) == 1 then r24_p47 = false end
    end
    local fire_rate = r20.fire_rate
    local r28_p47
    if Value_2 == "browningmg" and shield_supplies.ammo_mag == 7 then
        r28_p47 = {directory = {"tools", Value_2}}
        r28_p47.soundfile = "steam" .. math.random(1, 3)
        r28_p47.location = Character.HumanoidRootPart
        bFunctions:soundHandler(r28_p47)
    end
    local r29_p47, r30
    if shield_supplies.ammo_mag <= 1 and Value_2 == "pugsley" then
        r30 = Value_2
        if r18 ~= "" then r30 = r18 end
        r29_p47 = {
            char = Character,
            originweapon = r30,
            weapon = Value_2,
            model = Value_3,
            module = r20,
            core = shield_supplies
        }
        weaponEffects("magazine_last_round", {main = r29_p47})
    end
    if Value_2 == "lewis" and shield_supplies.ammo_mag <= 25 then
        local __up6 = Value_2
        if r18 ~= "" then __up6 = r18 end
        weaponEffects("lewis_magazine", {
            main = {
                char = Character,
                originweapon = __up6,
                weapon = Value_2,
                model = Value_3,
                module = r20,
                core = shield_supplies
            }
        })
        if shield_supplies.ammo_mag <= 0 then
            bFunctions:soundHandler({directory = {"tools", Value_2}, soundfile = "last", location = Character.HumanoidRootPart})
        end
    end
    if Value_2 == "mpistol" then
        local __up6 = Value_2
        if r18 ~= "" then __up6 = r18 end
        weaponEffects("m_mag_update", {
            main = {
                char = Character,
                originweapon = __up6,
                weapon = Value_2,
                model = Value_3,
                module = r20,
                core = shield_supplies
            }
        })
    end
    if shield_supplies.ammo_mag <= 0 then
        local r28_p47, r29_p47, r30
        if Value_2 == "rsc" then
            r28_p47 = {transp = 1}
            r30 = Value_2
            if r18 ~= "" then r30 = r18 end
            r29_p47 = {
                char = Character,
                originweapon = r30,
                weapon = Value_2,
                model = Value_3,
                module = r20,
                core = shield_supplies
            }
            r28_p47.main = r29_p47
            weaponEffects("casing_visibility", r28_p47)
        end
        if Value_2 == "mpgun" then
            local __up6 = Value_2
            if r18 ~= "" then __up6 = r18 end
            weaponEffects("magazine_last_round", {
                main = {
                    char = Character,
                    originweapon = __up6,
                    weapon = Value_2,
                    model = Value_3,
                    module = r20,
                    core = shield_supplies
                }
            })
        end
        if Value_2 == "mgturret" or Value_2 == "browningmg" then
            bFunctions:soundHandler({
                directory = {"tools", Value_2},
                soundfile = "overheat" .. math.random(1, 2),
                location = Character.HumanoidRootPart
            })
            fire_rate = r20.reload_start
            r25[r12]:Stop(0)
            r25.reload_start:Play(0.1, 1, 1 / fire_rate)
            shield_supplies.ammo_mag = math.random(50, 70)
        end
        if r25[r8] and r24_p47 == true then
            r29.slide_locked = true
            r25[r8]:Play(0.2)
        end
    end
    if Value_2 == "springfield" and r29.alt_mode == true then r23_p47 = false end
    if r25.cycle and r23_p47 == true then shield_supplies.need_bolt = true end
    local ambi_penalty
    if r20.auto ~= true then
        if Character:FindFirstChild("vanguardbuff") then fire_rate *= 0.85 end
        if Character:FindFirstChild("buff_elite") then fire_rate *= 0.8 end
        if Character.perk.Value == "quickdraw" then
            fire_rate = shield_supplies.need_bolt == true and fire_rate * 0.955 or fire_rate * 0.925
        end
        if (Character.perk.Value == "akimbo" and Parent_2:FindFirstChild("akimbo")) and (Parent_2.akimbo.Value == true or r0_p47 == true) then
            ambi_penalty = Instance.new("StringValue")
            game:GetService("Debris"):AddItem(ambi_penalty, 0.75)
            ambi_penalty.Name = "ambi_penalty"
            ambi_penalty.Parent = Character
            fire_rate *= 0.7
        end
        if workspace.serverStuff.restorationmode.Value == true then fire_rate *= 1.2 end
    end
    if Character:FindFirstChild("class") and Character.class.Value == "conscript" and not Character:FindFirstChild("elitekit") or workspace.serverStuff.trainingmode.Value == true then
        fire_rate *= 1.2
    end
    if Value_2 == "mares" and (r0_p47 ~= true or not Character:FindFirstChild("Cavalry Sword")) and (Character.perk.Value == "akimbo" and Parent_2:FindFirstChild("akimbo")) then
        if Parent_2.akimbo.Value == true or r0_p47 == true then
            fire_rate *= 1.1
        elseif r29.alt_mode == true then
            fire_rate *= 1.1
        end
    end
    if r0_p47 == true and Character:FindFirstChild("Cavalry Sword") then fire_rate *= 1.1 end
    if Value_2 == "dbgun" and r29.alt_mode == true and shield_supplies.ammo_mag > 0 then
        fire_rate = 0.08
    end
    if r19_p47 == true then
        if Value_2 == "saa" then
            fire_rate = 0.35
            if r29.alt_mode == true then fire_rate = 0.4 end
            if Character:FindFirstChild("elitekit") and Character.elitekit.Value == "ocelot" then
                fire_rate = 0.16
            end
        end
    elseif Value_2 == "saa" and Character:FindFirstChild("elitekit") and Character.elitekit.Value == "ocelot" then
        fire_rate = 0.45
    end
    if Value_2 == "pugsley" and core_checkers.crouching == true and Character.class.Value ~= "rook" then
        _G.knockdownproc()
    end
    bFunctions:s_wait(fire_rate)
    if r13_p47 == "pedersen_fire" and r29.jammed and r29.jammed == true then
        r29.jammed = false
        r25.pedersen_jam:Play(0.2, 1, 1)
        bFunctions:s_wait(1)
    end
    core_checkers.sprint_block = false
    if Value_2 == "walker" and r2[3] >= 1 then
        r70_0(true)
        return
    end
    if r20.auto == true and keysheld.m1 == true and core_checkers.shift_locked == true and core_checkers.aiming == true and tick() - core_checkers.fall_damage_interrupt > 0 then
        action.Value = false
        r92("autoshot")
    end
    if Value_2 == "dbgun" and r29.alt_mode == true and shield_supplies.ammo_mag > 0 then
        action.Value = false
        r77()
        return
    end
    if shield_supplies.need_bolt == true then
        if core_checkers.queue_inv ~= nil then
            action.Value = false
            while true do
                RenderStepped:wait()
                if core_checkers.queue_inv ~= nil or r29.equipped ~= true then continue end
                break
            end
        end
        if Value_2 == "pugsley" then
            action.Value = true
            repeat
                RenderStepped:Wait()
                local ambi_penalty_2 = tick() - core_checkers.fall_damage_interrupt
            until ambi_penalty_2 >= 0
        end
        if r6 == true and r25.fire_left and Value_2 ~= "trench" then r25.fire_left:Stop(0.1) end
        action.Value = false
        r76_0()
        shield_supplies.need_bolt = false
    end
    if shield_supplies.ammo_mag <= 0 and Value_2 == "mauser" and r18 == "mauservariant" then
        local r28_p47 = {transp = 1}
        local __up6 = Value_2
        if r18 ~= "" then __up6 = r18 end
        r28_p47.main = {
            char = Character,
            originweapon = __up6,
            weapon = Value_2,
            model = Value_3,
            module = r20,
            core = shield_supplies
        }
        weaponEffects("casing_visibility", r28_p47)
        r28_p47 = {directory = {"train_sounds"}}
        r28_p47.soundfile = "steam_fire" .. math.random(1, 5)
        r28_p47.location = Character.HumanoidRootPart
        bFunctions:soundHandler(r28_p47)
        if Character.perk.Value ~= "vet" and r29.equipped and r29.dual_wield_tool == nil then
            r25.check_empty.Priority = Enum.AnimationPriority.Action
            r25.check_empty:Play(0.1, 1, 0.6666666666666666)
            bFunctions:s_wait(1.5)
        elseif Parent_2:FindFirstChild("akimbo") and Parent_2.akimbo.Value == true and r29.dual_wield_tool and r29.dual_wield_tool:FindFirstChild("weapon") and r29.dual_wield_tool.weapon.Value == "mauservariant" and r29.dual_wield_tool:FindFirstChild("mag_empty") and r29.dual_wield_tool.mag_empty.Value == true then
            r25.check_empty.Priority = Enum.AnimationPriority.Action
            r25.check_empty:Play(0.1, 1, 0.6666666666666666)
            bFunctions:s_wait(1.5)
            r70_0(true)
            action.Value = false
            return
        end
        action.Value = false
        if not r29.equipped or shield_supplies.ammo_mag > 0 or r29.dual_wield_tool ~= nil then return end
        r70_0(true)
        return
    end
    action.Value = false
    if tick() - r71 <= 0.4 and r20.capacity <= 2 then
        r71 = 0
        r74_0()
    end
end
event.Event:Connect(function(r0_p48, r1, r2) -- Line: 6952 | Upvalues: ("r92" (ref), "r64_0" (copy), "Value_2" (ref), "r18" (ref), "shield_supplies" (ref), "Humanoid" (copy), "Parent_2" (copy), "r70_0" (copy), "r74_0" (copy), "r29" (copy), "r86" (ref), "r25" (copy), "core_checkers" (copy), "Character" (copy), "pistol" (ref))
    if r0_p48 == "fire_weapon" then
        r92(true)
        return
    end
    if r0_p48 == "swing_weapon" then
        r64_0(true)
        return
    end
    if r0_p48 == "reload_weapon_swap" then
        if Value_2 ~= "mauser" or r18 ~= "mauservariant" then
            r74_0(true)
            return
        end
        if shield_supplies.ammo_mag <= 0 then
            Humanoid:EquipTool(Parent_2)
            task.wait()
            r70_0(true)
        end
        return
    end
    if r0_p48 == "dual_active" then
        r29.dual_wield_active = r1
        if Value_2 ~= "steyr" and Value_2 ~= "mares" or r29.alt_mode ~= true then return end
        r86(true)
        return
    end
    local r3
    if r0_p48 == "dual_shoot" then
        r3 = "shoot"
        if Parent_2:FindFirstChild("akimbo") and Parent_2:FindFirstChild("akimbo").Value == true then
            r3 = "akimbo_left"
        else
            shield_supplies.ammo_mag = r1
        end
        r25[r3]:Stop(0)
        r25[r3]:Play(0.01, 1, r2)
        return
    end
    if r0_p48 == "dual_shoot_empty" then
        local r3 = "shoot_empty"
        if not Parent_2:FindFirstChild("akimbo") or Parent_2:FindFirstChild("akimbo").Value ~= true then
            r25["shoot"]:Stop(0)
            r25[r3]:Stop(0)
            r25[r3]:Play(0, 1, 1)
            return
        end
        r3 = "akimbo_left_empty"
        r25["akimbo_left"]:Stop(0)
        r25[r3]:Stop(0)
        r25[r3]:Play(0, 1, 1)
        return
    end
    local r3
    if r0_p48 == "reset_aimtime" then
        core_checkers.aim_time = tick()
        r29.draw = tick()
        if r29.slide_locked == true then
            r3 = "locked"
            if not r25.akimbo_locked or not Parent_2:FindFirstChild("akimbo") or Parent_2.akimbo.Value ~= false or r29.dual_wield_active ~= true then
                r25[r3]:Play(0)
                return
            end
            r3 = "akimbo_locked"
            r25[r3]:Play(0)
            return
        end
    else
        if r0_p48 == "drop_weapon" then
            r70_0(r1)
            return
        end
        if r0_p48 == "throw_axe" then
            r3 = Character:FindFirstChild("equipment")
            if r29.equipped ~= false or not r3 or r3.Value <= 0 then return end
            pistol()
        end
    end
end)
r86 = function(r0) -- Line: 7036 | Upvalues: ("r29" (copy), "r25" (copy), "r20" (ref), "Value_2" (ref), "r18" (ref), "core_checkers" (copy), "bFunctions" (copy), "Character" (copy), "action" (copy), "localize" (copy))
    if r29.anim_swaps == nil then
        r29.anim_swaps = {r25.alt_changeaim, r25.alt_changefire, r25.alt_changefire_empty, r25.aim, r25.fire, r25.fire_empty, r25.alt_changefire_last, r25.fire_last}
        r29.anim_swapstwo = {r25.alt_changefire_left, r25.alt_changefire_empty_left, r25.alt_changefire_last_left, r25.alt_changeaim_left, r25.fire_left, r25.fire_empty_left, r25.fire_last_left, r25.aim_left}
    end
    r25.aim:Stop(r20.aim_speed)
    if r25.aim_left then r25.aim_left:Stop(r20.aim_speed) end
    local r1 = 0.3
    if Value_2 == "mauser" then
        if r18 ~= "" then return end
        r1 = 1
        local alt_stockon = r25.alt_stockon
        if r29.alt_mode == true then
            core_checkers.inv_swapping = true
            alt_stockon = r25.alt_stockoff
        else
            core_checkers.inv_swapping = false
        end
        alt_stockon:Play(0.1, 1, 1)
    else
        r29.no_steady_acc = not r29.no_steady_acc
        bFunctions:soundHandler({
            directory = {"tools", "shared", "gsfx", "readysound"},
            soundfile = "ready" .. math.random(1, 4),
            location = Character.HumanoidRootPart
        })
    end
    if r29.alt_mode == true then
        r25.aim = r29.anim_swaps[4]
        r25.fire = r29.anim_swaps[5]
        if r25.fire_empty then r25.fire_empty = r29.anim_swaps[6] end
        if r25.fire_last then r25.fire_last = r29.anim_swaps[8] end
        if r25.fire_left then r25.fire_left = r29.anim_swapstwo[5] end
        if r25.fire_empty_left then r25.fire_empty_left = r29.anim_swapstwo[6] end
        if r25.fire_last_left then r25.fire_last_left = r29.anim_swapstwo[7] end
        if r25.aim_left then r25.aim_left = r29.anim_swapstwo[8] end
    else
        r25.aim = r29.anim_swaps[1]
        r25.fire = r29.anim_swaps[2]
        if r25.fire_empty then r25.fire_empty = r29.anim_swaps[3] end
        if r25.fire_last then r25.fire_last = r29.anim_swaps[7] end
        if r25.fire_left then r25.fire_left = r29.anim_swapstwo[1] end
        if r25.fire_empty_left then r25.fire_empty_left = r29.anim_swapstwo[2] end
        if r25.fire_last_left then r25.fire_last_left = r29.anim_swapstwo[3] end
        if r25.aim_left then r25.aim_left = r29.anim_swapstwo[4] end
    end
    r29.alt_mode = not r29.alt_mode
    if r0 ~= true then
        action.Value = true
        bFunctions:s_wait(r1)
        action.Value = false
    end
    if r29.alt_mode == true then
        if Value_2 == "mauser" then
            core_checkers.inv_block_reason = _G.localizationdebug == true and "#mauser_invswap" or localize("mauser_invswap")
            r20.movement = 2
            r20.firing_movement = 2
            r20.fire_rate = 0.27
            r20.recoil = 4
            r20.accuracy = 6
            r20.moving_accuracy = 100
        elseif Value_2 == "lever" then
            r20.movement = 0.5
            r20.firing_movement = 0.5
            r20.accuracy = 35
            r20.moving_accuracy = 35
        elseif Value_2 == "steyr" then
            r20.recoil = 3
            r20.moving_accuracy = 10
            r20.fire_rate = 0.45
            r20.movement = 3
            r20.firing_movement = 3
            r20.accuracy = 2
        elseif Value_2 == "rsc" then
            r20.recoil = 5
            r20.accuracy = 30
            r20.moving_accuracy = 50
            r20.aim_speed = 0.3
            r20.movement = 1
            r20.firing_movement = 0.5
        elseif Value_2 == "remington" then
            r20.accuracy = 1
            r20.moving_accuracy = 1
        elseif Value_2 == "autosg" then
            r20.firing_movement = 3
            r20.movement = 4
            r20.recoil_count = 6
            r20.recoil = 6
            r20.aim_speed = 0.5
        elseif Value_2 == "mares" then
            r20.recoil = 12
            r20.movement = 0.5
            r20.firing_movement = 0.5
            r20.firing_movement_last = 0.25
            r20.moving_accuracy = 60
            r20.aim_speed = 0.125
        end
    else
        core_checkers.inv_block_reason = ""
        r20 = bFunctions:deepCopy(require(game.ReplicatedStorage.weapon_modules:FindFirstChild(Value_2)))
    end
    core_checkers.speed_mod = r20.movement
end
local r93 = false
local function r94() -- Line: 7187 | Upvalues: ("Parent_2" (copy), "Value_2" (ref), "action" (copy), "Character" (copy), "keysheld" (copy), "r29" (copy), "r25" (copy), "bFunctions" (copy), "r18" (ref), "CurrentCamera" (copy), "r20" (ref), "core_checkers" (copy), "r57" (copy), "Value_3" (copy), "visualEffects" (copy), "events" (copy), "Humanoid" (copy), "r79_0" (copy), "RenderStepped" (copy), "core_game" (copy), "r92" (ref), "weaponEffects" (copy), "shield_supplies" (ref), "r86" (ref), "bipod" (copy), "localize" (copy), "r87_0" (copy), "r93" (ref), "left_aiming" (copy), "r42" (copy))
    if workspace.serverStuff.trainingmode.Value == true then return end
    local drinking, amount, stop_movement
    if Parent_2:FindFirstChild("akimbo") and Parent_2:FindFirstChild("akimbo_aiming") and Parent_2.akimbo.Value == true then
        if Value_2 ~= "saa" or action.Value ~= false or Character:FindFirstChild("stop_movement") ~= nil or Character.HumanoidRootPart.Velocity.Magnitude > 0.5 then
            Parent_2.akimbo_aiming.Value = not Parent_2.akimbo_aiming.Value
            return
        end
        drinking = true
        amount = tick()
        while true do
            if keysheld[_G.get_keybinds("alt")] ~= nil then break end
            game:GetService("RunService").RenderStepped:Wait()
        end
        while true do
            if not keysheld[_G.get_keybinds("alt")] then break end
            game:GetService("RunService").RenderStepped:Wait()
            stop_movement = tick() - amount
            if stop_movement < 0.25 then continue end
            drinking = false
            break
        end
        if drinking or not r29.dual_wield_tool or not r29.dual_wield_tool:FindFirstChild("weapon") or r29.dual_wield_tool.weapon.Value ~= "saa" then
            Parent_2.akimbo_aiming.Value = not Parent_2.akimbo_aiming.Value
            return
        end
        action.Value = true
        r25.akimbo_saa_spins:Play(0.1, 1, 1)
        stop_movement = Instance.new("StringValue")
        stop_movement.Name = "stop_movement"
        stop_movement.Parent = Character
        bFunctions:s_wait(7.4)
        action.Value = false
        if stop_movement then stop_movement:Destroy() end
        return
    end
    if Value_2 == "mosin" then
        if r18 ~= "" then return end
        Parent_2.scoped.Value = not Parent_2.scoped.Value
        local drinking_2 = "zoom_in"
        if Parent_2.scoped.Value == false then drinking_2 = "zoom_out" end
        bFunctions:soundHandler({directory = {"tools", "shared"}, soundfile = drinking_2, location = CurrentCamera}, true)
    elseif Value_2 == "pickaxe" then
        if Parent_2.durability.Value <= 0 then
            _G.popupmsg("pick_dura", "#pickaxe_drained", 1)
            return
        end
        r29.alt_mode = not r29.alt_mode
        if r29.alt_mode == true then
            _G.popupmsg("alt_on", "#pickaxe_weak", 1)
        else
            _G.popupmsg("alt_off", "#pickaxe_heavy", 1)
        end
    end
    local drinking = tick() - r29.draw
    if drinking < r20.draw_speed / core_checkers.draw_modifier then return end
    if r20.tooltype == "hammer" then
        if action.Value == true then return end
        r29.construction_mode = not r29.construction_mode
        return
    end
    if Value_2 == "henry" or Value_2 == "lance" or Value_2 == "trench" then
        if action.Value == true then return end
        if r18 == "henryvariant" then return end
        r57()
        return
    end
    local r4
    if Value_2 == "bottle" then
        if action.Value == true then return end
        if Value_3:FindFirstChild("glassbottle") or Value_3:FindFirstChild("amount") and Value_3.amount.Value <= 0 then
            if not Value_3:FindFirstChild("glassbottle") then _G.popupmsg("bottleempty", "#bottle_empty", 1) end
            action.Value = true
            r25.empty:Play(0.1, 1, 0.5)
            bFunctions:s_wait(2)
            action.Value = false
            return
        end
        if core_checkers.sick == true then
            _G.popupmsg("bottlesick", "#bottle_sick", 1)
            return
        end
        if Character:FindFirstChild("class") and Character.class.Value == "jaeger" then
            _G.popupmsg("bottlepoxxed", "#bottle_poxxed", 1)
        end
        action.Value = true
        drinking = Instance.new("StringValue")
        drinking.Name = "drinking"
        drinking.Parent = Character
        if not Value_3:FindFirstChild("amount") then
            local amount_2 = Instance.new("IntValue")
            amount_2.Name = "amount"
            amount_2.Value = 15
            amount_2.Parent = Value_3
        end
        core_checkers.sprint_block = true
        local stop_movement_2 = Character:FindFirstChild("helmet") and Character.helmet:FindFirstChild("knock") or Character:FindFirstChild("extralift")
        amount = true
        visualEffects("helmet_adjusting", {char = Character, val = "helmetoff"})
        r25.helmet_remove:Play(0.05, 1, 1)
        events.game_handler:Fire("helmet_lift", true)
        bFunctions:s_wait(0.5)
        r25.drink:Play(0.1, 1, 0.5)
        bFunctions:s_wait(2)
        r25.drink:Stop(0.1)
        r25.drink_motion:Play(0.1, 1, 0.5)
        while Humanoid ~= nil do
            if Humanoid.Health <= 0 or core_checkers.sick == true and math.random(1, 2) == 1 then break end
            events.interaction_handler:Fire(Parent_2, "drinkbottle")
            stop_movement_2 = Value_3.amount
            stop_movement_2.Value -= 1
            if Value_3.amount.Value <= 0 then Value_3.body.liquid.Transparency = 1 end
            r4 = {directory = {"tools", "bottle"}, pitchvariation = 0.1}
            r4.soundfile = "drink" .. math.random(1, 5)
            r4.location = Character.HumanoidRootPart
            bFunctions:soundHandler(r4)
            bFunctions:s_wait(0.5)
            if Humanoid == nil or Humanoid.Health <= 0 or keysheld[_G.get_keybinds("alt")] ~= true or Value_3.amount.Value <= 0 then
                break
            end
            r4 = {directory = {"tools", "bottle"}, pitchvariation = 0.1}
            r4.soundfile = "water" .. math.random(1, 4)
            r4.location = Character.HumanoidRootPart
            bFunctions:soundHandler(r4)
            bFunctions:s_wait(1.5)
            if Humanoid ~= nil and Humanoid.Health > 0 and keysheld[_G.get_keybinds("alt")] == true then
                continue
            end
            break
        end
        r4 = {directory = {"voices", "breath"}, volume_adjust = 0.5}
        r4.soundfile = Character.gender.Value .. "_exhale" .. math.random(1, 3)
        r4.location = Character.HumanoidRootPart
        bFunctions:soundHandler(r4)
        r25.drink_motion:Stop(0.1)
        r25.drink_done:Play(0.1, 1, 0.5)
        bFunctions:s_wait(2)
        core_checkers.sprint_block = false
        drinking:Destroy()
        events.game_handler:Fire("helmet_lift", false)
        if amount == true then
            visualEffects("helmet_adjusting", {char = Character, val = "helmet"})
            r25.helmet_place:Play(0.05, 1, 1)
            bFunctions:s_wait(0.5)
        end
        action.Value = false
        return
    end
    local r3_p56
    if Value_2 == "machete" then
        if action.Value == true then return end
        drinking = nil
        if not Value_3:FindFirstChild("body") or not Value_3.body:FindFirstChild("blade") or not Value_3.body.blade:FindFirstChild("blood1") then
            return
        end
        drinking = Value_3.body.blade
        if drinking == nil then return end
        action.Value = true
        r25.clean:Play(0.1, 1, 0.5)
        bFunctions:s_wait(0.6)
        r3_p56 = {directory = {"tools", "machete"}}
        r3_p56.soundfile = "clean_notdirty" .. math.random(1, 4)
        r3_p56.location = Character.HumanoidRootPart
        bFunctions:soundHandler(r3_p56)
        if drinking:FindFirstChild("blood1") and drinking.blood1.Transparency ~= 1 then
            events.interaction_handler:Fire(Parent_2, "cleanmachete", 1)
            drinking.blood1.Transparency = 1
            r3_p56 = {directory = {"tools", "machete"}}
            r3_p56.soundfile = "clean_dirty" .. math.random(1, 2)
            r3_p56.location = Character.HumanoidRootPart
            bFunctions:soundHandler(r3_p56)
        end
        if not drinking:FindFirstChild("machetepoxstain") and Character:FindFirstChild("class") and Character.class.Value == "jaeger" then
            events.interaction_handler:Fire(Parent_2, "cleanmachete", 3)
            r3_p56 = {directory = {"tools", "machete"}}
            r3_p56.soundfile = "clean_dirty" .. math.random(1, 2)
            r3_p56.location = Character.HumanoidRootPart
            bFunctions:soundHandler(r3_p56)
        end
        bFunctions:s_wait(0.9)
        r3_p56 = {directory = {"tools", "machete"}}
        r3_p56.soundfile = "clean_notdirty" .. math.random(1, 4)
        r3_p56.location = Character.HumanoidRootPart
        bFunctions:soundHandler(r3_p56)
        if not drinking:FindFirstChild("blood2") or drinking.blood2.Transparency == 1 then
            bFunctions:s_wait(0.5)
            action.Value = false
            return
        end
        events.interaction_handler:Fire(Parent_2, "cleanmachete", 2)
        drinking.blood2.Transparency = 1
        if drinking:FindFirstChild("blood3") then drinking.blood3.Transparency = 1 end
        r3_p56 = {directory = {"tools", "machete"}}
        r3_p56.soundfile = "clean_dirty" .. math.random(1, 2)
        r3_p56.location = Character.HumanoidRootPart
        bFunctions:soundHandler(r3_p56)
        bFunctions:s_wait(0.5)
        action.Value = false
        return
    end
    if Value_2 == "lewis" then
        if action.Value == true then return end
        r79_0()
        return
    end
    if r20.tooltype == "whistle" then
        if action.Value == true then return end
        action.Value = true
        core_checkers.selection_box_selected = ""
        core_checkers.display_selections({"advance", "defend", "focus"})
        repeat
            RenderStepped:wait()
            if core_checkers.selection_box_selected == "" and core_checkers.queue_inv == nil then continue end
            break
        until core_checkers.queue_inv ~= nil
        if core_checkers.queue_inv ~= nil then core_checkers.selection_box_selected = "none" end
        if core_checkers.selection_box_selected ~= "none" then
            _G.whistle_at = core_checkers.selection_box_selected
            drinking = "advance"
            if core_checkers.selection_box_selected == "defend" then drinking = "defend" end
            if core_checkers.selection_box_selected == "focus" then drinking = "focus" end
            _G.popupmsg("orderissue" .. math.random(1, 100), "#whistle_issue_" .. drinking, 1)
        end
        core_game.selectionboxes.Visible = false
        core_checkers.selection_box_selected = ""
        action.Value = false
        return
    end
    if Value_2 == "lebel" then
        if action.Value == true then return end
        r29.alt_mode = not r29.alt_mode
        action.Value = true
        if r29.alt_mode == true then
            _G.popupmsg("alt_on", "#lebel_firemode_single", 1)
            r25.alt_mode_on:Play(0.2, 1, 1)
        else
            _G.popupmsg("alt_off", "#lebel_firemode_repeating", 1)
            r25.alt_mode_off:Play(0.2, 1, 1)
        end
        bFunctions:s_wait(0.5)
        action.Value = false
        return
    end
    if Value_2 == "pieper" then
        if action.Value == true then return end
        if _G.get_settings("qprimeknell") == true then
            _G.pieper_alt = true
            if r29.slide_locked ~= false or action.Value ~= false then
                _G.pieper_alt = false
                return
            end
            r92()
            _G.pieper_alt = false
            return
        end
        if _G.pieper_alt == nil then _G.pieper_alt = false end
        _G.pieper_alt = not _G.pieper_alt
        if _G.pieper_alt == true then
            _G.popupmsg("alt_on", "#pieper_firemode_manual", 1)
            return
        end
        _G.popupmsg("alt_off", "#pieper_firemode_double", 1)
        return
    end
    local r5_p56
    if Value_2 == "walker" then
        if action.Value == true then return end
        action.Value = true
        drinking = 1
        if Character:FindFirstChild("perk") and Character.perk.Value == "vet" then
            local amount_3 = true
            local stop_movement_3 = tick()
            while true do
                if keysheld[_G.get_keybinds("alt")] ~= nil then break end
                game:GetService("RunService").RenderStepped:Wait()
            end
            while true do
                if not keysheld[_G.get_keybinds("alt")] then break end
                game:GetService("RunService").RenderStepped:Wait()
                if tick() - stop_movement_3 < 0.2 then continue end
                amount_3 = false
                break
            end
            if not amount_3 then
                r25.spin_start:Play(0.1, 1, 1 / drinking)
                bFunctions:s_wait(drinking * 1.5)
                r25.spin_loop:Play(0.1, 1, 1 / drinking)
                while true do
                    if keysheld[_G.get_keybinds("alt")] == nil then break end
                    bFunctions:s_wait(drinking * 0.567)
                end
                r25.spin_loop:Stop(0.1)
                if Character:FindFirstChild("flashy_walker_spin") and true or false then
                    r25.spin_end_flashy:Play(0.1, 1, 1 / drinking)
                    bFunctions:s_wait(drinking * 1.75)
                    events.game_handler:Fire("walker_cool")
                    bFunctions:s_wait(drinking * 0.25)
                else
                    r25.spin_end:Play(0.1, 1, 1 / drinking)
                    bFunctions:s_wait(drinking * 1)
                end
                action.Value = false
                return
            end
        end
        drinking = 1.3
        r25.spin_cylinder:Play(0.1, 1, 1 / drinking)
        bFunctions:s_wait(drinking * 0.6)
        local amount_2 = math.random(4, 9)
        local __up1 = Value_2
        if r18 ~= "" then __up1 = r18 end
        r5_p56 = {
            char = Character,
            originweapon = __up1,
            weapon = Value_2,
            model = Value_3,
            module = r20,
            core = shield_supplies
        }
        weaponEffects("walker_cylinder_rotate", {main = r5_p56, add_amount = amount_2})
        for i_0 = 1, amount_2 do
            r5_p56, __up1 = _G, "walkercylinder" .. Parent_2.slot.Value
            r5_p56[__up1] += 1
            if _G["walkercylinder" .. Parent_2.slot.Value] > 6 then
                _G["walkercylinder" .. Parent_2.slot.Value] = 1
            end
        end
        bFunctions:s_wait(drinking * 0.3)
        local r4 = {}
        __up1 = Value_2
        if r18 ~= "" then __up1 = r18 end
        r5_p56 = {
            char = Character,
            originweapon = __up1,
            weapon = Value_2,
            model = Value_3,
            module = r20,
            core = shield_supplies
        }
        r4.main = r5_p56
        weaponEffects("walker_cylinder_rotate", r4)
        local stop_movement_2, r3_p56 = _G, "walkercylinder" .. Parent_2.slot.Value
        stop_movement_2[r3_p56] += 1
        if _G["walkercylinder" .. Parent_2.slot.Value] > 6 then
            _G["walkercylinder" .. Parent_2.slot.Value] = 1
        end
        bFunctions:s_wait(drinking * 0.2)
        action.Value = false
        return
    end
    if Value_2 == "mares" then
        if action.Value == true then return end
        if Character:FindFirstChild("class") and Character.class.Value == "conscript" then return end
        r86(false)
        return
    end
    if Value_2 == "autosg" then
        if action.Value == true then return end
        if Character:FindFirstChild("class") and Character.class.Value == "conscript" then return end
        if Value_2 == "autosg" and r18 == "autosgvariant" then return end
        r86(false)
        return
    end
    if Value_2 == "springfield" then
        if action.Value == true or r18 == "springfieldvariant" then return end
        if r29.pedersen_mag == nil then
            r29.pedersen_mag = 0
            if r29.extra_mag == nil then r29.extra_mag = false end
            r29.initial_mag = true
        end
        if r29.pedersen_mag <= 1 and r29.extra_mag == false and r29.initial_mag == false and r29.alt_mode == false then
            drinking = Character
            if drinking then
                drinking = Character:FindFirstChild("perk")
                if drinking then drinking = Character.perk.Value == "vet" end
            end
            _G.popupmsg("pedersen_nomags", not drinking and "#springfield_pedersen_empty" or "#springfield_pedersen_empty_vet", 1)
            return
        end
        action.Value = true
        r29.state = "reload"
        if r29.alt_mode == false then
            r25.pedersen_bolt_remove:Play(0.2, 1, 0.5)
            bFunctions:s_wait(2)
            r25.pedersen_device_on:Play(0.2, 1, 0.5)
            bFunctions:s_wait(2)
            r25.pedersen_mag_in:Play(0.2, 1, 0.5)
            bFunctions:s_wait(2)
            if r29.pedersen_mag == 0 then
                if r29.initial_mag == false then r29.extra_mag = false end
                r29.initial_mag = false
                r29.pedersen_mag = 40
                if r29.newmag_chamber and r29.newmag_chamber == true then
                    r29.newmag_chamber = false
                    drinking = r29
                    drinking.pedersen_mag += 1
                else
                    r25.pedersen_charge:Play(0.2, 1, 1)
                    bFunctions:s_wait(1)
                end
            end
            r29.jam_count = math.random(7, 18)
            r20.fire_rate = 0.333
            r20.recoil = 1
            r29.last_mag = shield_supplies.ammo_mag
            shield_supplies.pedersen_device = true
            shield_supplies.ammo_mag = r29.pedersen_mag
        else
            drinking = "pedersen_mag_out"
            if shield_supplies.ammo_mag <= 1 then
                drinking = "pedersen_mag_eject"
                if shield_supplies.ammo_mag == 1 then r29.newmag_chamber = true end
                shield_supplies.ammo_mag = 0
            end
            r25[drinking]:Play(0.2, 1, 0.5)
            bFunctions:s_wait(2)
            r25.pedersen_device_off:Play(0.2, 1, 0.5)
            bFunctions:s_wait(2)
            r25.pedersen_bolt_place:Play(0.2, 1, 0.5)
            bFunctions:s_wait(2)
            r29.pedersen_mag = shield_supplies.ammo_mag
            shield_supplies.ammo_mag = r29.last_mag
            shield_supplies.pedersen_device = false
            local r3_p56, r5_p56
            if shield_supplies.ammo_mag <= 0 then
                r3_p56 = {}
                r5_p56 = Value_2
                if r18 ~= "" then r5_p56 = r18 end
                r3_p56.main = {
                    char = Character,
                    originweapon = r5_p56,
                    weapon = Value_2,
                    model = Value_3,
                    module = r20,
                    core = shield_supplies
                }
                weaponEffects("set_chamber_empty", r3_p56)
            end
            r25.cycle_pedersen:Play(0.2, 1, 1)
            bFunctions:s_wait(1)
            if shield_supplies.ammo_mag <= 0 then
                local __up1 = Value_2
                if r18 ~= "" then __up1 = r18 end
                weaponEffects("set_chamber_full", {
                    main = {
                        char = Character,
                        originweapon = __up1,
                        weapon = Value_2,
                        model = Value_3,
                        module = r20,
                        core = shield_supplies
                    }
                })
            end
            r20 = bFunctions:deepCopy(require(game.ReplicatedStorage.weapon_modules:FindFirstChild(Value_2)))
        end
        r29.interrupt_reload = false
        r29.state = "normal"
        action.Value = false
        r29.alt_mode = not r29.alt_mode
        return
    end
    if Value_2 == "enfield" then
        if action.Value == true then return end
        if Parent_2:FindFirstChild("gl_uses") == nil then return end
        if r18 == "enfieldvariant" then return end
        if shield_supplies.blank_round_loaded == nil then
            shield_supplies.blank_round_loaded = false
            r29.grenade_fired = false
        end
        r29.state = "reload"
        if r29.alt_mode == false then
            if Parent_2.gl_uses.Value <= 0 then
                r29.state = "normal"
                drinking = Character
                if drinking then
                    drinking = Character:FindFirstChild("perk")
                    if drinking then drinking = Character.perk.Value == "vet" end
                end
                _G.popupmsg("nogl_left", not drinking and "#enfield_grenades_empty" or "#enfield_grenades_empty_vet", 1)
                return
            end
            r29.alt_mode = true
            action.Value = true
            r25.cutoff_on:Play(0.1, 1, 2)
            bFunctions:s_wait(0.25)
            if shield_supplies.blank_round_loaded == false then
                drinking = "load_blank"
                if Character.perk.Value == "vet" and shield_supplies.ammo_mag > 0 then
                    drinking = "load_blank_vet"
                    core_checkers[bipod .. "_reserves"] = core_checkers[bipod .. "_reserves"] + 1
                end
                r25[drinking]:Play(0.1, 1, 0.6666666666666666)
                bFunctions:s_wait(1.5)
                r25.blank_end:Play(0.1, 1, 2)
                bFunctions:s_wait(0.5)
                if shield_supplies.ammo_mag > 0 then shield_supplies.ammo_mag -= 1 end
            end
            shield_supplies.blank_round_loaded = true
            shield_supplies.ammo_mag += 1
            r25.load_grenade:Play(0.1, 1, 0.6666666666666666)
            bFunctions:s_wait(1.5)
            action.Value = false
        else
            r29.alt_mode = false
            action.Value = true
            drinking = "unload_grenade"
            local amount_2 = 1.5
            if shield_supplies.blank_round_loaded == false then
                drinking = "discard_grenade"
                amount_2 = 1
            end
            r25[drinking]:Play(0.1, 1, 1 / amount_2)
            bFunctions:s_wait(amount_2)
            r25.cutoff_off:Play(0.2, 1, 2)
            bFunctions:s_wait(0.25)
            local stop_movement_2 = false
            if shield_supplies.ammo_mag > 1 then
                stop_movement_2 = true
                r25.blank_boltback:Play(0.2, 1, 1)
                bFunctions:s_wait(0.5)
                r25.reload_end:Play(0.2, 1, 2)
                bFunctions:s_wait(0.5)
            end
            if shield_supplies.blank_round_loaded == true then shield_supplies.ammo_mag -= 1 end
            if stop_movement_2 == true then shield_supplies.blank_round_loaded = false end
            action.Value = false
        end
        r29.state = "normal"
        r29.interrupt_reload = false
        return
    end
    if Value_2 == "dbgun" then
        if action.Value == true then return end
        drinking = tick() - r29.alt_cd
        if drinking <= 0.3 then return end
        r29.alt_mode = not r29.alt_mode
        r29.alt_cd = tick()
        if r29.alt_mode == true then
            _G.popupmsg("alt_on", "#dbgun_firemode_double", 1)
            return
        end
        _G.popupmsg("alt_off", "#dbgun_firemode_single", 1)
        return
    end
    local amount
    if Value_2 == "saa" then
        if action.Value == true then return end
        if shield_supplies.ammo_mag <= 0 then return end
        if r18 ~= "" then return end
        if action.Value == false then
            action.Value = true
            core_checkers.sprint_block = true
            r29.alt_mode = true
            r25.quickdraw_start:Play(0.2, 1, 1)
            drinking = tick()
            repeat
                core_checkers.aim_time = tick()
                RenderStepped:wait()
                local amount_2 = tick() - drinking
            until amount_2 >= 0.75
            r25.quickdraw:Play(0.2, 1, 0.5)
            amount = false
            while true do
                core_checkers.aim_time = tick()
                if keysheld.m1 == true and core_checkers.jumped_air == false then
                    amount = true
                    break
                end
                if keysheld[_G.get_keybinds("reload")] == true or keysheld[_G.get_keybinds("alt")] == true or keysheld[_G.get_keybinds("checkammo")] == true or core_checkers.queue_inv ~= nil then
                    break
                end
                RenderStepped:Wait()
            end
            r25.quickdraw:Stop(0.2)
            action.Value = false
            if amount == true then r92() end
            r29.alt_mode = false
            core_checkers.sprint_block = false
            return
        end
    elseif Value_2 == "scho" then
        if action.Value == true then return end
        if r29.scho_spin == nil then r29.scho_spin = 0 end
        if action.Value ~= false or tick() - r29.alt_cd < 1 then return end
        drinking = tick() - r29.alt_cd
        if drinking < 1 or tick() - r29.alt_cd >= 1.0833333333333335 then
            r29.scho_spin = 0
            r25.spin_start:Play(0.3, 1, 1.2)
            r29.alt_cd = tick()
            return
        end
        r25.spin:Play(0.3, 1, 1.2)
        r29.alt_cd = tick() - 0.4166666666666667
        r29.scho_spin += 1
        if r29.scho_spin >= 5 and Value_2 == "scho" then
            drinking = Instance.new("StringValue")
            game:GetService("Debris"):AddItem(drinking, 50)
            drinking.Name = "morale"
            drinking.Parent = Character
            r29.scho_spin = 0
            return
        end
    else
        if Value_2 == "mauser" or Value_2 == "lever" or Value_2 == "steyr" or Value_2 == "rsc" then
            if action.Value == true then return end
            if Character:FindFirstChild("class") and Character.class.Value == "conscript" then return end
            if Value_2 == "lever" and r18 == "levervariant" then return end
            if Value_2 == "steyr" and r18 == "steyrvariant" then return end
            r86(false)
            return
        end
        if Value_2 == "remington" then
            if action.Value == true or r18 ~= "" then return end
            r29.alt_mode = not r29.alt_mode
            if r29.alt_mode == true then
                _G.popupmsg("alt_on", "#remington_alt_melee", 1)
                return
            end
            _G.popupmsg("alt_off", "#remington_alt_throw", 1)
            return
        end
        if Value_2 == "mpistol" then
            if action.Value == true then return end
            bFunctions:soundHandler({
                directory = {"tools", "shared"}, soundfile = "reloadstart", pitchvariation = 0.1,
                location = Character.HumanoidRootPart
            })
            action.Value = true
            r25.tag_look:Play(0.1, 1, 0.5)
            delay(0.1, function() -- Line: 8086 | Upvalues: ("bFunctions" (upval), "Character" (upval), "visualEffects" (upval))
                bFunctions:soundHandler({
                    directory = {"tools", "shared", "gsfx", "generalpouch"},
                    pitchvariation = 0.1,
                    soundfile = "generalpouch" .. math.random(1, 2),
                    location = Character.HumanoidRootPart
                })
                visualEffects("faketag_hand", {char = Character})
            end)
            delay(0.3, function() -- Line: 8102 | Upvalues: ("bFunctions" (upval), "Character" (upval))
                bFunctions:soundHandler({
                    directory = {"tools", "mpistol"},
                    pitchvariation = 0.1,
                    soundfile = "tag_rattle" .. math.random(1, 3),
                    location = Character.HumanoidRootPart
                })
            end)
            bFunctions:s_wait(1)
            drinking = tick()
            r25.tag_look:AdjustSpeed(0)
            r25.tag_look.TimePosition = 0.5
            while true do
                if keysheld[_G.get_keybinds("alt")] == nil and tick() - drinking >= 0.5 then break end
                r25.tag_look.TimePosition = 0.5
                RenderStepped:Wait()
            end
            bFunctions:soundHandler({
                directory = {"tools", "shared"}, soundfile = "reloadend", pitchvariation = 0.1,
                location = Character.HumanoidRootPart
            })
            r25.tag_look.TimePosition = 0.5
            r25.tag_look:AdjustSpeed(0.5)
            delay(0.5, function() -- Line: 8139 | Upvalues: ("bFunctions" (upval), "Character" (upval))
                bFunctions:soundHandler({
                    directory = {"tools", "mpistol"},
                    pitchvariation = 0.1,
                    soundfile = "tag_rattle" .. math.random(1, 3),
                    location = Character.HumanoidRootPart
                })
            end)
            delay(0.7, function() -- Line: 8148 | Upvalues: ("visualEffects" (upval), "Character" (upval))
                visualEffects("faketag_hand", {char = Character})
            end)
            bFunctions:s_wait(1.2)
            action.Value = false
            return
        end
        local stop_movement_2
        if Value_2 == "vanguardshield" then
            if action.Value == true then return end
            if Parent_2:FindFirstChild("client_inactive") then return end
            drinking = "shield_foldout"
            amount = 1.75
            if r29.alt_mode == false then
                stop_movement_2 = true
                if Value_3:FindFirstChild("special") and Value_3.special:FindFirstChild("leftshield") and Value_3.special:FindFirstChild("rightshield") and Value_3.special.leftshield:FindFirstChild("damagepart") and Value_3.special.rightshield:FindFirstChild("damagepart") and Value_3.special.leftshield.damagepart.Transparency == 1 and Value_3.special.rightshield.damagepart.Transparency == 1 then
                    stop_movement_2 = false
                end
                if stop_movement_2 == true then
                    core_checkers.inv_block_reason = _G.localizationdebug == true and "#vanguardshield_blockswap" or localize("vanguardshield_blockswap")
                    core_checkers.inv_swapping = false
                end
            else
                amount = 1
                drinking = "shield_foldin"
                core_checkers.inv_block_reason = ""
                core_checkers.inv_swapping = true
            end
            if r29.dual_wield_tool == nil then amount = 1.75 end
            if not Value_3:FindFirstChild("special") or not Value_3.special:FindFirstChild("leftshield") or not Value_3.special:FindFirstChild("rightshield") or not Value_3.special.leftshield:FindFirstChild("damagepart") or not Value_3.special.rightshield:FindFirstChild("damagepart") then
                r87_0(false)
                return
            end
            action.Value = true
            local r4
            if Value_3.special.leftshield.damagepart.Transparency == 0 or Value_3.special.rightshield.damagepart.Transparency == 0 then
                r4 = {directory = {"tools", "shared"}}
                r4.soundfile = "unready" .. math.random(1, 4)
                r4.location = Character.HumanoidRootPart
                bFunctions:soundHandler(r4)
            end
            if Value_3.special.leftshield.damagepart.Transparency == 0 then
                r25[drinking .. "_left"]:Play(0.1, 1, 2 * amount)
                bFunctions:s_wait(0.3 / amount)
                bFunctions:soundHandler({
                    directory = {"tools", Value_2},
                    pitchvariation = 0.1,
                    soundfile = "shield_shuffle" .. math.random(1, 3),
                    location = Character.HumanoidRootPart
                })
                bFunctions:soundHandler({
                    directory = {"tools", Value_2},
                    soundfile = drinking, pitchvariation = 0.1,
                    location = Character.HumanoidRootPart
                })
                bFunctions:s_wait(0.2 / amount)
            end
            if Value_3.special.rightshield.damagepart.Transparency == 0 then
                r25[drinking .. "_right"]:Play(0.1, 1, 2 * amount)
                bFunctions:s_wait(0.3 / amount)
                bFunctions:soundHandler({
                    directory = {"tools", Value_2},
                    pitchvariation = 0.1,
                    soundfile = "shield_shuffle" .. math.random(1, 3),
                    location = Character.HumanoidRootPart
                })
                bFunctions:soundHandler({
                    directory = {"tools", Value_2},
                    soundfile = drinking, pitchvariation = 0.1,
                    location = Character.HumanoidRootPart
                })
                bFunctions:s_wait(0.2 / amount)
            end
            action.Value = false
            r87_0(false)
            return
        end
        if r20.tooltype == "stims" then
            if action.Value == true then
                if core_game.selectionboxes.Visible then core_game.selectionboxes.Visible = false end
                r93 = true
                return
            end
            if Character.supplies.Value <= 0 then
                _G.popupmsg("stim_supply", "#stims_supplies", 1)
                return
            end
            drinking = 0
            amount = 0
            local stop_movement_3 = false
            action.Value = true
            core_checkers.inv_swapping = false
            r93 = false
            while true do
                if action.Value ~= true then break end
                if stop_movement_3 and not core_game.selectionboxes.Visible and _G.get_settings("oldmortselection") ~= true or Character.supplies.Value <= 0 then
                    break
                end
                if _G.get_settings("oldmortselection") ~= false and amount > 0 then break end
                if _G.get_settings("continuemortselection") ~= true and amount > 0 or r93 ~= false then break end
                drinking = 0
                if _G.get_settings("oldmortselection") == true then
                    _G.popupmsg("stim_popup", "#stims_oldselection", 1)
                    local r3_p56 = tick()
                    r25.choosing:Play(0.3, 1, 0.5)
                    repeat
                        drinking = 0
                        if keysheld[Enum.KeyCode.One] then
                            drinking = 1
                        elseif keysheld[Enum.KeyCode.Two] then
                            drinking = 2
                        elseif keysheld[Enum.KeyCode.Three] then
                            drinking = 3
                        elseif keysheld[Enum.KeyCode.Four] then
                            drinking = 4
                        elseif keysheld[Enum.KeyCode.Five] then
                            drinking = 5
                        elseif keysheld[Enum.KeyCode.Six] then
                            drinking = 6
                        end
                        if tick() - r3_p56 >= 0.5 and (keysheld[Enum.KeyCode.Q] == true or keysheld.m1 == true or r93 == true) then
                            break
                        end
                        RenderStepped:wait()
                    until drinking ~= 0
                    if r93 == true then break end
                    r93 = false
                else
                    r25.choosing:Play(0.3, 1, 0.5)
                    core_checkers.selection_box_selected = ""
                    core_checkers.display_selections({"1", "2", "3", "4", "5", "6"})
                    stop_movement_3 = true
                    r93 = false
                    repeat
                        RenderStepped:wait()
                        if core_checkers.selection_box_selected == "" and core_checkers.queue_inv == nil and action.Value ~= false and core_game.selectionboxes.Visible and r93 ~= true then
                            continue
                        end
                        break
                    until r93 == true
                    r93 = false
                    if core_checkers.queue_inv ~= nil or action.Value == false then
                        core_checkers.selection_box_selected = "none"
                    end
                    if core_checkers.selection_box_selected ~= "none" then
                        drinking = tonumber(core_checkers.selection_box_selected)
                    end
                    core_checkers.selection_box_selected = ""
                end
                if not (typeof(drinking) ~= "number" or drinking <= 0 or drinking > 6) then
                    core_game.selectionboxes.Visible = true
                    amount += 1
                    bFunctions:soundHandler({
                        directory = {"tools", "stimbottle"}, soundfile = "grab", pitchvariation = 0.1,
                        location = Character.HumanoidRootPart
                    })
                    _G.popupmsg("stim_load" .. math.random(1, 100), "#stims_add_" .. r29.stimulants[drinking].int, 1)
                    Character.supplies.Value = Character.supplies.Value - 1
                    if Character.supplies.Value <= 0 or _G.get_settings("continuemortselection") == false then
                        core_game.selectionboxes.Visible = false
                    end
                    events.medical_handler:Fire("apply_stims", drinking)
                    if shield_supplies.stim_content == nil then shield_supplies.stim_content = {} end
                    if shield_supplies.stim_colour == nil then
                        shield_supplies.stim_colour = Color3.fromRGB(199, 199, 199)
                    end
                    shield_supplies.stim_colour = shield_supplies.stim_colour:Lerp(game.ReplicatedStorage.outfits.mortician:FindFirstChild("stim" .. drinking).vial.inside.Color, 0.5)
                    delay(0.2, function() -- Line: 8380 | Upvalues: ("weaponEffects" (upval), "Value_2" (upval), "r18" (upval), "Character" (upval), "Value_3" (upval), "r20" (upval), "shield_supplies" (upval))
                        local __up1 = Value_2
                        if r18 ~= "" then __up1 = r18 end
                        weaponEffects("stimbottle_changecolour", {
                            main = {
                                char = Character,
                                originweapon = __up1,
                                weapon = Value_2,
                                model = Value_3,
                                module = r20,
                                core = shield_supplies
                            },
                            colour = shield_supplies.stim_colour
                        })
                    end)
                    table.insert(shield_supplies.stim_content, drinking)
                    r29.alt_mode = true
                    r29.stim_uses = 3
                    r25.load:Play(0.1, 1, 1.5)
                    bFunctions:s_wait(0.73)
                    spawn(function() -- Line: 8393 | Upvalues: ("weaponEffects" (upval), "Value_2" (upval), "r18" (upval), "Character" (upval), "Value_3" (upval), "r20" (upval), "shield_supplies" (upval))
                        local __up1 = Value_2
                        if r18 ~= "" then __up1 = r18 end
                        weaponEffects("stim_empty_vial", {
                            main = {
                                char = Character,
                                originweapon = __up1,
                                weapon = Value_2,
                                model = Value_3,
                                module = r20,
                                core = shield_supplies
                            }
                        })
                    end)
                    r25.load:Stop(0.3)
                end
            end
            r25.choosing:Stop(0.3)
            core_game.selectionboxes.Visible = false
            core_checkers.inv_swapping = true
            action.Value = false
            return
        end
        if r20.tooltype == "firstaid" then
            if action.Value == true then return end
            left_aiming(true)
            return
        end
        if r20.tooltype == "binocs" then
            if Character:FindFirstChild("binoc_ping_cd") then return end
            if action.Value == true then return end
            drinking = Instance.new("StringValue")
            game:GetService("Debris"):AddItem(drinking, 2)
            drinking.Name = "binoc_ping_cd"
            drinking.Parent = Character
            r25.point:Play(0.3, 1, 1)
            local amount_2, stop_movement_3 = bFunctions:raycastline({
                point = CurrentCamera.CFrame.Position,
                destination = CurrentCamera.CFrame.LookVector, range = 500,
                layermask = r42
            })
            if stop_movement_3 then events.interaction_handler:Fire(Parent_2, "binoc_ping", stop_movement_3) end
        end
    end
end
local function r95() -- Line: 8450 | Upvalues: ("action" (copy), "core_checkers" (copy), "r29" (copy), "bFunctions" (copy), "CurrentCamera" (copy), "r39" (copy), "r25" (copy), "events" (copy), "Parent_2" (copy))
    if action.Value == true then return end
    if core_checkers.aiming == false then return end
    if r29.internal_binocs == nil then r29.internal_binocs = 0 end
    if tick() - r29.internal_binocs <= 0.5 then return end
    local r0_p57, r1 = bFunctions:raycastline({
        point = CurrentCamera.CFrame.Position,
        destination = CurrentCamera.CFrame.LookVector, range = 500,
        layermask = r39
    })
    if (r0_p57 and (r0_p57.Name == "leftshield" or r0_p57.Name == "rightshield" or r0_p57.Name == "mainshield" or r0_p57.Name == "topshield")) and (r0_p57.Parent and r0_p57.Parent.Parent and r0_p57.Parent.Parent.Parent and r0_p57.Parent.Parent.Parent:FindFirstChild("Torso")) then
        r0_p57 = r0_p57.Parent.Parent.Parent.Torso
    end
    if r0_p57 and r0_p57.Name == "protect" and r0_p57.Parent and r0_p57.Parent.Name == "parts" and r0_p57.Parent.Parent and r0_p57.Parent.Parent.Parent and r0_p57.Parent.Parent.Parent:FindFirstChild("Torso") then
        r0_p57 = r0_p57.Parent.Parent.Parent.Torso
    end
    if r0_p57 and r0_p57.Parent and r0_p57.Parent:FindFirstChild("Humanoid") and r0_p57.Parent.Humanoid.Health > 0 and r0_p57.Parent:FindFirstChild("mark_cd") == nil then
        r29.internal_binocs = tick()
        r25.point:Play(0.3, 1, 1)
        events.interaction_handler:Fire(Parent_2, "binoc_mark", r0_p57.Parent)
    end
end
local function r96_0() -- Line: 8491 | Upvalues: ("action" (copy), "r29" (copy), "r20" (ref), "core_checkers" (copy), "Parent_2" (copy), "r25" (copy), "bFunctions" (copy), "events" (copy), "visualEffects" (copy), "Character" (copy), "Humanoid" (copy))
    if action.Value == true or tick() - r29.draw < r20.draw_speed / core_checkers.draw_modifier then
        return
    end
    if Parent_2:FindFirstChild("inactive") or Parent_2:FindFirstChild("client_inactive") then return end
    action.Value = true
    local client_inactive = Instance.new("StringValue")
    game:GetService("Debris"):AddItem(client_inactive, 2)
    client_inactive.Name = "client_inactive"
    client_inactive.Parent = Parent_2
    r25.use:Play(0.1, 1, 1)
    bFunctions:s_wait(0.4)
    events.interaction_handler:Fire(Parent_2, "lancerstimmed")
    bFunctions:s_wait(0.55)
    visualEffects("lancer_fakestim", {char = Character})
    bFunctions:s_wait(0.1)
    action.Value = false
    Humanoid:UnequipTools()
end
local function r97_0() -- Line: 8523 | Upvalues: ("r29" (copy), "shield_supplies" (ref), "action" (copy), "r20" (ref), "core_checkers" (copy), "bFunctions" (copy), "Character" (copy), "r25" (copy), "r84_0" (copy), "weaponEffects" (copy), "Value_2" (ref), "r18" (ref), "Value_3" (copy))
    if r29.alt_mode == false or shield_supplies.stim_content == nil or #shield_supplies.stim_content <= 0 then
        return
    end
    if action.Value == true or tick() - r29.draw < r20.draw_speed / core_checkers.draw_modifier then
        return
    end
    action.Value = true
    bFunctions:soundHandler({
        directory = {"tools", "stimbottle"},
        pitchvariation = 0.1,
        soundfile = "shake" .. math.random(1, 3),
        location = Character.HumanoidRootPart
    })
    delay(0.6, function() -- Line: 8540 | Upvalues: ("bFunctions" (upval), "Character" (upval))
        bFunctions:soundHandler({
            directory = {"tools", "stimbottle"}, soundfile = "throw", pitchvariation = 0.1,
            location = Character.HumanoidRootPart
        })
    end)
    r25.ready:Play(0.1, 1, 1.5)
    bFunctions:s_wait(0.7)
    bFunctions:fast_spawn(function() -- Line: 8565 | Upvalues: ("r84_0" (upval))
        r84_0(4, 2, 0.02)
    end)
    r29.alt_mode = false
    local r2 = {}
    local __up10 = Value_2
    if r18 ~= "" then __up10 = r18 end
    r2.main = {
        char = Character,
        originweapon = __up10,
        weapon = Value_2,
        model = Value_3,
        module = r20,
        core = shield_supplies
    }
    weaponEffects("stimbottle_invis", r2)
    r25.throw_over:Play(0.1, 1, 2)
    bFunctions:s_wait(0.5)
    r25.throw_over:Stop(0.2)
    r25.new:Play(0.2, 1, 1.5)
    bFunctions:s_wait(0.75)
    action.Value = false
end
pistol = function() -- Line: 8588 | Upvalues: ("Parent_2" (copy), "Character" (copy), "bFunctions" (copy), "Value_2" (ref), "core_checkers" (copy), "r84_0" (copy), "r29" (copy))
    if Parent_2:FindFirstChild("client_inactive") then return end
    local equipment = Character:FindFirstChild("equipment")
    if equipment == nil or equipment.Value <= 0 then return end
    local r1 = 2
    local r2 = 0.02
    if not Character:FindFirstChild("class") or Character.class.Value ~= "lancer" or not Character:FindFirstChild("perk") or Character.perk.Value ~= "marksman" then
        bFunctions:soundHandler({directory = {"tools", Value_2}, soundfile = "throw1", location = Character.HumanoidRootPart})
        bFunctions:soundHandler({directory = {"tools", Value_2}, soundfile = "throw2", location = Character.HumanoidRootPart})
        core_checkers.equipment_show_cd = tick()
        core_checkers.equipment_ticker = tick()
        equipment.Value -= 1
        bFunctions:fast_spawn(function() -- Line: 8629 | Upvalues: ("r84_0" (upval), "r1" (ref), "r2" (ref))
            r84_0(8, r1, r2)
        end)
        r29.alt_mode = false
        return
    end
    r1 = 6
    r2 = 0.01
    local r3 = 0.1
    bFunctions:soundHandler({directory = {"tools", Value_2}, soundfile = "throw1", location = Character.HumanoidRootPart})
    bFunctions:soundHandler({directory = {"tools", Value_2}, soundfile = "throw2", location = Character.HumanoidRootPart})
    core_checkers.equipment_show_cd = tick()
    core_checkers.equipment_ticker = tick()
    equipment.Value -= 1
    bFunctions:fast_spawn(function() -- Line: 8629 | Upvalues: ("r84_0" (upval), "r1" (ref), "r2" (ref))
        r84_0(8, r1, r2)
    end)
    r29.alt_mode = false
end
local r98_0 = 0
local function r99_0() -- Line: 8797 | Upvalues: ("core_checkers" (copy), "r98_0" (ref), "LocalPlayer" (copy), "Value_3" (copy), "Character" (copy), "bFunctions" (copy), "r29" (copy), "RenderStepped" (copy), "Humanoid" (copy), "keysheld" (copy), "action" (copy), "r25" (copy), "visualEffects" (copy), "r20" (ref), "events" (copy), "Parent_2" (copy), "r47" (ref))
    if core_checkers.aiming == false then return end
    if tick() - r98_0 <= 0.5 then return end
    if core_checkers.shift_locked == false then return end
    if workspace.throwables:FindFirstChild(LocalPlayer.Name .. "_firebeam") == nil or workspace.throwables:FindFirstChild(LocalPlayer.Name .. "_firemuzzle") == nil then
        return
    end
    if Value_3:FindFirstChild("firehitbox") == nil then return end
    if tick() - core_checkers.fall_damage_interrupt <= 0 then return end
    if workspace.serverStuff.values.gamemode.Value == "truce" and Character:FindFirstChild("engage") == nil then
        return
    end
    if workspace.serverStuff.medievalmode.Value == true then
        _G.popupmsg("guninmedieval", "#message_deny_medieval", 1)
        return
    end
    bFunctions:soundHandler({
        directory = {"tools", "wex"}, soundfile = "trigger_hit", pitchvariation = 0.1,
        location = Character.HumanoidRootPart
    })
    if r29.flamer_fuel <= 0 then
        spawn(function() -- Line: 8834 | Upvalues: ("RenderStepped" (upval), "Humanoid" (upval), "core_checkers" (upval), "r29" (upval), "keysheld" (upval), "bFunctions" (upval), "Character" (upval))
            repeat
                RenderStepped:Wait()
                if Humanoid ~= nil and Humanoid.Health > 0 and tick() - core_checkers.fall_damage_interrupt > 0 and r29.equipped ~= false and core_checkers.aiming ~= false and keysheld.m1 == true and core_checkers.shift_locked ~= false then
                    continue
                end
                bFunctions:soundHandler({
                    directory = {"tools", "wex"}, soundfile = "trigger_release", pitchvariation = 0.1,
                    location = Character.HumanoidRootPart
                })
                return
            until core_checkers.shift_locked == false
        end)
        return
    end
    local r2 = {
        directory = {"tools", "wex"},
        pitchvariation = 0.1,
        soundfile = "ready" .. math.random(1, 4),
        location = Character.HumanoidRootPart
    }
    bFunctions:soundHandler(r2)
    action.Value = true
    local r0_p65 = "firing"
    if core_checkers.flip_cam == true then r0_p65 = "firing_left" end
    r25[r0_p65]:Play(0.2, 1, 0.1)
    if workspace.throwables:FindFirstChild(LocalPlayer.Name .. "_firemuzzle"):FindFirstChild("residual") and workspace.throwables:FindFirstChild(LocalPlayer.Name .. "_firemuzzle").residual.Enabled == false then
        visualEffects("flamer_fx", {
            beampart = workspace.throwables:FindFirstChild(LocalPlayer.Name .. "_firebeam"),
            muzzlepart = workspace.throwables:FindFirstChild(LocalPlayer.Name .. "_firemuzzle"),
            firehitbox = Value_3:FindFirstChild("firehitbox"), state = "initialsmoke"
        })
        bFunctions:s_wait(0.3)
    end
    r25[r0_p65]:AdjustSpeed(1)
    r98_0 = tick()
    core_checkers.int_speed -= r20.firing_movement
    core_checkers.slow_rotate = true
    if Value_3 then
        visualEffects("flamer_fx", {
            beampart = workspace.throwables:FindFirstChild(LocalPlayer.Name .. "_firebeam"),
            muzzlepart = workspace.throwables:FindFirstChild(LocalPlayer.Name .. "_firemuzzle"),
            firehitbox = Value_3:FindFirstChild("firehitbox"), state = "start"
        })
    end
    local r1_p65 = tick()
    repeat
        RenderStepped:Wait()
        if core_checkers.flip_cam == true and r25.firing.IsPlaying == true then
            r25.firing:Stop(0.1)
            if r25.firing_left.IsPlaying == false then r25.firing_left:Play(0.1, 1, 1) end
        end
        if core_checkers.flip_cam == false and r25.firing_left.IsPlaying == true then
            r25.firing_left:Stop(0.1)
            if r25.firing.IsPlaying == false then r25.firing:Play(0.1, 1, 1) end
        end
        if r29.flamer_fuel <= 0 then break end
        r2 = tick() - r1_p65
        if r2 >= 0.1 then
            r2 = r29
            r2.flamer_fuel -= 1
            if r29.flamer_fuel <= 0 and Character:FindFirstChild("flametankempty") == nil then
                events.interaction_handler:Fire(Parent_2, "flametankempty")
            end
            r1_p65 = tick()
            r2 = {}
            if not Value_3:FindFirstChild("firehitbox") then return end
            local r3 = workspace:GetPartsInPart(Value_3.firehitbox, r47)
            for r7, r8 in ipairs(r3) do
                if not (r8.Name == "bullet_whizz" or not r8.Parent or not r8.Parent:FindFirstChild("Humanoid") or r8.Parent.Humanoid:FindFirstChild("burning_heavy") ~= nil or r8.Parent.Humanoid.Health <= 0 or r2[r8.Parent.Name] ~= nil) then
                    r2[r8.Parent.Name] = true
                    events.interaction_handler:Fire(Parent_2, "flamethrower", r8.Parent)
                end
            end
        end
        if Humanoid == nil or Humanoid.Health <= 0 or tick() - core_checkers.fall_damage_interrupt <= 0 or r29.equipped == false then
            break
        end
        if (core_checkers.aiming == false or keysheld.m1 ~= true or core_checkers.shift_locked == false) and tick() - r98_0 >= 0.5 then
            break
        end
    until r29.flamer_fuel <= 0
    if r29.flamer_fuel <= 0 and Character:FindFirstChild("flametankempty") == nil then
        events.interaction_handler:Fire(Parent_2, "flametankempty")
    end
    if Value_3 then
        visualEffects("flamer_fx", {
            beampart = workspace.throwables:FindFirstChild(LocalPlayer.Name .. "_firebeam"),
            muzzlepart = workspace.throwables:FindFirstChild(LocalPlayer.Name .. "_firemuzzle"),
            firehitbox = Value_3:FindFirstChild("firehitbox"), state = "stop"
        })
    end
    core_checkers.int_speed += r20.firing_movement
    core_checkers.slow_rotate = false
    action.Value = false
    bFunctions:soundHandler({
        directory = {"tools", "wex"}, soundfile = "trigger_release", pitchvariation = 0.1,
        location = Character.HumanoidRootPart
    })
    r98_0 = tick()
    r25.firing_left:Stop(0.5)
    r25.firing:Stop(0.5)
end
r77 = function(r0_p67) -- Line: 8996 | Upvalues: ("r15" (ref), "Character" (copy), "action" (copy), "shield_supplies" (ref), "core_checkers" (copy), "r20" (ref), "left_aiming" (copy), "r29" (copy), "r97_0" (copy), "r96_0" (copy), "r82_0" (copy), "r83_0" (copy), "r81_0" (copy), "r95" (copy), "r99_0" (copy), "Value_2" (ref), "r18" (ref), "Parent_2" (copy), "r88_0" (copy), "RenderStepped" (copy), "r92" (ref), "r64_0" (copy), "events" (copy), "r25" (copy), "Humanoid" (copy), "bFunctions" (copy), "LocalPlayer" (copy), "base" (copy), "r85_0" (copy))
    if r15 == true then return end
    if Character:FindFirstChild("exec") then return end
    if Character:FindFirstChild("execing") then return end
    if action.Value == true then return end
    if shield_supplies.need_bolt == true then return end
    if tick() - core_checkers.fall_damage_interrupt <= 0 then return end
    if r20.tooltype == "firstaid" then
        left_aiming()
        return
    end
    local r1_p67 = tick() - r29.draw
    if r1_p67 < r20.draw_speed / core_checkers.draw_modifier then return end
    if r20.tooltype == "lantern" then return end
    if r20.tooltype == "stims" then
        r97_0()
        return
    end
    if r20.tooltype == "lancerstim" then
        r96_0()
        return
    end
    if r20.tooltype == "wrench" then
        r82_0()
        return
    end
    if r20.tooltype == "throwable" then
        r83_0()
        return
    end
    if r20.tooltype == "flagpole" then
        r81_0()
        return
    end
    if r20.tooltype == "binocs" then
        r95()
        return
    end
    if r20.tooltype == "flamer" then
        r99_0()
        return
    end
    if Value_2 == "remington" and r18 == "" and r29.alt_mode == false and action.Value == false and core_checkers.aiming == false and Parent_2:FindFirstChild("akimbo") == nil then
        r88_0()
        return
    end
    local r2
    if r29.dual_wield_tool ~= nil or Value_2 == "vanguardshield" then
        r1_p67 = Parent_2:FindFirstChild("guarding")
        r2 = false
        if Parent_2:FindFirstChild("akimbo") and Parent_2.akimbo.Value == true then r2 = true end
        local r3
        if core_checkers.aiming == true then
            if r29.dual_wield_tool ~= nil then
                if r29.dual_wield_tool:FindFirstChild("weapon") and r29.dual_wield_tool.weapon.Value == "cavsword" then
                    if not r29.dual_wield_tool or not r29.dual_wield_tool:FindFirstChild("event") then return end
                    if r1_p67 then r1_p67.Value = true end
                    r29.dual_wield_tool.event:Fire("swing_weapon")
                    repeat
                        RenderStepped:Wait()
                    until action.Value == false
                    if r29.alt_mode == false and r1_p67 then
                        r1_p67.Value = false
                        return
                    end
                else
                    if Value_2 == "vanguardshield" and r29.alt_mode == true then return end
                    r3 = tick() - core_checkers.aim_time
                    if math.clamp(r20.aim_speed / core_checkers.handling_modifier, 0.125, 10) < r3 then
                        if Parent_2:FindFirstChild("akimbo") and Parent_2.akimbo.Value == true and Parent_2:FindFirstChild("akimbo_aiming") then
                            if Parent_2.akimbo_aiming.Value == false and r29.flipflop ~= nil then
                                r0_p67 = r29.flipflop
                                if r0_p67 == true and shield_supplies.ammo_mag <= 0 and r29.dual_wield_tool.mag_empty.Value == false then
                                    r0_p67 = nil
                                end
                                if r0_p67 ~= true and r29.dual_wield_tool.mag_empty.Value == true and shield_supplies.ammo_mag > 0 then
                                    r0_p67 = true
                                end
                                r29.flipflop = not r29.flipflop
                            elseif _G.using_controller == true then
                                r0_p67 = if r0_p67 == true then nil else true
                            end
                        end
                        if r0_p67 == true then
                            if shield_supplies.ammo_mag <= 1 then r29.fire_buffer = 0 end
                            r92()
                            return
                        end
                        if not r29.dual_wield_tool or not r29.dual_wield_tool:FindFirstChild("event") or not r29.other_wep_module then
                            return
                        end
                        if not r29.dual_wield_tool:FindFirstChild("mag_empty") or r29.dual_wield_tool.mag_empty.Value ~= true then
                            r29.dual_wield_tool.event:Fire("fire_weapon")
                            return
                        end
                        r29.fire_buffer = 0
                        r29.dual_wield_tool.event:Fire("fire_weapon")
                        return
                    end
                end
            else
                if r1_p67 then r1_p67.Value = true end
                r64_0()
                if r29.alt_mode == false and r1_p67 then
                    r1_p67.Value = false
                    return
                end
            end
        else
            r3 = false
            if Value_2 == "vanguardshield" and core_checkers.sprinting == true then r3 = true end
            if r3 == false then
                if r29.dual_wield_tool and r29.dual_wield_tool:FindFirstChild("event") and r29.alt_mode == false and Value_2 == "vanguardshield" then
                    if r1_p67 then r1_p67.Value = true end
                    r29.dual_wield_tool.event:Fire("swing_weapon")
                    repeat
                        RenderStepped:Wait()
                    until action.Value == false
                    if r29.alt_mode == false and r1_p67 then
                        r1_p67.Value = false
                        return
                    end
                else
                    if r1_p67 then r1_p67.Value = true end
                    r64_0()
                    if r29.alt_mode ~= false or not r1_p67 then return end
                    r1_p67.Value = false
                end
            end
        end
        return
    end
    if r20.tooltype == "whistle" then
        core_checkers.equipment_show_cd = tick()
        r1_p67 = Character:FindFirstChild("equipment")
        if r1_p67.Value > 0 and not Character:FindFirstChild("buff_" .. _G.whistle_at .. "_already") then
            local r2
            if Character:FindFirstChild("elitekit") and Character.elitekit.Value == "radio" then
                r2 = "#whistle_issue_ineffective"
                if r1_p67.Value > 0 then
                    r2 = "#whistle_issue_survivalist"
                elseif math.random(1, 20) == 1 then
                    r2 = "#whistle_issue_annoyance"
                end
                if Character:FindFirstChild("elitekit") and Character.elitekit.Value == "radio" then
                    r2 = "#whistle_issue_radio"
                end
                _G.popupmsg("whistlecd", r2, 1)
            else
                r1_p67.Value -= 1
                r2 = _G.whistle_at
                if _G.whistle_long and (r2 ~= "advance" or not _G.get_settings("advancerollout")) then
                    r2 ..= "_long"
                end
                events.equipment_handler:Fire(r2)
            end
        end
        action.Value = true
        r25.use:Play(0.1, 1, 1)
        r25[_G.whistle_at]:Play(0.1, 1, 1)
        delay(0.1, function() -- Line: 9244 | Upvalues: ("Humanoid" (upval), "r29" (upval), "bFunctions" (upval), "Character" (upval))
            if Humanoid and Humanoid.Health > 0 and r29.equipped == true then
                bFunctions:soundHandler({
                    directory = {"tools", "whistle", "sfx"},
                    soundfile = "whistle_" .. _G.whistle_at,
                    location = Character.HumanoidRootPart
                })
            end
        end)
        bFunctions:s_wait(2.75)
        action.Value = false
        return
    end
    if r20.tooltype ~= "hammer" and r20.tooltype ~= "jaegerkit" or r29.construction_mode ~= true then
        if core_checkers.shift_locked == false then return end
        if core_checkers.aiming == false or r20.tooltype == "pick" or r20.tooltype == "melee" or r20.tooltype == "hammer" or r20.tooltype == "throwaxe" then
            if Value_2 == "rooklauncher" then return end
            r1_p67 = false
            if r25.hipfire and r18 == "" then r1_p67 = true end
            if Character:FindFirstChild("bodyshield") and shield_supplies.ammo_mag > 0 then r1_p67 = true end
            if r1_p67 == true and shield_supplies.ammo_mag > 0 then
                r92()
                return
            end
            r64_0()
            return
        end
        r1_p67 = tick() - core_checkers.aim_time
        if math.clamp(r20.aim_speed / core_checkers.handling_modifier, 0.125, 10) < r1_p67 then
            if Value_2 == "rooklauncher" then
                r85_0()
                return
            end
            r92()
        end
        return
    end
    if not r29.construct_pos or r29.construct_ready ~= true or not Character:FindFirstChild("supplies") then
        return
    end
    if _G.ping_locked == true then return end
    if Humanoid:FindFirstChild("burning_heavy") then return end
    r1_p67 = 0
    for r5_p67, r6 in ipairs(workspace.constructions:GetChildren()) do
        if not (not r6:FindFirstChild("owner") or r6.owner.Value ~= LocalPlayer.Name or r6.Name ~= r29.constructing) then
            r1_p67 += 1
        end
    end
    local r2 = base.base_constructs[r29.constructing]
    local r3 = 10
    local r4 = 1
    if r2 then
        r3 = r2.limits
        r4 = r2.cost
    end
    if r29.constructing == "Mantrap" or r29.constructing == "Dynamite Stack" or r29.constructing == "Tin Bomb" or r29.constructing == "Gas Shell" then
        r4 = 2
    end
    if r29.constructing == "Light Lure" then r4 = 1 end
    if r1_p67 < r3 then
        local r5_p67 = 0.5
        if r29.constructing == "Tripwire" then r5_p67 = 0.1 end
        if tick() - r29.construct_cd <= r5_p67 then return end
        if r4 <= Character.supplies.Value then
            r29.construct_cd = tick()
            if r20.tooltype == "hammer" then
                events.construction_handler:Fire("build", r29.constructing, r29.construct_pos)
                return
            end
            if r20.tooltype ~= "jaegerkit" then return end
            if workspace.serverStuff.values.gamemode.Value == "truce" and Character:FindFirstChild("engage") == nil then
                return
            end
            if Character:FindFirstChild("oathbroken") then
                _G.popupmsg("brokenoath", "#message_brokenoath", 1)
                return
            end
            events.interaction_handler:Fire(Parent_2, "place_trap", {trap = r29.constructing, pos = r29.construct_pos})
            return
        end
        if r20.tooltype == "hammer" then
            _G.popupmsg("construct_warn", "#message_construct_supplies", 2)
            return
        end
        _G.popupmsg("construct_warn", "#message_trap_supplies", 2)
        return
    end
    if r20.tooltype == "hammer" then
        _G.popupmsg("construct_warn", "#message_constructlimit_" .. r29.constructing, 2)
        return
    end
    _G.popupmsg("construct_warn", "#message_traplimit", 2)
end
local r100_0 = 1
local r101_0 = 0
local r102_0 = r29.construct_constructions[1]
local function r103() -- Line: 9392 | Upvalues: ("r29" (copy), "bFunctions" (copy), "CurrentCamera" (copy), "r40" (copy), "r45" (ref), "updateCharacterTransparency" (copy), "Parent_2" (copy), "Value_3" (copy), "Character" (copy), "r42" (copy), "r31" (ref), "r32" (ref), "core_checkers" (copy), "r20" (ref), "r102_0" (ref), "core_game" (copy), "max" (ref), "LocalPlayer" (copy), "r43" (copy), "r47" (ref), "r41" (copy), "r39" (copy), "localize" (copy), "Value_2" (ref), "r25" (copy), "base" (copy), "get_string_reference" (copy), "keysheld" (copy), "action" (copy), "shield_supplies" (ref), "r77" (ref))
    if r29.equipped == false then return end
    local r0_p68, r1_p68 = bFunctions:raycastline({
        point = CurrentCamera.CFrame.Position,
        destination = CurrentCamera.CFrame.LookVector, range = 500,
        layermask = r40
    })
    r45 = r1_p68
    updateCharacterTransparency()
    local r2, r3_p68, r4, r5_p68, r6, r7, r9
    if Parent_2:FindFirstChild("bipod") and Value_3 and Value_3:FindFirstChild("hitbox") then
        r2 = Character.Head.Position - vector.create(0, 0.5, 0)
        r3_p68, r4 = bFunctions:raycastline({
            point = r2 + CurrentCamera.CFrame.lookVector * 4,
            destination = -Character.HumanoidRootPart.CFrame.upVector, range = 2.25,
            layermask = r42
        })
        r5_p68, r6 = bFunctions:raycastline({
            point = r2 + CurrentCamera.CFrame.lookVector * 1.5,
            destination = -Character.HumanoidRootPart.CFrame.upVector, range = 2.25,
            layermask = r42
        })
        if r3_p68 or r5_p68 then
            Parent_2.bipod.Value = tick()
            if r31 == false then
                r31 = true
                r7 = tick() - r32
                if r7 >= 0.2 and core_checkers.aiming == true then
                    r32 = tick()
                    r9 = {directory = {"tools", "shared"}, pitchvariation = 0.1}
                    r9.soundfile = "bipod_deploy" .. math.random(1, 4)
                    r9.location = Character.HumanoidRootPart
                    bFunctions:soundHandler(r9)
                end
            end
        else
            if core_checkers.aiming == false then Parent_2.bipod.Value = 0 end
            r7 = tick() - r32
            if r7 > 0.2 and r31 == true then
                r31 = false
                r7 = tick() - r32
                if r7 >= 0.2 and core_checkers.aiming == true then
                    r32 = tick()
                    r9 = {directory = {"tools", "shared"}, pitchvariation = 0.1}
                    r9.soundfile = "bipod_undeploy" .. math.random(1, 4)
                    r9.location = Character.HumanoidRootPart
                    bFunctions:soundHandler(r9)
                end
            end
        end
    end
    if r29.construction_mode == true then
        if r20.tooltype == "jaegerkit" then
            if core_checkers.aiming == true then
                if r29.constructing ~= "Tripwire" then
                    r29.confirm_construct = 0
                    if r29.construct_holo then
                        r29.constructing = "Tripwire"
                        r29.construct_holo:Destroy()
                        r29.construct_holo = nil
                    end
                end
            elseif r29.constructing == "Tripwire" then
                r29.constructing = r102_0
                if r29.construct_holo then
                    r29.construct_holo:Destroy()
                    r29.construct_holo = nil
                end
            end
        end
        local r2
        if r29.construct_holo == nil then
            r2 = game.ReplicatedStorage.deployables:FindFirstChild(r29.constructing)
            if r2 then
                r29.construct_holo = r2:Clone()
                for r6, r7 in ipairs(r29.construct_holo:GetDescendants()) do
                    if r7:IsA("BasePart") and r7.Material ~= Enum.Material.Neon then
                        r7.CanCollide = false
                        r7.CanQuery = false
                        r7.Locked = true
                        if r7.Parent == r29.construct_holo.finished or r7.Parent.Parent == r29.construct_holo.finished then
                            r7.Transparency = 0.5
                            r7.Parent = r29.construct_holo.finished
                            r7.Material = Enum.Material.SmoothPlastic
                            continue
                        end
                        r7.Transparency = 1
                    elseif not r7:IsA("Decal") then
                    else
                        r7:Destroy()
                    end
                end
                r29.construct_holo.Parent = CurrentCamera
            end
        else
            r29.construct_pos = Character.HumanoidRootPart.CFrame + Character.HumanoidRootPart.CFrame.lookVector * 3 - vector.create(0, 2.5, 0)
            if r20.tooltype == "hammer" then r29.construct_holo:PivotTo(r29.construct_pos) end
            r2 = nil
            local r3_p68
            local r4
            local r5_p68
            local r6
            local r7
            local r8_p68, r9
            if r20.tooltype == "hammer" then
                local r7, r8_p68 = bFunctions:raycastline({
                    point = Character.HumanoidRootPart.Position,
                    destination = Character.HumanoidRootPart.CFrame.LookVector, range = 4,
                    layermask = r42
                })
                r2, r3_p68 = r7, r8_p68
                r4, r5_p68 = bFunctions:raycastline({
                    point = r3_p68,
                    destination = -Character.HumanoidRootPart.CFrame.upVector, range = 5,
                    layermask = r42
                })
                r29.construct_pos = Character.HumanoidRootPart.CFrame + Character.HumanoidRootPart.CFrame.lookVector * 3 - Vector3.new(0, (r3_p68 - r5_p68).Magnitude - 0.5, 0)
            elseif r20.tooltype == "jaegerkit" and core_game.Parent.loadout_menu.Visible == false and r45 then
                r2 = nil
                r7 = Character.Head.Position
                r9 = 7.5
                if r29.constructing == "Tripwire" then r9 += 2.5 end
                r4, r5_p68, r6 = bFunctions:raycastline({
                    point = r7,
                    destination = CFrame.new(r7, r45).LookVector,
                    range = r9,
                    layermask = r42
                })
            end
            if max then
                if r2 and r2:IsDescendantOf(max) then
                    r2 = nil
                    r4 = nil
                end
                if r4 and r4:IsDescendantOf(max) then
                    r2 = nil
                    r4 = nil
                end
            end
            if r4 and r4.Name == "nobuild" and r20.tooltype == "hammer" then
                r2 = nil
                r4 = nil
            end
            if (r4 and r4.Parent and r4.Parent.Parent and r4.Parent.Parent.Parent and r4.Parent.Parent.Parent.Parent) and (r4.Parent.Parent.Parent.Parent.Name == "Elevator" or r4.Parent.Parent.Parent.Name == "Elevator" or r4.Parent.Parent.Name == "Elevator" or r4.Parent.Name == "Elevator") then
                r2 = nil
                r4 = nil
            end
            if r20.tooltype == "jaegerkit" and r5_p68 then
                r29.construct_pos = CFrame.new(r5_p68)
                if r4 then
                    r29.construct_pos = CFrame.new(r5_p68, r5_p68 - r6) * CFrame.Angles(1.5707963267948966, 0, 0) + r6 * 0.5
                end
                if r4 and r4.Transparency == 1 then r4 = nil end
                if r29.constructing == "Tripwire" then
                    r7 = nil
                    local r8_p68 = 20
                    for r12, r13 in ipairs(workspace.constructions:GetChildren()) do
                        if not (not r13:FindFirstChild("fuse_hook") or not r13:FindFirstChild("tripwires") or r13.Name == "Tripwire" or r13:FindFirstChild("triggered") ~= nil or not r13:FindFirstChild("owner") or r13.owner.Value ~= LocalPlayer.Name or not r13:FindFirstChild("health") or r13.health.Value < 0 or not r13:FindFirstChild("core")) then
                            local magnitude = (r29.construct_pos.Position - r13.core.Position).magnitude
                            if magnitude <= r8_p68 then
                                local r15 = CFrame.new(r29.construct_pos.Position, r13.core.Position)
                                if not bFunctions:raycastline({
                                    point = r15.Position,
                                    destination = r15.LookVector * 1,
                                    range = magnitude,
                                    layermask = r43
                                }) then
                                    r8_p68 = magnitude
                                    r7 = r13.fuse_hook.Position
                                end
                            end
                        end
                    end
                    if r7 then
                        local r9 = CFrame.new(r29.construct_pos.Position, r7)
                        r29.los_tripwire.Parent = CurrentCamera
                        r29.los_tripwire.CFrame = r9 + r9.LookVector * (r8_p68 / 2)
                        r29.los_tripwire.Size = Vector3.new(0.1, 0.1, r8_p68)
                    else
                        r29.los_tripwire.Parent = nil
                    end
                else
                    r29.los_tripwire.Parent = nil
                end
            end
            r29.construct_holo:PivotTo(r29.construct_pos)
            r7 = r29.construct_holo.bounding:GetTouchingParts()
            if r29.construct_holo ~= nil and r2 == nil and r4 and #r7 <= 0 and #workspace:GetPartsInPart(r29.construct_holo.bounding, r47) <= 0 then
                for r12, r13 in ipairs(r29.construct_holo.finished:GetChildren()) do
                    if r13:IsA("BasePart") then r13.Color = Color3.new(0.9, 0.9, 0.9) end
                end
                if r29.los_tripwire then r29.los_tripwire.Color = Color3.new(0.9, 0.9, 0.9) end
                r29.construct_ready = true
            else
                for r12, r13 in ipairs(r29.construct_holo.finished:GetChildren()) do
                    if r13:IsA("BasePart") then r13.Color = Color3.new(0.7, 0.2, 0.2) end
                end
                if r29.los_tripwire then r29.los_tripwire.Color = Color3.new(0.7, 0.2, 0.2) end
                r29.construct_ready = false
            end
        end
    elseif r29.construct_holo then
        core_checkers.check_ammo = 0
        r29.construct_holo:Destroy()
        r29.construct_holo = nil
        r29.construct_pos = nil
        r29.construct_ready = false
    end
    if r29.extra_bb or r20.tooltype == "firstaid" or r20.tooltype == "stims" then
        local __up20 = r41
        if r20.tooltype == "hammer" then __up20 = r39 end
        local r3_p68 = bFunctions:raycastline({
            point = CurrentCamera.CFrame.Position,
            destination = CurrentCamera.CFrame.lookVector,
            range = 10 + (CurrentCamera.CFrame.Position - Character.HumanoidRootPart.Position).Magnitude,
            layermask = __up20
        })
        if r20.tooltype == "hammer" then
            local r4 = false
            if r3_p68 and r3_p68.Parent and r3_p68.Parent.Parent and r3_p68.Parent.Parent:FindFirstChild("core") and r3_p68.Parent.Parent:FindFirstChild("health") then
                r3_p68 = r3_p68.Parent.Parent
                r4 = true
            end
            if r4 and core_checkers.shift_locked == true then
                if r3_p68.team.Value == LocalPlayer.Team and r3_p68:FindFirstChild("health") and table.find({"Barricade", "Palisade", "Barbed Wires", "Sandbags", "Cache"}, r3_p68.Name) then
                    r29.extra_bb.CFrame = r3_p68.core.CFrame
                    r29.extra_bb.bb.user.Text = string.gsub(localize("message_construct_ownership_" .. r3_p68.Name), "{player}", r3_p68.owner.Value, 1)
                    local r6 = r3_p68.health.Value / r3_p68.health.maxhealth.Value
                    if r3_p68.construction.Value < 100 then r6 = r3_p68.construction.Value / 100 end
                    r29.extra_bb.bb.perc.Text = math.ceil(r6 * 100) .. "%"
                    r29.extra_bb.bb.bar.inner.Size = UDim2.new(r6, 0, 0.2, 0)
                    r29.extra_bb.bb.Enabled = true
                else
                    r29.extra_bb.bb.Enabled = false
                end
            else
                r29.extra_bb.bb.Enabled = false
            end
        elseif r20.tooltype == "firstaid" or r20.tooltype == "stims" then
            r29.heal_target = r3_p68 and r3_p68.Parent:FindFirstChild("Humanoid") and r3_p68.Parent:FindFirstChild("chems") and r3_p68.Parent:FindFirstChild("Torso") and r3_p68.Parent.Humanoid.Health > 0 and r3_p68.Parent.Parent == Character.Parent and r3_p68.Parent or nil
        end
    end
    if core_checkers.aiming == true and r20.draw_speed / core_checkers.draw_modifier < tick() - r29.draw and core_checkers.jumped_air == false then
        local r2 = true
        local r3_p68 = true
        if Value_2 == "vanguardshield" and r29.alt_mode == true then r2 = false end
        if r25.bipod_aim and Parent_2:FindFirstChild("bipod") and r20.draw_speed / core_checkers.draw_modifier < tick() - r29.draw then
            if tick() - Parent_2.bipod.Value <= base.bulwark_buffer then
                r2 = false
                r3_p68 = false
                if r25.bipod_aim.IsPlaying == false then
                    r25.bipod_aim:Play(math.clamp(r20.aim_speed / core_checkers.handling_modifier, 0.125, 10), 1, 0.5)
                end
            elseif r25.bipod_aim.IsPlaying == true then
                r25.bipod_aim:Stop(math.clamp(r20.aim_speed / core_checkers.handling_modifier, 0.125, 10))
            end
        end
        if r29.dual_wield_tool ~= nil then r3_p68 = false end
        if r25.aim_left then
            if core_checkers.flip_cam == true and r3_p68 == true then
                if r20.draw_speed / core_checkers.draw_modifier < tick() - r29.draw then
                    if r25.hipfire and r25.hipfire.IsPlaying == true then r25.hipfire:Stop(0.3) end
                    r2 = false
                    if r25.aim_left.IsPlaying == false then
                        r25.aim_left:Play(math.clamp(r20.aim_speed / core_checkers.handling_modifier, 0.125, 10), 1, 0.5)
                    end
                    if Parent_2:FindFirstChild("left_aiming") then Parent_2.left_aiming.Value = true end
                    if r25.aim.IsPlaying == true then
                        r25.aim:Stop(math.clamp(r20.aim_speed / core_checkers.handling_modifier, 0.125, 10))
                    end
                end
            else
                if r25.aim_left.IsPlaying == true then
                    r25.aim_left:Stop(math.clamp(r20.aim_speed / core_checkers.handling_modifier, 0.125, 10))
                end
                if Parent_2:FindFirstChild("left_aiming") then Parent_2.left_aiming.Value = false end
            end
        end
        if r25.aim.IsPlaying == false and r2 == true then
            if r25.hipfire then r25.hipfire:Stop(0.3) end
            r25.aim:Play(math.clamp(r20.aim_speed / core_checkers.handling_modifier, 0.125, 10), 1, 0.5)
        end
    else
        if Parent_2:FindFirstChild("left_aiming") then Parent_2.left_aiming.Value = false end
        if r25.aim.IsPlaying == true then
            r25.aim:Stop(math.clamp(r20.aim_speed / core_checkers.handling_modifier, 0.125, 10))
        end
        if r25.aim_left and r25.aim_left.IsPlaying == true then
            r25.aim_left:Stop(math.clamp(r20.aim_speed / core_checkers.handling_modifier, 0.125, 10))
        end
        if r25.bipod_aim and r25.bipod_aim.IsPlaying == true then
            r25.bipod_aim:Stop(math.clamp(r20.aim_speed / core_checkers.handling_modifier, 0.125, 10))
        end
    end
    local r2 = "sprint"
    local r3_p68 = 0.4
    if LocalPlayer.Character:FindFirstChild("perk") and (LocalPlayer.Character.perk.Value == "sprinter" or LocalPlayer.Character:FindFirstChild("elitekit") and (LocalPlayer.Character.elitekit.Value == "jaeger" or LocalPlayer.Character.elitekit.Value == "soldat" and LocalPlayer.Character.class.Value == "soldat")) then
        r3_p68 = 0.25
        if r25.sprint_greyhound ~= nil then r2 = "sprint_greyhound" end
    end
    if r25[r2] then
        if core_checkers.sprinting == true and core_checkers.sprinting_max_speed == true then
            if r25[r2].IsPlaying == false then r25[r2]:Play(r3_p68, 1, 0.8) end
        elseif r25[r2].IsPlaying == true then
            r25[r2]:Stop(r3_p68)
        end
    end
    if r20.tooltype == "hammer" or r20.tooltype == "jaegerkit" or r20.tooltype == "stims" or Parent_2:FindFirstChild("durability") or r20.tooltype == "flamer" then
        local r4 = true
        if r20.tooltype ~= "hammer" and r20.tooltype ~= "jaegerkit" or r29.construction_mode ~= false then
        else
            r4 = false
        end
        if r4 == true and CurrentCamera:FindFirstChild("ammo_check") then
            local r5_p68
            local r6 = "#label_supplies"
            CurrentCamera.ammo_check.bg.Size = game.ReplicatedStorage.misc.ammo_check.bg.Size
            CurrentCamera.ammo_check.bg.walkertext.Visible = false
            CurrentCamera.ammo_check.bg.count.Visible = true
            CurrentCamera.ammo_check.bg.ammo.Visible = true
            if Parent_2:FindFirstChild("durability") then
                r5_p68 = math.floor(Parent_2.durability.Value / r29.durability_max * 100) .. "%"
                r6 = "#label_sharpness"
                CurrentCamera.ammo_check.bg.maxammo.inner.bar.Size = UDim2.new(1, 0, Parent_2.durability.Value / r29.durability_max, 0)
            elseif r20.tooltype == "flamer" then
                r5_p68 = math.floor(r29.flamer_fuel / r29.flamer_fuel_max * 100) .. "%"
                r6 = "#label_flamerfuel"
                CurrentCamera.ammo_check.bg.maxammo.inner.bar.Size = UDim2.new(1, 0, r29.flamer_fuel / r29.flamer_fuel_max, 0)
            else
                r5_p68 = Character.supplies.Value .. "/" .. Character.supplies.max.Value
                CurrentCamera.ammo_check.bg.maxammo.inner.bar.Size = UDim2.new(1, 0, Character.supplies.Value / Character.supplies.max.Value, 0)
            end
            CurrentCamera.ammo_check.bg.ammo.Text = r5_p68
            CurrentCamera.ammo_check.bg.count.Text = get_string_reference(r6)
            core_checkers.check_ammo = tick()
        end
    end
    if keysheld.m1 == true and r29.state == "reload" and r29.interrupt_reload == false and action.Value == true then
        r29.interrupt_reload = true
    end
    if tick() - r29.fire_buffer <= 0.2 and action.Value == false and (shield_supplies.ammo_mag >= 1 or Parent_2:FindFirstChild("akimbo") and Parent_2.akimbo.Value == true) and core_checkers.queue_inv == nil and r29.construction_mode == false and shield_supplies.force_block_fire == false and tick() - r29.draw > 0.5 then
        r77(r29.fire_buffer_type)
    end
end
local r104_0
local r105_0
local function r106_0() -- Line: 9934 | Upvalues: ("CurrentCamera" (copy), "LocalPlayer" (copy), "bFunctions" (copy), "r40" (copy), "r44" (ref), "r49" (ref), "Character" (copy), "r25" (copy), "r29" (copy), "r20" (ref), "core_checkers" (copy), "Value_3" (copy), "r42" (copy), "r100_0" (ref), "Value_2" (ref), "Parent_2" (copy), "r104_0" (ref), "r105_0" (ref), "core_game" (copy), "r66_0" (ref), "r65_0" (ref), "base" (copy), "r101_0" (ref))
    local Position = CurrentCamera.CFrame.Position
    if LocalPlayer.CameraMode ~= Enum.CameraMode.LockFirstPerson then
        Position = CurrentCamera.CFrame.Position + CurrentCamera.CFrame.LookVector * 1
    end
    local r1_p69, r2 = bFunctions:raycastline({
        point = Position,
        destination = CurrentCamera.CFrame.LookVector, range = 500,
        layermask = r40
    })
    r44 = r2
    if r49 then
        r49.warningbeam.Enabled = false
        r49.x.Enabled = false
    end
    if Character:FindFirstChild("execing") then
        if r25.melee1 and r25.melee1.IsPlaying == true then r25.melee1:Stop(0) end
        if r25.melee2 and r25.melee2.IsPlaying == true then r25.melee2:Stop(0) end
        if r25.altmelee1 and r25.altmelee1.IsPlaying == true then r25.altmelee1:Stop(0) end
        if r25.altmelee2 and r25.altmelee2.IsPlaying == true then r25.altmelee2:Stop(0) end
        if r25.melee_alt1 and r25.melee_alt1.IsPlaying == true then r25.melee_alt1:Stop(0) end
        if r25.melee_alt2 and r25.melee_alt2.IsPlaying == true then r25.melee_alt2:Stop(0) end
        if r25.charge and r25.charge.IsPlaying == true then r25.charge:Stop(0) end
        if r25.charge_stop and r25.charge_stop.IsPlaying == true then r25.charge_stop:Stop(0) end
    end
    if r29.equipped == false and r29.dual_wield_active == false then return end
    local r3_p69 = tick() - r29.draw
    if r3_p69 < r20.draw_speed / core_checkers.draw_modifier then
        core_checkers.aim_time = tick()
        r29.aim_sound = false
    end
    local r4, r7, r9
    if r25.short and r20.length > 0 then
        if core_checkers.aiming == true and Value_3:FindFirstChild("hitbox") and r20.draw_speed / core_checkers.draw_modifier < tick() - r29.draw and r29.state ~= "reload" and r29.state ~= "cycling" then
            r3_p69 = r42
            local r7, r8 = bFunctions:raycastline({
                point = Character.Head.Position - Character.Head.CFrame.lookVector + Character.HumanoidRootPart.CFrame.rightVector * (Character.HumanoidRootPart.CFrame:ToObjectSpace(Value_3.hitbox.CFrame).Position.X / 3),
                destination = CurrentCamera.CFrame.LookVector,
                range = r20.length,
                layermask = r3_p69
            })
            if workspace.serverStuff.trainingmode.Value == true then
                r9 = Value_3.special.muzzle.CFrame - Value_3.special.muzzle.CFrame.lookVector * r20.length
                local r11, r12 = bFunctions:raycastline({
                    point = r9.Position,
                    destination = CFrame.new(r9.Position, r44).LookVector, range = 500,
                    layermask = r3_p69
                })
                if r11 and r11.Parent and r11.Parent:FindFirstChild("Humanoid") and r11.Parent:FindFirstChild("rank") and r11.Parent:FindFirstChild("enemy") == nil then
                    r7 = r11
                    r12 = Character.HumanoidRootPart.Position + Character.HumanoidRootPart.CFrame.lookVector * 2
                end
            end
            if r7 or core_checkers.jumped_air == true then
                r100_0 = r7 and 1 - (Character.HumanoidRootPart.Position - r8).magnitude / r20.length + 0.4 or 1
                r29.shorted = true
            else
                r29.shorted = false
            end
        else
            r29.shorted = false
        end
        if r29.shorted == true then
            r3_p69 = r25.short
            r4 = nil
            if r25.short_alt and Character["Left Arm"]:FindFirstChild(Value_2 .. Parent_2.slot.Value) then
                r3_p69 = r25.short_alt
                r4 = r25.short
            end
            if r3_p69.IsPlaying == false then r3_p69:Play(0.1, math.clamp(r100_0, 0, 1), 0.5) end
            r3_p69:AdjustWeight(math.clamp(r100_0, 0, 1))
            if r4 and r4.IsPlaying == true then r4:Stop(0.1) end
        else
            if r25.short.IsPlaying == true then r25.short:Stop(0.1) end
            if r25.short_alt and r25.short_alt.IsPlaying == true then r25.short_alt:Stop(0.1) end
        end
    end
    core_checkers.gun_crosshair = false
    if r29.dual_wield_tool == nil then
    end
    r104_0 = nil
    r105_0 = nil
    if core_game.crosshair.Visible == true then
        r3_p69 = core_game.crosshair
        local r4 = r29.dual_wield_tool == nil or false
        if Parent_2:FindFirstChild("akimbo") then
            r4 = true
            if r29.dual_wield_active == true then r3_p69 = core_game.akimbocrosshair end
        end
        r65_0 = tick() - r66_0 >= 0.03 and 0 or 40
        if (r29.aim_sound == false and math.clamp(r20.aim_speed / core_checkers.handling_modifier, 0.125, 10) < tick() - core_checkers.aim_time) and (r20.tooltype == "gun" or r20.tooltype == "launcher") then
            r29.aim_sound = true
            bFunctions:soundHandler({
                directory = {"tools", Value_2}, soundfile = "aimed", pitchvariation = 0.1,
                location = Character.HumanoidRootPart
            })
        end
        if r20.tooltype ~= "gun" and r20.tooltype ~= "launcher" and r29.dual_wield_tool == nil or r29.shorted ~= false then
        elseif r29.state ~= "reload" and r29.state ~= "walker_reload" and math.clamp(r20.aim_speed / core_checkers.handling_modifier, 0.125, 10) < tick() - core_checkers.aim_time and r20.draw_speed / core_checkers.draw_modifier < tick() - r29.draw and core_checkers.charging == false then
            core_checkers.gun_crosshair = true
        end
        local accuracy = r20.accuracy
        if tick() - core_checkers.moving_accuracy >= 0 or core_checkers.in_air == true then
            accuracy = r20.moving_accuracy
        end
        local pellets = r20.pellets
        if Parent_2:FindFirstChild("bipod") and tick() - Parent_2.bipod.Value <= base.bulwark_buffer and tick() - core_checkers.moving_accuracy < 0 and core_checkers.in_air == false then
            accuracy = 2
        end
        if r20.tooltype ~= "gun" and r20.tooltype ~= "launcher" or pellets ~= 1 then
        else
            accuracy /= core_checkers.accuracy_modifier
        end
        if core_checkers.holding_breath == true and core_checkers.hold_breathaccuracy <= tick() - core_checkers.hold_breathtime and pellets == 1 and r29.no_steady_acc == false then
            accuracy = 0
        end
        if Parent_2:FindFirstChild("scoped") and Parent_2.scoped.Value == true then accuracy = 0 end
        accuracy = math.clamp(accuracy * 1.1, 0, 200)
        if r20.tooltype == "gun" and pellets > 1 then accuracy = math.clamp(accuracy * 0.7, 0, 200) end
        if Value_2 == "enfield" and r29.alt_mode == true then accuracy = 0 end
        if Value_2 == "saa" and Character:FindFirstChild("elitekit") and Character.elitekit.Value == "ocelot" then
            accuracy = 0
        end
        r101_0 = bFunctions:lerp(r101_0, accuracy + r65_0, 0.3)
        if r4 == true then
            r3_p69.Size = UDim2.new(0, 1, 0, 1)
            r3_p69.main.Size = UDim2.new(0, r101_0, 0, r101_0)
        end
        if r49 and Parent_2:FindFirstChild("mounted_weapon") == nil and r20.tooltype == "gun" and r29.shorted == false and r29.state ~= "reload" and math.clamp(r20.aim_speed / core_checkers.handling_modifier, 0.125, 10) < tick() - core_checkers.aim_time and r20.draw_speed / core_checkers.draw_modifier < tick() - r29.draw and Value_3 and Value_3:FindFirstChild("special") and Value_3.special:FindFirstChild("muzzle") and r44 then
            local r7 = Value_3.special.muzzle.CFrame - Value_3.special.muzzle.CFrame.lookVector * r20.length
            local r9 = r20.length + 7
            if _G.get_settings("longrangeobstruction") == true then r9 = 200 end
            r104_0, r105_0 = bFunctions:raycastline({
                point = r7.Position,
                destination = CFrame.new(r7.Position, r44).LookVector,
                range = r9,
                layermask = r42
            })
        end
    else
        r29.aim_sound = false
        r65_0 = 0
    end
    if r49 and _G.get_settings("disableobstruction") ~= true and workspace.serverStuff.trainingmode.Value == false then
        if r104_0 then
            r49.CFrame = CFrame.new(r105_0)
            if _G.get_settings("laserobstruction") == true then r49.warningbeam.Enabled = true end
            r49.x.Enabled = true
            return
        end
        r49.x.Enabled = false
        r49.warningbeam.Enabled = false
    end
end
local r107 = {}
if Value_2 == "firstaid" then
    r107 = Character ~= nil and Character:FindFirstChild("perk") and Character.perk.Value == "healing" and localization.get("firstaid_check_healer") or localization.get("firstaid_check")
end
_G.update_tool_localizations[Parent_2.slot.Value] = function() -- Line: 10219 | Name: update_localization | Upvalues: ("Value_2" (ref), "r107" (ref), "Character" (copy), "localization" (copy))
    if Value_2 == "firstaid" then
        r107 = Character ~= nil and Character:FindFirstChild("perk") and Character.perk.Value == "healing" and localization.get("firstaid_check_healer") or localization.get("firstaid_check")
    end
end
local function r109(r0) -- Line: 10230 | Upvalues: ("r29" (copy), "action" (copy), "core_checkers" (copy), "r77" (ref))
    if r29.dropped == true then return end
    if r29.construction_mode ~= false or tick() - r29.draw <= 0.5 or action.Value ~= true or core_checkers.queue_inv ~= nil or r29.state == "reload" then
        r77(r0)
        return
    end
    r29.fire_buffer = tick()
    r29.fire_buffer_type = r0 == true and true or false
    r77(r0)
end
UserInputService.InputBegan:Connect(function(r0_p75, r1_p75) -- Line: 10245 | Upvalues: ("r29" (copy), "Character" (copy), "core_game" (copy), "UserInputService" (copy), "Parent_2" (copy), "r109" (copy), "r71" (ref), "Value_2" (ref), "bFunctions" (copy), "core_checkers" (copy), "action" (copy), "r25" (copy), "events" (copy), "Humanoid" (copy), "r20" (ref), "r74_0" (copy), "RenderStepped" (copy), "r102_0" (ref), "LocalPlayer" (copy), "r80_0" (copy), "weaponEffects" (copy), "r18" (ref), "Value_3" (copy), "shield_supplies" (ref), "r70_0" (copy), "r75_0" (copy), "localize" (copy), "r78_0" (copy), "r94" (copy), "visualEffects" (copy), "r107" (ref))
    if r1_p75 == true then return end
    if r29.dropped == true then return end
    if Character:FindFirstChild("exec") then return end
    if Character:FindFirstChild("execing") then return end
    if core_game.Parent.loadout_menu.Visible == true then return end
    if r29.equipped == false then return end
    if r0_p75.UserInputType ~= Enum.UserInputType.MouseButton2 and r0_p75.KeyCode ~= Enum.KeyCode.ButtonL2 or UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
    elseif Parent_2:FindFirstChild("akimbo_aiming") and Parent_2.akimbo_aiming.Value == true then
        r109(true)
    end
    if r0_p75.KeyCode then
        local client_inactive
        if r0_p75.KeyCode == _G.get_keybinds("reload") then
            r71 = tick()
            if Value_2 == "vanguardshield" and r29.alt_mode == true then
                if Parent_2:FindFirstChild("client_inactive") or Parent_2:FindFirstChild("inactive") then return end
                client_inactive = Instance.new("StringValue")
                game:GetService("Debris"):AddItem(client_inactive, 30)
                client_inactive.Name = "client_inactive"
                client_inactive.Parent = Parent_2
                bFunctions:soundHandler({
                    directory = {"tools", Value_2}, soundfile = "shield_prep", pitchvariation = 0.1,
                    location = Character.HumanoidRootPart
                })
                bFunctions:soundHandler({
                    directory = {"tools", Value_2}, soundfile = "belt1", pitchvariation = 0.1,
                    location = Character.HumanoidRootPart
                })
                delay(0.2, function() -- Line: 10303 | Upvalues: ("bFunctions" (upval), "Value_2" (upval), "Character" (upval))
                    bFunctions:soundHandler({
                        directory = {"tools", Value_2}, soundfile = "belt2", pitchvariation = 0.1,
                        location = Character.HumanoidRootPart
                    })
                end)
                core_checkers.inv_swapping = true
                core_checkers.inv_block_reason = ""
                action.Value = true
                r25.shield_plant:Play(0.1, 1, 1)
                bFunctions:s_wait(1)
                events.interaction_handler:Fire(Parent_2, "vanguard_plantshield")
                action.Value = false
                Humanoid:UnequipTools()
                return
            end
            if r20.tooltype == "gun" or r20.tooltype == "launcher" then
                r74_0()
            elseif r29.dual_wield_tool ~= nil then
                if action.Value == true then return end
                if r29.dual_wield_tool ~= nil then
                    if core_checkers.inv_swapping ~= true then
                        if core_checkers.inv_block_reason ~= "" then
                            _G.popupmsg("block_warning", core_checkers.inv_block_reason, 1)
                        end
                        return
                    end
                    r29.dual_wield_tool.event:Fire("reload_weapon_swap")
                end
            elseif r20.tooltype == "hammer" or r20.tooltype == "jaegerkit" then
                if action.Value == true or core_checkers.aiming == true then
                    if core_game.selectionboxes.Visible == true then
                        core_game.selectionboxes.Visible = false
                        core_checkers.selection_box_selected = "none"
                    end
                    return
                end
                action.Value = true
                core_checkers.selection_box_selected = ""
                core_checkers.display_selections(r29.construct_constructions)
                repeat
                    RenderStepped:wait()
                    if core_checkers.selection_box_selected == "" and core_checkers.aiming ~= true and core_checkers.queue_inv == nil then
                        continue
                    end
                    break
                until core_checkers.queue_inv ~= nil
                if core_checkers.aiming == true or core_checkers.queue_inv ~= nil then
                    core_checkers.selection_box_selected = "none"
                end
                if core_checkers.selection_box_selected ~= "none" then
                    r29.constructing = core_checkers.selection_box_selected
                    r102_0 = r29.constructing
                    if r29.construct_holo then
                        r29.construct_holo:Destroy()
                        r29.construct_holo = nil
                    end
                    if r20.tooltype == "jaegerkit" then
                        client_inactive = 0
                        for r6, r7 in ipairs(workspace.constructions:GetChildren()) do
                            if not (not r7:FindFirstChild("owner") or not r7:FindFirstChild("health") or r7.health.Value <= 0 or r7.owner.Value ~= LocalPlayer.Name or r7.Name ~= r29.constructing) then
                                client_inactive += 1
                            end
                        end
                        if client_inactive >= 2 then
                            _G.popupmsg("max" .. r29.constructing, "#message_traplimit_" .. r29.constructing, 2)
                        end
                    end
                end
                core_game.selectionboxes.Visible = false
                core_checkers.selection_box_selected = ""
                action.Value = false
            elseif Value_2 == "pickaxe" then
                if action.Value == true then return end
                if r29.sharpening_stones <= 0 then
                    _G.popupmsg("nosharpenstone", "#pickaxe_supplies", 2)
                    return
                end
                if Parent_2.durability.Value == r29.durability_max then
                    _G.popupmsg("maxsharp", "#pickaxe_max", 2)
                    return
                end
                client_inactive = r29
                client_inactive.sharpening_stones -= 1
                action.Value = true
                r25.sharpen:Play(0.1, 1, 0.75)
                bFunctions:s_wait(2.2)
                bFunctions:soundHandler({
                    directory = {"tools", Value_2}, soundfile = "finishsharpen", pitchvariation = 0.1,
                    location = Character.HumanoidRootPart
                })
                Parent_2.durability.Value = r29.durability_max
                bFunctions:s_wait(0.8)
                action.Value = false
            elseif r20.tooltype == "binocs" then
                if Character:FindFirstChild("class") and Character.class.Value == "conscript" then return end
                if core_checkers.aiming == false then r80_0() end
            elseif r20.tooltype == "stims" then
                if r29.alt_mode == true then
                    spawn(function() -- Line: 10442 | Upvalues: ("weaponEffects" (upval), "Value_2" (upval), "r18" (upval), "Character" (upval), "Value_3" (upval), "r20" (upval), "shield_supplies" (upval))
                        local __up1 = Value_2
                        if r18 ~= "" then __up1 = r18 end
                        weaponEffects("stimbottle_dispose", {
                            main = {
                                char = Character,
                                originweapon = __up1,
                                weapon = Value_2,
                                model = Value_3,
                                module = r20,
                                core = shield_supplies
                            }
                        })
                    end)
                    core_checkers.inv_swapping = false
                    action.Value = true
                    r29.alt_mode = false
                    r25.new:Play(0.1, 1, 1.5)
                    bFunctions:s_wait(0.75)
                    action.Value = false
                    shield_supplies.stim_content = {}
                    core_checkers.inv_swapping = true
                else
                    _G.popupmsg("nostimloaded", "f#stims_discard_empty", 2)
                end
            end
        end
        if r0_p75.KeyCode == _G.get_keybinds("dropweapon") and r20.tooltype == "gun" and action.Value == true and r29.state == "reload" then
            r70_0()
            return
        end
        if r0_p75.KeyCode == _G.get_keybinds("checkammo") then
            if r20.tooltype == "gun" then
                r75_0()
            else
                local client_inactive_2
                local r3
                if r20.tooltype == "hammer" then
                    if r29.construction_mode == true then
                        client_inactive_2 = tick() - r29.construct_cd
                        if client_inactive_2 <= 0.5 then return end
                        if r29.confirm_construct == nil then r29.confirm_construct = 0 end
                        client_inactive_2 = tick() - r29.confirm_construct
                        if client_inactive_2 > 5 then
                            r29.confirm_construct = tick()
                            _G.popupmsg("construct_confirmdestroy", "#message_construct_confirmdestroy_" .. r29.constructing, 2)
                        else
                            r29.construct_cd = tick()
                            client_inactive_2 = {}
                            for r6, r7 in ipairs(workspace.constructions:GetChildren()) do
                                if not (not r7:FindFirstChild("owner") or not r7:FindFirstChild("health") or r7.health.Value <= 0 or r7.owner.Value ~= LocalPlayer.Name or r7.Name ~= r29.constructing) then
                                    table.insert(client_inactive_2, r7)
                                end
                            end
                            if #client_inactive_2 >= 1 then
                                r3 = nil
                                r3 = #client_inactive_2 > 1 and string.gsub(localize("message_construct_destroy"), "{number}", #client_inactive_2, 1) or localize("message_construct_destroy_single")
                                _G.popupmsg("construct_destroy", r3, 2)
                                events.construction_handler:Fire("destroy_all", r29.constructing)
                                for r7, r8_p75 in ipairs(client_inactive_2) do
                                    if not (r8_p75.Name ~= r29.constructing or not r8_p75:FindFirstChild("owner") or r8_p75.owner.Value ~= LocalPlayer.Name) then
                                        r8_p75:Destroy()
                                    end
                                end
                            else
                                _G.popupmsg("construct_nodestroy", "#message_construct_destroy_none", 2)
                            end
                        end
                    end
                elseif r20.tooltype == "binocs" then
                    if Character:FindFirstChild("class") and Character.class.Value == "conscript" then return end
                    if core_checkers.aiming == false then r78_0() end
                elseif r20.tooltype == "whistle" then
                    if _G.whistle_long == false then
                        _G.whistle_long = true
                        r3 = "orderlong" .. math.random(1, 100)
                        _G.popupmsg(r3, "#whistle_long", 1)
                    else
                        _G.whistle_long = false
                        r3 = "orderlong" .. math.random(1, 100)
                        _G.popupmsg(r3, "#whistle_short", 1)
                    end
                else
                    local r4
                    if r20.tooltype == "shield" then
                        if action.Value == true then return end
                        if Parent_2:FindFirstChild("shield_supplies") and Parent_2.shield_supplies.Value <= 0 then
                            _G.popupmsg("repairlack", "#vanguardshield_supplies", 2)
                            return
                        end
                        if Value_3:FindFirstChild("special") and Value_3.special:FindFirstChild("leftshield") and Value_3.special:FindFirstChild("rightshield") and Value_3.special:FindFirstChild("topshield") and Parent_2:FindFirstChild("shield_supplies") then
                            client_inactive_2 = {Value_3.special.topshield, Value_3.special.rightshield, Value_3.special.leftshield}
                            table.sort(client_inactive_2, function(r0, r1) -- Line: 10640
                                return r0.health.Value < r1.health.Value
                            end)
                            r3 = {}
                            r4 = false
                            for i_0 = 1, 3 do
                                local r8_p75 = client_inactive_2[i_0]
                                if not r8_p75:FindFirstChild("health") or r8_p75.health.Value >= r8_p75.health.max.Value then
                                    continue
                                end
                                r4 = true
                                break
                            end
                            if r4 == false then
                                _G.popupmsg("repairstag", "#vanguardshield_norepair", 2)
                                return
                            end
                            if r29.alt_mode == true then
                                r94()
                                if action.Value == true then return end
                            end
                            bFunctions:soundHandler({
                                directory = {"tools", "shared"}, soundfile = "reloadstart", pitchvariation = 0.1,
                                location = Character.HumanoidRootPart
                            })
                            action.Value = true
                            for i_1 = 1, 3 do
                                local r8_p75 = client_inactive_2[i_1]
                                local Value = r8_p75.health.max.Value
                                if r8_p75.Name ~= "topshield" then Value = 0 end
                                if not (not r8_p75:FindFirstChild("health") or r8_p75.health.Value >= Value or not r8_p75:FindFirstChild("damagepart")) then
                                    if r8_p75.damagepart.Transparency == 0 then
                                        bFunctions:soundHandler({
                                            directory = {"tools", Value_2},
                                            pitchvariation = 0.1,
                                            soundfile = "shield_shuffle" .. math.random(1, 3),
                                            location = Character.HumanoidRootPart
                                        })
                                        r25["remove_" .. r8_p75.Name]:Play(0.1, 1, 1)
                                        bFunctions:s_wait(0.5)
                                        bFunctions:soundHandler({
                                            directory = {"tools", Value_2}, soundfile = "metal_detach",
                                            pitchvariation = 0.1, location = Character.HumanoidRootPart
                                        })
                                        visualEffects("fake_shield_parts", {part = r8_p75, transp = 1})
                                        events.interaction_handler:Fire(Parent_2, "remove_vanguardshield", r8_p75)
                                        bFunctions:s_wait(0.5)
                                    end
                                    table.insert(r3, r8_p75)
                                    Parent_2.shield_supplies.Value = Parent_2.shield_supplies.Value - 1
                                    if Parent_2.shield_supplies.Value <= 0 then break end
                                end
                            end
                            for i_2 = 1, #r3 do
                                local r8_p75 = r3[i_2]
                                if not (not r8_p75:FindFirstChild("health") or not r8_p75:FindFirstChild("part") or r8_p75.damagepart.Transparency ~= 1) then
                                    bFunctions:soundHandler({
                                        directory = {"tools", Value_2}, soundfile = "shield_prep", pitchvariation = 0.1,
                                        location = Character.HumanoidRootPart
                                    })
                                    r25["replace_" .. r8_p75.Name]:Play(0.1, 1, 1)
                                    bFunctions:s_wait(0.1)
                                    visualEffects("fake_shield_parts", {part = r8_p75, transp = 0})
                                    bFunctions:s_wait(0.4)
                                    bFunctions:soundHandler({
                                        directory = {"tools", Value_2}, soundfile = "shield_repair",
                                        pitchvariation = 0.1, location = Character.HumanoidRootPart
                                    })
                                    events.interaction_handler:Fire(Parent_2, "replace_vanguardshield", r8_p75)
                                    bFunctions:s_wait(0.5)
                                end
                            end
                        end
                        bFunctions:soundHandler({
                            directory = {"tools", "shared"}, soundfile = "reloadend", pitchvariation = 0.1,
                            location = Character.HumanoidRootPart
                        })
                        action.Value = false
                    elseif r20.tooltype == "stims" and action.Value == false then
                        r25.checkstim:Play(0.1, 1, 1)
                        action.Value = true
                        if shield_supplies.stim_content == nil or #shield_supplies.stim_content <= 0 then
                            _G.popupmsg("stimdesc", "#stims_empty", 1.5)
                        else
                            client_inactive_2 = {}
                            for r6, r7 in ipairs(shield_supplies.stim_content) do
                                client_inactive_2[r7] = client_inactive_2[r7] and client_inactive_2[r7] + 1 or 1
                            end
                            for r6, r7 in pairs(client_inactive_2) do
                                local r8_p75 = r29.stimulants[r6]
                                local r9 = localize("stims_check")
                                r9 = string.gsub(r9, "{units}", r7 * 10, 1)
                                r9 = string.gsub(r9, "{stim}", localize("stim_" .. r8_p75.int), 1)
                                r9 = string.gsub(r9, "{desc}", localize("stim_desc_" .. r8_p75.int), 1)
                                _G.popupmsg("stimchecking" .. math.random(1, 100), r9, 1.5)
                            end
                        end
                        bFunctions:s_wait(1)
                        action.Value = false
                    elseif r20.tooltype == "throwaxe" and action.Value == false and Parent_2:FindFirstChild("use_count") then
                        r25.checkaxes:Play(0.1, 1, 1)
                        action.Value = true
                        bFunctions:s_wait(1)
                        action.Value = false
                    elseif r20.tooltype == "firstaid" and action.Value == false then
                        r25.checkhealth:Play(0.1, 1, 1)
                        action.Value = true
                        client_inactive_2 = {300, 200, 150, 100, 50}
                        r3 = r107[1]
                        if Humanoid.Health < Humanoid.MaxHealth then
                            for i_3 = 1, #client_inactive_2 do
                                if Humanoid.Health < client_inactive_2[i_3] then r3 = r107[i_3 + 1] end
                            end
                        end
                        if core_checkers.sick == true then
                            if Character.chems:FindFirstChild("int") then
                                r3 = localize("firstaid_check_int")
                                if Character.perk.Value == "healing" then r3 = localize("firstaid_check_healer_int") end
                            else
                                r3 = localize("firstaid_check_sick")
                                if Character.perk.Value == "healing" then
                                    r3 = localize("firstaid_check_healer_sick")
                                elseif Character:FindFirstChild("chems") and Character.chems:FindFirstChild("eth") then
                                    r3 = localize("firstaid_check_eth")
                                end
                            end
                        elseif Character.perk.Value == "healing" then
                            r4 = string.gsub(localize("firstaid_check_healer_health"), "{health}", math.ceil(Humanoid.Health), 1)
                            r3 ..= " " .. r4
                        end
                        _G.popupmsg("healthstate" .. math.random(1, 100), r3, 1.5)
                        r4 = localize("firstaid_check_stim_none")
                        local Children = Character.chems:GetChildren()
                        if #Children > 0 then
                            local r6 = {}
                            local r7 = {}
                            for r11_p75, r12_p75 in ipairs(Children) do
                                if r6[r12_p75.Name] == nil then
                                    r6[r12_p75.Name] = 1
                                    r7[r12_p75.Name] = math.ceil(r12_p75:GetAttribute("TickTimeLeft") or r12_p75:GetAttribute("Duration") or 0)
                                else
                                    r6[r12_p75.Name] = r6[r12_p75.Name] + 1
                                    r7[r12_p75.Name] = r7[r12_p75.Name] + math.ceil(r12_p75:GetAttribute("Duration") or 0)
                                end
                            end
                            r4 = ""
                            local r8_p75 = 0
                            local r9 = 0
                            for r13_p75, r14_p75 in pairs(r6) do
                                r9 += 1
                            end
                            for r13_p75, r14_p75 in pairs(r6) do
                                r8_p75 += 1
                                local r15 = r29.stimulants[r13_p75]
                                if r15 then
                                    local r16 = localize("firstaid_check_stim")
                                    r16 = string.gsub(r16, "{units}", r14_p75 * 10, 1)
                                    r16 = string.gsub(r16, "{stim}", localize("stim_" .. r15.int), 1)
                                    if Character:FindFirstChild("perk") and Character.perk.Value == "healing" then
                                        r16 ..= " " .. string.gsub(localize("firstaid_check_healer_duration"), "{time}", r7[r13_p75], 1)
                                    end
                                    r4 ..= r9 <= r8_p75 and r16 .. "." or r16 .. ", "
                                end
                            end
                        end
                        _G.popupmsg("chemstate" .. math.random(1, 100), r4, 1.5)
                        bFunctions:s_wait(1)
                        action.Value = false
                    elseif Value_2 == "lance" and action.Value == false then
                        action.Value = true
                        if LocalPlayer.Character:FindFirstChild("flagwave_cd") == nil then
                            events.interaction_handler:Fire(Parent_2, "flagwave")
                            client_inactive_2 = Instance.new("StringValue")
                            game:GetService("Debris"):AddItem(client_inactive_2, 15)
                            client_inactive_2.Name = "flagwave_cd"
                            client_inactive_2.Parent = Character
                        else
                            _G.popupmsg("flagcd", "#lance_ineffective", 1)
                        end
                        r4 = {directory = {"tools", "lance"}}
                        r4.soundfile = "flag" .. math.random(1, 2)
                        r4.location = Character.HumanoidRootPart
                        bFunctions:soundHandler(r4)
                        r25.raise_flag:Play(0.2, 1, 1)
                        bFunctions:s_wait(2.5)
                        action.Value = false
                    end
                end
            end
        end
        if r0_p75.KeyCode == _G.get_keybinds("alt") then
            r94()
            if action.Value ~= true or core_game.selectionboxes.Visible ~= true then return end
            core_game.selectionboxes.Visible = false
            core_checkers.selection_box_selected = "none"
        end
    end
end)
Parent_2.Activated:Connect(r109)
Parent_2.Equipped:Connect(function() -- Line: 10966 | Upvalues: ("r15" (ref), "Character" (copy), "r29" (copy), "LocalPlayer" (copy), "visualEffects" (copy), "r44" (ref), "r45" (ref), "core_checkers" (copy), "Value_2" (ref), "r18" (ref), "localize" (copy), "action" (copy), "CurrentCamera" (copy), "r20" (ref), "Parent_2" (copy), "core_game" (copy), "bFunctions" (copy), "weaponEffects" (copy), "Value_3" (copy), "shield_supplies" (ref), "events" (copy), "r25" (copy), "r87_0" (copy), "RenderStepped" (copy))
    if r15 == true then return end
    if Character == nil or Character:FindFirstChild("HumanoidRootPart") == nil then return end
    if r29.dropped == true then return end
    if workspace.throwables:FindFirstChild(LocalPlayer.Name .. "_compass") then
        visualEffects("destroy_compasses", {char = Character})
    end
    r44 = nil
    r45 = nil
    core_checkers.aim_time = tick()
    r29.draw = tick()
    if (Character and Character:FindFirstChild("perk") and Character.perk.Value == "tunnelrat") and (Value_2 == "pick" or Value_2 == "pickaxe") then
        r29.draw = 0
    end
    r29.equipped = true
    if Value_2 == "mauser" and r18 == "" and r29.alt_mode == true then
        core_checkers.inv_block_reason = _G.localizationdebug == true and "#mauser_invswap" or localize("mauser_invswap")
    elseif Value_2 ~= "mauser" then
        core_checkers.inv_block_reason = ""
    end
    action.Value = false
    if CurrentCamera:FindFirstChild("ammo_check") then
        CurrentCamera.ammo_check.bg.maxammo.Visible = true
    end
    local Action3 = Enum.AnimationPriority.Action3
    local r2 = r18 == "" and Value_2 or r18
    local r1_p78 = r20.alt_name and _G.get_settings("toggleskins") == false and (LocalPlayer.Team == game.Teams["Royal Nation"] and localize("tool_" .. r2 .. "_nation", nil, r20.name or Parent_2.Name) or localize("tool_" .. r2 .. "_empire", nil, r20.name or Parent_2.Name)) or localize("tool_" .. r2, nil, r20.name or Parent_2.Name)
    core_game.inventoryitemname.item.Text = r1_p78
    local r3_p78 = core_game.inventory:FindFirstChild(Value_2 .. Parent_2.slot.Value) or core_game.inventory:FindFirstChild(r18 .. Parent_2.slot.Value)
    if r3_p78 then
        core_checkers.inventory_display = tick()
        r3_p78.line.BackgroundColor3 = Color3.new(1, 1, 1)
        r3_p78.icon.ImageColor3 = Color3.new(1, 1, 1)
        r3_p78.num.TextColor3 = Color3.new(1, 1, 1)
    end
    core_checkers.speed_mod = r20.movement
    local r4
    if Character:FindFirstChild("elitekit") and Character.elitekit.Value == "jaeger" then r4 = 5 end
    bFunctions:soundHandler({
        directory = {"tools", Value_2}, soundfile = "draw",
        force_max_dist = r4, pitchvariation = 0.1,
        location = Character.HumanoidRootPart
    })
    local r7 = {state = "equip"}
    local __up8 = Value_2
    if r18 ~= "" then __up8 = r18 end
    r7.main = {
        char = Character,
        originweapon = __up8,
        weapon = Value_2,
        model = Value_3,
        module = r20,
        core = shield_supplies
    }
    r7.slot = Parent_2.slot.Value
    local r8_p78 = true
    weaponEffects("weapon_visibility", r7, r8_p78)
    events.game_handler:Fire("weapon_visibility", {wep = Parent_2, state = "equip"})
    if Value_2 == "henry" and Character.perk.Value == "vet" and r29.alt_mode == false then
        r7 = {visibility = true}
        __up8 = Value_2
        if r18 ~= "" then __up8 = r18 end
        r8_p78 = {
            char = Character,
            originweapon = __up8,
            weapon = Value_2,
            model = Value_3,
            module = r20,
            core = shield_supplies
        }
        r7.main = r8_p78
        weaponEffects("henry_offhandround", r7)
    end
    if Parent_2:FindFirstChild("akimbo") and Parent_2.akimbo.Value == true then
        Parent_2.akimbo.Value = false
    end
    local r5_p78, r6
    if (Value_2 ~= "vanguardshield" and (Value_2 ~= "cavsword" or Parent_2.slot.Value ~= 1)) and (r20.size == 1 and r20.tooltype == "gun" and Character:FindFirstChild("perk") and Character.perk.Value == "akimbo" and Parent_2:FindFirstChild("akimbo")) then
        r5_p78 = 2
        if Parent_2:FindFirstChild("akimbo_aiming") then
            Parent_2.akimbo_aiming.Value = false
            if Parent_2:FindFirstChild("slot") and Parent_2.slot.Value == 2 then r5_p78 = 1 end
        end
        r29.dual_wield_tool = nil
        if r29.dual_wield_tool == nil then
            r6 = Value_2
            if r18 ~= "" then r6 = r18 end
            r20 = bFunctions:deepCopy(require(game.ReplicatedStorage.weapon_modules:FindFirstChild(r6)))
            for r10_p78, r11_p78 in ipairs(LocalPlayer.Backpack:GetChildren()) do
                if not r11_p78:FindFirstChild("slot") or r11_p78.slot.Value ~= r5_p78 or r11_p78.Name == "empty" then
                    continue
                end
                local r12 = (r11_p78:FindFirstChild("pistol") and r11_p78.pistol.Value == true and r11_p78:FindFirstChild("inactive") == nil and r11_p78:FindFirstChild("client_inactive") == nil) and true
                if r11_p78.weapon.Value == "cavsword" and r11_p78:FindFirstChild("inactive") == nil and r11_p78:FindFirstChild("client_inactive") == nil and Value_2 == "vanguardshield" then
                    r12 = true
                end
                if r12 ~= true then break end
                r29.dual_wield_tool = r11_p78
                break
            end
            if r25.aim_normal then r25.aim_normal.Priority = r25.aim.Priority end
            if r25.aim_dual then r25.aim_dual.Priority = r25.aim.Priority end
            if r29.dual_wield_tool then
                r25.sprint = r25.sprint_dual
                local Value = r29.dual_wield_tool.weapon.Value
                if Value_2 == "vanguardshield" then
                    if Value == "cavsword" then
                        r25.sword_aim.Priority = r25.aim.Priority
                        r25.sword_fullguard_aimed.Priority = r25.shieldraised_aimed.Priority
                        r25.sword_fullguard_idle.Priority = r25.shieldraised_idle.Priority
                        r25.aim = r25.sword_aim
                        r25.shieldraised_aimed = r25.sword_fullguard_aimed
                        r25.shieldraised_idle = r25.sword_fullguard_idle
                        r25.sprint = r25.sprint_normal
                    else
                        r25.aim = r25.aim_normal
                    end
                else
                    r25.aim = r25.aim_dual
                end
                local r8_p78 = require(game.ReplicatedStorage.weapon_modules:FindFirstChild(Value))
                r29.other_wep_module = r8_p78
                function r29.dual_wield_vfx() -- Line: 11169 | Upvalues: ("Character" (upval), "r29" (upval), "r8_p78" (copy))
                    return {
                        char = Character,
                        originweapon = r29.dual_wield_tool.weapon.Value,
                        weapon = r29.dual_wield_tool.weapon.Value,
                        model = r29.dual_wield_tool.model.Value,
                        module = r8_p78
                    }
                end
                if Character.perk.Value == "akimbo" and r20.size == 1 and r20.tooltype == "gun" then
                    r20.aim_speed = (r20.aim_speed + r8_p78.aim_speed) / 1.5
                    r20.movement += r8_p78.movement
                    r25.held = r25.akimbo_held
                    Action3 = Enum.AnimationPriority.Action
                    Parent_2.akimbo.Value = true
                else
                    r20.aim_speed = r8_p78.aim_speed
                end
            else
                if Value_2 == "vanguardshield" then
                    if r29.alt_mode == true then r87_0(true) end
                    r25.aim = r25.shield_noweapon_aim
                else
                    r25.aim = r25.aim_normal
                end
                if Character.perk.Value == "akimbo" and r20.size == 1 and r20.tooltype == "gun" then
                    r25.held = r25.held_normal
                    Parent_2.akimbo.Value = false
                end
                r25.sprint = r25.sprint_normal
            end
        end
    end
    if r25.fire then r25.fire.Priority = Action3 end
    if r25.akimbo_fire then r25.akimbo_fire.Priority = Action3 end
    if r25.fire_left then r25.fire_left.Priority = Action3 end
    if r25.alt_changefire then r25.alt_changefire.Priority = Action3 end
    if r25.alt_changefire_empty then r25.alt_changefire_empty.Priority = Action3 end
    if r25.fire_empty then r25.fire_empty.Priority = Action3 end
    if r25.akimbo_fire_empty then r25.akimbo_fire_empty.Priority = Action3 end
    if r25.fire_empty_left then r25.fire_empty_left.Priority = Action3 end
    if r25.fire_last then r25.fire_last.Priority = Action3 end
    if r25.alt_changefire_last then r25.alt_changefire_last.Priority = Action3 end
    if r25.alt_changefire_left then r25.alt_changefire_left.Priority = Action3 end
    if r25.alt_changefire_last_left then r25.alt_changefire_last_left.Priority = Action3 end
    if r25.alt_changefire_empty_left then r25.alt_changefire_empty_left.Priority = Action3 end
    r25.held:Play(0, 1, 0.25)
    if r29.dual_wield_tool then
        r29.dual_wield_tool.event:Fire("dual_active", true)
        r29.dual_wield_tool.event:Fire("reset_aimtime")
        local r5_p78
        local r6
        if Value_2 == "cavsword" then r5_p78 = true end
        if Character.perk.Value == "akimbo" and r20.size == 1 and r20.tooltype == "gun" then
            r5_p78 = true
            r6 = true
        end
        weaponEffects("weapon_visibility", {
            main = r29.dual_wield_vfx(),
            slot = r29.dual_wield_tool.slot.Value, state = "equip",
            flipped = r5_p78,
            dual = r6
        }, true)
        events.game_handler:Fire("weapon_visibility", {
            wep = r29.dual_wield_tool, state = "equip",
            flipped = r5_p78,
            dual = r6
        })
    end
    if r29.slide_locked == true then
        r25.locked:Play(0)
        if r25.akimbo_locked then r25.akimbo_locked:Stop(0) end
    end
    if r29.alt_slide_locked == true then r25.locked_alt:Play(0) end
    local r5_p78 = math.clamp(1 / (r20.draw_speed / core_checkers.draw_modifier), 0, 1.5)
    local r6 = "draw"
    if r25.draw_dual and r29.dual_wield_tool ~= nil then r6 = "draw_dual" end
    r25[r6]:Play(0, 1, r5_p78)
    if Value_2 == "saa" and Character:FindFirstChild("cowboy") then
        delay(0.15, function() -- Line: 11323 | Upvalues: ("r25" (upval))
            r25.ocelot_draw_spin:Play(0.1, 1, 1.4)
        end)
    end
    r7 = tick()
    repeat
        RenderStepped:Wait()
        core_checkers.aim_time = tick()
        r29.aim_sound = false
        r8_p78 = tick() - r29.draw
        if r20.draw_speed / core_checkers.draw_modifier > r8_p78 and r29.equipped ~= false then continue end
        return
    until r29.equipped == false
end)
Parent_2.Unequipped:Connect(function() -- Line: 11337 | Upvalues: ("r15" (ref), "Character" (copy), "r29" (copy), "r25" (copy), "Parent_2" (copy), "r44" (ref), "r45" (ref), "core_checkers" (copy), "core_game" (copy), "Value_2" (ref), "r18" (ref), "r49" (ref), "bFunctions" (copy), "r87_0" (copy), "weaponEffects" (copy), "Value_3" (copy), "r20" (ref), "shield_supplies" (ref), "events" (copy))
    if r15 == true then return end
    if Character == nil or Character:FindFirstChild("HumanoidRootPart") == nil then return end
    if r29.dropped == true then return end
    if r29.slide_locked == true and r25.akimbo_locked then
        r25.locked:Stop(0)
        r25.akimbo_locked:Play(0)
    end
    if Parent_2:FindFirstChild("akimbo") then Parent_2.akimbo.Value = false end
    r44 = nil
    r45 = nil
    core_checkers.check_ammo = 0
    if r29.los_tripwire then r29.los_tripwire.Parent = nil end
    if r29.construct_holo then
        r29.construct_holo:Destroy()
        r29.construct_holo = nil
    end
    if r29.extra_bb then r29.extra_bb.bb.Enabled = false end
    r29.construct_ready = false
    r29.construct_pos = nil
    if r25.fire then r25.fire.Priority = Enum.AnimationPriority.Action end
    if r25.akimbo_fire then r25.akimbo_fire.Priority = Enum.AnimationPriority.Action end
    if r25.fire_left then r25.fire_left.Priority = Enum.AnimationPriority.Action end
    if r25.alt_changefire then r25.alt_changefire.Priority = Enum.AnimationPriority.Action end
    if r25.alt_changefire_empty then
        r25.alt_changefire_empty.Priority = Enum.AnimationPriority.Action
    end
    if r25.fire_empty then r25.fire_empty.Priority = Enum.AnimationPriority.Action end
    if r25.akimbo_fire_empty then r25.akimbo_fire_empty.Priority = Enum.AnimationPriority.Action end
    if r25.fire_empty_left then r25.fire_empty_left.Priority = Enum.AnimationPriority.Action end
    if r25.fire_last then r25.fire_last.Priority = Enum.AnimationPriority.Action end
    if r25.alt_changefire_left then r25.alt_changefire_left.Priority = Enum.AnimationPriority.Action end
    if r25.alt_changefire_last_left then
        r25.alt_changefire_last_left.Priority = Enum.AnimationPriority.Action
    end
    local r0_p79
    if r25.alt_changefire_empty_left then
        r25.alt_changefire_empty_left.Priority = Enum.AnimationPriority.Action
        r0_p79 = r25.alt_changefire_empty_left
    else
        r0_p79 = core_game.inventory:FindFirstChild(Value_2 .. Parent_2.slot.Value) or core_game.inventory:FindFirstChild(r18 .. Parent_2.slot.Value)
    end
    if r0_p79 then
        core_checkers.inventory_display = tick()
        r0_p79.line.BackgroundColor3 = Color3.new(0, 0, 0)
        r0_p79.icon.ImageColor3 = Color3.new(0, 0, 0)
        r0_p79.num.TextColor3 = Color3.new(0, 0, 0)
    end
    if r49 then
        r49.warningbeam.Enabled = false
        r49.x.Enabled = false
    end
    for r4, r5_p79 in pairs(r25) do
        if r4 == "throw_over" or r4 == "throw_under" then continue end
        local r6 = true
        if Value_2 == "crossbow" and r4 == "locked" then
            r6 = false
            if Character:FindFirstChild("crossbow1") and Character:FindFirstChild("crossbow2") then
                r6 = true
            end
        end
        if r6 == true then r5_p79:Stop(0.01) end
    end
    if r25.unequip then r25.unequip:Play(0.1, 1, 1) end
    if Character and Character:FindFirstChild("HumanoidRootPart") then
        bFunctions:soundHandler({
            directory = {"tools", "shared"}, soundfile = "unequip", pitchvariation = 0.1,
            location = Character.HumanoidRootPart
        })
        r29.equipped = false
        if Value_2 == "vanguardshield" and r29.alt_mode == true and r29.dual_wield_tool then
            r87_0(false)
        end
        local r3 = {state = "holster"}
        local __up9 = Value_2
        if r18 ~= "" then __up9 = r18 end
        r3.main = {
            char = Character,
            originweapon = __up9,
            weapon = Value_2,
            model = Value_3,
            module = r20,
            core = shield_supplies
        }
        r3.slot = Parent_2.slot.Value
        local r4 = true
        weaponEffects("weapon_visibility", r3, r4)
        if Value_2 == "henry" and Character.perk.Value == "vet" then
            r3 = {visibility = false}
            __up9 = Value_2
            if r18 ~= "" then __up9 = r18 end
            r4 = {
                char = Character,
                originweapon = __up9,
                weapon = Value_2,
                model = Value_3,
                module = r20,
                core = shield_supplies
            }
            r3.main = r4
            weaponEffects("henry_offhandround", r3)
        end
        events.game_handler:Fire("weapon_visibility", {wep = Parent_2, state = "holster"})
        if r29.dual_wield_tool then
            if not r29.dual_wield_tool:FindFirstChild("event") then return end
            r29.dual_wield_tool.event:Fire("dual_active", false)
            local r1
            local r2
            if Value_2 == "cavsword" then r1 = true end
            if Character.perk.Value == "akimbo" and r20.size == 1 and r20.tooltype == "gun" then
                r1 = true
                r2 = true
            end
            weaponEffects("weapon_visibility", {
                main = r29.dual_wield_vfx(),
                slot = r29.dual_wield_tool.slot.Value, state = "holster",
                flipped = r1,
                dual = r2
            }, true)
            events.game_handler:Fire("weapon_visibility", {
                wep = r29.dual_wield_tool, state = "holster",
                flipped = r1,
                dual = r2
            })
        end
    end
end)
local r110 = RenderStepped:Connect(r103)
local r111 = game:GetService("RunService").Stepped:Connect(r106_0)
r69 = function() -- Line: 11536 | Upvalues: ("r29" (copy), "r49" (ref), "r25" (copy), "empty_ammo" (copy), "r15" (ref), "r110" (copy), "r111" (copy), "Parent_2" (copy))
    if r29.construct_holo ~= nil then r29.construct_holo:Destroy() end
    if r29.los_tripwire ~= nil then r29.los_tripwire:Destroy() end
    if r49 ~= nil then r49:Destroy() end
    if r29.extra_bb then r29.extra_bb:Destroy() end
    for r3, r4 in pairs(r25) do
        r4:Stop(0)
        r4:Destroy()
    end
    empty_ammo:Disconnect()
    r15 = true
    r29.equipped = false
    r110:Disconnect()
    r111:Disconnect()
    delay(2, function() -- Line: 11571 | Upvalues: ("Parent_2" (upval))
        if Parent_2 then Parent_2:Destroy() end
    end)
end
r26.Destroying = Parent_2.Destroying:Connect(function() -- Line: 11578 | Upvalues: ("r26" (copy))
    for r3, r4 in r26 do
        r4:Disconnect()
    end
    table.clear(r26)
end)
Humanoid.Died:Connect(r69)
