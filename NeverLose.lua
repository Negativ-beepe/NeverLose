local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local VirtualUser = game:GetService("VirtualUser")
local Stats = game:GetService("Stats")
local lp = Players.LocalPlayer

local alive = true
local gui
local conns = {}

-- ================= НАСТРОЙКИ И СОХРАНЕНИЕ =================
local BIND_DEFS = {
    {key = "AntiDodge", short = "AD", name = "Anti Dodge"},
    {key = "ChangeButton", short = "CB", name = "Change Button"},
    {key = "SpeedHack", short = "SH", name = "SpeedHack"},
    {key = "FOVOn", short = "FOV", name = "FOV"},
}

local State = {
    AntiDodge = false, ChangeButton = false, SpeedHack = false,
    Speed = 40, BlockMs = 200, Range = 20, -- BlockMs и Range фиксированные
    FOVOn = false, FOV = 90,
    MenuPct = 100, Opacity = 100, ColorIdx = 1,
    ShowStats = true, AntiAFK = true, Notify = true,
    BindPos = {},
}
for _, d in ipairs(BIND_DEFS) do State["Bind_" .. d.key] = false end

local ACCENTS = {
    {"Red", Color3.fromRGB(225, 29, 46)},
    {"Blue", Color3.fromRGB(41, 121, 255)},
    {"Purple", Color3.fromRGB(168, 85, 247)},
    {"Green", Color3.fromRGB(34, 197, 94)},
    {"Orange", Color3.fromRGB(249, 115, 22)},
    {"Pink", Color3.fromRGB(236, 72, 153)},
}

local FILE = "NeverLose_settings.json"
local SAVE_KEYS = {
    "AntiDodge", "ChangeButton", "SpeedHack", "Speed",
    "FOVOn", "FOV",
    "MenuPct", "Opacity", "ColorIdx", "ShowStats", "AntiAFK", "Notify", "BindPos",
}
for _, d in ipairs(BIND_DEFS) do table.insert(SAVE_KEYS, "Bind_" .. d.key) end

pcall(function()
    if isfile and isfile(FILE) then
        local data = HttpService:JSONDecode(readfile(FILE))
        for _, k in ipairs(SAVE_KEYS) do
            if data[k] ~= nil and type(data[k]) == type(State[k]) then
                State[k] = data[k]
            end
        end
    end
end)
if not ACCENTS[State.ColorIdx] then State.ColorIdx = 1 end

local saveToken = 0
local function saveSettings()
    saveToken = saveToken + 1
    local tok = saveToken
    task.delay(0.6, function()
        if tok ~= saveToken or not alive then return end
        pcall(function()
            if writefile then
                local data = {}
                for _, k in ipairs(SAVE_KEYS) do data[k] = State[k] end
                writefile(FILE, HttpService:JSONEncode(data))
            end
        end)
    end)
end

local notify = function() end
local updateKO = function() end
local hbStats

local ACC = ACCENTS[State.ColorIdx][2]

local DODGE_IDS = {
    ["9123573488"] = true, -- назад
    ["8718268965"] = true, -- вправо
    ["8718568305"] = true, -- влево
}
local SIGNALS = {"InputBegan", "Activated", "MouseButton1Click", "MouseButton1Down", "TouchTap"}

local function getArea()
    local pg = lp:FindFirstChild("PlayerGui")
    local m = pg and pg:FindFirstChild("MobileControls")
    return m and m:FindFirstChild("MobileButtonAreaContainer")
end

local function getBtn(name)
    local a = getArea()
    local m = a and a:FindFirstChild(name)
    return m and m:FindFirstChild("button")
end

-- ================= ANTI DODGE =================
local blocker
local function ensureBlocker()
    local btn = getBtn("PunchMainContainer")
    if not btn then return nil end
    if blocker and blocker.Parent == btn then return blocker end
    if blocker then blocker:Destroy() end
    blocker = Instance.new("TextButton")
    blocker.Name = "AntiDodgeBlock"
    blocker.Size = UDim2.new(1, 0, 1, 0)
    blocker.BackgroundTransparency = 1
    blocker.Text = ""
    blocker.AutoButtonColor = false
    blocker.Active = true
    blocker.Visible = false
    blocker.ZIndex = 1000
    blocker.Parent = btn
    return blocker
end

local function isDodging(char)
    local hum = char:FindFirstChildOfClass("Humanoid")
    local animator = hum and hum:FindFirstChildOfClass("Animator")
    if not animator then return false end
    local limit = State.BlockMs / 1000
    for _, t in ipairs(animator:GetPlayingAnimationTracks()) do
        local id = tostring(t.Animation.AnimationId):match("%d+")
        if id and DODGE_IDS[id] and t.IsPlaying and t.TimePosition <= limit then
            return true
        end
    end
    return false
end

local function enemyDodgingNearby()
    local myRoot = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    if not myRoot then return false end
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= lp and p.Character then
            local r = p.Character:FindFirstChild("HumanoidRootPart")
            if r and (r.Position - myRoot.Position).Magnitude <= State.Range and isDodging(p.Character) then
                return true
            end
        end
    end
    return false
end

local hbAnti = RunService.Heartbeat:Connect(function()
    local b = ensureBlocker()
    if b then b.Visible = State.AntiDodge and enemyDodgingNearby() end
end)

-- ================= CHANGE BUTTON =================
local hooked = {}
local busy = false

local function firePunch(input)
    local btn = getBtn("PunchMainContainer")
    if not btn then return end
    if blocker and blocker.Visible then return end
    for _, sig in ipairs(SIGNALS) do
        pcall(function()
            for _, c in ipairs(getconnections(btn[sig])) do
                if sig == "InputBegan" then c:Fire(input, false) else c:Fire() end
            end
        end)
    end
end

local function fireOrig(rec, input)
    for _, o in ipairs(rec.orig) do
        pcall(function()
            o.c:Enable()
            if o.sig == "InputBegan" then o.c:Fire(input, false) else o.c:Fire() end
            if State.ChangeButton then o.c:Disable() end
        end)
    end
end

local function hookDodge(btn)
    if hooked[btn] then return end
    local rec = {orig = {}}
    for _, sig in ipairs(SIGNALS) do
        pcall(function()
            for _, c in ipairs(getconnections(btn[sig])) do
                table.insert(rec.orig, {c = c, sig = sig})
                if State.ChangeButton then c:Disable() end
            end
        end)
    end
    rec.ours = btn.InputBegan:Connect(function(input)
        if not State.ChangeButton or busy then return end
        local t = input.UserInputType
        if t ~= Enum.UserInputType.Touch and t ~= Enum.UserInputType.MouseButton1 then return end
        busy = true
        firePunch(input)
        RunService.Heartbeat:Wait()
        fireOrig(rec, input)
        busy = false
    end)
    hooked[btn] = rec
end

local function setChange(on)
    State.ChangeButton = on
    for _, rec in pairs(hooked) do
        for _, o in ipairs(rec.orig) do
            pcall(function() if on then o.c:Disable() else o.c:Enable() end end)
        end
    end
end

task.spawn(function()
    while alive do
        local area = getArea()
        if area then
            for _, c in ipairs(area:GetChildren()) do
                if c.Name:find("Dodge") then
                    local b = c:FindFirstChild("button")
                    if b and not hooked[b] then hookDodge(b) end
                end
            end
        end
        for b, rec in pairs(hooked) do
            if not b.Parent then
                if rec.ours then rec.ours:Disconnect() end
                hooked[b] = nil
            end
        end
        task.wait(1)
    end
end)

-- ================= SPEEDHACK =================
local hbSpeed = RunService.Heartbeat:Connect(function()
    if not State.SpeedHack then return end
    local char = lp.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not hum or not root or hum.Health <= 0 then return end
    local dir = hum.MoveDirection
    if dir.Magnitude > 0.01 then
        local u = dir.Unit
        local v = root.AssemblyLinearVelocity
        root.AssemblyLinearVelocity = Vector3.new(u.X * State.Speed, v.Y, u.Z * State.Speed)
    end
end)

-- ================= FOV =================
local origFOV = (workspace.CurrentCamera and workspace.CurrentCamera.FieldOfView) or 70
RunService:BindToRenderStep("NL_Camera", Enum.RenderPriority.Camera.Value + 1, function()
    local cam = workspace.CurrentCamera
    if cam and State.FOVOn then cam.FieldOfView = State.FOV end
end)

-- ================= ANTI AFK =================
table.insert(conns, lp.Idled:Connect(function()
    if State.AntiAFK then
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end
end))

-- ================= СЧЁТЧИК KO =================
local KO = 0
local lastPunch = 0

local function hookMyChar(char)
    table.insert(conns, char.AttributeChanged:Connect(function(a)
        if a == "LastPunchTime" then lastPunch = tick() end
    end))
end
if lp.Character then hookMyChar(lp.Character) end
table.insert(conns, lp.CharacterAdded:Connect(hookMyChar))

local function hookEnemyKO(p)
    if p == lp then return end
    local function onChar(char)
        local hum = char:WaitForChild("Humanoid", 5)
        if not hum then return end
        local counted = false
        table.insert(conns, hum.HealthChanged:Connect(function(h)
            if h <= 0 and not counted then
                counted = true
                local myRoot = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
                local er = char:FindFirstChild("HumanoidRootPart")
                if tick() - lastPunch <= 4 and myRoot and er and (myRoot.Position - er.Position).Magnitude <= 25 then
                    KO = KO + 1
                    updateKO()
                    notify("KO +1")
                end
            end
        end))
    end
    if p.Character then task.spawn(onChar, p.Character) end
    table.insert(conns, p.CharacterAdded:Connect(function(c) task.spawn(onChar, c) end))
end
for _, p in ipairs(Players:GetPlayers()) do hookEnemyKO(p) end
table.insert(conns, Players.PlayerAdded:Connect(hookEnemyKO))

-- ================= ВИЗУАЛ (AMOLED) =================
local BG = Color3.fromRGB(0, 0, 0)
local PANEL = Color3.fromRGB(9, 9, 9)
local DARK = Color3.fromRGB(0, 0, 0)
local LINE = Color3.fromRGB(30, 30, 33)
local GRAY = Color3.fromRGB(138, 138, 146)
local OFFC = Color3.fromRGB(38, 38, 42)
local WHITE = Color3.fromRGB(242, 242, 242)
local CENTER = UDim2.new(0.5, 0, 0.5, 0)

local W0, H0 = 330, 360
local MINW, MINH, MAXW, MAXH = 280, 260, 600, 600

local accFns = {}
local function onAccent(f) f(ACC) table.insert(accFns, f) end
local function acc(obj, prop, fn)
    onAccent(function(c) obj[prop] = fn and fn(c) or c end)
end
local function rgbStr(c)
    return string.format("rgb(%d,%d,%d)", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end
local function darker(c) return c:Lerp(Color3.new(0, 0, 0), 0.75) end
local function setAccent(idx)
    State.ColorIdx = idx
    ACC = ACCENTS[idx][2]
    for _, f in ipairs(accFns) do pcall(f, ACC) end
end

local function menuScale() return State.MenuPct / 100 end
local function targetAlpha() return 1 - State.Opacity / 100 end

local function corner(o, r) local c = Instance.new("UICorner", o) c.CornerRadius = UDim.new(0, r) end
local function stroke(o, col)
    local s = Instance.new("UIStroke", o)
    s.Color = col
    s.Thickness = 1
    return s
end
local function label(parent, text, size, color, pos, sz, align)
    local l = Instance.new("TextLabel", parent)
    l.BackgroundTransparency = 1
    l.Text = text
    l.TextSize = size
    l.TextColor3 = color
    l.Font = Enum.Font.GothamMedium
    l.Position = pos
    l.Size = sz
    l.TextXAlignment = align or Enum.TextXAlignment.Left
    l.RichText = true
    return l
end

local function makeDraggable(handle, target, onTap, onDrop)
    local dragging, moved, dragStart, startPos = false, false, nil, nil
    handle.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging, moved = true, false
            dragStart, startPos = i.Position, target.Position
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    if moved then
                        if onDrop then onDrop() end
                    elseif onTap then
                        onTap()
                    end
                end
            end)
        end
    end)
    table.insert(conns, UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseMovement) then
            local d = i.Position - dragStart
            if d.Magnitude > 6 then moved = true end
            if moved then
                target.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
            end
        end
    end))
end

gui = Instance.new("ScreenGui")
gui.Name = "NeverLose"
gui.ResetOnSpawn = false
gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")

-- ================= УВЕДОМЛЕНИЯ =================
notify = function(text)
    if not State.Notify or not alive or not gui then return end
    local t = Instance.new("CanvasGroup", gui)
    t.AnchorPoint = Vector2.new(0.5, 0.5)
    t.Size = UDim2.new(0, 190, 0, 32)
    t.Position = UDim2.new(0.5, 0, 0.2, -12)
    t.BackgroundColor3 = BG
    t.GroupTransparency = 1
    corner(t, 10)
    local s = stroke(t, LINE)
    acc(s, "Color", darker)
    local bar = Instance.new("Frame", t)
    bar.Size = UDim2.new(0, 3, 1, 0)
    bar.BorderSizePixel = 0
    acc(bar, "BackgroundColor3")
    label(t, text, 12, WHITE, UDim2.new(0, 0, 0, 0), UDim2.new(1, 0, 1, 0), Enum.TextXAlignment.Center)
    TweenService:Create(t, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        GroupTransparency = 0, Position = UDim2.new(0.5, 0, 0.2, 0),
    }):Play()
    task.delay(1.6, function()
        local out = TweenService:Create(t, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
            GroupTransparency = 1, Position = UDim2.new(0.5, 0, 0.2, -12),
        })
        out.Completed:Connect(function() t:Destroy() end)
        out:Play()
    end)
end

-- ================= СЧЁТЧИК FPS / PING / KO =================
local hud = Instance.new("TextLabel", gui)
hud.AnchorPoint = Vector2.new(0.5, 0)
hud.Position = UDim2.new(0.8, 0, 0, 6)
hud.Size = UDim2.new(0, 220, 0, 22)
hud.BackgroundColor3 = Color3.new(0, 0, 0)
hud.BackgroundTransparency = 0.2
hud.TextColor3 = WHITE
hud.TextSize = 11
hud.Font = Enum.Font.GothamMedium
hud.Text = "FPS --  |  Ping --  |  KO 0"
hud.Active = true
hud.Visible = State.ShowStats
corner(hud, 8)
acc(stroke(hud, LINE), "Color", darker)
makeDraggable(hud, hud, nil, nil)

do
    local frames, elapsed = 0, 0
    hbStats = RunService.RenderStepped:Connect(function(dt)
        frames = frames + 1
        elapsed = elapsed + dt
        if elapsed >= 0.5 then
            local fps = math.floor(frames / elapsed + 0.5)
            frames, elapsed = 0, 0
            local ping = 0
            pcall(function()
                ping = math.floor(Stats.Network.ServerStatsItem["Data Ping"]:GetValue() + 0.5)
            end)
            hud.Text = string.format("FPS %d  |  Ping %d ms  |  KO %d", fps, ping, KO)
        end
    end)
end

-- ================= SHUTDOWN =================
local function shutdown()
    alive = false
    State.AntiDodge = false
    State.SpeedHack = false
    pcall(function() RunService:UnbindFromRenderStep("NL_Camera") end)
    pcall(function()
        if State.FOVOn and workspace.CurrentCamera then
            workspace.CurrentCamera.FieldOfView = origFOV
        end
    end)
    pcall(setChange, false)
    pcall(function() hbAnti:Disconnect() end)
    pcall(function() hbSpeed:Disconnect() end)
    pcall(function() hbStats:Disconnect() end)
    for _, rec in pairs(hooked) do
        if rec.ours then pcall(function() rec.ours:Disconnect() end) end
    end
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    if blocker then pcall(function() blocker:Destroy() end) end
    if gui then pcall(function() gui:Destroy() end) end
end

-- ================= МЕНЮ =================
local main = Instance.new("CanvasGroup", gui)
main.AnchorPoint = Vector2.new(0.5, 0.5)
main.Size = UDim2.new(0, W0, 0, H0)
main.Position = CENTER
main.BackgroundColor3 = BG
main.GroupTransparency = 1
main.Visible = false
corner(main, 14)
acc(stroke(main, LINE), "Color", darker)
local mainScale = Instance.new("UIScale", main)
mainScale.Scale = menuScale() * 0.85

local header = Instance.new("Frame", main)
header.Size = UDim2.new(1, 0, 0, 48)
header.BackgroundColor3 = BG
header.BorderSizePixel = 0
corner(header, 14)
local hfill = Instance.new("Frame", header)
hfill.Size = UDim2.new(1, 0, 0, 24)
hfill.Position = UDim2.new(0, 0, 1, -24)
hfill.BackgroundColor3 = BG
hfill.BorderSizePixel = 0

local title = label(header, "", 16, WHITE, UDim2.new(0, 14, 0, 7), UDim2.new(0.6, 0, 0, 20))
acc(title, "Text", function(c) return 'Never<font color="' .. rgbStr(c) .. '">Lose</font>' end)
local ownerL = label(header, "", 10, GRAY, UDim2.new(0, 14, 0, 28), UDim2.new(0.6, 0, 0, 14))
acc(ownerL, "Text", function(c) return 'Owner: <font color="' .. rgbStr(c) .. '">Seth</font>' end)

local redline = Instance.new("Frame", main)
redline.Size = UDim2.new(1, 0, 0, 2)
redline.Position = UDim2.new(0, 0, 0, 48)
redline.BorderSizePixel = 0
acc(redline, "BackgroundColor3")

local function hbtn(txt, x)
    local b = Instance.new("TextButton", header)
    b.Size = UDim2.new(0, 30, 0, 30)
    b.Position = UDim2.new(1, x, 0, 9)
    b.BackgroundTransparency = 1
    b.Text = txt
    b.TextColor3 = GRAY
    b.TextSize = 18
    b.Font = Enum.Font.GothamMedium
    return b
end
local btnMin = hbtn("-", -68)
local btnClose = hbtn("X", -36)

local body = Instance.new("Frame", main)
body.Position = UDim2.new(0, 0, 0, 50)
body.Size = UDim2.new(1, 0, 1, -50)
body.BackgroundTransparency = 1

local tabs = Instance.new("Frame", body)
tabs.Size = UDim2.new(1, 0, 0, 34)
tabs.BackgroundColor3 = DARK
tabs.BorderSizePixel = 0

local pages, tabBtns, tabLines = {}, {}, {}
local function newPage()
    local p = Instance.new("ScrollingFrame", body)
    p.Position = UDim2.new(0, 0, 0, 34)
    p.Size = UDim2.new(1, 0, 1, -58)
    p.BackgroundTransparency = 1
    p.BorderSizePixel = 0
    p.ScrollBarThickness = 3
    acc(p, "ScrollBarImageColor3")
    p.CanvasSize = UDim2.new()
    p.AutomaticCanvasSize = Enum.AutomaticSize.Y
    p.ScrollingDirection = Enum.ScrollingDirection.Y
    p.Visible = false
    local pad = Instance.new("UIPadding", p)
    pad.PaddingTop = UDim.new(0, 10)
    pad.PaddingBottom = UDim.new(0, 10)
    pad.PaddingLeft = UDim.new(0, 12)
    pad.PaddingRight = UDim.new(0, 12)
    local l = Instance.new("UIListLayout", p)
    l.Padding = UDim.new(0, 6)
    l.SortOrder = Enum.SortOrder.LayoutOrder
    return p
end

local function selectTab(name)
    for n, p in pairs(pages) do p.Visible = (n == name) end
    for n, b in pairs(tabBtns) do
        b.TextColor3 = (n == name) and WHITE or GRAY
        tabLines[n].Visible = (n == name)
    end
end

local TAB_COUNT = 3
local function addTab(name, idx)
    pages[name] = newPage()
    local b = Instance.new("TextButton", tabs)
    b.Size = UDim2.new(1 / TAB_COUNT, 0, 1, 0)
    b.Position = UDim2.new((idx - 1) / TAB_COUNT, 0, 0, 0)
    b.BackgroundTransparency = 1
    b.Text = name
    b.TextSize = 12
    b.Font = Enum.Font.GothamMedium
    b.TextColor3 = GRAY
    local ln = Instance.new("Frame", b)
    ln.Size = UDim2.new(1, 0, 0, 2)
    ln.Position = UDim2.new(0, 0, 1, -2)
    ln.BorderSizePixel = 0
    ln.Visible = false
    acc(ln, "BackgroundColor3")
    tabBtns[name], tabLines[name] = b, ln
    b.MouseButton1Click:Connect(function() selectTab(name) end)
end
addTab("Combat", 1)
addTab("Rage", 2)
addTab("Settings", 3)

local function section(parent, text, order)
    local l = label(parent, text, 10, WHITE, UDim2.new(), UDim2.new(1, 0, 0, 14))
    acc(l, "TextColor3")
    l.LayoutOrder = order or 0
end

local Toggles = {}
local BindRefresh = {}

local function addToggle(parent, text, key, order, cb)
    local row = Instance.new("Frame", parent)
    row.Size = UDim2.new(1, 0, 0, 42)
    row.BackgroundColor3 = PANEL
    row.LayoutOrder = order or 1
    corner(row, 8)
    stroke(row, LINE)
    label(row, text, 12, WHITE, UDim2.new(0, 12, 0, 0), UDim2.new(1, -70, 1, 0))
    local on = State[key] == true
    local sw = Instance.new("Frame", row)
    sw.Size = UDim2.new(0, 42, 0, 22)
    sw.Position = UDim2.new(1, -54, 0.5, -11)
    sw.BackgroundColor3 = on and ACC or OFFC
    corner(sw, 11)
    local knob = Instance.new("Frame", sw)
    knob.Size = UDim2.new(0, 16, 0, 16)
    knob.Position = on and UDim2.new(1, -19, 0, 3) or UDim2.new(0, 3, 0, 3)
    knob.BackgroundColor3 = on and WHITE or GRAY
    corner(knob, 8)
    onAccent(function(c) if on then sw.BackgroundColor3 = c end end)
    local hit = Instance.new("TextButton", row)
    hit.Size = UDim2.new(1, 0, 1, 0)
    hit.BackgroundTransparency = 1
    hit.Text = ""

    local function apply(v)
        on = v
        State[key] = v
        local ti = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
        TweenService:Create(sw, ti, {BackgroundColor3 = on and ACC or OFFC}):Play()
        TweenService:Create(knob, ti, {
            Position = on and UDim2.new(1, -19, 0, 3) or UDim2.new(0, 3, 0, 3),
            BackgroundColor3 = on and WHITE or GRAY,
        }):Play()
        if cb then cb(v) end
        if BindRefresh[key] then BindRefresh[key]() end
        notify(text .. (on and " ON" or " OFF"))
        saveSettings()
    end
    Toggles[key] = apply
    hit.MouseButton1Click:Connect(function() apply(not on) end)
    if on and cb then pcall(cb, true) end
end

local function addButton(parent, text, cb, order)
    local b = Instance.new("TextButton", parent)
    b.Size = UDim2.new(1, 0, 0, 42)
    b.BackgroundColor3 = PANEL
    b.LayoutOrder = order or 1
    b.Text = text
    b.TextColor3 = WHITE
    b.TextSize = 12
    b.Font = Enum.Font.GothamMedium
    b.AutoButtonColor = true
    corner(b, 8)
    stroke(b, LINE)
    b.MouseButton1Click:Connect(function() cb(b) end)
    return b
end

local function addSlider(parent, text, min, max, key, order, suffix, onChange, onCommit)
    suffix = suffix or ""
    local default = math.clamp(State[key], min, max)
    State[key] = default
    local row = Instance.new("Frame", parent)
    row.Size = UDim2.new(1, 0, 0, 50)
    row.BackgroundColor3 = PANEL
    row.LayoutOrder = order or 1
    corner(row, 8)
    stroke(row, LINE)
    label(row, text, 11, WHITE, UDim2.new(0, 12, 0, 6), UDim2.new(0.5, 0, 0, 16))
    local valL = label(row, tostring(default) .. suffix, 11, WHITE, UDim2.new(0.5, -12, 0, 6), UDim2.new(0.5, 0, 0, 16), Enum.TextXAlignment.Right)
    local track = Instance.new("Frame", row)
    track.Size = UDim2.new(1, -24, 0, 4)
    track.Position = UDim2.new(0, 12, 0, 34)
    track.BackgroundColor3 = OFFC
    track.BorderSizePixel = 0
    corner(track, 2)
    local fill = Instance.new("Frame", track)
    fill.Size = UDim2.new((default - min) / (max - min), 0, 1, 0)
    fill.BorderSizePixel = 0
    acc(fill, "BackgroundColor3")
    corner(fill, 2)
    local knob = Instance.new("Frame", track)
    knob.Size = UDim2.new(0, 14, 0, 14)
    knob.AnchorPoint = Vector2.new(0.5, 0.5)
    knob.Position = UDim2.new((default - min) / (max - min), 0, 0.5, 0)
    knob.BackgroundColor3 = WHITE
    knob.BorderSizePixel = 0
    corner(knob, 7)
    local hit = Instance.new("TextButton", row)
    hit.Size = UDim2.new(1, 0, 0, 28)
    hit.Position = UDim2.new(0, 0, 0, 22)
    hit.BackgroundTransparency = 1
    hit.Text = ""
    local dragging = false
    local cur = default
    local function setFromX(x)
        local frac = math.clamp((x - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
        local val = math.floor(min + frac * (max - min) + 0.5)
        local f = (val - min) / (max - min)
        cur = val
        State[key] = val
        fill.Size = UDim2.new(f, 0, 1, 0)
        knob.Position = UDim2.new(f, 0, 0.5, 0)
        valL.Text = tostring(val) .. suffix
        if onChange then onChange(val) end
    end
    hit.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            parent.ScrollingEnabled = false
            setFromX(i.Position.X)
        end
    end)
    table.insert(conns, UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseMovement) then
            setFromX(i.Position.X)
        end
    end))
    table.insert(conns, UIS.InputEnded:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1) then
            dragging = false
            parent.ScrollingEnabled = true
            saveSettings()
            if onCommit then onCommit(cur) end
        end
    end))
end

-- ================= БИНДЫ (КВАДРАТИКИ НА ЭКРАНЕ) =================
local bindFrames = {}
local function bindPos(i, key)
    local p = State.BindPos[key]
    if type(p) == "table" and #p == 4 then
        return UDim2.new(p[1], p[2], p[3], p[4])
    end
    return UDim2.new(0, 36, 0.3 + (i - 1) * 0.11, 0)
end

for i, d in ipairs(BIND_DEFS) do
    local b = Instance.new("TextButton", gui)
    b.Name = "Bind_" .. d.key
    b.AnchorPoint = Vector2.new(0.5, 0.5)
    b.Size = UDim2.new(0, 44, 0, 44)
    b.Position = bindPos(i, d.key)
    b.BackgroundColor3 = Color3.new(0, 0, 0)
    b.BackgroundTransparency = 0.1
    b.Text = d.short
    b.TextSize = 12
    b.Font = Enum.Font.GothamBold
    b.AutoButtonColor = false
    b.Visible = State["Bind_" .. d.key] == true
    corner(b, 10)
    local st = Instance.new("UIStroke", b)
    st.Thickness = 2
    local function refresh()
        local on = State[d.key] == true
        st.Color = on and ACC or LINE
        b.TextColor3 = on and ACC or GRAY
    end
    onAccent(refresh)
    BindRefresh[d.key] = refresh
    makeDraggable(b, b, function()
        if Toggles[d.key] then Toggles[d.key](not State[d.key]) end
    end, function()
        State.BindPos[d.key] = {b.Position.X.Scale, b.Position.X.Offset, b.Position.Y.Scale, b.Position.Y.Offset}
        saveSettings()
    end)
    bindFrames[d.key] = b
end

-- Combat
section(pages.Combat, "AIM ASSIST", 0)
addToggle(pages.Combat, "Anti Dodge", "AntiDodge", 1)
addToggle(pages.Combat, "Change Button", "ChangeButton", 2, function(v)
    if v and not getconnections then notify("getconnections not supported") end
    setChange(v)
end)

-- Rage
section(pages.Rage, "MOVEMENT", 0)
addToggle(pages.Rage, "SpeedHack", "SpeedHack", 1)
addSlider(pages.Rage, "Speed", 16, 120, "Speed", 2)

section(pages.Rage, "VISUAL", 3)
addToggle(pages.Rage, "FOV Changer", "FOVOn", 4, function(v)
    if not v and workspace.CurrentCamera then
        workspace.CurrentCamera.FieldOfView = origFOV
    end
end)
addSlider(pages.Rage, "FOV", 50, 120, "FOV", 5)

local panic = Instance.new("TextButton", pages.Rage)
panic.Size = UDim2.new(1, 0, 0, 42)
panic.LayoutOrder = 9999
panic.Text = "Panic"
panic.TextColor3 = WHITE
panic.TextSize = 13
panic.Font = Enum.Font.GothamMedium
panic.AutoButtonColor = true
acc(panic, "BackgroundColor3")
corner(panic, 8)
panic.MouseButton1Click:Connect(shutdown)

-- Settings
section(pages.Settings, "MENU", 0)
addSlider(pages.Settings, "Menu Size", 60, 140, "MenuPct", 1, "%", nil, function()
    TweenService:Create(mainScale, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Scale = menuScale()}):Play()
end)
addSlider(pages.Settings, "Opacity", 40, 100, "Opacity", 2, "%", function()
    if main.Visible then main.GroupTransparency = targetAlpha() end
end)

do
    local row = Instance.new("Frame", pages.Settings)
    row.Size = UDim2.new(1, 0, 0, 64)
    row.BackgroundColor3 = PANEL
    row.LayoutOrder = 3
    corner(row, 8)
    stroke(row, LINE)
    label(row, "Accent Color", 11, WHITE, UDim2.new(0, 12, 0, 6), UDim2.new(1, -24, 0, 16))
    local holder = Instance.new("Frame", row)
    holder.BackgroundTransparency = 1
    holder.Position = UDim2.new(0, 12, 0, 28)
    holder.Size = UDim2.new(1, -24, 0, 28)
    local lay = Instance.new("UIListLayout", holder)
    lay.FillDirection = Enum.FillDirection.Horizontal
    lay.Padding = UDim.new(0, 8)
    local rings = {}
    local function refresh()
        for i, st in ipairs(rings) do
            st.Transparency = (i == State.ColorIdx) and 0 or 1
        end
    end
    for i, a in ipairs(ACCENTS) do
        local b = Instance.new("TextButton", holder)
        b.Size = UDim2.new(0, 26, 0, 26)
        b.BackgroundColor3 = a[2]
        b.Text = ""
        b.AutoButtonColor = false
        corner(b, 13)
        local st = Instance.new("UIStroke", b)
        st.Color = WHITE
        st.Thickness = 2
        rings[i] = st
        b.MouseButton1Click:Connect(function()
            setAccent(i)
            refresh()
            saveSettings()
            notify("Color: " .. a[1])
        end)
    end
    refresh()
end

addButton(pages.Settings, "Center Menu", function()
    TweenService:Create(main, TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {Position = CENTER}):Play()
end, 4)
addButton(pages.Settings, "Reset Size", function()
    TweenService:Create(main, TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {Size = UDim2.new(0, W0, 0, H0)}):Play()
end, 5)

section(pages.Settings, "BINDS", 6)
for i, d in ipairs(BIND_DEFS) do
    addToggle(pages.Settings, "Bind: " .. d.name, "Bind_" .. d.key, 6 + i, function(v)
        bindFrames[d.key].Visible = v
    end)
end

section(pages.Settings, "EXTRA", 20)
addToggle(pages.Settings, "Show Stats", "ShowStats", 21, function(v) hud.Visible = v end)
addToggle(pages.Settings, "Anti AFK", "AntiAFK", 22)
addToggle(pages.Settings, "Notifications", "Notify", 23)

do
    local row = Instance.new("Frame", pages.Settings)
    row.Size = UDim2.new(1, 0, 0, 36)
    row.BackgroundColor3 = PANEL
    row.LayoutOrder = 24
    corner(row, 8)
    stroke(row, LINE)
    label(row, "KOs this session", 11, WHITE, UDim2.new(0, 12, 0, 0), UDim2.new(0.6, 0, 1, 0))
    local koL = label(row, "0", 12, WHITE, UDim2.new(0.6, 0, 0, 0), UDim2.new(0.4, -12, 1, 0), Enum.TextXAlignment.Right)
    acc(koL, "TextColor3")
    updateKO = function() koL.Text = tostring(KO) end
end
addButton(pages.Settings, "Reset KOs", function()
    KO = 0
    updateKO()
end, 25)

-- футер
local foot = Instance.new("Frame", body)
foot.AnchorPoint = Vector2.new(0, 1)
foot.Position = UDim2.new(0, 0, 1, 0)
foot.Size = UDim2.new(1, 0, 0, 24)
foot.BackgroundColor3 = BG
foot.BorderSizePixel = 0
corner(foot, 14)
local ffill = Instance.new("Frame", foot)
ffill.Size = UDim2.new(1, 0, 0, 12)
ffill.BackgroundColor3 = BG
ffill.BorderSizePixel = 0
label(foot, "NeverLose v1.0", 10, Color3.fromRGB(106, 106, 114), UDim2.new(0, 14, 0, 0), UDim2.new(0.5, 0, 1, 0))
label(foot, "Owner: Seth", 10, Color3.fromRGB(106, 106, 114), UDim2.new(0.5, -30, 0, 0), UDim2.new(0.5, 0, 1, 0), Enum.TextXAlignment.Right)

-- уголок для изменения размера
local grip = Instance.new("TextButton", main)
grip.AnchorPoint = Vector2.new(1, 1)
grip.Position = UDim2.new(1, 0, 1, 0)
grip.Size = UDim2.new(0, 28, 0, 28)
grip.BackgroundTransparency = 1
grip.Text = "◢"
grip.TextSize = 18
grip.Font = Enum.Font.GothamBold
grip.ZIndex = 50
acc(grip, "TextColor3")

do
    local resizing, startPos, startW, startH, startMainPos = false, nil, 0, 0, nil
    grip.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
            resizing = true
            startPos = i.Position
            startW, startH = main.Size.X.Offset, main.Size.Y.Offset
            startMainPos = main.Position
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then resizing = false end
            end)
        end
    end)
    table.insert(conns, UIS.InputChanged:Connect(function(i)
        if resizing and (i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseMovement) then
            local sc = mainScale.Scale
            local d = i.Position - startPos
            local nw = math.clamp(startW + d.X / sc, MINW, MAXW)
            local nh = math.clamp(startH + d.Y / sc, MINH, MAXH)
            main.Size = UDim2.new(0, nw, 0, nh)
            local dw, dh = (nw - startW) * sc, (nh - startH) * sc
            main.Position = UDim2.new(
                startMainPos.X.Scale, startMainPos.X.Offset + dw / 2,
                startMainPos.Y.Scale, startMainPos.Y.Offset + dh / 2
            )
        end
    end))
end

selectTab("Combat")

-- ================= АНИМАЦИИ ОКНА =================
local function showMenu()
    main.Position = CENTER
    main.Visible = true
    main.GroupTransparency = 1
    mainScale.Scale = menuScale() * 0.85
    TweenService:Create(main, TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {GroupTransparency = targetAlpha()}):Play()
    TweenService:Create(mainScale, TweenInfo.new(0.55, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = menuScale()}):Play()
end

local function hideMenu(done)
    local t = TweenService:Create(main, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {GroupTransparency = 1})
    TweenService:Create(mainScale, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {Scale = menuScale() * 0.9}):Play()
    t.Completed:Connect(function()
        main.Visible = false
        if done then done() end
    end)
    t:Play()
end

-- ================= СВЁРНУТЫЙ ВИД (NL) =================
local mini = Instance.new("TextButton", gui)
mini.AnchorPoint = Vector2.new(0.5, 0.5)
mini.Size = UDim2.new(0, 46, 0, 46)
mini.Position = UDim2.new(0, 45, 0.18, 0)
mini.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
mini.RichText = true
mini.TextColor3 = WHITE
mini.TextSize = 18
mini.Font = Enum.Font.GothamBold
mini.AutoButtonColor = false
mini.Visible = false
acc(mini, "Text", function(c) return 'N<font color="' .. rgbStr(c) .. '">L</font>' end)
corner(mini, 12)
acc(stroke(mini, LINE), "Color", darker)
local miniScale = Instance.new("UIScale", mini)
miniScale.Scale = 0.1

btnMin.MouseButton1Click:Connect(function()
    hideMenu(function()
        mini.Visible = true
        miniScale.Scale = 0.1
        TweenService:Create(miniScale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}):Play()
    end)
end)

makeDraggable(mini, mini, function()
    mini.Visible = false
    showMenu()
end, nil)

btnClose.MouseButton1Click:Connect(shutdown)
makeDraggable(header, main, nil, nil)

-- ================= ЗАСТАВКА =================
local splash = Instance.new("TextLabel", gui)
splash.AnchorPoint = Vector2.new(0.5, 0.5)
splash.Position = UDim2.new(0.5, 0, 0.5, -12)
splash.Size = UDim2.new(0, 320, 0, 50)
splash.BackgroundTransparency = 1
splash.RichText = true
splash.TextColor3 = WHITE
splash.TextSize = 36
splash.Font = Enum.Font.GothamBold
splash.TextTransparency = 1
acc(splash, "Text", function(c) return 'Never<font color="' .. rgbStr(c) .. '">Lose</font>' end)

local sline = Instance.new("Frame", gui)
sline.AnchorPoint = Vector2.new(0.5, 0.5)
sline.Position = UDim2.new(0.5, 0, 0.5, 22)
sline.Size = UDim2.new(0, 0, 0, 2)
sline.BorderSizePixel = 0
acc(sline, "BackgroundColor3")
corner(sline, 1)

local sowner = Instance.new("TextLabel", gui)
sowner.AnchorPoint = Vector2.new(0.5, 0.5)
sowner.Position = UDim2.new(0.5, 0, 0.5, 40)
sowner.Size = UDim2.new(0, 200, 0, 18)
sowner.BackgroundTransparency = 1
sowner.RichText = true
sowner.TextColor3 = GRAY
sowner.TextSize = 12
sowner.Font = Enum.Font.GothamMedium
sowner.TextTransparency = 1
acc(sowner, "Text", function(c) return 'Owner: <font color="' .. rgbStr(c) .. '">Seth</font>' end)

task.spawn(function()
    local qo = Enum.EasingStyle.Quint
    TweenService:Create(splash, TweenInfo.new(0.6, qo, Enum.EasingDirection.Out), {TextTransparency = 0, Position = UDim2.new(0.5, 0, 0.5, -20)}):Play()
    TweenService:Create(sline, TweenInfo.new(0.7, qo, Enum.EasingDirection.Out), {Size = UDim2.new(0, 170, 0, 2)}):Play()
    task.wait(0.3)
    TweenService:Create(sowner, TweenInfo.new(0.5, qo, Enum.EasingDirection.Out), {TextTransparency = 0}):Play()
    task.wait(1.0)
    local fo = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
    TweenService:Create(splash, fo, {TextTransparency = 1}):Play()
    TweenService:Create(sowner, fo, {TextTransparency = 1}):Play()
    TweenService:Create(sline, fo, {BackgroundTransparency = 1, Size = UDim2.new(0, 0, 0, 2)}):Play()
    task.wait(0.45)
    splash:Destroy()
    sline:Destroy()
    sowner:Destroy()
    if alive then showMenu() end
end)
