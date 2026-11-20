--[[
    NOCTIS · AUTO BOSS  v3
    Ciclo infinito, sem você apertar nada:
      Guardião -> Conversar -> "Mostre-me as Salas de Boss" -> espera X s (amigo apertar PRONTO)
      -> INICIAR -> ataca o boss sem parar -> boss morre -> volta ao lobby -> repete.

    Só duas teclas (editáveis na aba Config):
      - mostrar/esconder o menu
      - iniciar / pausar / retomar o script

    Requisitos: VirtualInputManager. Opcionais (melhoram a confiabilidade): getconnections, firesignal,
    fireproximityprompt, gethui, writefile/readfile.
]]

if not game:IsLoaded() then game.Loaded:Wait() end

local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local UIS          = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local GuiService   = game:GetService("GuiService")
local HttpService  = game:GetService("HttpService")
local CoreGui      = game:GetService("CoreGui")

local VIM
pcall(function() VIM = game:GetService("VirtualInputManager") end)

local LP = Players.LocalPlayer
local ENV = (getgenv and getgenv()) or _G
if ENV.NOCTIS_UNLOAD then pcall(ENV.NOCTIS_UNLOAD) end

local conns = {}
local function track(c) conns[#conns + 1] = c return c end

local function dbg(...)
    local t = {}
    for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
    print("[Noctis] " .. table.concat(t, " "))
end

------------------------------------------------------------------------
-- Configuração salva
------------------------------------------------------------------------
local FILE = "noctis_autoboss.json"
local Saved = {}
pcall(function()
    if isfile and readfile and isfile(FILE) then
        local d = HttpService:JSONDecode(readfile(FILE))
        if type(d) == "table" then Saved = d end
    end
end)

local MODES = { "Melee", "Sword", "Gun", "Fruit" }
local KEYS  = { "Z", "X", "C", "V", "F" }
local MODE_DELAY = { Melee = 0.10, Sword = 0.12, Gun = 0.14, Fruit = 0.16 }
local RESERVED = { Z = true, X = true, C = true, V = true, F = true, E = true }

local function keyOr(v, def)
    if type(v) == "string" and Enum.KeyCode[v] then return v end
    return def
end

-- Guardião: posição memorizada (só gravada depois que a conversa com ele abrir a sala de verdade)
local Guard = { pos = nil, part = nil, model = nil, confirmed = false }
if type(Saved.guardPos) == "table" and tonumber(Saved.guardPos.x) and tonumber(Saved.guardPos.y)
    and tonumber(Saved.guardPos.z) then
    Guard.pos = Vector3.new(Saved.guardPos.x, Saved.guardPos.y, Saved.guardPos.z)
    Guard.confirmed = true
end

local S = {
    running = false, paused = false, fighting = false, boss = nil, status = "Parado",
    awaitStart = nil,
    mode      = Saved.mode or "Melee",
    tools     = type(Saved.tools) == "table" and Saved.tools or {},
    skills    = type(Saved.skills) == "table" and Saved.skills or {},
    distance  = tonumber(Saved.distance) or 4,
    height    = tonumber(Saved.height) or 0,
    flip      = Saved.flip == true,
    m1        = Saved.m1 ~= false,
    aim       = Saved.aim ~= false,
    bossKey   = type(Saved.bossKey) == "string" and Saved.bossKey or "noctis",
    startWait = tonumber(Saved.startWait) or 4,
    useVim    = Saved.useVim == true,   -- mouse/teclado virtual (reserva), desligado por padrão
    startedAt = 0,
    keys = {
        menu   = keyOr(Saved.keyMenu,   "RightShift"),
        toggle = keyOr(Saved.keyToggle, "End"),
    },
}

local function skillOf(mode, key)
    if type(S.skills[mode]) ~= "table" then S.skills[mode] = {} end
    local s = S.skills[mode][key]
    if type(s) ~= "table" then
        s = { on = false, cd = 3 }
        S.skills[mode][key] = s
    end
    s.cd = tonumber(s.cd) or 3
    s.on = s.on == true
    return s
end

local function save()
    pcall(function()
        if writefile then
            writefile(FILE, HttpService:JSONEncode({
                mode = S.mode, tools = S.tools, skills = S.skills,
                distance = S.distance, height = S.height, flip = S.flip, m1 = S.m1,
                aim = S.aim, bossKey = S.bossKey, startWait = S.startWait, useVim = S.useVim,
                guardPos = (Guard.confirmed and Guard.pos) and { x = Guard.pos.X, y = Guard.pos.Y, z = Guard.pos.Z } or nil,
                keyMenu = S.keys.menu, keyToggle = S.keys.toggle,
            }))
        end
    end)
end

------------------------------------------------------------------------
-- Tema / status
------------------------------------------------------------------------
local C = {
    bg     = Color3.fromRGB(13, 14, 20),
    panel  = Color3.fromRGB(20, 22, 31),
    card   = Color3.fromRGB(27, 30, 42),
    stroke = Color3.fromRGB(50, 54, 72),
    text   = Color3.fromRGB(235, 237, 245),
    sub    = Color3.fromRGB(135, 141, 163),
    red    = Color3.fromRGB(236, 69, 87),
    amber  = Color3.fromRGB(255, 170, 74),
    green  = Color3.fromRGB(70, 214, 140),
    gray   = Color3.fromRGB(95, 100, 120),
}

local UI = {}
local updateHint, refreshRun

local function setStatus(msg, kind)
    if S.status ~= msg then dbg(msg) end
    S.status = msg
    if UI.Status then UI.Status.Text = msg end
    if UI.Dot then
        UI.Dot.BackgroundColor3 = (kind == "err" and C.red) or (kind == "ok" and C.green)
            or (kind == "run" and C.amber) or C.gray
    end
end

------------------------------------------------------------------------
-- Utilidades
------------------------------------------------------------------------
local function getHRP()
    local ch = LP.Character
    return ch and ch:FindFirstChild("HumanoidRootPart")
end

local function has(s, kw) return string.find(s, kw, 1, true) ~= nil end
local function typing() return UIS:GetFocusedTextBox() ~= nil end

-- espera com timeout; o relógio congela enquanto estiver pausado
local function waitUntil(fn, timeout, step)
    local t0 = os.clock()
    step = step or 0.25
    while S.running and os.clock() - t0 < timeout do
        if S.paused then
            local p0 = os.clock()
            while S.running and S.paused do task.wait(0.15) end
            t0 = t0 + (os.clock() - p0)
        else
            local v = fn()
            if v then return v end
            task.wait(step)
        end
    end
    return nil
end

-- dorme respeitando pausa
local function sleepP(sec)
    local t = 0
    while S.running and t < sec do
        if S.paused then
            task.wait(0.15)
        else
            task.wait(0.1)
            t = t + 0.1
        end
    end
end

------------------------------------------------------------------------
-- Leitura da UI do jogo
------------------------------------------------------------------------
local function isShown(obj)
    local cur = obj
    while cur and cur ~= game do
        if cur:IsA("GuiObject") and not cur.Visible then return false end
        if cur:IsA("LayerCollector") then return cur.Enabled end
        cur = cur.Parent
    end
    return true
end

local function normText(o)
    local s = string.lower(o.Text or "")
    s = string.gsub(s, "<[^>]+>", "")
    s = string.match(s, "^%s*(.-)%s*$")
    return s
end

local function guiTexts()
    local out = {}
    local pg = LP:FindFirstChildOfClass("PlayerGui")
    if not pg then return out end
    for _, o in ipairs(pg:GetDescendants()) do
        if (o:IsA("TextLabel") or o:IsA("TextButton")) and o.Text ~= "" then
            if not (UI.Gui and UI.Gui:IsAncestorOf(o)) and isShown(o) then
                out[#out + 1] = { o = o, t = normText(o) }
            end
        end
    end
    return out
end

local function findExact(L, str)
    for _, r in ipairs(L) do
        if r.t == str then return r.o end
    end
    return nil
end

local function findContains(L, str)
    for _, r in ipairs(L) do
        if has(r.t, str) then return r.o end
    end
    return nil
end

local function nearestButton(o)
    local cur = o
    for _ = 1, 6 do
        if not cur or cur:IsA("LayerCollector") then return nil end
        if cur:IsA("GuiButton") then return cur end
        cur = cur.Parent
    end
    return nil
end

local function dialogOption(L) return findContains(L, "salas de boss") end

local function roomUiOpen(L)
    return findExact(L, "convidar") ~= nil or findExact(L, "sala de boss") ~= nil
end

local function startButton(L)
    local b
    for _, r in ipairs(L) do
        if r.t == "iniciar" and (not b or r.o.AbsolutePosition.Y > b.AbsolutePosition.Y) then b = r.o end
    end
    return b
end

local function defeatVisible()
    for _, r in ipairs(guiTexts()) do
        if has(r.t, "boss defeated") or has(r.t, "returning in") or has(r.t, "boss derrotado") then
            return true
        end
    end
    return false
end

------------------------------------------------------------------------
-- Entrada SEM hardware: tudo é entregue direto aos scripts do jogo.
-- Mouse/teclado virtual (VIM) só existe como reserva e fica DESLIGADO por padrão.
------------------------------------------------------------------------
local function fakeInput(kind, keyCode, state, x, y)
    local pos = UIS:GetMouseLocation()
    return {
        UserInputType = kind, UserInputState = state, KeyCode = keyCode or Enum.KeyCode.Unknown,
        Position = Vector3.new(x or pos.X, y or pos.Y, 0), Delta = Vector3.zero,
        IsModifierKeyDown = function() return false end,
    }
end

local function connsOf(signal)
    if not getconnections then return {} end
    local ok, list = pcall(getconnections, signal)
    return (ok and type(list) == "table") and list or {}
end

local function fireConns(signal, ...)
    local args = table.pack(...)
    local n = 0
    for _, c in ipairs(connsOf(signal)) do
        if pcall(function() c:Fire(table.unpack(args, 1, args.n)) end) then n = n + 1 end
    end
    return n
end

-- conexões do CoreScript/PlayerModule ficam de fora
local function isCoreConn(c)
    local ok, res = pcall(function()
        local env = getfenv(c.Function)
        local sc = type(env) == "table" and rawget(env, "script") or nil
        if typeof(sc) ~= "Instance" then return false end
        if sc.Name == "PlayerModule" or sc:FindFirstAncestor("PlayerModule") then return true end
        return sc:IsDescendantOf(CoreGui)
    end)
    return ok and res or false
end

local connCache = { t = 0, down = {}, up = {} }
local function gameInputConns()
    if os.clock() - connCache.t > 2 then
        connCache.t = os.clock()
        connCache.down, connCache.up = {}, {}
        for _, c in ipairs(connsOf(UIS.InputBegan)) do
            if not isCoreConn(c) then connCache.down[#connCache.down + 1] = c end
        end
        for _, c in ipairs(connsOf(UIS.InputEnded)) do
            if not isCoreConn(c) then connCache.up[#connCache.up + 1] = c end
        end
    end
    return connCache.down, connCache.up
end

-- entrega uma tecla/botão do mouse aos handlers de UserInputService do jogo (sem tocar no hardware)
local function dispatchGlobal(kind, keyCode, hold)
    if typing() then return false end
    local downList, upList = gameInputConns()
    if #downList == 0 then return false end
    local down = fakeInput(kind, keyCode, Enum.UserInputState.Begin)
    local n = 0
    for _, c in ipairs(downList) do
        if pcall(function() c:Fire(down, false) end) then n = n + 1 end
    end
    task.wait(hold or 0.04)
    local up = fakeInput(kind, keyCode, Enum.UserInputState.End)
    for _, c in ipairs(upList) do pcall(function() c:Fire(up, false) end) end
    return n > 0
end

-- reserva: VirtualInputManager (mexe no cursor / no teclado de verdade; só se ligar na Config)
local function vimClickAt(x, y)
    if not (S.useVim and VIM) then return false end
    if typing() then task.wait(0.3) return false end
    local prev = UIS:GetMouseLocation()
    pcall(function() VIM:SendMouseMoveEvent(x, y, game) end)
    task.wait(0.08)
    local ok = pcall(function()
        VIM:SendMouseButtonEvent(x, y, 0, true, game, 1)
        task.wait(0.06)
        VIM:SendMouseButtonEvent(x, y, 0, false, game, 1)
    end)
    task.wait(0.04)
    pcall(function() VIM:SendMouseMoveEvent(prev.X, prev.Y, game) end)
    return ok
end

local function vimClickObj(obj, flipInset)
    local p, s = obj.AbsolutePosition, obj.AbsoluteSize
    local x = p.X + s.X * 0.5
    local y = p.Y + s.Y * 0.5
    local sg = obj:FindFirstAncestorWhichIsA("ScreenGui")
    local add = not (sg and sg.IgnoreGuiInset)
    if flipInset then add = not add end
    if add then y = y + GuiService:GetGuiInset().Y end
    return vimClickAt(x, y)
end

local function selectEnter(btn)
    if not (S.useVim and VIM) or typing() then return false end
    local ok = pcall(function()
        GuiService.SelectedObject = btn
        task.wait(0.12)
        VIM:SendKeyEvent(true, Enum.KeyCode.Return, false, game)
        task.wait(0.05)
        VIM:SendKeyEvent(false, Enum.KeyCode.Return, false, game)
        task.wait(0.1)
        GuiService.SelectedObject = nil
    end)
    return ok
end

-- dispara as conexões do próprio botão
local function fireConn(btn)
    local n = 0
    for _, sig in ipairs({ "MouseButton1Down", "MouseButton1Up", "MouseButton1Click", "Activated" }) do
        local ok, signal = pcall(function() return btn[sig] end)
        if ok and signal then
            if sig == "Activated" then
                n = n + fireConns(signal, fakeInput(Enum.UserInputType.MouseButton1, nil, Enum.UserInputState.End), 1)
            else
                n = n + fireConns(signal)
            end
        end
    end
    return n > 0
end

-- firesignal(botao.MouseButton1Click / Activated)
local function fireGuiSignals(btn)
    if not firesignal then return false end
    local any = false
    for _, sig in ipairs({ "MouseButton1Down", "MouseButton1Up", "MouseButton1Click" }) do
        if pcall(function() firesignal(btn[sig]) end) then any = true end
    end
    if pcall(function()
        firesignal(btn.Activated, fakeInput(Enum.UserInputType.MouseButton1, nil, Enum.UserInputState.End), 1)
    end) then any = true end
    return any
end

-- UIs customizadas: entrega "clique" via InputBegan/InputEnded no objeto e nos pais próximos
local function fireInputChain(obj)
    local fired = 0
    local cur = obj
    for _ = 1, 6 do
        if not cur or cur:IsA("LayerCollector") then break end
        if cur:IsA("GuiObject") then
            local p, s = cur.AbsolutePosition, cur.AbsoluteSize
            local x, y = p.X + s.X / 2, p.Y + s.Y / 2
            local down = fakeInput(Enum.UserInputType.MouseButton1, nil, Enum.UserInputState.Begin, x, y)
            local up = fakeInput(Enum.UserInputType.MouseButton1, nil, Enum.UserInputState.End, x, y)
            fired = fired + fireConns(cur.InputBegan, down, false)
            task.wait(0.03)
            fired = fired + fireConns(cur.InputEnded, up, false)
        end
        cur = cur.Parent
    end
    return fired > 0
end

-- um método por vez; para quando doneFn() ficar verdadeiro
local function tryClick(obj, doneFn)
    local btn = nearestButton(obj)
    for _ = 1, 2 do
        local methods = {}
        if btn then
            methods[#methods + 1] = function() return fireConn(btn) end
            methods[#methods + 1] = function() return fireGuiSignals(btn) end
        end
        methods[#methods + 1] = function() return fireInputChain(obj) end
        if S.useVim and VIM then
            if btn then methods[#methods + 1] = function() return selectEnter(btn) end end
            methods[#methods + 1] = function() return vimClickObj(obj, false) end
            methods[#methods + 1] = function() return vimClickObj(obj, true) end
        end
        for _, m in ipairs(methods) do
            if not S.running then return false end
            if doneFn() then return true end
            pcall(m)
            if waitUntil(doneFn, 1.5, 0.15) then return true end
        end
    end
    return doneFn() and true or false
end

-- tecla do jogo (skills etc.): trava de digitação + entrega direta; VIM só se ligado
local function pressKey(name, hold)
    if typing() then return false end
    local kc = Enum.KeyCode[name]
    if not kc then return false end
    local ok = dispatchGlobal(Enum.UserInputType.Keyboard, kc, hold or 0.05)
    if S.useVim and VIM and not typing() then
        pcall(function()
            VIM:SendKeyEvent(true, kc, false, game)
            task.wait(hold or 0.05)
            VIM:SendKeyEvent(false, kc, false, game)
        end)
        ok = true
    end
    return ok
end

------------------------------------------------------------------------
-- NPC Guardião
------------------------------------------------------------------------

local function partOf(inst)
    if not inst then return nil end
    if inst:IsA("BasePart") then return inst end
    if inst:IsA("Attachment") then
        return inst.Parent and inst.Parent:IsA("BasePart") and inst.Parent or nil
    end
    if inst:IsA("Model") then
        return inst:FindFirstChild("HumanoidRootPart") or inst.PrimaryPart
            or inst:FindFirstChildWhichIsA("BasePart", true)
    end
    if inst.Parent and inst.Parent ~= game then return partOf(inst.Parent) end
    return nil
end

local function isGuardText(s)
    s = string.lower(s or "")
    return has(s, "sala de noctis") or (has(s, "guardi") and has(s, "noctis"))
        or has(s, "guardião") or has(s, "guardiao")
end

local function acceptGuard(part)
    if not part then return nil end
    Guard.part = part
    Guard.pos = part.Position
    -- só confia no modelo se for mesmo um NPC (tem Humanoid), nunca um modelo-mapa grande
    local m = part:FindFirstAncestorOfClass("Model")
    Guard.model = (m and m:FindFirstChildOfClass("Humanoid")) and m or nil
    return part
end

local function findGuardian()
    if Guard.part and Guard.part:IsDescendantOf(workspace) then
        Guard.pos = Guard.part.Position
        return Guard.part
    end
    Guard.part = nil
    local hrp0 = getHRP()
    local nearTalk, nearD
    for _, o in ipairs(workspace:GetDescendants()) do
        if o:IsA("ProximityPrompt") then
            local pp = partOf(o.Parent)
            if pp then
                if isGuardText(o.ObjectText) or isGuardText(o.Parent and o.Parent.Name)
                    or isGuardText(o.Parent and o.Parent.Parent and o.Parent.Parent.Name) then
                    return acceptGuard(pp)
                end
                if hrp0 and has(string.lower(o.ActionText or ""), "convers") then
                    local d = (pp.Position - hrp0.Position).Magnitude
                    if d < 60 and (not nearD or d < nearD) then nearTalk, nearD = pp, d end
                end
            end
        elseif o:IsA("TextLabel") and isGuardText(o.Text) then
            local bb = o:FindFirstAncestorWhichIsA("BillboardGui")
            local part = partOf(bb and (bb.Adornee or bb.Parent) or o.Parent)
            if part then return acceptGuard(part) end
        elseif o:IsA("Humanoid") and isGuardText(o.DisplayName) then
            local part = partOf(o.Parent)
            if part then return acceptGuard(part) end
        elseif o:IsA("Model") and isGuardText(o.Name) then
            local part = partOf(o)
            if part then return acceptGuard(part) end
        end
    end
    -- nome flutuante desenhado na PlayerGui (BillboardGui com Adornee)
    local pg = LP:FindFirstChildOfClass("PlayerGui")
    if pg then
        for _, o in ipairs(pg:GetDescendants()) do
            if o:IsA("TextLabel") and isGuardText(o.Text) and not (UI.Gui and UI.Gui:IsAncestorOf(o)) then
                local bb = o:FindFirstAncestorWhichIsA("BillboardGui")
                if bb and bb.Adornee then
                    local part = partOf(bb.Adornee)
                    if part and part:IsDescendantOf(workspace) then return acceptGuard(part) end
                end
            end
        end
    end
    -- último recurso: o prompt "Conversar" mais próximo de você
    if nearTalk then return acceptGuard(nearTalk) end
    return nil
end

local lastGuardScan = 0
local function guardianThrottled()
    if Guard.part and Guard.part:IsDescendantOf(workspace) then return findGuardian() end
    if os.clock() - lastGuardScan < 2 then return nil end
    lastGuardScan = os.clock()
    return findGuardian()
end

-- perto do Guardião = estamos no lobby
local function inLobby()
    local hrp = getHRP()
    return Guard.pos ~= nil and hrp ~= nil and (hrp.Position - Guard.pos).Magnitude < 120
end

-- prompt "Conversar" do Guardião (prefere o que está no modelo dele)
local function promptFor(part)
    local scope = part:FindFirstAncestorOfClass("Model")
    local best, bs
    for _, o in ipairs(workspace:GetDescendants()) do
        if o:IsA("ProximityPrompt") then
            local pp = partOf(o.Parent)
            if pp then
                local d = (pp.Position - part.Position).Magnitude
                if d < 40 then
                    local score = d
                    if scope and o:IsDescendantOf(scope) then score = score - 20 end
                    if has(string.lower(o.ActionText or ""), "convers") then score = score - 8 end
                    if not bs or score < bs then best, bs = o, score end
                end
            end
        end
    end
    return best
end

local function teleportNear(part)
    local hrp = getHRP()
    if not (hrp and part) then return end
    local base = part.Position
    local dir = (hrp.Position - base) * Vector3.new(1, 0, 1)
    if dir.Magnitude < 1 then dir = part.CFrame.LookVector * Vector3.new(1, 0, 1) end
    if dir.Magnitude < 0.01 then dir = Vector3.new(0, 0, 1) end
    local pos = base + dir.Unit * 4 + Vector3.new(0, 1, 0)
    hrp.CFrame = CFrame.lookAt(pos, Vector3.new(base.X, pos.Y, base.Z))
    hrp.AssemblyLinearVelocity = Vector3.zero
end

local function approach(part)
    local hrp = getHRP()
    if hrp and (hrp.Position - part.Position).Magnitude > 7 then
        teleportNear(part)
        task.wait(0.4)
    end
end

-- formas de "Conversar", em ordem: fireproximityprompt direto, Triggered, hold programático,
-- botão "Conversar" da tela (sem mouse) e, só se ligado na Config, a tecla E virtual
local function talkWays(prompt)
    local ways = {}
    if prompt and fireproximityprompt then ways[#ways + 1] = "fire" end
    if prompt then ways[#ways + 1] = "trigger" end
    if prompt then ways[#ways + 1] = "hold" end
    ways[#ways + 1] = "button"
    if S.useVim and VIM then ways[#ways + 1] = "key" end
    return ways
end

local function talkMethod(way, prompt)
    if prompt then
        pcall(function()
            prompt.Enabled = true
            prompt.RequiresLineOfSight = false
            prompt.HoldDuration = 0
            if prompt.MaxActivationDistance < 20 then prompt.MaxActivationDistance = 20 end
        end)
    end
    if way == "fire" then
        pcall(function() fireproximityprompt(prompt) end)
    elseif way == "trigger" then
        fireConns(prompt.Triggered, LP)
    elseif way == "hold" then
        pcall(function()
            prompt:InputHoldBegin()
            task.wait(0.2)
            prompt:InputHoldEnd()
        end)
    elseif way == "button" then
        local b = findExact(guiTexts(), "conversar")
        if b then
            tryClick(b, function()
                local L = guiTexts()
                return dialogOption(L) ~= nil or roomUiOpen(L)
            end)
        end
    elseif way == "key" then
        local k = "E"
        if prompt then pcall(function() k = prompt.KeyboardKeyCode.Name end) end
        pressKey(k, 0.2)
    end
end

local function dumpTalkFailure(part, prompt)
    dbg("falha ao conversar. Guardião em", part and part.Position or "?", "| prompt:",
        prompt and prompt:GetFullName() or "nenhum")
    if prompt then
        dbg("  ActionText:", prompt.ActionText, "| Enabled:", prompt.Enabled,
            "| Hold:", prompt.HoldDuration, "| Dist:", prompt.MaxActivationDistance)
    end
    local n = 0
    for _, o in ipairs(workspace:GetDescendants()) do
        if o:IsA("ProximityPrompt") and n < 8 then
            n = n + 1
            dbg("  prompt:", o:GetFullName(), "|", o.ActionText, "|", o.ObjectText)
        end
    end
end

-- chega até o Guardião, conversa e abre "Salas de Boss"; true quando a tela da sala abrir
local function openRoom(g)
    local prompt
    local talkTry = 0
    for attempt = 1, 10 do
        if not S.running then return false end
        local L = guiTexts()
        if roomUiOpen(L) then return true end
        local opt = dialogOption(L)
        if opt then
            setStatus("Abrindo Salas de Boss...", "run")
            if tryClick(opt, function() return roomUiOpen(guiTexts()) end) then return true end
        else
            talkTry = talkTry + 1
            setStatus("Falando com o Guardião... (" .. talkTry .. ")", "run")
            if not prompt or not prompt.Parent then prompt = promptFor(g) end
            approach(g)
            local ways = talkWays(prompt)
            talkMethod(ways[(talkTry - 1) % #ways + 1], prompt)
            waitUntil(function()
                local L2 = guiTexts()
                return dialogOption(L2) ~= nil or roomUiOpen(L2)
            end, 2.2, 0.2)
        end
    end
    dumpTalkFailure(g, prompt)
    return false
end

------------------------------------------------------------------------
-- Boss (nunca o Guardião)
------------------------------------------------------------------------
local Baseline = {}

local function bossRoot(m)
    if not m then return nil end
    return m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart", true)
end

local function bossAlive(m)
    if not (m and m.Parent) then return false end
    local hum = m:FindFirstChildOfClass("Humanoid")
    if hum and hum.Health <= 0 then return false end
    return bossRoot(m) ~= nil
end

-- qualquer coisa com "guardi" ou "sala" é do NPC/lobby, nunca o boss
local function isBadText(s)
    s = string.lower(s or "")
    return has(s, "guardi") or has(s, "sala")
end

-- nomes flutuantes desenhados na PlayerGui apontando para um modelo (ex.: "Guardião da Sala de Noctis")
local function badAdornees()
    local list = {}
    local pg = LP:FindFirstChildOfClass("PlayerGui")
    if not pg then return list end
    for _, bb in ipairs(pg:GetDescendants()) do
        if bb:IsA("BillboardGui") and bb.Adornee then
            for _, d in ipairs(bb:GetDescendants()) do
                if d:IsA("TextLabel") and isBadText(d.Text) then
                    list[#list + 1] = bb.Adornee
                    break
                end
            end
        end
    end
    return list
end

-- nome do modelo, DisplayName ou texto na cabeça contém a palavra-chave
local function nameHit(o, kw)
    if has(string.lower(o.Name), kw) then return true end
    local hum = o:FindFirstChildOfClass("Humanoid")
    if hum and has(string.lower(hum.DisplayName), kw) then return true end
    local head = o:FindFirstChild("Head")
    if head then
        for _, d in ipairs(head:GetDescendants()) do
            if d:IsA("TextLabel") and has(normText(d), kw) then return true end
        end
    end
    return false
end

local function isBadModel(o, bad, talk)
    -- 1) lista negra: o modelo do Guardião
    if Guard.model and (o == Guard.model or o:IsDescendantOf(Guard.model) or Guard.model:IsDescendantOf(o)) then
        return true
    end
    -- 2) qualquer modelo com botão de conversa
    if o:FindFirstChildWhichIsA("ProximityPrompt", true) then return true end
    -- 3) "guardi" / "sala" no nome, DisplayName ou em qualquer texto dentro do modelo
    if isBadText(o.Name) then return true end
    local hum = o:FindFirstChildOfClass("Humanoid")
    if hum and isBadText(hum.DisplayName) then return true end
    for _, d in ipairs(o:GetDescendants()) do
        if d:IsA("TextLabel") and isBadText(d.Text) then return true end
    end
    for _, a in ipairs(bad) do
        if a:IsDescendantOf(o) then return true end
    end
    -- reforço por posição: colado no Guardião ou num prompt "Conversar"
    local root = bossRoot(o)
    if root then
        if Guard.pos and (root.Position - Guard.pos).Magnitude < 25 then return true end
        for _, p in ipairs(talk) do
            if (root.Position - p).Magnitude < 15 then return true end
        end
    end
    return false
end

local function snapshotBaseline()
    Baseline = {}
    local kw = string.lower(S.bossKey or "")
    if kw == "" then return end
    for _, o in ipairs(workspace:GetDescendants()) do
        if o:IsA("Model") and not Players:GetPlayerFromCharacter(o) and nameHit(o, kw) then
            Baseline[o] = true
        end
    end
end

-- strict = ignora modelos que já existiam antes do INICIAR. Não usa MaxHealth.
local function findBoss(strict, allowNoHum)
    local kw = string.lower(S.bossKey or "")
    if kw == "" then return nil end
    local cands, talk = {}, {}
    for _, o in ipairs(workspace:GetDescendants()) do
        if o:IsA("Model") then
            if not (strict and Baseline[o]) and not Players:GetPlayerFromCharacter(o) then
                local hum = o:FindFirstChildOfClass("Humanoid")
                local aliveOk = (hum and hum.Health > 0) or (allowNoHum and not hum)
                if aliveOk and nameHit(o, kw) then cands[#cands + 1] = o end
            end
        elseif o:IsA("ProximityPrompt") then
            local at = string.lower((o.ActionText or "") .. " " .. (o.ObjectText or ""))
            if has(at, "convers") or has(at, "talk") or has(at, "falar") or isBadText(at) then
                local pp = partOf(o.Parent)
                if pp then talk[#talk + 1] = pp.Position end
            end
        end
    end
    if #cands == 0 then return nil end
    local bad = badAdornees()
    local hrp = getHRP()
    local best, bd
    for _, o in ipairs(cands) do
        local root = bossRoot(o)
        if root and not isBadModel(o, bad, talk) then
            local d = hrp and (root.Position - hrp.Position).Magnitude or 0
            if not bd or d < bd then best, bd = o, d end
        end
    end
    return best
end

------------------------------------------------------------------------
-- Ataque (contínuo, não depende de ter Tool equipada)
------------------------------------------------------------------------
local function toolNameFor(mode, char)
    if S.tools[mode] then return S.tools[mode] end
    local eq = char:FindFirstChildOfClass("Tool")
    if eq then return eq.Name end
    local bp = LP:FindFirstChildOfClass("Backpack")
    local t = bp and bp:FindFirstChildOfClass("Tool")
    return t and t.Name or nil
end

local function ensureTool(char, hum, want)
    if not want then return nil end
    local tool = char:FindFirstChild(want)
    if tool and tool:IsA("Tool") then return tool end
    local bp = LP:FindFirstChildOfClass("Backpack")
    local t = bp and bp:FindFirstChild(want)
    if t and t:IsA("Tool") then
        pcall(function() hum:EquipTool(t) end)
        task.wait(0.15)
        local eq = char:FindFirstChild(want)
        if eq and eq:IsA("Tool") then return eq end
    end
    return nil
end

local function aimPoint(root)
    local cam = workspace.CurrentCamera
    local vp = cam.ViewportSize
    local v, on = cam:WorldToScreenPoint(root.Position)   -- já considera o inset do topo
    if on and v.Z > 0 then
        return math.clamp(v.X, 8, vp.X - 8), math.clamp(v.Y, 8, vp.Y - 8)
    end
    return vp.X / 2, vp.Y / 2
end

local function overMenu(loc)
    local m = UI.Main
    if not (m and UI.Gui and UI.Gui.Enabled) then return false end
    local p, s = m.AbsolutePosition, m.AbsoluteSize
    return loc.X >= p.X and loc.X <= p.X + s.X and loc.Y >= p.Y and loc.Y <= p.Y + s.Y
end

-- M1 sem hardware: tool:Activate() + clique entregue aos handlers do jogo.
-- Mouse virtual (move o cursor) só se ligado na Config.
local function m1Click(tool, root)
    if tool then pcall(function() tool:Activate() end) end
    if typing() then return end
    dispatchGlobal(Enum.UserInputType.MouseButton1, nil, 0.03)
    if not (S.useVim and VIM) then return end
    local aimed = (S.mode == "Gun" or S.mode == "Fruit")
    local x, y
    if aimed then
        x, y = aimPoint(root)
    else
        local loc = UIS:GetMouseLocation()
        if overMenu(loc) then x, y = aimPoint(root) else x, y = loc.X, loc.Y end
    end
    pcall(function()
        if aimed then VIM:SendMouseMoveEvent(x, y, game) end
        VIM:SendMouseButtonEvent(x, y, 0, true, game, 1)
        task.wait(0.03)
        VIM:SendMouseButtonEvent(x, y, 0, false, game, 1)
    end)
end

local function attackLoop()
    local last, auto, lastMode = {}, nil, S.mode
    while S.fighting and S.running do
        local char = LP.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        local root = S.boss and bossRoot(S.boss)
        if not S.paused and hum and hum.Health > 0 and root then
            if lastMode ~= S.mode then auto, lastMode = nil, S.mode end
            local want = S.tools[S.mode]
            if not want then
                auto = auto or toolNameFor(S.mode, char)
                want = auto
            end
            local tool = ensureTool(char, hum, want)   -- pode ser nil: ataca do mesmo jeito
            if S.m1 then m1Click(tool, root) end
            local now = os.clock()
            for _, k in ipairs(KEYS) do
                local sk = skillOf(S.mode, k)
                if sk.on and now - (last[k] or 0) >= sk.cd then
                    if pressKey(k) then
                        last[k] = now
                        task.wait(0.08)
                    end
                end
            end
        end
        task.wait(MODE_DELAY[S.mode] or 0.12)
    end
end

-- gruda nas costas do boss
track(RunService.Heartbeat:Connect(function()
    if not S.fighting or S.paused then return end
    local hrp = getHRP()
    local root = S.boss and bossRoot(S.boss)
    if not (hrp and root) then return end
    local back = S.flip and -S.distance or S.distance
    local pos = (root.CFrame * CFrame.new(0, S.height, back)).Position
    local look = Vector3.new(root.Position.X, pos.Y, root.Position.Z)
    if (look - pos).Magnitude > 0.1 then hrp.CFrame = CFrame.lookAt(pos, look) end
    hrp.AssemblyLinearVelocity = Vector3.zero
    hrp.AssemblyAngularVelocity = Vector3.zero
end))

pcall(function()
    RunService:UnbindFromRenderStep("NoctisAim")
    RunService:BindToRenderStep("NoctisAim", Enum.RenderPriority.Camera.Value + 1, function()
        if not (S.fighting and S.aim) or S.paused then return end
        local cam = workspace.CurrentCamera
        local root = S.boss and bossRoot(S.boss)
        if cam and root then cam.CFrame = CFrame.lookAt(cam.CFrame.Position, root.Position) end
    end)
end)

------------------------------------------------------------------------
-- Ciclo
------------------------------------------------------------------------
local function waitBackToLobby()
    setStatus("Boss derrotado · voltando ao lobby...", "ok")
    sleepP(2)
    waitUntil(function() return not defeatVisible() end, 20, 0.5)
    waitUntil(function()
        local hrp = getHRP()
        if not Guard.pos then return true end
        return hrp and (hrp.Position - Guard.pos).Magnitude < 400
    end, 25, 0.5)
end

local function fightBoss(boss)
    S.boss, S.fighting, S.awaitStart = boss, true, nil
    task.spawn(attackLoop)
    local startedWithText = defeatVisible()
    local gone, tick = 0, 0
    while S.running do
        if S.paused then
            task.wait(0.3)
        else
            if bossAlive(boss) then gone = 0 else gone = gone + 1 end
            tick = tick + 1
            if gone >= 3 then break end
            if tick % 4 == 0 and not startedWithText and defeatVisible() then break end
            local hum = boss:FindFirstChildOfClass("Humanoid")
            if hum then
                setStatus(string.format("Atacando · %s  %d/%d", boss.Name,
                    math.floor(hum.Health), math.floor(hum.MaxHealth)), "run")
            else
                setStatus("Atacando · " .. boss.Name, "run")
            end
            task.wait(0.5)
        end
    end
    S.fighting, S.boss = false, nil
    if S.running then waitBackToLobby() end
end

local function startRoom()
    for i = S.startWait, 1, -1 do
        if not S.running then return end
        if not roomUiOpen(guiTexts()) then return end
        setStatus(string.format("Sala aberta · iniciando em %ds", i), "run")
        sleepP(1)
    end
    if not S.running then return end
    local b = startButton(guiTexts())
    if not b then return end
    snapshotBaseline()   -- tudo que já existe com o nome do boss fica de fora
    setStatus("Apertando INICIAR...", "run")
    local done = tryClick(b, function() return not roomUiOpen(guiTexts()) end)
    if done then
        S.awaitStart = os.clock()
        setStatus("Entrando na luta...", "run")
    else
        setStatus("INICIAR não respondeu, tentando de novo...", "err")
    end
end

local arenaSince = nil
local lastGoto = 0

-- Guardião fora do alcance de streaming: vai até a posição memorizada para ele carregar
local function gotoSavedGuardian()
    local hrp = getHRP()
    if not (Guard.pos and hrp) then return false end
    if (hrp.Position - Guard.pos).Magnitude < 12 then return false end   -- já está lá e ele não aparece
    if os.clock() - lastGoto < 6 then return true end
    lastGoto = os.clock()
    setStatus("Indo até a posição salva do Guardião...", "run")
    pcall(function() LP:RequestStreamAroundAsync(Guard.pos) end)
    hrp.CFrame = CFrame.new(Guard.pos + Vector3.new(0, 3, 6))
    hrp.AssemblyLinearVelocity = Vector3.zero
    return true
end

local function step()
    -- 1º localiza o Guardião: ele precisa estar na lista negra antes de qualquer busca de boss
    local g = guardianThrottled()

    -- nos primeiros segundos, sem saber onde o Guardião está, não dá para distinguir lobby de arena
    local settling = (not Guard.pos) and (os.clock() - S.startedAt < 6)

    -- no lobby só aceita boss depois do INICIAR; fora do lobby (arena) procura normal
    local boss
    if settling then
        setStatus("Localizando o Guardião...", "run")
    elseif not inLobby() then
        boss = findBoss(true)
        if boss then
            arenaSince = nil
        else
            arenaSince = arenaSince or os.clock()
            local waited = os.clock() - (S.awaitStart or arenaSince)
            if waited > 8 then boss = findBoss(false) end
            if not boss and waited > 16 then boss = findBoss(false, true) end   -- boss sem Humanoid
        end
    else
        arenaSince = nil
        if S.awaitStart then boss = findBoss(true) end
    end
    if boss then
        arenaSince = nil
        fightBoss(boss)
        return
    end

    if roomUiOpen(guiTexts()) then
        startRoom()
        return
    end

    if S.awaitStart then
        if os.clock() - S.awaitStart < 90 then
            setStatus("Entrando na luta...", "run")
            task.wait(0.5)
            return
        end
        S.awaitStart = nil
    end

    if g then
        if openRoom(g) then
            -- conversa funcionou: memoriza onde o Guardião fica (para carregá-lo depois)
            local gp = Guard.part
            if gp and gp:IsDescendantOf(workspace) then
                local old = Guard.pos
                Guard.pos, Guard.confirmed = gp.Position, true
                if not old or (old - Guard.pos).Magnitude > 3 or not Saved.guardPos then
                    Saved.guardPos = { x = Guard.pos.X, y = Guard.pos.Y, z = Guard.pos.Z }
                    save()
                end
            end
        elseif S.running then
            setStatus("Não consegui abrir a sala, tentando de novo...", "err")
            task.wait(2)
        end
        return
    end

    if not settling then
        if Guard.confirmed and gotoSavedGuardian() then
            task.wait(1.5)
        elseif Guard.confirmed then
            setStatus("Guardião não aparece na posição salva (veja o Diagnóstico)", "err")
            task.wait(1)
        else
            setStatus("Não achei o Guardião: chegue perto dele uma vez", "err")
            task.wait(1)
        end
    else
        task.wait(0.5)
    end
end

local function stopBot(msg)
    S.running, S.paused, S.fighting, S.boss, S.awaitStart = false, false, false, nil, nil
    setStatus(msg or "Parado", "idle")
    if refreshRun then refreshRun() end
end

local function startBot()
    if S.running then return end
    S.running, S.paused, S.awaitStart = true, false, nil
    S.startedAt = os.clock()
    arenaSince = nil
    Baseline = {}
    if refreshRun then refreshRun() end
    setStatus("Iniciando ciclo...", "run")
    task.spawn(function()
        while S.running do
            if S.paused then
                task.wait(0.2)
            else
                local ok, err = pcall(step)
                if not ok then
                    dbg("erro:", err)
                    setStatus("Erro: " .. tostring(err), "err")
                    task.wait(2)
                end
            end
        end
        S.fighting, S.boss = false, nil
        if refreshRun then refreshRun() end
    end)
end

-- iniciar / pausar / retomar com a mesma tecla
local function toggle()
    if not S.running then
        startBot()
    else
        S.paused = not S.paused
        if S.paused then
            setStatus("Pausado · " .. S.keys.toggle .. " retoma", "idle")
        else
            setStatus("Retomado", "run")
        end
        if refreshRun then refreshRun() end
    end
end

------------------------------------------------------------------------
-- Diagnóstico (copia um relatório para a área de transferência) e espião de remotes
------------------------------------------------------------------------
local function pathOf(i)
    local ok, p = pcall(function() return i:GetFullName() end)
    return ok and p or tostring(i)
end

local Spy = { hooked = false, on = false, counts = {}, order = {} }

local function argStr(v, depth)
    local t = typeof(v)
    if t == "string" then return '"' .. string.sub(v, 1, 40) .. '"' end
    if t == "Instance" then return "<" .. v.ClassName .. ":" .. v.Name .. ">" end
    if t == "table" then
        if (depth or 0) >= 1 then return "{...}" end
        local parts, n = {}, 0
        for k, x in pairs(v) do
            n = n + 1
            if n > 6 then parts[#parts + 1] = "..." break end
            parts[#parts + 1] = tostring(k) .. "=" .. argStr(x, (depth or 0) + 1)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return tostring(v)
end

-- grava (sem alterar nada) os RemoteEvents/Functions que o JOGO dispara enquanto você ataca na mão
local function startSpy(seconds)
    if not (hookmetamethod and getnamecallmethod) then
        setStatus("Executor sem hookmetamethod: não dá para espionar remotes", "err")
        return false
    end
    if not Spy.hooked then
        Spy.hooked = true
        local old
        old = hookmetamethod(game, "__namecall", (newcclosure or function(f) return f end)(function(self, ...)
            local m = getnamecallmethod()
            if Spy.on and (m == "FireServer" or m == "InvokeServer") and typeof(self) == "Instance"
                and not (checkcaller and checkcaller()) then
                pcall(function()
                    local args = table.pack(...)
                    local parts = {}
                    for i = 1, math.min(args.n, 6) do parts[i] = argStr(args[i], 0) end
                    local e = Spy.counts[self]
                    if not e then
                        e = { n = 0, m = m, sample = "" }
                        Spy.counts[self] = e
                        Spy.order[#Spy.order + 1] = self
                    end
                    e.n = e.n + 1
                    if e.n <= 2 then e.sample = e.sample .. "(" .. table.concat(parts, ", ") .. ") " end
                end)
            end
            if setnamecallmethod then pcall(setnamecallmethod, m) end
            return old(self, ...)
        end))
    end
    Spy.counts, Spy.order, Spy.on = {}, {}, true
    task.delay(seconds, function() Spy.on = false end)
    return true
end

local function buildReport()
    local out = {}
    local function add(...)
        local t = {}
        for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
        out[#out + 1] = table.concat(t, " ")
    end
    add("== NOCTIS DIAG ==")
    add("API: VIM=" .. tostring(VIM ~= nil), "getconnections=" .. tostring(getconnections ~= nil),
        "firesignal=" .. tostring(firesignal ~= nil), "fireproximityprompt=" .. tostring(fireproximityprompt ~= nil),
        "hookmetamethod=" .. tostring(hookmetamethod ~= nil), "setclipboard=" .. tostring(setclipboard ~= nil),
        "VIM ligado=" .. tostring(S.useVim))
    local hrp = getHRP()
    add("Jogador:", hrp and hrp.Position or "sem personagem", "| lobby:", tostring(inLobby()),
        "| Guard.pos:", tostring(Guard.pos), "| confirmado:", tostring(Guard.confirmed))

    local g = findGuardian()
    add("-- Guardião:", g and pathOf(g) or "NÃO ENCONTRADO")
    if g then
        add("   pos", g.Position, "| modelo:", Guard.model and pathOf(Guard.model) or "nenhum")
        local pr = promptFor(g)
        if pr then
            add("   prompt:", pathOf(pr), "| ActionText=" .. tostring(pr.ActionText), "ObjectText=" .. tostring(pr.ObjectText),
                "Enabled=" .. tostring(pr.Enabled), "Hold=" .. tostring(pr.HoldDuration),
                "Dist=" .. tostring(pr.MaxActivationDistance), "Tecla=" .. tostring(pr.KeyboardKeyCode))
        else
            add("   prompt: NENHUM num raio de 40 studs")
        end
    end

    add("-- ProximityPrompts a menos de 80 studs:")
    local np = 0
    for _, o in ipairs(workspace:GetDescendants()) do
        if o:IsA("ProximityPrompt") and np < 12 then
            local pp = partOf(o.Parent)
            if pp and hrp and (pp.Position - hrp.Position).Magnitude < 80 then
                np = np + 1
                add("   ", pathOf(o), "|", tostring(o.ActionText), "|", tostring(o.ObjectText))
            end
        end
    end

    add("-- Modelos com '" .. tostring(S.bossKey) .. "' no nome/cabeça:")
    local kw = string.lower(S.bossKey or "")
    local bad = badAdornees()
    local talk = {}
    for _, o in ipairs(workspace:GetDescendants()) do
        if o:IsA("ProximityPrompt") then
            local at = string.lower((o.ActionText or "") .. " " .. (o.ObjectText or ""))
            if has(at, "convers") or has(at, "talk") or has(at, "falar") then
                local pp = partOf(o.Parent)
                if pp then talk[#talk + 1] = pp.Position end
            end
        end
    end
    local nc = 0
    for _, o in ipairs(workspace:GetDescendants()) do
        if o:IsA("Model") and nc < 15 and kw ~= "" and not Players:GetPlayerFromCharacter(o) and nameHit(o, kw) then
            nc = nc + 1
            local hum = o:FindFirstChildOfClass("Humanoid")
            add("   ", pathOf(o), "| Humanoid:", hum and ("hp " .. math.floor(hum.Health)) or "NÃO",
                "| rejeitado:", tostring(isBadModel(o, bad, talk)),
                "| prompt dentro:", tostring(o:FindFirstChildWhichIsA("ProximityPrompt", true) ~= nil))
        end
    end
    if nc == 0 then add("   nenhum") end

    add("-- Tools (equipada / mochila):")
    local ch = LP.Character
    if ch then
        for _, t in ipairs(ch:GetChildren()) do
            if t:IsA("Tool") then add("   [equipada]", t.Name) end
        end
    end
    local bp = LP:FindFirstChildOfClass("Backpack")
    if bp then
        for _, t in ipairs(bp:GetChildren()) do add("   [mochila]", t.ClassName, t.Name) end
    end

    add("-- Textos visíveis na tela (amostra):")
    local seen, n = {}, 0
    for _, r in ipairs(guiTexts()) do
        if n < 45 and #r.t > 0 and #r.t < 48 and not seen[r.t] then
            seen[r.t] = true
            n = n + 1
            add("   ", r.t)
        end
    end

    if #Spy.order > 0 then
        add("-- Remotes disparados pelo jogo durante a espionagem:")
        for _, inst in ipairs(Spy.order) do
            local e = Spy.counts[inst]
            add("   ", e.n .. "x", e.m, pathOf(inst), e.sample)
        end
    end
    return table.concat(out, "\n")
end

local function runDiagnostic()
    local ok, rep = pcall(buildReport)
    if not ok then
        setStatus("Falha no diagnóstico: " .. tostring(rep), "err")
        return
    end
    print(rep)
    local copied = false
    if setclipboard then copied = pcall(setclipboard, rep) end
    local saved = false
    if writefile then saved = pcall(writefile, "noctis_diag.txt", rep) end
    if copied then
        setStatus("Diagnóstico copiado: cole no chat com a IA", "ok")
    elseif saved then
        setStatus("Diagnóstico salvo em noctis_diag.txt (workspace do executor)", "ok")
    else
        setStatus("Diagnóstico impresso no console (F9)", "ok")
    end
end

------------------------------------------------------------------------
-- UI · helpers
------------------------------------------------------------------------
local ordN = 0
local function nextOrd() ordN = ordN + 1 return ordN end

local function mk(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props or {}) do o[k] = v end
    o.Parent = parent
    return o
end
local function corner(o, r) return mk("UICorner", { CornerRadius = UDim.new(0, r or 8) }, o) end
local function stroke(o, col, th, tr)
    return mk("UIStroke", { Color = col or C.stroke, Thickness = th or 1, Transparency = tr or 0,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, o)
end
local function pad(o, l, t, r, b)
    return mk("UIPadding", { PaddingLeft = UDim.new(0, l), PaddingTop = UDim.new(0, t),
        PaddingRight = UDim.new(0, r or l), PaddingBottom = UDim.new(0, b or t) }, o)
end
local function vlist(o, gap)
    return mk("UIListLayout", { Padding = UDim.new(0, gap or 6), SortOrder = Enum.SortOrder.LayoutOrder }, o)
end

local function lbl(parent, text, size, color, font, xalign, props)
    local t = mk("TextLabel", {
        BackgroundTransparency = 1, Text = text, TextSize = size or 13, TextColor3 = color or C.text,
        Font = font or Enum.Font.GothamMedium, TextXAlignment = xalign or Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, 0, 0, (size or 13) + 4),
    }, nil)
    if props then for k, v in pairs(props) do t[k] = v end end
    t.Parent = parent
    return t
end

local function hover(btn, base, over)
    track(btn.MouseEnter:Connect(function()
        TweenService:Create(btn, TweenInfo.new(0.12), { BackgroundColor3 = over }):Play()
    end))
    track(btn.MouseLeave:Connect(function()
        TweenService:Create(btn, TweenInfo.new(0.12), { BackgroundColor3 = base }):Play()
    end))
end

local function switch(parent, val, cb)
    local f = mk("TextButton", { Text = "", AutoButtonColor = false, Size = UDim2.fromOffset(38, 20),
        BackgroundColor3 = val and C.red or C.stroke }, parent)
    corner(f, 10)
    local k = mk("Frame", { Size = UDim2.fromOffset(14, 14), AnchorPoint = Vector2.new(0, 0.5),
        Position = val and UDim2.new(1, -17, 0.5, 0) or UDim2.new(0, 3, 0.5, 0),
        BackgroundColor3 = Color3.new(1, 1, 1) }, f)
    corner(k, 7)
    local state = val and true or false
    local function render()
        TweenService:Create(f, TweenInfo.new(0.14), { BackgroundColor3 = state and C.red or C.stroke }):Play()
        TweenService:Create(k, TweenInfo.new(0.14), {
            Position = state and UDim2.new(1, -17, 0.5, 0) or UDim2.new(0, 3, 0.5, 0) }):Play()
    end
    track(f.MouseButton1Click:Connect(function()
        state = not state
        render()
        cb(state)
    end))
    return { Frame = f, Set = function(v) state = v and true or false render() end }
end

local function toggleRow(parent, text, sub, val, cb)
    local row = mk("Frame", { Size = UDim2.new(1, 0, 0, sub and 46 or 38), BackgroundColor3 = C.card,
        LayoutOrder = nextOrd() }, parent)
    corner(row, 8)
    if sub then
        lbl(row, text, 13, C.text, nil, nil, { Position = UDim2.new(0, 12, 0, 6), Size = UDim2.new(1, -70, 0, 17) })
        lbl(row, sub, 11, C.sub, Enum.Font.Gotham, nil, { Position = UDim2.new(0, 12, 0, 24), Size = UDim2.new(1, -70, 0, 15) })
    else
        lbl(row, text, 13, C.text, nil, nil, { Position = UDim2.new(0, 12, 0, 0), Size = UDim2.new(1, -70, 1, 0) })
    end
    local sw = switch(row, val, cb)
    sw.Frame.AnchorPoint = Vector2.new(1, 0.5)
    sw.Frame.Position = UDim2.new(1, -12, 0.5, 0)
    return sw
end

local function sliderRow(parent, text, min, max, val, dec, cb)
    local row = mk("Frame", { Size = UDim2.new(1, 0, 0, 48), BackgroundColor3 = C.card, LayoutOrder = nextOrd() }, parent)
    corner(row, 8)
    lbl(row, text, 13, C.text, nil, nil, { Position = UDim2.new(0, 12, 0, 6), Size = UDim2.new(1, -90, 0, 17) })
    local vl = lbl(row, "", 12, C.amber, Enum.Font.GothamBold, Enum.TextXAlignment.Right,
        { Position = UDim2.new(1, -72, 0, 6), Size = UDim2.new(0, 60, 0, 17) })
    local bar = mk("Frame", { Position = UDim2.new(0, 12, 0, 33), Size = UDim2.new(1, -24, 0, 4),
        BackgroundColor3 = C.stroke }, row)
    corner(bar, 2)
    local fill = mk("Frame", { Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = C.red }, bar)
    corner(fill, 2)
    local knob = mk("Frame", { Size = UDim2.fromOffset(12, 12), AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0, 0, 0.5, 0), BackgroundColor3 = Color3.new(1, 1, 1) }, bar)
    corner(knob, 6)
    local hit = mk("TextButton", { Text = "", BackgroundTransparency = 1, Position = UDim2.new(0, 6, 0, 24),
        Size = UDim2.new(1, -12, 0, 22) }, row)

    local mult = 10 ^ (dec or 0)
    local function render(v)
        local rel = (v - min) / (max - min)
        fill.Size = UDim2.new(rel, 0, 1, 0)
        knob.Position = UDim2.new(rel, 0, 0.5, 0)
        vl.Text = tostring(v)
    end
    local function setFromX(x)
        local rel = math.clamp((x - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1), 0, 1)
        local v = math.floor((min + (max - min) * rel) * mult + 0.5) / mult
        render(v)
        cb(v)
    end
    local dragging = false
    track(hit.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            setFromX(i.Position.X)
        end
    end))
    track(UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement
            or i.UserInputType == Enum.UserInputType.Touch) then
            setFromX(i.Position.X)
        end
    end))
    track(UIS.InputEnded:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseButton1
            or i.UserInputType == Enum.UserInputType.Touch) then
            dragging = false
            save()
        end
    end))
    render(math.clamp(val, min, max))
    return { Set = function(v) render(math.clamp(v, min, max)) end }
end

local function textBox(parent, text, w, cb)
    local b = mk("TextBox", { Size = UDim2.fromOffset(w, 26), BackgroundColor3 = C.panel, Text = text,
        TextColor3 = C.text, PlaceholderColor3 = C.sub, Font = Enum.Font.GothamMedium, TextSize = 12,
        ClearTextOnFocus = false }, parent)
    corner(b, 6)
    stroke(b, C.stroke, 1, 0.2)
    track(b.FocusLost:Connect(function() cb(b.Text, b) end))
    return b
end

local function segmented(parent, options, current, cb)
    local row = mk("Frame", { Size = UDim2.new(1, 0, 0, 36), BackgroundColor3 = C.card, LayoutOrder = nextOrd() }, parent)
    corner(row, 8)
    pad(row, 3, 3)
    mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 3),
        SortOrder = Enum.SortOrder.LayoutOrder }, row)
    local n, btns = #options, {}
    local function style(sel)
        for name, b in pairs(btns) do
            local on = name == sel
            TweenService:Create(b, TweenInfo.new(0.12), {
                BackgroundColor3 = on and C.red or C.panel,
                TextColor3 = on and Color3.new(1, 1, 1) or C.sub }):Play()
        end
    end
    for i, name in ipairs(options) do
        local b = mk("TextButton", { Text = name, Font = Enum.Font.GothamBold, TextSize = 12, AutoButtonColor = false,
            Size = UDim2.new(1 / n, -math.ceil(3 * (n - 1) / n), 1, 0), BackgroundColor3 = C.panel,
            TextColor3 = C.sub, LayoutOrder = i }, row)
        corner(b, 6)
        btns[name] = b
        track(b.MouseButton1Click:Connect(function()
            style(name)
            cb(name)
        end))
    end
    style(current)
    return { Set = style }
end

local function listBox(parent, height)
    local sf = mk("ScrollingFrame", { Size = UDim2.new(1, 0, 0, height), BackgroundColor3 = C.card, BorderSizePixel = 0,
        ScrollBarThickness = 3, ScrollBarImageColor3 = C.red, CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y, LayoutOrder = nextOrd() }, parent)
    corner(sf, 8)
    pad(sf, 6, 6)
    vlist(sf, 4)
    return sf
end

local function fillList(sf, items, emptyText)
    for _, c in ipairs(sf:GetChildren()) do
        if c:IsA("GuiObject") then c:Destroy() end
    end
    if #items == 0 then
        lbl(sf, emptyText or "Vazio", 12, C.sub, Enum.Font.Gotham, Enum.TextXAlignment.Center,
            { Size = UDim2.new(1, 0, 0, 30) })
        return
    end
    for i, it in ipairs(items) do
        local b = mk("TextButton", { Text = "", AutoButtonColor = false, Size = UDim2.new(1, 0, 0, 34),
            BackgroundColor3 = it.selected and C.red or C.panel,
            BackgroundTransparency = it.selected and 0.78 or 0, LayoutOrder = i }, sf)
        corner(b, 6)
        if it.selected then stroke(b, C.red, 1, 0.1) end
        lbl(b, it.title, 13, C.text, nil, nil, { Position = UDim2.new(0, 10, 0, 0), Size = UDim2.new(0.55, -10, 1, 0) })
        if it.sub then
            lbl(b, it.sub, 11, C.sub, Enum.Font.Gotham, Enum.TextXAlignment.Right,
                { Position = UDim2.new(0.55, 0, 0, 0), Size = UDim2.new(0.45, -10, 1, 0) })
        end
        track(b.MouseButton1Click:Connect(it.onClick))
    end
end

local function smallButton(parent, text, w, cb)
    local b = mk("TextButton", { Text = text, Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = C.text,
        AutoButtonColor = false, Size = UDim2.fromOffset(w, 26), BackgroundColor3 = C.panel }, parent)
    corner(b, 6)
    stroke(b, C.stroke, 1, 0.2)
    hover(b, C.panel, C.card)
    track(b.MouseButton1Click:Connect(cb))
    return b
end

local function sectionTitle(parent, text, sub)
    local f = mk("Frame", { Size = UDim2.new(1, 0, 0, sub and 34 or 20), BackgroundTransparency = 1,
        LayoutOrder = nextOrd() }, parent)
    lbl(f, string.upper(text), 11, C.red, Enum.Font.GothamBold, nil, { Size = UDim2.new(1, 0, 0, 15) })
    if sub then
        lbl(f, sub, 11, C.sub, Enum.Font.Gotham, nil, { Position = UDim2.new(0, 0, 0, 16), Size = UDim2.new(1, 0, 0, 15) })
    end
    return f
end

------------------------------------------------------------------------
-- UI · janela
------------------------------------------------------------------------
local gui = mk("ScreenGui", { Name = "NoctisAuto" .. tostring(math.random(1000, 9999)), ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling, IgnoreGuiInset = true, DisplayOrder = 1000 }, nil)
local okParent = pcall(function() gui.Parent = (gethui and gethui()) or CoreGui end)
if not okParent or not gui.Parent then gui.Parent = LP:WaitForChild("PlayerGui") end
UI.Gui = gui

local W, H = 440, 470
local main = mk("Frame", { Name = "Main", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, 0),
    Size = UDim2.fromOffset(W, H), BackgroundColor3 = C.bg, BorderSizePixel = 0, ClipsDescendants = true }, gui)
UI.Main = main
corner(main, 14)
stroke(main, C.red, 1, 0.55)
local uiScale = mk("UIScale", {}, main)
local function fit()
    local cam = workspace.CurrentCamera
    if cam then
        local vp = cam.ViewportSize
        uiScale.Scale = math.clamp(math.min((vp.X - 16) / W, (vp.Y - 16) / H, 1), 0.5, 1)
    end
end
fit()

local header = mk("Frame", { Size = UDim2.new(1, 0, 0, 52), BackgroundColor3 = C.panel, BorderSizePixel = 0 }, main)
local logo = mk("Frame", { Size = UDim2.fromOffset(22, 22), Position = UDim2.new(0, 16, 0.5, 0),
    AnchorPoint = Vector2.new(0, 0.5), BackgroundColor3 = Color3.new(1, 1, 1), Rotation = 45 }, header)
corner(logo, 5)
mk("UIGradient", { Color = ColorSequence.new(C.red, C.amber), Rotation = 90 }, logo)
lbl(header, "NOCTIS", 16, C.text, Enum.Font.GothamBlack, nil, { Position = UDim2.new(0, 50, 0, 8), Size = UDim2.new(0, 200, 0, 20) })
lbl(header, "AUTO BOSS  ·  CIRCUS TOWN", 10, C.sub, Enum.Font.GothamMedium, nil,
    { Position = UDim2.new(0, 51, 0, 28), Size = UDim2.new(0, 220, 0, 14) })

local btnMin = mk("TextButton", { Text = "–", Font = Enum.Font.GothamBold, TextSize = 18, TextColor3 = C.sub,
    AutoButtonColor = false, Size = UDim2.fromOffset(30, 30), AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, -52, 0.5, 0), BackgroundColor3 = C.card }, header)
corner(btnMin, 8)
hover(btnMin, C.card, C.stroke)
local btnClose = mk("TextButton", { Text = "×", Font = Enum.Font.GothamBold, TextSize = 18, TextColor3 = C.sub,
    AutoButtonColor = false, Size = UDim2.fromOffset(30, 30), AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, -14, 0.5, 0), BackgroundColor3 = C.card }, header)
corner(btnClose, 8)
hover(btnClose, C.card, C.red)

local accent = mk("Frame", { Position = UDim2.new(0, 0, 0, 52), Size = UDim2.new(1, 0, 0, 2),
    BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0 }, main)
mk("UIGradient", { Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, C.red), ColorSequenceKeypoint.new(0.6, C.amber), ColorSequenceKeypoint.new(1, C.bg) }) }, accent)

do
    local dragging, dragStart, startPos
    track(header.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPos = true, i.Position, main.Position
        end
    end))
    track(UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement
            or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - dragStart
            local sc = uiScale.Scale
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X / sc,
                startPos.Y.Scale, startPos.Y.Offset + d.Y / sc)
        end
    end))
    track(UIS.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))
end

local body = mk("Frame", { Position = UDim2.new(0, 0, 0, 54), Size = UDim2.new(1, 0, 1, -54), BackgroundTransparency = 1 }, main)
local tabBar = mk("Frame", { Size = UDim2.new(1, 0, 0, 36), BackgroundTransparency = 1 }, body)
local pagesHolder = mk("Frame", { Position = UDim2.new(0, 0, 0, 38), Size = UDim2.new(1, 0, 1, -38 - 76),
    BackgroundTransparency = 1 }, body)

local TABS = { "Sala", "Combate", "Skills", "Config" }
local tabBtns, pages = {}, {}

local function newPage()
    local sf = mk("ScrollingFrame", { Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, BorderSizePixel = 0,
        ScrollBarThickness = 3, ScrollBarImageColor3 = C.red, CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y, Visible = false }, pagesHolder)
    pad(sf, 14, 6, 14, 10)
    vlist(sf, 8)
    return sf
end

local refreshTools, refreshSkills

local function showTab(name)
    for _, t in ipairs(TABS) do
        local on = t == name
        pages[t].Visible = on
        tabBtns[t].Text.TextColor3 = on and C.text or C.sub
        tabBtns[t].Line.Visible = on
    end
    if name == "Combate" and refreshTools then refreshTools() end
    if name == "Skills" and refreshSkills then refreshSkills() end
end

for i, name in ipairs(TABS) do
    local holder = mk("TextButton", { Text = "", BackgroundTransparency = 1, AutoButtonColor = false,
        Size = UDim2.new(1 / #TABS, 0, 1, 0), Position = UDim2.new((i - 1) / #TABS, 0, 0, 0) }, tabBar)
    local txt = lbl(holder, name, 13, C.sub, Enum.Font.GothamBold, Enum.TextXAlignment.Center, { Size = UDim2.new(1, 0, 1, 0) })
    local line = mk("Frame", { Size = UDim2.new(0.5, 0, 0, 2), AnchorPoint = Vector2.new(0.5, 1),
        Position = UDim2.new(0.5, 0, 1, -1), BackgroundColor3 = C.red, BorderSizePixel = 0, Visible = false }, holder)
    corner(line, 1)
    tabBtns[name] = { Text = txt, Line = line }
    pages[name] = newPage()
    track(holder.MouseButton1Click:Connect(function() showTab(name) end))
end

------------------------------------------------------------------------
-- Aba Sala
------------------------------------------------------------------------
do
    local pg = pages.Sala

    local flow = mk("Frame", { Size = UDim2.new(1, 0, 0, 78), BackgroundColor3 = C.card, LayoutOrder = nextOrd() }, pg)
    corner(flow, 8)
    stroke(flow, C.red, 1, 0.6)
    lbl(flow, "CICLO AUTOMÁTICO", 10, C.red, Enum.Font.GothamBold, nil,
        { Position = UDim2.new(0, 12, 0, 8), Size = UDim2.new(1, -24, 0, 14) })
    lbl(flow, "Guardião  →  Salas de Boss  →  espera  →  INICIAR", 12, C.text, Enum.Font.GothamMedium, nil,
        { Position = UDim2.new(0, 12, 0, 28), Size = UDim2.new(1, -24, 0, 16) })
    lbl(flow, "→  ataca até o boss morrer  →  volta ao lobby  →  repete", 12, C.text, Enum.Font.GothamMedium, nil,
        { Position = UDim2.new(0, 12, 0, 48), Size = UDim2.new(1, -24, 0, 16) })

    sectionTitle(pg, "Antes de iniciar", "Tempo para o amigo apertar PRONTO depois que a sala abre.")
    sliderRow(pg, "Esperar antes de INICIAR (s)", 1, 30, S.startWait, 0, function(v) S.startWait = v end)

    sectionTitle(pg, "Boss", "Parte do nome do modelo do boss. O Guardião é excluído sozinho.")
    local row = mk("Frame", { Size = UDim2.new(1, 0, 0, 40), BackgroundColor3 = C.card, LayoutOrder = nextOrd() }, pg)
    corner(row, 8)
    lbl(row, "Nome do boss contém", 13, C.text, nil, nil, { Position = UDim2.new(0, 12, 0, 0), Size = UDim2.new(1, -170, 1, 0) })
    local bx = textBox(row, S.bossKey, 130, function(txt, box)
        txt = string.match(txt or "", "^%s*(.-)%s*$")
        if txt == "" then txt = "noctis" end
        S.bossKey = txt
        box.Text = txt
        save()
    end)
    bx.AnchorPoint = Vector2.new(1, 0.5)
    bx.Position = UDim2.new(1, -12, 0.5, 0)
end

------------------------------------------------------------------------
-- Aba Combate
------------------------------------------------------------------------
do
    local pg = pages.Combate
    sectionTitle(pg, "Equipamento", "Cada tipo lembra o item e as skills dele.")
    UI.ModeSeg = segmented(pg, MODES, S.mode, function(m)
        S.mode = m
        save()
        refreshTools()
        refreshSkills()
    end)
    UI.ToolList = listBox(pg, 118)

    sectionTitle(pg, "Ataque")
    toggleRow(pg, "Ataque básico (M1)", "Clica sem parar no boss", S.m1, function(v) S.m1 = v save() end)
    toggleRow(pg, "Mirar a câmera no boss", "Importante para Gun e Fruit", S.aim, function(v) S.aim = v save() end)

    sectionTitle(pg, "Posição")
    sliderRow(pg, "Distância atrás do boss", 1, 14, S.distance, 1, function(v) S.distance = v end)
    sliderRow(pg, "Altura", -6, 10, S.height, 1, function(v) S.height = v end)
    toggleRow(pg, "Inverter lado", "Use se ficar na frente em vez das costas", S.flip, function(v) S.flip = v save() end)
end

refreshTools = function()
    local names, seen = {}, {}
    local function scan(c)
        if not c then return end
        for _, t in ipairs(c:GetChildren()) do
            if t:IsA("Tool") and not seen[t.Name] then
                seen[t.Name] = true
                names[#names + 1] = t.Name
            end
        end
    end
    scan(LP.Character)
    scan(LP:FindFirstChildOfClass("Backpack"))
    local cur = S.tools[S.mode]
    local items = { {
        title = "Automático", sub = "o que estiver equipado", selected = cur == nil,
        onClick = function() S.tools[S.mode] = nil save() refreshTools() end,
    } }
    for _, n in ipairs(names) do
        local nm = n
        items[#items + 1] = {
            title = nm, selected = cur == nm,
            onClick = function() S.tools[S.mode] = nm save() refreshTools() end,
        }
    end
    fillList(UI.ToolList, items)
end

------------------------------------------------------------------------
-- Aba Skills
------------------------------------------------------------------------
local skillRows = {}
do
    local pg = pages.Skills
    sectionTitle(pg, "Habilidades", "Marque as que devem ser usadas e a recarga de cada uma.")
    local modeInfo = mk("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundColor3 = C.card, LayoutOrder = nextOrd() }, pg)
    corner(modeInfo, 8)
    UI.SkillMode = lbl(modeInfo, "", 12, C.amber, Enum.Font.GothamBold, nil,
        { Position = UDim2.new(0, 12, 0, 0), Size = UDim2.new(1, -24, 1, 0) })

    for _, key in ipairs(KEYS) do
        local row = mk("Frame", { Size = UDim2.new(1, 0, 0, 44), BackgroundColor3 = C.card, LayoutOrder = nextOrd() }, pg)
        corner(row, 8)
        local badge = mk("TextLabel", { Size = UDim2.fromOffset(28, 28), Position = UDim2.new(0, 10, 0.5, 0),
            AnchorPoint = Vector2.new(0, 0.5), BackgroundColor3 = C.panel, Text = key, Font = Enum.Font.GothamBold,
            TextSize = 14, TextColor3 = C.red }, row)
        corner(badge, 6)
        stroke(badge, C.red, 1, 0.5)
        lbl(row, "Usar habilidade " .. key, 13, C.text, nil, nil,
            { Position = UDim2.new(0, 48, 0, 0), Size = UDim2.new(1, -250, 1, 0) })
        lbl(row, "recarga (s)", 11, C.sub, Enum.Font.Gotham, Enum.TextXAlignment.Right,
            { Position = UDim2.new(1, -196, 0, 0), Size = UDim2.new(0, 80, 1, 0) })

        local cdBox = textBox(row, "3", 44, function(txt, box)
            local n = tonumber(txt)
            local sk = skillOf(S.mode, key)
            if n then sk.cd = math.clamp(n, 0.1, 120) end
            box.Text = tostring(sk.cd)
            save()
        end)
        cdBox.AnchorPoint = Vector2.new(1, 0.5)
        cdBox.Position = UDim2.new(1, -62, 0.5, 0)
        cdBox.TextXAlignment = Enum.TextXAlignment.Center

        local sw = switch(row, false, function(v)
            skillOf(S.mode, key).on = v
            save()
        end)
        sw.Frame.AnchorPoint = Vector2.new(1, 0.5)
        sw.Frame.Position = UDim2.new(1, -12, 0.5, 0)

        skillRows[key] = { Switch = sw, Box = cdBox }
    end
end

refreshSkills = function()
    if UI.SkillMode then UI.SkillMode.Text = "Equipamento: " .. S.mode end
    for _, key in ipairs(KEYS) do
        local sk = skillOf(S.mode, key)
        skillRows[key].Switch.Set(sk.on)
        skillRows[key].Box.Text = tostring(sk.cd)
    end
end

------------------------------------------------------------------------
-- Aba Config
------------------------------------------------------------------------
local listening -- { field, btn } enquanto espera uma tecla nova

local function keybindRow(parent, text, field)
    local row = mk("Frame", { Size = UDim2.new(1, 0, 0, 38), BackgroundColor3 = C.card, LayoutOrder = nextOrd() }, parent)
    corner(row, 8)
    lbl(row, text, 13, C.text, nil, nil, { Position = UDim2.new(0, 12, 0, 0), Size = UDim2.new(1, -140, 1, 0) })
    local b
    b = smallButton(row, S.keys[field], 112, function()
        if listening and listening.btn ~= b then listening.btn.Text = S.keys[listening.field] end
        listening = { field = field, btn = b }
        b.Text = "aperte a tecla..."
    end)
    b.AnchorPoint = Vector2.new(1, 0.5)
    b.Position = UDim2.new(1, -12, 0.5, 0)
    return b
end

do
    local pg = pages.Config
    sectionTitle(pg, "Atalhos", "Clique no botão e aperte a tecla. Esc cancela.")
    keybindRow(pg, "Esconder / mostrar menu", "menu")
    keybindRow(pg, "Iniciar / pausar / retomar", "toggle")

    sectionTitle(pg, "Entrada", "Padrão: tudo vai direto ao jogo, sem usar seu mouse nem teclado.")
    toggleRow(pg, "Mouse/teclado virtual (reserva)", "Ligado: pode mover seu cursor e travar o chat", S.useVim, function(v)
        S.useVim = v
        save()
    end)

    sectionTitle(pg, "Diagnóstico", "Se algo não funcionar, gere o relatório e cole no chat.")
    local dbtn = mk("TextButton", { Text = "GERAR DIAGNÓSTICO", Font = Enum.Font.GothamBold, TextSize = 12,
        TextColor3 = C.text, AutoButtonColor = false, Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = C.card,
        LayoutOrder = nextOrd() }, pg)
    corner(dbtn, 8)
    stroke(dbtn, C.stroke, 1, 0.2)
    hover(dbtn, C.card, C.stroke)
    track(dbtn.MouseButton1Click:Connect(function() task.spawn(runDiagnostic) end))

    local sbtn = mk("TextButton", { Text = "ESPIONAR REMOTES (10 s) · ataque e use skills na mão", Font = Enum.Font.GothamBold,
        TextSize = 11, TextColor3 = C.text, AutoButtonColor = false, Size = UDim2.new(1, 0, 0, 34),
        BackgroundColor3 = C.card, LayoutOrder = nextOrd() }, pg)
    corner(sbtn, 8)
    stroke(sbtn, C.stroke, 1, 0.2)
    hover(sbtn, C.card, C.stroke)
    track(sbtn.MouseButton1Click:Connect(function()
        if startSpy(10) then
            setStatus("Espionando 10 s: ataque e use as skills na mão agora", "run")
            task.delay(10.5, function() runDiagnostic() end)
        end
    end))

    local info = mk("Frame", { Size = UDim2.new(1, 0, 0, 52), BackgroundColor3 = C.card, LayoutOrder = nextOrd() }, pg)
    corner(info, 8)
    UI.InfoKeys = lbl(info, "", 12, C.text, Enum.Font.Gotham, nil,
        { Position = UDim2.new(0, 12, 0, 8), Size = UDim2.new(1, -24, 0, 16) })
    lbl(info, "Tudo é salvo sozinho (noctis_autoboss.json).", 11, C.sub, Enum.Font.Gotham, nil,
        { Position = UDim2.new(0, 12, 0, 28), Size = UDim2.new(1, -24, 0, 16) })

    local unl = mk("TextButton", { Text = "DESCARREGAR SCRIPT", Font = Enum.Font.GothamBold, TextSize = 12,
        TextColor3 = C.text, AutoButtonColor = false, Size = UDim2.new(1, 0, 0, 36), BackgroundColor3 = C.panel,
        LayoutOrder = nextOrd() }, pg)
    corner(unl, 8)
    stroke(unl, C.red, 1, 0.4)
    hover(unl, C.panel, C.card)
    UI.UnloadBtn = unl
end

------------------------------------------------------------------------
-- Rodapé
------------------------------------------------------------------------
local footer = mk("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0),
    Size = UDim2.new(1, 0, 0, 76), BackgroundColor3 = C.panel, BorderSizePixel = 0 }, body)
mk("Frame", { Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = C.stroke, BorderSizePixel = 0 }, footer)
UI.Dot = mk("Frame", { Size = UDim2.fromOffset(8, 8), Position = UDim2.new(0, 16, 0, 22), BackgroundColor3 = C.gray }, footer)
corner(UI.Dot, 4)
UI.Status = lbl(footer, S.status, 12, C.text, Enum.Font.GothamMedium, nil,
    { Position = UDim2.new(0, 32, 0, 14), Size = UDim2.new(1, -250, 0, 24) })
UI.Hint = lbl(footer, "", 10, C.sub, Enum.Font.Gotham, nil,
    { Position = UDim2.new(0, 32, 0, 40), Size = UDim2.new(1, -250, 0, 14) })

-- o gradiente fica num fundo separado: num TextButton ele pintaria o texto da mesma cor e o sumiria
UI.RunBg = mk("Frame", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0.5, 0),
    Size = UDim2.fromOffset(118, 44), BackgroundColor3 = Color3.new(1, 1, 1) }, footer)
corner(UI.RunBg, 10)
UI.RunGrad = mk("UIGradient", { Color = ColorSequence.new(C.red, C.amber), Rotation = 20 }, UI.RunBg)
UI.Run = mk("TextButton", { Text = "INICIAR", Font = Enum.Font.GothamBlack, TextSize = 14, TextColor3 = Color3.new(1, 1, 1),
    AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 2 }, UI.RunBg)

UI.Stop = mk("TextButton", { Text = "PARAR", Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = C.text,
    AutoButtonColor = false, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -140, 0.5, 0),
    Size = UDim2.fromOffset(80, 44), BackgroundColor3 = C.card, Visible = false }, footer)
corner(UI.Stop, 10)
stroke(UI.Stop, C.stroke, 1, 0.2)
hover(UI.Stop, C.card, C.stroke)

refreshRun = function()
    if not S.running then
        UI.Run.Text = "INICIAR"
        UI.RunGrad.Color = ColorSequence.new(C.red, C.amber)
    elseif S.paused then
        UI.Run.Text = "RETOMAR"
        UI.RunGrad.Color = ColorSequence.new(C.red, C.amber)
    else
        UI.Run.Text = "PAUSAR"
        UI.RunGrad.Color = ColorSequence.new(Color3.fromRGB(70, 74, 96), Color3.fromRGB(46, 50, 68))
    end
    UI.Stop.Visible = S.running
end

updateHint = function()
    local k = S.keys
    if UI.Hint then UI.Hint.Text = k.menu .. " menu · " .. k.toggle .. " iniciar/pausar" end
    if UI.InfoKeys then UI.InfoKeys.Text = k.menu .. " esconde/mostra · " .. k.toggle .. " inicia/pausa/retoma" end
end

track(UI.Run.MouseButton1Click:Connect(toggle))
track(UI.Stop.MouseButton1Click:Connect(function() stopBot("Parado") end))

------------------------------------------------------------------------
-- Minimizar / fechar / atalhos
------------------------------------------------------------------------
local minimized = false
track(btnMin.MouseButton1Click:Connect(function()
    minimized = not minimized
    body.Visible = not minimized
    accent.Visible = not minimized
    TweenService:Create(main, TweenInfo.new(0.16), { Size = UDim2.fromOffset(W, minimized and 52 or H) }):Play()
end))

local function unload()
    S.running, S.paused, S.fighting, S.boss = false, false, false, nil
    pcall(function() RunService:UnbindFromRenderStep("NoctisAim") end)
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    conns = {}
    pcall(function() gui:Destroy() end)
    ENV.NOCTIS_UNLOAD = nil
end
ENV.NOCTIS_UNLOAD = unload

track(btnClose.MouseButton1Click:Connect(unload))
track(UI.UnloadBtn.MouseButton1Click:Connect(unload))

track(UIS.InputBegan:Connect(function(i, gp)
    if i.UserInputType ~= Enum.UserInputType.Keyboard then return end
    local name = i.KeyCode.Name

    -- capturando tecla nova para um atalho
    if listening then
        local l = listening
        listening = nil
        if i.KeyCode == Enum.KeyCode.Escape or i.KeyCode == Enum.KeyCode.Unknown then
            l.btn.Text = S.keys[l.field]
        elseif RESERVED[name] then
            l.btn.Text = S.keys[l.field]
            setStatus(name .. " é usada pelo ataque/skills, escolha outra tecla", "err")
        else
            S.keys[l.field] = name
            l.btn.Text = name
            save()
            updateHint()
        end
        return
    end

    if gp then return end  -- digitando no chat / outro campo de texto
    if name == S.keys.menu then
        gui.Enabled = not gui.Enabled
    elseif name == S.keys.toggle then
        toggle()
    end
end))

local cam0 = workspace.CurrentCamera
if cam0 then track(cam0:GetPropertyChangedSignal("ViewportSize"):Connect(fit)) end

------------------------------------------------------------------------
-- Início
------------------------------------------------------------------------
updateHint()
refreshSkills()
refreshRun()
showTab("Sala")
setStatus("Pronto · " .. S.keys.toggle .. " inicia", "idle")