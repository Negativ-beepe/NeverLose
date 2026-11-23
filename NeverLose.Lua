-- NeverLose v2.1
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")
local lp = Players.LocalPlayer

-- при повторном запуске убираем прошлую копию
if getgenv and getgenv().NL_Shutdown then pcall(getgenv().NL_Shutdown) end

local State = {
    AntiDodge = false,
    PunchDelay = 1, -- пауза между ударами в Farm, секунды
    ChangeButton = false,
    SpeedHack = false, Speed = 40,
    Sticky = false, StickDist = 3,
    Rich = false, RichDelay = 90,
    Notify = true,
    Blur = true,
}

local DODGE_TIME = {
    ["9123573488"] = 0.2,
    ["8718268965"] = 0.2,
    ["8718568305"] = 0.2,
}
local DODGE_NAME_KEYS = {"dodge"} -- если в названии анимации есть это слово, считаем её додж-анимацией
local DODGE_WINDOW = 0.3          -- окно для анимаций, найденных по названию
local RANGE = 20
local SIGNALS = {"InputBegan", "Activated", "MouseButton1Click", "MouseButton1Down", "TouchTap"}

-- ЗВУК ЗАПУСКА: если хочешь свой звук, впиши id, например "rbxassetid://123456789"
local CUSTOM_STARTUP_SOUND = ""

local alive = true
local gui, overlay, blur
local conns = {}
local notify = function() end          -- назначается ниже, в блоке меню
local onTargetChanged = function() end -- назначается ниже, в блоке меню

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

local function getMyRoot()
    local c = lp.Character
    local h = c and c:FindFirstChildOfClass("Humanoid")
    local r = c and c:FindFirstChild("HumanoidRootPart")
    if h and r and h.Health > 0 then return r end
end

-- ================= ЗВУК ЗАПУСКА =================
local function playStartup()
    task.spawn(function()
        local list
        if CUSTOM_STARTUP_SOUND ~= "" then
            list = {{CUSTOM_STARTUP_SOUND, 1}}
        else
            -- встроенный звук Roblox, три ноты вверх (мелодия запуска)
            local id = "rbxasset://sounds/electronicpingshort.wav"
            list = {{id, 0.75}, {id, 1.0}, {id, 1.5}}
        end
        for _, s in ipairs(list) do
            if not alive then return end
            pcall(function()
                local snd = Instance.new("Sound")
                snd.SoundId = s[1]
                snd.Volume = 1
                snd.PlaybackSpeed = s[2]
                snd.Parent = SoundService
                snd:Play()
                Debris:AddItem(snd, 4)
            end)
            task.wait(0.16)
        end
    end)
end

-- ================= ЦЕЛЬ (для Sticky и Rich) =================
local selectedName = nil -- nil = Auto (ближайший игрок)

local function aliveRoot(p)
    local c = p.Character
    local h = c and c:FindFirstChildOfClass("Humanoid")
    local r = c and c:FindFirstChild("HumanoidRootPart")
    if h and r and h.Health > 0 then return r end
end

local function nearestPlayer()
    local myRoot = getMyRoot()
    if not myRoot then return end
    local best, bestRoot, bestD
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= lp then
            local r = aliveRoot(p)
            if r then
                local d = (r.Position - myRoot.Position).Magnitude
                if not bestD or d < bestD then
                    best, bestRoot, bestD = p, r, d
                end
            end
        end
    end
    return best, bestRoot
end

local function getTarget()
    if selectedName then
        local p = Players:FindFirstChild(selectedName)
        if not p then
            selectedName = nil
            onTargetChanged()
            notify("Target", "игрок вышел, теперь Auto")
            return nearestPlayer()
        end
        return p, aliveRoot(p)
    end
    return nearestPlayer()
end

-- ================= ANTI DODGE =================
local blocker
local function ensureBlocker()
    local btn = getBtn("PunchMainContainer")
    if not btn then return nil end
    if blocker and blocker.Parent == btn then return blocker end
    if blocker then pcall(function() blocker:Destroy() end) end
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

local function getPing()
    local ok, p = pcall(function() return lp:GetNetworkPing() end)
    if ok and type(p) == "number" then return math.clamp(p, 0, 0.3) end
    return 0
end

-- сколько секунд от начала анимации считать её доджем (nil = это не додж)
local function dodgeLimit(track)
    local anim = track.Animation
    if not anim then return nil end
    local id = tostring(anim.AnimationId):match("%d+")
    if id and DODGE_TIME[id] then return DODGE_TIME[id] end
    local nm = (tostring(anim.Name) .. " " .. tostring(track.Name)):lower()
    for _, k in ipairs(DODGE_NAME_KEYS) do
        if nm:find(k, 1, true) then return DODGE_WINDOW end
    end
    return nil
end

-- запоминаем момент старта доджа через событие AnimationPlayed
-- (раньше проверка шла только опросом каждый кадр и часто не успевала поймать додж)
local dodgeUntil = setmetatable({}, {__mode = "k"}) -- [Character] = до какого времени идёт додж
local animHooked = setmetatable({}, {__mode = "k"})

local function hookChar(p, char)
    if p == lp or animHooked[char] then return end
    animHooked[char] = true
    task.spawn(function()
        local hum = char:WaitForChild("Humanoid", 10)
        if not hum or not alive then return end
        local animator = hum:FindFirstChildOfClass("Animator") or hum:WaitForChild("Animator", 10)
        if not animator or not alive then return end
        table.insert(conns, animator.AnimationPlayed:Connect(function(track)
            local limit = dodgeLimit(track)
            if limit then
                dodgeUntil[char] = os.clock() + limit + getPing()
            end
        end))
    end)
end

local function hookPlayer(p)
    if p == lp then return end
    if p.Character then hookChar(p, p.Character) end
    table.insert(conns, p.CharacterAdded:Connect(function(c) hookChar(p, c) end))
end
for _, p in ipairs(Players:GetPlayers()) do hookPlayer(p) end
table.insert(conns, Players.PlayerAdded:Connect(hookPlayer))

local function isDodging(char)
    local now = os.clock()
    local u = dodgeUntil[char]
    if u and now <= u then return true end
    local hum = char:FindFirstChildOfClass("Humanoid")
    local animator = hum and hum:FindFirstChildOfClass("Animator")
    if not animator then return false end
    local ping = getPing()
    for _, t in ipairs(animator:GetPlayingAnimationTracks()) do
        local limit = dodgeLimit(t)
        if limit and t.IsPlaying and t.TimePosition <= limit + ping then
            return true
        end
    end
    return false
end

local function enemyDodgingNearby()
    local myRoot = getMyRoot()
    if not myRoot then return false end
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= lp and p.Character then
            local r = p.Character:FindFirstChild("HumanoidRootPart")
            if r and (r.Position - myRoot.Position).Magnitude <= RANGE and isDodging(p.Character) then
                return true
            end
        end
    end
    return false
end

local latchUntil = 0
local hbAnti = RunService.Heartbeat:Connect(function()
    local b = ensureBlocker()
    if not b then return end
    local now = os.clock()
    if State.AntiDodge then
        local ok, res = pcall(enemyDodgingNearby)
        if ok and res then latchUntil = now + 0.12 end -- держим блок чуть дольше, чтобы не мигал
        b.Visible = now < latchUntil
    else
        b.Visible = false
    end
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
            pcall(function()
                if on then o.c:Disable() else o.c:Enable() end
            end)
        end
    end
end

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

-- ================= STICKY / RICH =================
local richBusy = false

-- dist > 0: за спиной цели, dist < 0: перед целью (лицом к ней)
local function standAt(myRoot, tr, dist)
    local pos = (tr.CFrame * CFrame.new(0, 0, dist)).Position
    local look = Vector3.new(tr.Position.X, pos.Y, tr.Position.Z)
    if (look - pos).Magnitude > 0.1 then
        myRoot.CFrame = CFrame.lookAt(pos, look)
    else
        myRoot.CFrame = CFrame.new(pos)
    end
    myRoot.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
end

-- Sticky: каждый кадр держит тебя рядом с целью
local hbSticky = RunService.Heartbeat:Connect(function()
    if not State.Sticky or richBusy then return end
    local myRoot = getMyRoot()
    if not myRoot then return end
    local _, tr = getTarget()
    if not tr then return end
    pcall(standAt, myRoot, tr, -State.StickDist)
end)

-- Rich: при ударе телепорт к цели, через RichDelay мс обратно
local function richHit()
    if not State.Rich or State.Sticky or richBusy then return end
    local myRoot = getMyRoot()
    if not myRoot then return end
    local _, tr = getTarget()
    if not tr then return end
    richBusy = true
    local origin = myRoot.CFrame
    pcall(standAt, myRoot, tr, 3)
    task.delay(State.RichDelay / 1000, function()
        local r = getMyRoot()
        if r then
            r.CFrame = origin
            r.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
        end
        richBusy = false
    end)
end

local richBtn, richConn
local function hookPunch(btn)
    if richBtn == btn then return end
    if richConn then richConn:Disconnect() end
    richBtn = btn
    richConn = btn.InputBegan:Connect(function(input)
        local t = input.UserInputType
        if t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseButton1 then
            richHit()
        end
    end)
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
            local pb = getBtn("PunchMainContainer")
            if pb then hookPunch(pb) end
        end
        for b, rec in pairs(hooked) do
            if not b.Parent then
                if rec.ours then rec.ours:Disconnect() end
                hooked[b] = nil
            end
        end
        pcall(onTargetChanged)
        task.wait(1)
    end
end)

-- ================= MACRO (запись и повтор действий) =================
local HttpService = game:GetService("HttpService")
local MACRO_FILE = "NL_macro.json"
local LOOP_PAUSE = 2 -- пауза между циклами, секунды
local Macro = {pos = {}, acts = {}, duration = 0}
local recording, playing = false, false
local recT0, recAcc, loopsDone = 0, 0, 0
local recConns, recHooked, held = {}, {}, {}
local refreshMacroInfo = function() end

local function macroInfo()
    if recording then return "Запись идёт..." end
    if playing then return "Повтор, циклов: " .. loopsDone end
    if #Macro.pos == 0 and #Macro.acts == 0 then return "Макрос пустой" end
    return string.format("Записано: %d движений, %d действий, %.1f c", #Macro.pos, #Macro.acts, Macro.duration)
end

local function saveMacro()
    if not writefile then return end
    local data = {duration = Macro.duration, pos = {}, acts = Macro.acts}
    for _, p in ipairs(Macro.pos) do
        table.insert(data.pos, {p.t, {p.cf:GetComponents()}})
    end
    pcall(function() writefile(MACRO_FILE, HttpService:JSONEncode(data)) end)
end

local function loadMacro()
    if not (isfile and readfile and isfile(MACRO_FILE)) then return end
    local ok, data = pcall(function() return HttpService:JSONDecode(readfile(MACRO_FILE)) end)
    if not ok or type(data) ~= "table" then return end
    Macro.duration = data.duration or 0
    Macro.acts = data.acts or {}
    Macro.pos = {}
    for _, p in ipairs(data.pos or {}) do
        table.insert(Macro.pos, {t = p[1], cf = CFrame.new(table.unpack(p[2]))})
    end
end
loadMacro()

-- ---- запись ----
local function recEvent(ev)
    if not recording then return end
    ev.t = os.clock() - recT0
    table.insert(Macro.acts, ev)
end

local function recHookButton(name, btn)
    if recHooked[btn] then return end
    recHooked[btn] = true
    table.insert(recConns, btn.InputBegan:Connect(function(i)
        local ut = i.UserInputType
        if not recording or (ut ~= Enum.UserInputType.Touch and ut ~= Enum.UserInputType.MouseButton1) then return end
        recEvent({k = "btn", name = name, down = true, x = i.Position.X, y = i.Position.Y})
        i.Changed:Connect(function()
            if i.UserInputState == Enum.UserInputState.End then
                recEvent({k = "btn", name = name, down = false, x = i.Position.X, y = i.Position.Y})
            end
        end)
    end))
end

local function recHookAll()
    local area = getArea()
    if not area then return end
    for _, c in ipairs(area:GetChildren()) do
        local b = c:FindFirstChild("button")
        if b then recHookButton(c.Name, b) end
    end
end

local function guiPath(o)
    local pg = lp:FindFirstChild("PlayerGui")
    local path, cur = {}, o
    while cur and cur ~= pg do
        table.insert(path, 1, cur.Name)
        cur = cur.Parent
    end
    if cur ~= pg then return nil end
    return path
end

local function recHookGui(o)
    if recHooked[o] or not (o:IsA("TextButton") or o:IsA("ImageButton")) then return end
    local path = guiPath(o)
    if not path or path[1] == "MobileControls" then return end
    recHooked[o] = true
    table.insert(recConns, o.Activated:Connect(function()
        recEvent({k = "gui", path = path, text = o:IsA("TextButton") and o.Text or ""})
    end))
end

local function trimMacro()
    local first, last = math.huge, 0
    local P, A = Macro.pos, Macro.acts
    if #P > 1 then
        local base = P[1].cf.Position
        for i = 2, #P do
            if (P[i].cf.Position - base).Magnitude > 1 then
                first = P[i].t
                break
            end
        end
        for i = #P, 2, -1 do
            if (P[i].cf.Position - P[i - 1].cf.Position).Magnitude > 0.5 then
                last = P[i].t
                break
            end
        end
    end
    if #A > 0 then
        first = math.min(first, A[1].t)
        last = math.max(last, A[#A].t)
    end
    if first == math.huge then return end
    local s0 = math.max(0, first - 0.5)
    local e0 = last + 1
    local np, na = {}, {}
    for _, p in ipairs(P) do
        if p.t >= s0 and p.t <= e0 then
            table.insert(np, {t = p.t - s0, cf = p.cf})
        end
    end
    for _, a in ipairs(A) do
        if a.t >= s0 and a.t <= e0 then
            a.t = a.t - s0
            table.insert(na, a)
        end
    end
    Macro.pos, Macro.acts = np, na
    Macro.duration = math.max(0, math.min(Macro.duration, e0) - s0)
end

local function startRecording()
    Macro.pos, Macro.acts, Macro.duration = {}, {}, 0
    recording = true
    recT0 = os.clock()
    recAcc = 0
    local r = getMyRoot()
    if r then table.insert(Macro.pos, {t = 0, cf = r.CFrame}) end
    recHookAll()
    local pg = lp:FindFirstChild("PlayerGui")
    if pg then
        for _, o in ipairs(pg:GetDescendants()) do recHookGui(o) end
        table.insert(recConns, pg.DescendantAdded:Connect(function(o)
            if recording then recHookGui(o) end
        end))
    end
end

local function stopRecording()
    if not recording then return end
    recording = false
    Macro.duration = os.clock() - recT0
    for _, c in ipairs(recConns) do pcall(function() c:Disconnect() end) end
    recConns, recHooked = {}, {}
    trimMacro()
    saveMacro()
end

local hbRec = RunService.Heartbeat:Connect(function(dt)
    if not recording then return end
    recAcc = recAcc + dt
    if recAcc < 0.1 then return end
    recAcc = 0
    local r = getMyRoot()
    if r then table.insert(Macro.pos, {t = os.clock() - recT0, cf = r.CFrame}) end
end)

-- ---- повтор ----
local function pressButton(btn, down, x, y)
    local input = {
        UserInputType = Enum.UserInputType.Touch,
        UserInputState = down and Enum.UserInputState.Begin or Enum.UserInputState.End,
        Position = Vector3.new(x or 0, y or 0, 0),
        Delta = Vector3.new(0, 0, 0),
        KeyCode = Enum.KeyCode.Unknown,
    }
    local sigs = down and SIGNALS or {"InputEnded", "MouseButton1Up"}
    for _, sig in ipairs(sigs) do
        pcall(function()
            for _, c in ipairs(getconnections(btn[sig])) do
                if sig == "InputBegan" or sig == "InputEnded" then c:Fire(input, false) else c:Fire() end
            end
        end)
    end
end

local function releaseHeld()
    for name in pairs(held) do
        local area = getArea()
        local holder = area and area:FindFirstChild(name)
        local b = holder and holder:FindFirstChild("button")
        if b then pressButton(b, false, 0, 0) end
    end
    held = {}
end

local function pressGui(path)
    local pg = lp:FindFirstChild("PlayerGui")
    local deadline = os.clock() + 3
    while playing and alive and os.clock() < deadline do
        local cur = pg
        for _, n in ipairs(path) do cur = cur and cur:FindFirstChild(n) end
        if cur and cur:IsA("GuiButton") then
            local fired = false
            for _, sig in ipairs({"Activated", "MouseButton1Click", "MouseButton1Down"}) do
                local ok, list = pcall(function() return getconnections(cur[sig]) end)
                if ok and list and #list > 0 then
                    for _, c in ipairs(list) do pcall(function() c:Fire() end) end
                    fired = true
                    break
                end
            end
            if not fired and firesignal then pcall(firesignal, cur.Activated) end
            return
        end
        task.wait(0.1)
    end
end

-- ---- слежение за ботом ----
local BOT_NAMES = {"iron", "bot"} -- части имени модели бота (маленькими буквами)
local BOT_RANGE_NAMED = 60        -- бот с подходящим именем: ищем в этом радиусе
local BOT_RANGE_ANY = 35          -- любой другой NPC: только совсем рядом
local FIGHT_DIST = 3              -- на каком расстоянии перед ботом стоять

local humanoids = {}
local function trackHumanoid(o)
    if o:IsA("Humanoid") then humanoids[o] = true end
end
task.spawn(function()
    local n = 0
    for _, o in ipairs(workspace:GetDescendants()) do
        if not alive then break end
        trackHumanoid(o)
        n = n + 1
        if n % 3000 == 0 then task.wait() end
    end
end)
table.insert(conns, workspace.DescendantAdded:Connect(trackHumanoid))
table.insert(conns, workspace.DescendantRemoving:Connect(function(o) humanoids[o] = nil end))

local function findBot()
    local myRoot = getMyRoot()
    if not myRoot then return end
    local namedRoot, namedD, nearRoot, nearD
    for h in pairs(humanoids) do
        local m = h.Parent
        if m and h.Health > 0 and m ~= lp.Character and not Players:GetPlayerFromCharacter(m) then
            local r = m:FindFirstChild("HumanoidRootPart")
            if r then
                local d = (r.Position - myRoot.Position).Magnitude
                local nm = m.Name:lower()
                local named = false
                for _, key in ipairs(BOT_NAMES) do
                    if nm:find(key, 1, true) then named = true break end
                end
                if named then
                    if d <= BOT_RANGE_NAMED and (not namedD or d < namedD) then
                        namedRoot, namedD = r, d
                    end
                elseif d <= BOT_RANGE_ANY and (not nearD or d < nearD) then
                    nearRoot, nearD = r, d
                end
            end
        end
    end
    return namedRoot or nearRoot
end

local function punchOnce()
    local b = getBtn("PunchMainContainer")
    if not b then return end
    pressButton(b, true, 0, 0)
    task.delay(0.1, function() pressButton(b, false, 0, 0) end)
end

local function runOnce()
    local P, A = Macro.pos, Macro.acts
    local pi, ai = 1, 1
    local t0 = os.clock()
    local deferred = {}
    local botRoot, lastCheck, lastPunch = nil, 0, 0
    local wasFighting = false
    while playing and alive do
        local now = os.clock()
        local el = now - t0

        -- ищем бота ~10 раз в секунду
        if now - lastCheck >= 0.1 then
            lastCheck = now
            botRoot = findBot()
        end
        local fighting = botRoot ~= nil and botRoot.Parent ~= nil
        if fighting and not wasFighting then releaseHeld() end
        wasFighting = fighting

        -- записанные действия: во время боя кнопки пропускаем, клики по меню откладываем
        while ai <= #A and A[ai].t <= el do
            local a = A[ai]
            ai = ai + 1
            if a.k == "gui" then
                if fighting then
                    table.insert(deferred, a)
                else
                    task.spawn(pressGui, a.path)
                end
            elseif a.k == "btn" and not fighting then
                local area = getArea()
                local holder = area and area:FindFirstChild(a.name)
                local b = holder and holder:FindFirstChild("button")
                if b then
                    held[a.name] = a.down or nil
                    pressButton(b, a.down, a.x, a.y)
                end
            end
        end
        if not fighting and #deferred > 0 then
            for _, a in ipairs(deferred) do task.spawn(pressGui, a.path) end
            deferred = {}
        end

        local root = getMyRoot()
        if fighting then
            -- бой: идём за ботом и бьём раз в секунду
            if root then pcall(standAt, root, botRoot, -FIGHT_DIST) end
            if now - lastPunch >= State.PunchDelay then
                lastPunch = now
                punchOnce()
            end
        elseif root and #P > 0 then
            -- вне боя: повторяем записанное движение
            while pi < #P and P[pi + 1].t <= el do pi = pi + 1 end
            local cur, nxt = P[pi], P[pi + 1]
            local cf = cur.cf
            if nxt and nxt.t > cur.t then
                cf = cur.cf:Lerp(nxt.cf, math.clamp((el - cur.t) / (nxt.t - cur.t), 0, 1))
            end
            root.CFrame = cf
            root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
        end

        if not fighting and el >= Macro.duration and ai > #A and #deferred == 0 then break end
        RunService.Heartbeat:Wait()
    end
    releaseHeld()
end

local function startPlaying()
    if playing then return true end
    if #Macro.pos == 0 and #Macro.acts == 0 then return false end
    playing = true
    loopsDone = 0
    task.spawn(function()
        while playing and alive do
            runOnce()
            loopsDone = loopsDone + 1
            local w = os.clock() + LOOP_PAUSE
            while playing and alive and os.clock() < w do task.wait(0.1) end
        end
    end)
    return true
end

local function stopPlaying()
    playing = false
    releaseHeld()
end

local function clearMacro()
    stopRecording()
    stopPlaying()
    Macro.pos, Macro.acts, Macro.duration = {}, {}, 0
    if delfile and isfile and isfile(MACRO_FILE) then pcall(delfile, MACRO_FILE) end
end

task.spawn(function()
    while alive do
        if recording then recHookAll() end
        pcall(refreshMacroInfo)
        task.wait(1)
    end
end)

-- ================= SHUTDOWN =================
local function shutdown()
    if not alive then return end
    alive = false
    State.AntiDodge = false
    State.SpeedHack = false
    State.Sticky = false
    State.Rich = false
    recording = false
    playing = false
    pcall(function() hbRec:Disconnect() end)
    for _, c in ipairs(recConns) do pcall(function() c:Disconnect() end) end
    pcall(setChange, false)
    pcall(function() hbAnti:Disconnect() end)
    pcall(function() hbSpeed:Disconnect() end)
    pcall(function() hbSticky:Disconnect() end)
    if richConn then pcall(function() richConn:Disconnect() end) end
    for _, rec in pairs(hooked) do
        if rec.ours then pcall(function() rec.ours:Disconnect() end) end
    end
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    if blocker then pcall(function() blocker:Destroy() end) end
    if blur then pcall(function() blur:Destroy() end) end
    if overlay then pcall(function() overlay:Destroy() end) end
    if gui then pcall(function() gui:Destroy() end) end
    if getgenv and getgenv().NL_Shutdown == shutdown then getgenv().NL_Shutdown = nil end
end
if getgenv then getgenv().NL_Shutdown = shutdown end

-- ================= MENU =================
local RED = Color3.fromRGB(225, 29, 46)
local RED_HI = Color3.fromRGB(255, 72, 88)
local RED_LO = Color3.fromRGB(110, 10, 22)
local BG = Color3.fromRGB(9, 9, 11)
local PANEL = Color3.fromRGB(20, 20, 23)
local DARK = Color3.fromRGB(13, 13, 16)
local LINE = Color3.fromRGB(40, 40, 46)
local LINE_ON = Color3.fromRGB(120, 24, 36)
local GRAY = Color3.fromRGB(138, 138, 146)
local OFFC = Color3.fromRGB(42, 42, 48)
local WHITE = Color3.fromRGB(242, 242, 242)
local PURE = Color3.new(1, 1, 1)
local CENTER = UDim2.new(0.5, 0, 0.5, 0)

local W0, H0 = 400, 350 -- меню стало шире
local R = 22            -- радиус скругления окна
local RR = 16           -- радиус карточек

local function corner(o, r)
    local c = Instance.new("UICorner", o)
    c.CornerRadius = UDim.new(0, r)
    return c
end
-- полностью круглая плашка (капсула / круг)
local function pill(o)
    local c = Instance.new("UICorner", o)
    c.CornerRadius = UDim.new(0.5, 0)
    return c
end
local function stroke(o, col, th)
    local s = Instance.new("UIStroke", o)
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    s.Color = col
    s.Thickness = th or 1
    return s
end
-- размер текста везде на 2 меньше (минимум 10)
local function label(parent, text, size, color, pos, sz, align)
    local l = Instance.new("TextLabel", parent)
    l.BackgroundTransparency = 1
    l.Text = text
    l.TextSize = math.max(10, size - 2)
    l.TextColor3 = color
    l.Font = Enum.Font.GothamMedium
    l.Position = pos
    l.Size = sz
    l.TextXAlignment = align or Enum.TextXAlignment.Left
    l.RichText = true
    return l
end

-- ---------- плавное переливание (градиенты) ----------
local flows, ticks = {}, {}

local function grad(parent, rot, ...)
    local list = {...}
    local keys = {}
    for i, c in ipairs(list) do
        table.insert(keys, ColorSequenceKeypoint.new((i - 1) / (#list - 1), c))
    end
    local g = Instance.new("UIGradient", parent)
    g.Color = ColorSequence.new(keys)
    g.Rotation = rot or 0
    return g
end

-- mode: "spin" крутится по кругу, "slide" блик ездит туда-сюда, "sway" лёгкое покачивание
local function flow(g, mode, speed, phase)
    table.insert(flows, {g = g, mode = mode, speed = speed or 1, phase = phase or 0})
    return g
end

-- рамка с бегущим красно-чёрным градиентом
local function gstroke(o, th, speed)
    local s = Instance.new("UIStroke", o)
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    s.Color = PURE
    s.Thickness = th or 1.5
    local g = grad(s, 0, RED, Color3.fromRGB(24, 5, 9), RED_HI, Color3.fromRGB(24, 5, 9), RED)
    flow(g, "spin", speed or 1, 0)
    return s
end

table.insert(conns, RunService.RenderStepped:Connect(function()
    local t = os.clock()
    for i = #flows, 1, -1 do
        local f = flows[i]
        if not f.g.Parent then
            table.remove(flows, i)
        elseif f.mode == "spin" then
            f.g.Rotation = (t * 40 * f.speed + f.phase) % 360
        elseif f.mode == "slide" then
            f.g.Offset = Vector2.new(math.sin(t * f.speed + f.phase) * 0.6, 0)
        elseif f.mode == "sway" then
            f.g.Rotation = 90 + math.sin(t * f.speed + f.phase) * 22
        end
    end
    for _, fn in ipairs(ticks) do pcall(fn, t) end
end))

local function tw(o, time, props, style, dir)
    local t = TweenService:Create(o, TweenInfo.new(time, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
    t:Play()
    return t
end

local function makeDraggable(handle, target, onTap)
    local dragging, moved, dragStart, startPos = false, false, nil, nil
    handle.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging, moved = true, false
            dragStart, startPos = i.Position, target.Position
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    if onTap and not moved then onTap() end
                end
            end)
        end
    end)
    table.insert(conns, UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseMovement) then
            local d = i.Position - dragStart
            if d.Magnitude > 6 then moved = true end
            target.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end))
end

local host = (gethui and gethui()) or game:GetService("CoreGui")
for _, n in ipairs({"NeverLose", "NLOverlay"}) do
    local o = host:FindFirstChild(n)
    if o then pcall(function() o:Destroy() end) end
end
local oldBlur = Lighting:FindFirstChild("NLBlur")
if oldBlur then pcall(function() oldBlur:Destroy() end) end

-- затемнение (под меню)
overlay = Instance.new("ScreenGui")
overlay.Name = "NLOverlay"
overlay.IgnoreGuiInset = true
overlay.ResetOnSpawn = false
overlay.DisplayOrder = 1
overlay.Parent = host
local dim = Instance.new("Frame", overlay)
dim.Size = UDim2.new(1, 0, 1, 0)
dim.BackgroundColor3 = Color3.new(0, 0, 0)
dim.BackgroundTransparency = 1
dim.BorderSizePixel = 0
dim.Active = false

-- блюр
blur = Instance.new("BlurEffect")
blur.Name = "NLBlur"
blur.Size = 0
blur.Parent = Lighting

-- основной gui
gui = Instance.new("ScreenGui")
gui.Name = "NeverLose"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true -- координаты gui = координаты экрана (нужно для правильного места окна бинда)
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 2
gui.Parent = host

local menuOpen = false
local function setBackdrop(on)
    local ti = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    TweenService:Create(dim, ti, {BackgroundTransparency = on and 0.4 or 1}):Play()
    TweenService:Create(blur, ti, {Size = (on and State.Blur) and 20 or 0}):Play()
end

-- ================= УВЕДОМЛЕНИЯ =================
local toastHost = Instance.new("Frame", gui)
toastHost.AnchorPoint = Vector2.new(0.5, 0)
toastHost.Position = UDim2.new(0.5, 0, 0, 10)
toastHost.Size = UDim2.new(0, 290, 0, 240)
toastHost.BackgroundTransparency = 1
toastHost.ZIndex = 100
local tl = Instance.new("UIListLayout", toastHost)
tl.Padding = UDim.new(0, 6)
tl.HorizontalAlignment = Enum.HorizontalAlignment.Center
tl.SortOrder = Enum.SortOrder.LayoutOrder

local toastN = 0
-- state: true = ON, false = OFF, строка = произвольный текст
notify = function(title, state)
    if not State.Notify or not alive then return end
    local kids = {}
    for _, c in ipairs(toastHost:GetChildren()) do
        if c:IsA("CanvasGroup") then table.insert(kids, c) end
    end
    if #kids >= 4 then kids[1]:Destroy() end

    toastN = toastN + 1
    local isOn = (state == true)
    local statusText
    if state == true then
        statusText = '<font color="rgb(255,72,88)">ON</font>'
    elseif state == false then
        statusText = '<font color="rgb(138,138,146)">OFF</font>'
    else
        statusText = '<font color="rgb(138,138,146)">' .. tostring(state) .. '</font>'
    end

    local t = Instance.new("CanvasGroup", toastHost)
    t.Size = UDim2.new(1, 0, 0, 44)
    t.BackgroundColor3 = Color3.fromRGB(16, 16, 19)
    t.BorderSizePixel = 0
    t.LayoutOrder = toastN
    t.GroupTransparency = 1
    pill(t)
    stroke(t, isOn and LINE_ON or LINE)

    local bar = Instance.new("Frame", t)
    bar.AnchorPoint = Vector2.new(0, 0.5)
    bar.Position = UDim2.new(0, 18, 0.5, 0)
    bar.Size = UDim2.new(0, 4, 0, 18)
    bar.BackgroundColor3 = isOn and PURE or OFFC
    bar.BorderSizePixel = 0
    corner(bar, 2)
    if isOn then grad(bar, 90, RED_HI, RED_LO) end

    label(t, "<b>" .. title .. "</b>  " .. statusText, 14, WHITE, UDim2.new(0, 34, 0, 0), UDim2.new(1, -52, 1, -3))

    -- полоска времени снизу
    local life = Instance.new("Frame", t)
    life.AnchorPoint = Vector2.new(0, 1)
    life.Position = UDim2.new(0, 24, 1, -6)
    life.Size = UDim2.new(1, -48, 0, 2)
    life.BackgroundColor3 = PURE
    life.BorderSizePixel = 0
    corner(life, 1)
    grad(life, 0, RED_LO, RED_HI)
    tw(life, 2.2, {Size = UDim2.new(0, 0, 0, 2)}, Enum.EasingStyle.Linear)

    local sc = Instance.new("UIScale", t)
    sc.Scale = 0.85

    tw(t, 0.25, {GroupTransparency = 0})
    tw(sc, 0.3, {Scale = 1}, Enum.EasingStyle.Back)

    task.delay(2.2, function()
        if t.Parent then
            tw(t, 0.3, {GroupTransparency = 1}, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
            task.wait(0.32)
            if t.Parent then t:Destroy() end
        end
    end)
end

-- ================= ОКНО =================
local main = Instance.new("CanvasGroup", gui)
main.AnchorPoint = Vector2.new(0.5, 0.5)
main.Size = UDim2.new(0, W0, 0, H0)
main.Position = CENTER
main.BackgroundColor3 = BG
main.BorderSizePixel = 0
main.GroupTransparency = 1
main.Visible = false
main.ClipsDescendants = true
corner(main, R)
gstroke(main, 2, 1)
local mainScale = Instance.new("UIScale", main)
mainScale.Scale = 0.88

-- фон окна: чёрный с красноватым дыханием
local bgf = Instance.new("Frame", main)
bgf.Size = UDim2.new(1, 0, 1, 0)
bgf.BackgroundColor3 = PURE
bgf.BorderSizePixel = 0
flow(grad(bgf, 90, Color3.fromRGB(26, 8, 12), Color3.fromRGB(9, 9, 11), Color3.fromRGB(9, 9, 11), Color3.fromRGB(20, 6, 10)), "sway", 0.6, 0)
corner(bgf, R)

local header = Instance.new("Frame", main)
header.Size = UDim2.new(1, 0, 0, 48)
header.BackgroundColor3 = PURE
header.BorderSizePixel = 0
flow(grad(header, 0, Color3.fromRGB(14, 14, 17), Color3.fromRGB(52, 12, 20), Color3.fromRGB(14, 14, 17)), "slide", 1.1, 0)
corner(header, R)
-- нижняя половина шапки остаётся прямой, скругляются только верхние углы
local headerFill = Instance.new("Frame", header)
headerFill.Position = UDim2.new(0, 0, 0, 24)
headerFill.Size = UDim2.new(1, 0, 0, 24)
headerFill.BackgroundColor3 = PURE
headerFill.BorderSizePixel = 0
flow(grad(headerFill, 0, Color3.fromRGB(14, 14, 17), Color3.fromRGB(52, 12, 20), Color3.fromRGB(14, 14, 17)), "slide", 1.1, 0)

-- заголовок с переливающимся текстом
local title = Instance.new("TextLabel", header)
title.BackgroundTransparency = 1
title.Text = "NeverLose"
title.TextSize = 18
title.TextColor3 = PURE
title.Font = Enum.Font.GothamBold
title.Position = UDim2.new(0, 18, 0, 6)
title.Size = UDim2.new(0.6, 0, 0, 22)
title.TextXAlignment = Enum.TextXAlignment.Left
flow(grad(title, 0, Color3.fromRGB(255, 255, 255), RED_HI, Color3.fromRGB(255, 255, 255)), "slide", 1.6, 0)
label(header, 'Owner: <font color="rgb(225,29,46)">Seth</font>', 11, GRAY, UDim2.new(0, 18, 0, 29), UDim2.new(0.6, 0, 0, 14))

-- пульсирующая точка статуса
local dot = Instance.new("Frame", header)
dot.Size = UDim2.new(0, 8, 0, 8)
dot.Position = UDim2.new(1, -100, 0.5, -4)
dot.BackgroundColor3 = RED
dot.BorderSizePixel = 0
corner(dot, 4)
table.insert(ticks, function(t) dot.BackgroundTransparency = 0.5 - 0.5 * math.sin(t * 3) * 0.9 end)

local redline = Instance.new("Frame", main)
redline.Size = UDim2.new(1, 0, 0, 2)
redline.Position = UDim2.new(0, 0, 0, 48)
redline.BackgroundColor3 = PURE
redline.BorderSizePixel = 0
flow(grad(redline, 0, Color3.fromRGB(70, 6, 14), RED_HI, Color3.fromRGB(70, 6, 14)), "slide", 2.2, 0)

-- мягкое свечение под красной линией
local glow = Instance.new("Frame", main)
glow.Position = UDim2.new(0, 0, 0, 50)
glow.Size = UDim2.new(1, 0, 0, 14)
glow.BackgroundColor3 = RED
glow.BorderSizePixel = 0
glow.ZIndex = 5
local glowG = Instance.new("UIGradient", glow)
glowG.Rotation = 90
glowG.Transparency = NumberSequence.new(0.82, 1)

local function hbtn(txt, x)
    local b = Instance.new("TextButton", header)
    b.Size = UDim2.new(0, 28, 0, 28)
    b.Position = UDim2.new(1, x, 0, 10)
    b.BackgroundColor3 = RED
    b.BackgroundTransparency = 1
    b.Text = txt
    b.TextColor3 = GRAY
    b.TextSize = 18
    b.Font = Enum.Font.GothamMedium
    b.AutoButtonColor = false
    pill(b)
    b.MouseEnter:Connect(function() tw(b, 0.15, {BackgroundTransparency = 0.7, TextColor3 = WHITE}) end)
    b.MouseLeave:Connect(function() tw(b, 0.15, {BackgroundTransparency = 1, TextColor3 = GRAY}) end)
    return b
end
local btnMin = hbtn("-", -74)
local btnClose = hbtn("X", -42)

local body = Instance.new("Frame", main)
body.Position = UDim2.new(0, 0, 0, 50)
body.Size = UDim2.new(1, 0, 1, -50)
body.BackgroundTransparency = 1

local tabs = Instance.new("Frame", body)
tabs.Size = UDim2.new(1, 0, 0, 34)
tabs.BackgroundColor3 = DARK
tabs.BackgroundTransparency = 0.2
tabs.BorderSizePixel = 0

local TAB_COUNT = 4
local underline = Instance.new("Frame", tabs)
underline.Size = UDim2.new(1 / TAB_COUNT, -16, 0, 3)
underline.Position = UDim2.new(0, 8, 1, -3)
underline.BackgroundColor3 = PURE
underline.BorderSizePixel = 0
corner(underline, 2)
flow(grad(underline, 0, RED_LO, RED_HI, RED_LO), "slide", 2.5, 0)

local pages, tabBtns, tabIdx = {}, {}, {}
local function newPage()
    local p = Instance.new("ScrollingFrame", body)
    p.Position = UDim2.new(0, 0, 0, 34)
    p.Size = UDim2.new(1, 0, 1, -58)
    p.BackgroundTransparency = 1
    p.BorderSizePixel = 0
    p.ScrollBarThickness = 3
    p.ScrollBarImageColor3 = RED
    p.CanvasSize = UDim2.new(0, 0, 0, 0)
    p.AutomaticCanvasSize = Enum.AutomaticSize.Y
    p.ScrollingDirection = Enum.ScrollingDirection.Y
    p.Visible = false
    local pad = Instance.new("UIPadding", p)
    pad.PaddingTop = UDim.new(0, 10)
    pad.PaddingBottom = UDim.new(0, 10)
    pad.PaddingLeft = UDim.new(0, 14)
    pad.PaddingRight = UDim.new(0, 14)
    local l = Instance.new("UIListLayout", p)
    l.Padding = UDim.new(0, 7)
    l.SortOrder = Enum.SortOrder.LayoutOrder
    return p
end

local function selectTab(name, instant)
    for n, p in pairs(pages) do
        if n == name then
            if not p.Visible and not instant then
                p.Position = UDim2.new(0, 0, 0, 46)
                tw(p, 0.3, {Position = UDim2.new(0, 0, 0, 34)}, Enum.EasingStyle.Quint)
            end
            p.Visible = true
        else
            p.Visible = false
        end
    end
    for n, b in pairs(tabBtns) do
        local col = (n == name) and WHITE or GRAY
        if instant then b.TextColor3 = col else tw(b, 0.2, {TextColor3 = col}) end
    end
    local target = UDim2.new((tabIdx[name] - 1) / TAB_COUNT, 8, 1, -3)
    if instant then underline.Position = target else tw(underline, 0.3, {Position = target}, Enum.EasingStyle.Quint) end
end

local function addTab(name, idx)
    pages[name] = newPage()
    tabIdx[name] = idx
    local b = Instance.new("TextButton", tabs)
    b.Size = UDim2.new(1 / TAB_COUNT, 0, 1, 0)
    b.Position = UDim2.new((idx - 1) / TAB_COUNT, 0, 0, 0)
    b.BackgroundTransparency = 1
    b.Text = name
    b.TextSize = 12
    b.Font = Enum.Font.GothamMedium
    b.TextColor3 = GRAY
    tabBtns[name] = b
    b.MouseButton1Click:Connect(function() selectTab(name) end)
end
addTab("Combat", 1)
addTab("Rage", 2)
addTab("Farm", 3)
addTab("Settings", 4)

local function section(parent, text, order)
    local f = Instance.new("Frame", parent)
    f.Size = UDim2.new(1, 0, 0, 16)
    f.BackgroundTransparency = 1
    f.LayoutOrder = order or 0
    local p = Instance.new("Frame", f)
    p.Size = UDim2.new(0, 3, 0, 11)
    p.Position = UDim2.new(0, 0, 0.5, -5)
    p.BackgroundColor3 = PURE
    p.BorderSizePixel = 0
    corner(p, 2)
    grad(p, 90, RED_HI, RED_LO)
    label(f, text, 11, RED, UDim2.new(0, 10, 0, 0), UDim2.new(1, -10, 1, 0))
    return f
end

-- общий стиль карточки-строки
local function styleRow(row)
    row.BackgroundColor3 = PURE
    corner(row, RR)
    grad(row, 0, Color3.fromRGB(27, 27, 32), Color3.fromRGB(17, 15, 18))
    return stroke(row, LINE)
end

-- ================= БИНДЫ (три точки возле функции) =================
local binds = {}
local listening = nil
local popName = nil

local function keyName(b) return b.key and b.key.Name or "None" end

-- ловушка: нажатие мимо окна бинда закрывает его
local popCatcher = Instance.new("TextButton", gui)
popCatcher.Size = UDim2.new(1, 0, 1, 0)
popCatcher.BackgroundTransparency = 1
popCatcher.Text = ""
popCatcher.AutoButtonColor = false
popCatcher.ZIndex = 50
popCatcher.Visible = false

local popup = Instance.new("Frame", gui)
popup.Size = UDim2.new(0, 230, 0, 130)
popup.BackgroundColor3 = PURE
popup.BorderSizePixel = 0
popup.ZIndex = 51
popup.Active = true -- чтобы нажатия внутри окна не доходили до ловушки и не закрывали его
popup.Visible = false
corner(popup, R)
grad(popup, 90, Color3.fromRGB(28, 9, 13), Color3.fromRGB(12, 12, 15))
gstroke(popup, 1.5, 1.2)
local popScale = Instance.new("UIScale", popup)
local popTitle = label(popup, "", 12, RED, UDim2.new(0, 18, 0, 10), UDim2.new(1, -36, 0, 16))

-- строка 1: кнопка-квадрат на экране
local rowA = Instance.new("Frame", popup)
rowA.Position = UDim2.new(0, 10, 0, 34)
rowA.Size = UDim2.new(1, -20, 0, 38)
styleRow(rowA)
label(rowA, "Кнопка на экране", 13, WHITE, UDim2.new(0, 16, 0, 0), UDim2.new(1, -70, 1, 0))
local pSw = Instance.new("Frame", rowA)
pSw.Size = UDim2.new(0, 38, 0, 20)
pSw.Position = UDim2.new(1, -52, 0.5, -10)
pSw.BackgroundColor3 = OFFC
corner(pSw, 10)
local pKnob = Instance.new("Frame", pSw)
pKnob.Size = UDim2.new(0, 14, 0, 14)
pKnob.Position = UDim2.new(0, 3, 0, 3)
pKnob.BackgroundColor3 = GRAY
corner(pKnob, 7)
local pHit = Instance.new("TextButton", rowA)
pHit.Size = UDim2.new(1, 0, 1, 0)
pHit.BackgroundTransparency = 1
pHit.Text = ""

-- строка 2: клавиша (для ПК)
local rowB = Instance.new("Frame", popup)
rowB.Position = UDim2.new(0, 10, 0, 80)
rowB.Size = UDim2.new(1, -20, 0, 38)
styleRow(rowB)
label(rowB, "Клавиша", 13, WHITE, UDim2.new(0, 16, 0, 0), UDim2.new(0.3, 0, 1, 0))
local keyBtn = Instance.new("TextButton", rowB)
keyBtn.Size = UDim2.new(0.55, 0, 0, 26)
keyBtn.Position = UDim2.new(0.45, -10, 0.5, -13)
keyBtn.BackgroundColor3 = Color3.fromRGB(34, 20, 24)
keyBtn.TextColor3 = WHITE
keyBtn.TextSize = 11
keyBtn.Font = Enum.Font.GothamMedium
keyBtn.AutoButtonColor = false
keyBtn.Text = "None"
pill(keyBtn)
stroke(keyBtn, LINE_ON)

local function refreshDots(b)
    if not b.dots then return end
    local active = b.shown or b.key ~= nil
    for _, d in ipairs(b.dots) do
        tw(d, 0.2, {BackgroundColor3 = active and RED or GRAY})
    end
end

local function refreshPop()
    local b = binds[popName]
    if not b then return end
    local on = b.shown
    tw(pSw, 0.18, {BackgroundColor3 = on and RED or OFFC})
    tw(pKnob, 0.22, {
        Position = on and UDim2.new(1, -17, 0, 3) or UDim2.new(0, 3, 0, 3),
        BackgroundColor3 = on and WHITE or GRAY
    }, Enum.EasingStyle.Back)
    keyBtn.Text = (listening == popName) and "нажми клавишу..." or keyName(b)
    refreshDots(b)
end

local function closePop()
    listening = nil
    popup.Visible = false
    popCatcher.Visible = false
    local b = binds[popName]
    if b then refreshDots(b) end
end

local function openBind(name, anchor)
    local b = binds[name]
    if not b then return end
    popName = name
    popTitle.Text = 'BIND  <font color="rgb(242,242,242)">' .. name .. '</font>'

    -- при первом нажатии на бинд квадрат сразу появляется на экране
    if not b.autoShown then
        b.autoShown = true
        if not b.shown then
            b.shown = true
            b.sq.Visible = true
            b.sq.Size = UDim2.new(0, 10, 0, 10)
            tw(b.sq, 0.3, {Size = UDim2.new(0, 46, 0, 46)}, Enum.EasingStyle.Back)
            notify("Bind", "кнопка добавлена на экран")
        end
    end
    refreshPop()

    local ap, as = anchor.AbsolutePosition, anchor.AbsoluteSize
    local screen = gui.AbsoluteSize
    local x = math.clamp(ap.X + as.X / 2 - 115, 8, math.max(8, screen.X - 238))
    local y = ap.Y + as.Y + 6
    if y + 130 > screen.Y - 8 then y = math.max(8, ap.Y - 136) end
    popup.Position = UDim2.fromOffset(x, y)
    popCatcher.Visible = true
    popup.Visible = true
    popScale.Scale = 0.85
    tw(popScale, 0.28, {Scale = 1}, Enum.EasingStyle.Back)
end

popCatcher.MouseButton1Click:Connect(closePop)
pHit.MouseButton1Click:Connect(function()
    local b = binds[popName]
    if not b then return end
    b.shown = not b.shown
    b.sq.Visible = b.shown
    refreshPop()
end)
keyBtn.MouseButton1Click:Connect(function()
    if not binds[popName] then return end
    listening = popName
    refreshPop()
end)

-- бинд на клавишу (для ПК)
table.insert(conns, UIS.InputBegan:Connect(function(i, gp)
    if i.UserInputType ~= Enum.UserInputType.Keyboard then return end
    if listening then
        local b = binds[listening]
        if b then
            if i.KeyCode == Enum.KeyCode.Escape or i.KeyCode == Enum.KeyCode.Backspace then
                b.key = nil
            else
                b.key = i.KeyCode
            end
        end
        listening = nil
        if popup.Visible then refreshPop() end
        return
    end
    if gp then return end
    for _, b in pairs(binds) do
        if b.key and b.key == i.KeyCode then
            b.feat.Set(not b.feat.Get())
        end
    end
end))

-- квадратик на экране для функции (нажатие включает/выключает, можно перетаскивать)
local function attachBind(name, feat, info)
    local short, y, x = info[1], info[2], info[3] or 45
    local sq = Instance.new("TextButton", gui)
    sq.AnchorPoint = Vector2.new(0.5, 0.5)
    sq.Size = UDim2.new(0, 46, 0, 46)
    sq.Position = UDim2.new(0, x, y, 0)
    sq.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    sq.Text = short
    sq.TextColor3 = WHITE
    sq.TextSize = 15
    sq.Font = Enum.Font.GothamBold
    sq.AutoButtonColor = false
    sq.ZIndex = 20
    sq.Visible = false
    corner(sq, 12) -- квадрат со скруглёнными углами
    gstroke(sq, 1.5, 0.8)
    table.insert(feat.listeners, function(v)
        tw(sq, 0.2, {BackgroundColor3 = v and RED or Color3.fromRGB(0, 0, 0)})
    end)
    makeDraggable(sq, sq, function() feat.Set(not feat.Get()) end)
    binds[name] = {sq = sq, feat = feat, key = nil, shown = false}
    return binds[name]
end

-- opts: {notify = "Имя", default = true/false, bind = {"AD", y, x}}
local function addToggle(parent, text, cb, order, opts)
    opts = opts or {}
    local row = Instance.new("Frame", parent)
    row.Size = UDim2.new(1, 0, 0, 42)
    row.LayoutOrder = order or 1
    local st = styleRow(row)

    local accent = Instance.new("Frame", row)
    accent.AnchorPoint = Vector2.new(0, 0.5)
    accent.Position = UDim2.new(0, 8, 0.5, 0)
    accent.Size = UDim2.new(0, 3, 0, 0)
    accent.BackgroundColor3 = RED
    accent.BorderSizePixel = 0
    corner(accent, 2)

    local lw = opts.bind and -112 or -70
    local txt = label(row, text, 14, Color3.fromRGB(190, 190, 196), UDim2.new(0, 20, 0, 0), UDim2.new(1, lw, 1, 0))

    local sw = Instance.new("Frame", row)
    sw.Size = UDim2.new(0, 42, 0, 22)
    sw.Position = UDim2.new(1, -54, 0.5, -11)
    sw.BackgroundColor3 = OFFC
    corner(sw, 11)
    grad(sw, 90, Color3.fromRGB(255, 255, 255), Color3.fromRGB(185, 185, 185))
    local sws = stroke(sw, Color3.fromRGB(58, 58, 66))
    local knob = Instance.new("Frame", sw)
    knob.Size = UDim2.new(0, 16, 0, 16)
    knob.Position = UDim2.new(0, 3, 0, 3)
    knob.BackgroundColor3 = GRAY
    corner(knob, 8)
    local hit = Instance.new("TextButton", row)
    hit.Size = UDim2.new(1, 0, 1, 0)
    hit.BackgroundTransparency = 1
    hit.Text = ""

    local on = false
    local obj = {listeners = {}}
    function obj.Get() return on end
    function obj.Set(v, silent)
        if on == v then return end
        on = v
        tw(sw, 0.2, {BackgroundColor3 = on and RED or OFFC})
        tw(sws, 0.2, {Color = on and RED_HI or Color3.fromRGB(58, 58, 66)})
        tw(knob, 0.22, {
            Position = on and UDim2.new(1, -19, 0, 3) or UDim2.new(0, 3, 0, 3),
            BackgroundColor3 = on and WHITE or GRAY
        }, Enum.EasingStyle.Back)
        tw(st, 0.2, {Color = on and LINE_ON or LINE})
        tw(accent, 0.25, {Size = on and UDim2.new(0, 3, 0, 16) or UDim2.new(0, 3, 0, 0)}, Enum.EasingStyle.Quint)
        tw(txt, 0.2, {TextColor3 = on and WHITE or Color3.fromRGB(190, 190, 196)})
        cb(on)
        for _, f in ipairs(obj.listeners) do pcall(f, on) end
        if opts.notify and not silent then notify(opts.notify, on) end
    end
    hit.MouseEnter:Connect(function() if not on then tw(st, 0.15, {Color = Color3.fromRGB(70, 28, 34)}) end end)
    hit.MouseLeave:Connect(function() if not on then tw(st, 0.15, {Color = LINE}) end end)
    hit.MouseButton1Click:Connect(function() obj.Set(not on) end)

    -- три точки: открывают меню бинда
    if opts.bind then
        local bd = attachBind(text, obj, opts.bind)
        local dh = Instance.new("TextButton", row)
        dh.Size = UDim2.new(0, 30, 0, 36)
        dh.Position = UDim2.new(1, -90, 0.5, -18)
        dh.BackgroundTransparency = 1
        dh.Text = ""
        dh.AutoButtonColor = false
        dh.ZIndex = 5
        bd.dots = {}
        for k = 0, 2 do
            local d = Instance.new("Frame", dh)
            d.Size = UDim2.new(0, 4, 0, 4)
            d.Position = UDim2.new(0.5, -2, 0, 8 + k * 8)
            d.BackgroundColor3 = GRAY
            d.BorderSizePixel = 0
            d.ZIndex = 6
            pill(d)
            table.insert(bd.dots, d)
        end
        dh.MouseButton1Click:Connect(function() openBind(text, dh) end)
    end

    if opts.default then obj.Set(true, true) end
    return obj
end

local function addButton(parent, text, cb, order)
    local row = Instance.new("Frame", parent)
    row.Size = UDim2.new(1, 0, 0, 42)
    row.LayoutOrder = order or 1
    local st = styleRow(row)
    local b = Instance.new("TextButton", row)
    b.Size = UDim2.new(1, 0, 1, 0)
    b.BackgroundTransparency = 1
    b.Text = text
    b.TextColor3 = WHITE
    b.TextSize = 12
    b.Font = Enum.Font.GothamMedium
    b.AutoButtonColor = false
    b.MouseEnter:Connect(function() tw(st, 0.15, {Color = LINE_ON}) end)
    b.MouseLeave:Connect(function() tw(st, 0.15, {Color = LINE}) end)
    b.MouseButton1Down:Connect(function() tw(row, 0.08, {Size = UDim2.new(1, -6, 0, 40)}) end)
    b.MouseButton1Up:Connect(function() tw(row, 0.15, {Size = UDim2.new(1, 0, 0, 42)}, Enum.EasingStyle.Back) end)
    b.MouseButton1Click:Connect(function() cb(b) end)
    return b
end

local function addSlider(parent, text, min, max, default, cb, order, suffix, fmt)
    suffix = suffix or ""
    fmt = fmt or function(v) return tostring(v) end
    local row = Instance.new("Frame", parent)
    row.Size = UDim2.new(1, 0, 0, 52)
    row.LayoutOrder = order or 1
    styleRow(row)
    label(row, text, 13, WHITE, UDim2.new(0, 16, 0, 6), UDim2.new(0.5, 0, 0, 16))
    local valL = label(row, '<font color="rgb(255,72,88)">' .. fmt(default) .. suffix .. '</font>', 13, WHITE, UDim2.new(0.5, -16, 0, 6), UDim2.new(0.5, 0, 0, 16), Enum.TextXAlignment.Right)
    local track = Instance.new("Frame", row)
    track.Size = UDim2.new(1, -32, 0, 5)
    track.Position = UDim2.new(0, 16, 0, 35)
    track.BackgroundColor3 = OFFC
    track.BorderSizePixel = 0
    corner(track, 3)
    local fill = Instance.new("Frame", track)
    fill.Size = UDim2.new((default - min) / (max - min), 0, 1, 0)
    fill.BackgroundColor3 = PURE
    fill.BorderSizePixel = 0
    corner(fill, 3)
    flow(grad(fill, 0, RED_LO, RED_HI, RED_LO, RED_HI), "slide", 2, 0)
    local knob = Instance.new("Frame", track)
    knob.Size = UDim2.new(0, 15, 0, 15)
    knob.AnchorPoint = Vector2.new(0.5, 0.5)
    knob.Position = UDim2.new((default - min) / (max - min), 0, 0.5, 0)
    knob.BackgroundColor3 = WHITE
    knob.BorderSizePixel = 0
    corner(knob, 8)
    stroke(knob, RED, 2)
    local hit = Instance.new("TextButton", row)
    hit.Size = UDim2.new(1, 0, 0, 30)
    hit.Position = UDim2.new(0, 0, 0, 22)
    hit.BackgroundTransparency = 1
    hit.Text = ""
    local dragging = false
    local function setFromX(x)
        local frac = math.clamp((x - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
        local val = math.floor(min + frac * (max - min) + 0.5)
        local f = (val - min) / (max - min)
        fill.Size = UDim2.new(f, 0, 1, 0)
        knob.Position = UDim2.new(f, 0, 0.5, 0)
        valL.Text = '<font color="rgb(255,72,88)">' .. fmt(val) .. suffix .. '</font>'
        cb(val)
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
        end
    end))
end

local Features = {}

-- ---------- Combat ----------
section(pages.Combat, "AIM ASSIST", 0)
Features["Anti Dodge"] = addToggle(pages.Combat, "Anti Dodge", function(v) State.AntiDodge = v end, 1, {notify = "Anti Dodge", bind = {"AD", 0.40}})
Features["Change Button"] = addToggle(pages.Combat, "Change Button", function(v)
    if v and not getconnections then
        pcall(function()
            game:GetService("StarterGui"):SetCore("SendNotification", {Title = "NeverLose", Text = "Executor не поддерживает getconnections", Duration = 5})
        end)
    end
    setChange(v)
end, 2, {notify = "Change Button", bind = {"CB", 0.50}})

-- ---------- Rage ----------
section(pages.Rage, "MOVEMENT", 0)
Features["SpeedHack"] = addToggle(pages.Rage, "SpeedHack", function(v) State.SpeedHack = v end, 1, {notify = "SpeedHack", bind = {"SH", 0.60}})
addSlider(pages.Rage, "Speed", 16, 120, State.Speed, function(v) State.Speed = v end, 2)

section(pages.Rage, "TARGET", 10)
local targetRow = Instance.new("Frame", pages.Rage)
targetRow.Size = UDim2.new(1, 0, 0, 42)
targetRow.LayoutOrder = 11
styleRow(targetRow)
label(targetRow, "Target", 14, WHITE, UDim2.new(0, 16, 0, 0), UDim2.new(0.3, 0, 1, 0))
local targetBtn = Instance.new("TextButton", targetRow)
targetBtn.Size = UDim2.new(0.6, 0, 0, 28)
targetBtn.Position = UDim2.new(0.4, -12, 0.5, -14)
targetBtn.BackgroundColor3 = Color3.fromRGB(34, 20, 24)
targetBtn.TextColor3 = WHITE
targetBtn.TextSize = 11
targetBtn.Font = Enum.Font.GothamMedium
targetBtn.TextTruncate = Enum.TextTruncate.AtEnd
targetBtn.AutoButtonColor = false
targetBtn.Text = "Auto"
pill(targetBtn)
local targetStroke = stroke(targetBtn, LINE_ON)
targetBtn.MouseEnter:Connect(function() tw(targetStroke, 0.15, {Color = RED}) end)
targetBtn.MouseLeave:Connect(function() tw(targetStroke, 0.15, {Color = LINE_ON}) end)

onTargetChanged = function()
    if not targetBtn.Parent then return end
    if selectedName then
        targetBtn.Text = selectedName
    else
        local p = nearestPlayer()
        targetBtn.Text = "Auto: " .. (p and p.Name or "-")
    end
end

targetBtn.MouseButton1Click:Connect(function()
    local names = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= lp then table.insert(names, p.Name) end
    end
    table.sort(names)
    local idx = 0
    for i, n in ipairs(names) do
        if n == selectedName then idx = i end
    end
    idx = idx + 1
    if idx > #names then selectedName = nil else selectedName = names[idx] end
    onTargetChanged()
    notify("Target", selectedName or "Auto (ближайший)")
end)

section(pages.Rage, "TELEPORT", 20)
Features["Sticky"] = addToggle(pages.Rage, "Sticky", function(v) State.Sticky = v end, 21, {notify = "Sticky", bind = {"ST", 0.70}})
Features["Rich"] = addToggle(pages.Rage, "Rich", function(v) State.Rich = v end, 23, {notify = "Rich", bind = {"RH", 0.80}})

-- ---------- Farm (макрос) ----------
section(pages.Farm, "MACRO", 0)
Features["Record"] = addToggle(pages.Farm, "Record", function(v)
    if v then
        if Features["Play Loop"].Get() then Features["Play Loop"].Set(false, true) end
        startRecording()
    else
        stopRecording()
    end
    refreshMacroInfo()
end, 2, {notify = "Record", bind = {"RC", 0.40, 100}})

Features["Play Loop"] = addToggle(pages.Farm, "Play Loop", function(v)
    if v then
        if Features["Record"].Get() then Features["Record"].Set(false, true) end
        if not startPlaying() then
            notify("Macro", "сначала запиши макрос")
            Features["Play Loop"].Set(false, true)
        end
    else
        stopPlaying()
    end
    refreshMacroInfo()
end, 3, {notify = "Play Loop", bind = {"PL", 0.50, 100}})

-- Punch Delay: шаг 0.1 c (значение слайдера 1..50 = 0.1..5 c)
addSlider(pages.Farm, "Punch Delay", 1, 50, math.floor(State.PunchDelay * 10 + 0.5), function(v)
    State.PunchDelay = v / 10
end, 5, " c", function(v) return string.format("%.1f", v / 10) end)

addButton(pages.Farm, "Clear Macro", function()
    Features["Record"].Set(false, true)
    Features["Play Loop"].Set(false, true)
    clearMacro()
    refreshMacroInfo()
    notify("Macro", "очищен")
end, 4)

-- ---------- Settings ----------
section(pages.Settings, "MENU", 0)
addToggle(pages.Settings, "Notifications", function(v) State.Notify = v end, 1, {notify = "Notifications", default = true})
addToggle(pages.Settings, "Blur Background", function(v)
    State.Blur = v
    if menuOpen then setBackdrop(true) end
end, 2, {default = true})
-- футер: скруглены только нижние углы (под радиус окна)
local foot = Instance.new("Frame", body)
foot.AnchorPoint = Vector2.new(0, 1)
foot.Position = UDim2.new(0, 0, 1, 0)
foot.Size = UDim2.new(1, 0, 0, 24)
foot.BackgroundTransparency = 1
foot.BorderSizePixel = 0
foot.ClipsDescendants = true
local footBg = Instance.new("Frame", foot)
footBg.Position = UDim2.new(0, 0, 0, -30)
footBg.Size = UDim2.new(1, 0, 0, 54)
footBg.BackgroundColor3 = DARK
footBg.BorderSizePixel = 0
corner(footBg, R)
local footLine = Instance.new("Frame", foot)
footLine.Size = UDim2.new(1, 0, 0, 1)
footLine.BackgroundColor3 = PURE
footLine.BorderSizePixel = 0
flow(grad(footLine, 0, Color3.fromRGB(30, 6, 10), RED, Color3.fromRGB(30, 6, 10)), "slide", 1.4, 1.5)
label(foot, "NeverLose v2.1", 11, Color3.fromRGB(106, 106, 114), UDim2.new(0, 38, 0, 0), UDim2.new(0.5, -38, 1, 0))
label(foot, "Owner: Seth", 11, Color3.fromRGB(106, 106, 114), UDim2.new(0.5, 0, 0, 0), UDim2.new(0.5, -38, 1, 0), Enum.TextXAlignment.Right)

selectTab("Combat", true)

-- ================= АНИМАЦИИ ОКНА =================
local function showMenu()
    menuOpen = true
    main.Visible = true
    main.GroupTransparency = 1
    mainScale.Scale = 0.88
    tw(main, 0.4, {GroupTransparency = 0}, Enum.EasingStyle.Quint)
    tw(mainScale, 0.5, {Scale = 1}, Enum.EasingStyle.Back)
    setBackdrop(true)
end

local function hideMenu(done)
    menuOpen = false
    setBackdrop(false)
    closePop()
    local t = tw(main, 0.22, {GroupTransparency = 1}, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
    tw(mainScale, 0.22, {Scale = 0.92}, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
    t.Completed:Connect(function()
        if not menuOpen then main.Visible = false end
        if done then done() end
    end)
end

-- ================= СВЁРНУТЫЙ ВИД (NL) =================
local mini = Instance.new("TextButton", gui)
mini.AnchorPoint = Vector2.new(0.5, 0.5)
mini.Size = UDim2.new(0, 46, 0, 46)
mini.Position = UDim2.new(0, 45, 0.25, 0)
mini.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
mini.Text = 'N<font color="rgb(225,29,46)">L</font>'
mini.RichText = true
mini.TextColor3 = WHITE
mini.TextSize = 18
mini.Font = Enum.Font.GothamBold
mini.AutoButtonColor = false
mini.Visible = false
pill(mini)
gstroke(mini, 2, 1.2)
local miniScale = Instance.new("UIScale", mini)
miniScale.Scale = 0.1

btnMin.MouseButton1Click:Connect(function()
    hideMenu(function()
        if menuOpen then return end
        mini.Visible = true
        miniScale.Scale = 0.1
        tw(miniScale, 0.35, {Scale = 1}, Enum.EasingStyle.Back)
    end)
end)

makeDraggable(mini, mini, function()
    mini.Visible = false
    showMenu()
end)

btnClose.MouseButton1Click:Connect(shutdown)
makeDraggable(header, main, nil)

-- ================= ЗАСТАВКА =================
local splash = Instance.new("TextLabel", gui)
splash.AnchorPoint = Vector2.new(0.5, 0.5)
splash.Position = UDim2.new(0.5, 0, 0.5, -12)
splash.Size = UDim2.new(0, 320, 0, 50)
splash.BackgroundTransparency = 1
splash.RichText = true
splash.Text = 'Never<font color="rgb(225,29,46)">Lose</font>'
splash.TextColor3 = WHITE
splash.TextSize = 38
splash.Font = Enum.Font.GothamBold
splash.TextTransparency = 1

local sline = Instance.new("Frame", gui)
sline.AnchorPoint = Vector2.new(0.5, 0.5)
sline.Position = UDim2.new(0.5, 0, 0.5, 22)
sline.Size = UDim2.new(0, 0, 0, 2)
sline.BackgroundColor3 = PURE
sline.BorderSizePixel = 0
corner(sline, 1)
flow(grad(sline, 0, RED_LO, RED_HI, RED_LO), "slide", 4, 0)

local sowner = Instance.new("TextLabel", gui)
sowner.AnchorPoint = Vector2.new(0.5, 0.5)
sowner.Position = UDim2.new(0.5, 0, 0.5, 40)
sowner.Size = UDim2.new(0, 200, 0, 18)
sowner.BackgroundTransparency = 1
sowner.RichText = true
sowner.Text = 'Owner: <font color="rgb(225,29,46)">Seth</font>'
sowner.TextColor3 = GRAY
sowner.TextSize = 13
sowner.Font = Enum.Font.GothamMedium
sowner.TextTransparency = 1

task.spawn(function()
    playStartup() -- звук запуска
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
    if not alive then return end
    showMenu()
    notify("NeverLose", "загружен")
end)
