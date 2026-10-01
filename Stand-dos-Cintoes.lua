-- StandCore: the Giorgio TSB stand with no Giorgio around it.
--
-- Built by standcore/build.py from the SAME source Giorgio ships
-- (giorgio/tsb-stand.lua plus the TSB adapter lifted from tsb-ragebot.lua), so
-- the two never drift. This prelude stands in for the handful of framework
-- pieces the stand leans on (L, K, R, T); the epilogue publishes a small API
-- at getgenv().StandCore for any interface -- or none -- to drive.
--
-- Optional, set before running:
--   getgenv().StandConfig = { owner = "TheirUsername", prefix = ".", speak = true }
do
  local previous = rawget(getgenv(), "StandCore")
  if type(previous) == "table" and type(previous.unload) == "function" then pcall(previous.unload) end
end

local Players = game:GetService("Players")
local LP = Players.LocalPlayer
local HttpService = game:GetService("HttpService")

local Core = { version = "1.0.0", events = {} }
getgenv().StandCore = Core

-- A listener list per event name. An interface subscribes; nothing here waits
-- on it, and a listener that errors is dropped from that call only.
function Core.on(event, fn)
  local list = Core.events[event]
  if not list then list = {}; Core.events[event] = list end
  list[#list + 1] = fn
  return { Disconnect = function()
    local at = table.find(list, fn)
    if at then table.remove(list, at) end
  end }
end
local function emit(event, ...)
  local list = Core.events[event]
  if not list then return end
  for _, fn in ipairs(table.clone(list)) do pcall(fn, ...) end
end
Core.emit = emit

-- ---------------------------------------------------------------- L
local alive = true
local conns, cleanups, renderBinds, owned = {}, {}, {}, {}
local L = { RunService = game:GetService("RunService"), UIS = game:GetService("UserInputService") }
function L.live() return alive end
function L.hold(conn) conns[#conns + 1] = conn; return conn end
function L.cleanup(fn, order) cleanups[#cleanups + 1] = { fn = fn, order = order or 100 } end
function L.bind(name, priority, fn)
  L.RunService:BindToRenderStep(name, priority, fn)
  renderBinds[#renderBinds + 1] = name
end
function L.note(tag, message) emit("note", tag, message) end
local faultAt = {}
function L.fault(label, err)
  -- A fault inside the frame loop repeats every frame; one line a second each.
  local now = os.clock()
  if faultAt[label] and now - faultAt[label] < 1 then return end
  faultAt[label] = now
  warn("[StandCore] " .. tostring(label) .. ": " .. tostring(err))
  emit("fault", label, err)
end
function L.own(inst) owned[#owned + 1] = inst; return inst end
function L.mk(class, props)
  local inst = Instance.new(class)
  local parent
  for key, value in pairs(props or {}) do
    if key == "Parent" then parent = value else inst[key] = value end
  end
  if parent then inst.Parent = parent end
  return inst
end
L.Toast = { warn = function(title, message) emit("toast", title, message) end }

-- Settings live in the executor's workspace, one JSON file. Writes are batched:
-- a dragged slider saves once, half a second after it stops.
-- One file PER ACCOUNT. Several stands run on one PC and share one executor
-- workspace: with a single file, every stand loaded whatever the last one (or a
-- GUI session on another account) had saved -- live, a 4040-stud hide depth and
-- an Arc fan left over from a baseplate test. Keyed by user id, never by name.
local Cfg = { DIR = "StandCore", PATH = "StandCore/" .. tostring(LP.UserId) .. ".json", data = {}, dirty = false }
pcall(function()
  if isfile(Cfg.PATH) then
    local decoded = HttpService:JSONDecode(readfile(Cfg.PATH))
    if type(decoded) == "table" then Cfg.data = decoded end
  end
end)
function Cfg.save()
  Cfg.dirty = false
  pcall(function()
    if not isfolder(Cfg.DIR) then makefolder(Cfg.DIR) end
    writefile(Cfg.PATH, HttpService:JSONEncode(Cfg.data))
  end)
end
-- What a fresh executor runs with: the lines above the loadstring in
-- standcore/loader.lua, baked in here by the build. So a bare loadstring with
-- only the host set runs exactly the config the loader spells out, and so does
-- everyone else. A saved setting or a _G line still wins over these.
local DEFAULTS = { PREFIX = ".", MESSAGES = false, GUI = false, BLACK_SCREEN = true, ANTI_AFK = true, HUNT_DISTANCE = 7.4, HUNT_FROM = "Behind", MAX_STANDS = 4, YIELD = true, HUNT_WITHOUT_HOST = true, FOLLOW_SPEED = 1, OFFSET_RIGHT = 3, OFFSET_UP = 2.5, OFFSET_BACK = 4, ASSETS = "https://raw.githubusercontent.com/Mrzaytoon/stand-dos-cintoes/main/StandDosCintoes/" }
local HOUSE = {}
Core.defaults = DEFAULTS
function Cfg.feat(id, default)
  local value = Cfg.data[id]
  if value == nil then value = HOUSE[id] end
  if value == nil then return default end
  return value
end
function Cfg.setFeat(id, value)
  Cfg.data[id] = value
  if not Cfg.dirty then
    Cfg.dirty = true
    task.delay(0.5, function() if Cfg.dirty then Cfg.save() end end)
  end
  emit("setting", id, value)
end
L.Cfg = Cfg

-- A launcher's StandConfig seeds settings once, before the stand reads them.
do
  local seed = rawget(getgenv(), "StandConfig")
  if type(seed) == "table" then
    if type(seed.owner) == "string" then Cfg.data["stand.owner"] = seed.owner end
    if type(seed.prefix) == "string" then Cfg.data["stand.prefix"] = seed.prefix end
    if type(seed.speak) == "boolean" then Cfg.data["stand.speak"] = seed.speak end
  end
end

-- The executor config, the way a loadstring script is set up:
--   _G.HOST_USERNAME = "YourMainAccount"   _G.HUNT_DISTANCE = 7.4   ...
--   loadstring(game:HttpGet("<raw url>"))()
-- Every key is optional and wins over the saved settings each time it is set,
-- so the lines above the loadstring are always what runs. Read from _G first
-- and getgenv() second, so either style works. Wrong types are ignored and
-- listed, never half-applied.
Core.config, Core.configProblems = {}, {}
do
  local function read(key)
    local v = rawget(_G, key)
    if v == nil then v = rawget(getgenv(), key) end
    return v
  end
  -- key -> { saved setting, expected type }
  local KEYS = {
    HOST_USERNAME = { "owner", "string" }, OWNER = { "owner", "string" },
    PREFIX = { "prefix", "string" }, MESSAGES = { "speak", "boolean" },
    OFFSET_RIGHT = { "pose.Idle.x", "number" }, OFFSET_UP = { "pose.Idle.y", "number" }, OFFSET_BACK = { "pose.Idle.z", "number" },
    STANCE = { "stance", "string" }, FLOAT = { "float", "number" }, FOLLOW_SPEED = { "followSpeed", "number" },
    ORBIT = { "orbit", "boolean" }, ORBIT_SPEED = { "orbitSpeed", "number" }, ORBIT_HEIGHT = { "orbitHeight", "number" },
    HUNT_DISTANCE = { "huntDistance", "number" }, HUNT_FROM = { "approach.preset", "string" },
    MAX_STANDS = { "maxHunters", "number" }, YIELD = { "yield", "boolean" }, HUNT_WITHOUT_HOST = { "huntAlone", "boolean" },
    VOID_CARRY = { "combo", "boolean" }, DASH = { "dashSpam", "boolean" }, SKILLS = { "useSkills", "boolean" },
    M1 = { "useM1", "boolean" }, AUTO_ULT = { "autoUlt", "boolean" }, CAMERA = { "camera", "boolean" },
    DEEP_HIDE = { "hideDeep", "boolean" }, LOW_HP = { "lowHP", "number" }, SQUAD = { "squad.on", "boolean" },
  }
  local PRESETS = { "Behind", "Behind left", "Behind right", "Left flank", "Right flank", "In front", "Above", "Below", "Point blank" }
  for key, spec in pairs(KEYS) do
    local shipped = DEFAULTS[key]
    if type(shipped) == spec[2] then HOUSE["stand." .. spec[1]] = shipped end
    local v = read(key)
    if v ~= nil then
      if spec[2] == "number" and type(v) == "string" then v = tonumber(v) or v end
      if type(v) == spec[2] then
        Cfg.data["stand." .. spec[1]] = v
        Core.config[key] = v
      else
        Core.configProblems[#Core.configProblems + 1] = string.format("%s should be a %s, got %s", key, spec[2], typeof(v))
      end
    end
  end
  -- the distance applies to a hand-tuned ("Custom") angle too, not only presets
  if type(DEFAULTS.HUNT_DISTANCE) == "number" then HOUSE["stand.approach.radius"] = DEFAULTS.HUNT_DISTANCE end
  if type(Core.config.HUNT_DISTANCE) == "number" then Cfg.data["stand.approach.radius"] = Core.config.HUNT_DISTANCE end
  -- The interface's own switches, read by the API below. BLACK_SCREEN keeps its
  -- own default (on for an alt: a host is set and it is not this account)
  -- unless the loader ships it off.
  for _, key in ipairs({ "GUI", "ASSETS", "NOTIFY", "BLACK_SCREEN", "ANTI_AFK" }) do
    local v = read(key)
    if v == nil and (key ~= "BLACK_SCREEN" or DEFAULTS[key] == false) then v = DEFAULTS[key] end
    Core.config[key] = v
  end
  -- HUNT_FROM is a preset name: accept any letter case
  for _, name in ipairs(PRESETS) do
    local shipped, from = DEFAULTS.HUNT_FROM, Core.config.HUNT_FROM
    if type(shipped) == "string" and name:lower() == shipped:lower() then HOUSE["stand.approach.preset"] = name end
    if type(from) == "string" and name:lower() == from:lower() then Cfg.data["stand.approach.preset"] = name end
  end
end

-- ---------------------------------------------------------------- K, R, T
-- No Rep Root fling engine here: fling assist reports that and does nothing.
local K = { whitelist = {}, cfg = {}, flinging = false }
local R = { repRoot = true, fling = false, voidOriginal = workspace.FallenPartsDestroyHeight }
function R.validPosition(v)
  return v.X == v.X and v.Y == v.Y and v.Z == v.Z
    and math.abs(v.X) < math.huge and math.abs(v.Y) < math.huge and math.abs(v.Z) < math.huge
end
function R.runOne() return false, "StandCore has no Rep Root fling" end
local T = { c = { accent = Color3.fromRGB(255, 196, 92) } }
local C = nil -- no Giorgio interface; S.build is never called here

Core._internal = { L = L, K = K, R = R, T = T, Cfg = Cfg, conns = conns, cleanups = cleanups,
  renderBinds = renderBinds, owned = owned, setAlive = function(v) alive = v end }

do -- tsb movement adapter
local RS=L.RunService
local TSB={PLACE=10449761463,cfg={enabled=false,healthGuard=true}}
R.TSB=TSB
function TSB.supported() return game.PlaceId==TSB.PLACE end
local Void = { wanted = false, fn = nil, char = nil, born = setmetatable({}, { __mode = "k" }),
  method = "off", hookInstalled = false, hookArmed = false, fpdhOwned = false }
TSB.Void = Void
local KILL_LINE, GATE_INDEX = 6308, 40

function Void.locate(char)
  if not char or type(getconnections) ~= "function" or type(debug.getupvalue) ~= "function"
    or type(debug.setupvalue) ~= "function" or type(debug.info) ~= "function" then return nil end
  local ok, list = pcall(getconnections, RS.Heartbeat)
  if not ok or type(list) ~= "table" then return nil end
  for _, connection in ipairs(list) do
    local fn = connection.Function
    if type(fn) == "function" and (type(islclosure) ~= "function" or islclosure(fn)) then
      local okSource, source = pcall(debug.info, fn, "s")
      local okLine, line = pcall(debug.info, fn, "l")
      if okSource and okLine and line == KILL_LINE and string.find(tostring(source), "CharacterHandler.Client", 1, true) then
        local okChar, first = pcall(debug.getupvalue, fn, 1)
        local okHum, hum = pcall(debug.getupvalue, fn, 2)
        local okGate, gate = pcall(debug.getupvalue, fn, GATE_INDEX)
        if okChar and first == char and okHum and typeof(hum) == "Instance" and hum:IsA("Humanoid")
          and okGate and type(gate) == "boolean" then
          return fn
        end
      end
    end
  end
  return nil
end

-- Fallback when the script layout changes: refuse the kill-plane's Health write
-- while we are below the plane. Measured: blocked every write, no death. The hook
-- is never removed (restorefunction would also strip other scripts' hooks); it is
-- disarmed instead, which makes it a plain pass-through.
function Void.installHook()
  if Void.hookInstalled then Void.hookArmed = true; return true end
  if type(hookmetamethod) ~= "function" or type(checkcaller) ~= "function" then return false end
  local wrap = type(newcclosure) == "function" and newcclosure or function(f) return f end
  local original
  local ok = pcall(function()
    original = hookmetamethod(game, "__newindex", wrap(function(self, key, value)
      if Void.hookArmed and key == "Health" and type(value) == "number" and value <= 0 and not checkcaller() then
        local char = LP.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        local root = hum and hum.RootPart
        if self == hum and root and root.Position.Y < -490 then return end
      end
      return original(self, key, value)
    end))
  end)
  Void.hookInstalled = ok and original ~= nil
  Void.hookArmed = Void.hookInstalled
  return Void.hookInstalled
end

function Void.fpdhSafe()
  local floor = workspace.FallenPartsDestroyHeight
  return floor ~= floor
end

function Void.tick()
  if not Void.wanted then return end
  if not Void.fpdhSafe() then
    Void.fpdhOwned = pcall(function() workspace.FallenPartsDestroyHeight = 0 / 0 end) or Void.fpdhOwned
  end
  local char = LP.Character
  if not char then Void.method = "off"; return end
  if Void.char ~= char then Void.char, Void.fn, Void.method = char, nil, "pending" end
  local born = Void.born[char]
  -- The game opens the gate 2 s after spawn; closing it earlier gets overwritten.
  if born and os.clock() - born < 2.3 then return end
  if not Void.fn then Void.fn = Void.locate(char) end
  if Void.fn then
    local ok, gate = pcall(debug.getupvalue, Void.fn, GATE_INDEX)
    if ok and gate ~= false then pcall(debug.setupvalue, Void.fn, GATE_INDEX, false) end
    ok, gate = pcall(debug.getupvalue, Void.fn, GATE_INDEX)
    if ok and gate == false then Void.method = "gate"; Void.hookArmed = false; return end
  end
  if TSB.cfg.healthGuard ~= false and Void.installHook() then Void.method = "hook" else Void.method = "unprotected" end
end

-- True only when a verified mechanism will keep us alive below Y -500. The gate is
-- re-read live: a cached "closed" could be stale if the game reopened it since.
function Void.safe()
  if not Void.wanted or not Void.fpdhSafe() or Void.char ~= LP.Character then return false end
  if Void.method == "hook" then return Void.hookInstalled and Void.hookArmed end
  if Void.method ~= "gate" or not Void.fn then return false end
  local ok, gate = pcall(debug.getupvalue, Void.fn, GATE_INDEX)
  return ok and gate == false
end

-- The lowest Y we may write our own root to right now.
function Void.floor()
  return Void.safe() and -1e4 or -480
end

function Void.set(on)
  Void.wanted = on == true
  if Void.wanted then Void.tick(); return true end
  Void.hookArmed = false
  if Void.fn and Void.char and Void.char.Parent then pcall(debug.setupvalue, Void.fn, GATE_INDEX, true) end
  Void.fn, Void.char, Void.method = nil, nil, "off"
  if Void.fpdhOwned and not R.voidGuard then
    pcall(function() workspace.FallenPartsDestroyHeight = R.voidOriginal end)
  end
  Void.fpdhOwned = false
  return true
end

-- A character that existed before load has an unknown spawn time; tick() closes its
-- gate at once and re-closes it if the game's 2 s delay reopens it afterwards.
L.hold(LP.CharacterAdded:Connect(function(char) Void.born[char] = os.clock() end))

local Game = {}
TSB.Game = Game
Game.BLOCKERS = { "Counter", "HunterCounter", "AtomicCounter" }
-- A grab in progress. Measured 2026-09-24: when a Hunter grab connects the
-- victim's model gains BeingGrabbed, RootAnchor, NoRotate, Freeze and a
-- ForceField together, and loses them together when it lets go. It is NOT a
-- counter: BeingGrabbed used to sit in BLOCKERS, which made the stand back off
-- from its own grab -- exactly the window it wants to act in.
Game.GRABS = { "BeingGrabbed", "RootAnchor" }

function Game.body(player)
  local live = workspace:FindFirstChild("Live")
  local model = (live and live:FindFirstChild(player.Name)) or player.Character
  local hum = model and model:FindFirstChildOfClass("Humanoid")
  local root = hum and hum.RootPart or (model and model:FindFirstChild("HumanoidRootPart"))
  return model, hum, root
end

local function finiteVector(v)
  return v and v.X == v.X and v.Y == v.Y and v.Z == v.Z
    and math.abs(v.X) < 1e7 and math.abs(v.Y) < 1e7 and math.abs(v.Z) < 1e7
end
Game.finite = finiteVector

-- One read of everything the brain cares about for one player.
function Game.read(player)
  local model, hum, root = Game.body(player)
  local s = { player = player, model = model, hum = hum, root = root }
  if not model or not hum or not root or not root.Parent then s.gone = true; return s end
  s.health, s.maxHealth = hum.Health, math.max(hum.MaxHealth, 1)
  s.alive = s.health > 0 and not hum:GetAttribute("Dead")
  s.position = root.Position
  s.valid = finiteVector(s.position)
  s.forceField = model:FindFirstChildWhichIsA("ForceField") ~= nil
  s.immortal = model:FindFirstChild("AbsoluteImmortal") ~= nil
  s.ragdoll = model:FindFirstChild("Ragdoll") ~= nil or model:FindFirstChild("RagdollSim") ~= nil
  s.frozen = model:FindFirstChild("Freeze") ~= nil
  s.blocking = model:GetAttribute("Blocking") == true
  s.ulted = model:GetAttribute("Ulted") ~= nil and model:GetAttribute("Ulted") ~= false
  s.npc = model:GetAttribute("NPC") == true
  s.kit = model:GetAttribute("Character")
  s.lastHit = model:GetAttribute("LastHit")
  for _, name in ipairs(Game.BLOCKERS) do
    if model:FindFirstChild(name) then s.countering = true; break end
  end
  for _, name in ipairs(Game.GRABS) do
    if model:FindFirstChild(name) then s.grabbed = true; break end
  end
  s.seated = hum.Sit
  s.anchored = root.Anchored
  return s
end

-- Hotbar slots as the player sees them: tool name and whether it is cooling down.
function Game.hotbar()
  local slots = {}
  local gui = LP:FindFirstChildOfClass("PlayerGui")
  local bar = gui and gui:FindFirstChild("Hotbar")
  bar = bar and bar:FindFirstChild("Backpack")
  bar = bar and bar:FindFirstChild("Hotbar")
  for index = 1, 4 do
    local slot = bar and bar:FindFirstChild(tostring(index))
    local base = slot and slot:FindFirstChild("Base")
    local label = base and base:FindFirstChild("ToolName")
    local name = label and label:IsA("TextLabel") and label.Text or nil
    local cooldown = base and base:FindFirstChild("Cooldown")
    slots[index] = { index = index, name = (name and name ~= "") and name or nil, cooling = cooldown ~= nil,
      remaining = cooldown and cooldown:IsA("GuiObject") and math.clamp(-cooldown.Size.Y.Scale, 0, 1) or 0 }
  end
  return slots
end

function Game.tool(name)
  if not name then return nil end
  for _, holder in ipairs({ LP:FindFirstChildOfClass("Backpack"), LP.Character }) do
    if holder then
      for _, tool in ipairs(holder:GetChildren()) do
        if tool:IsA("Tool") and (tool:GetAttribute("Name") == name or tool.Name == name) then return tool end
      end
    end
  end
  return nil
end

function Game.ultimateReady()
  local value = LP:GetAttribute("Ultimate")
  return type(value) == "number" and value >= 100
end

function Game.killCount()
  local value = LP:GetAttribute("Kills")
  if type(value) == "number" then return value end
  local stats = LP:FindFirstChild("leaderstats")
  local stat = stats and (stats:FindFirstChild("Kills") or stats:FindFirstChild("Total Kills"))
  return stat and tonumber(stat.Value) or 0
end

-- ---------------------------------------------------------------- the wire
-- Everything the game's own input handler sends, with MousePos always filled in.
local Wire = { budget = 0, stamp = 0 }
TSB.Wire = Wire
local KEYS = { Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four }
Wire.KEYS = KEYS

function Wire.fire(payload)
  local now = os.clock()
  if now - Wire.stamp >= 1 then Wire.stamp, Wire.budget = now, 0 end
  if Wire.budget >= 45 then return false end -- hard ceiling; the game never needs more
  local model = Game.body(LP)
  local remote = model and model:FindFirstChild("Communicate")
  if not remote then return false end
  Wire.budget += 1
  return (pcall(remote.FireServer, remote, payload))
end

function Wire.aim(part)
  return part and CFrame.new(part.Position) or CFrame.new()
end

function Wire.press(key, aim, extra)
  local payload = { Goal = "KeyPress", Key = key, MousePos = aim }
  if extra then for k, v in pairs(extra) do payload[k] = v end end
  return Wire.fire(payload)
end

function Wire.release(key)
  return Wire.fire({ Goal = "KeyRelease", Key = key })
end

-- A hotbar move. On keyboard the game's number key only EQUIPS the tool (the
-- hotbar LocalScript calls Humanoid:EquipTool); a KeyPress alone never runs a
-- move. The gamepad path sends the tool itself, auto-activated, and that is what
-- this sends. Measured 2026-09-23: KeyPress One..Four played no move animation
-- and set no cooldown; this played Shove's animation and put slot 3 on cooldown.
-- CrushingPull is omitted for the same reason as in Wire.m1.
function Wire.skill(index)
  local slot = Game.hotbar()[index]
  local tool = slot and Game.tool(slot.name)
  if not tool then return false end
  pcall(function() tool:SetAttribute("Name", slot.name) end)
  return Wire.fire({ Goal = "Console Move", Tool = tool, IsAutoActivate = true })
end

-- A dash, as the game's own Q handler sends it (captured 2026-09-23): the
-- direction rides in `Dash` as the movement key -- W forward, A/D sideways, S back.
function Wire.dash(direction, aim)
  local ok = Wire.fire({ Goal = "KeyPress", Key = Enum.KeyCode.Q, Dash = direction or Enum.KeyCode.W, MousePos = aim })
  task.delay(0.05, function() if L.live() then Wire.fire({ Goal = "KeyRelease", Key = Enum.KeyCode.Q }) end end)
  return ok
end

function Wire.m1(aim)
  -- A normal M1 the way the game's own input path sends it. ToolName is filled
  -- from the equipped kit so the server runs that kit's swing, not a fist M1.
  -- CrushingPull is deliberately omitted: computing it means calling the game's
  -- shared.GetCrushingPullHit, and running game code from here is what kicked us
  -- in other titles. An empty pull just reads as a plain swing, which is fine for
  -- every kit except Esper's slot-1 special (still lands as a normal M1).
  local char = LP.Character
  local tool = char and char:FindFirstChildOfClass("Tool")
  local payload = { Goal = "LeftClick", MousePos = aim }
  if tool then payload.ToolName = tool:GetAttribute("Name") or tool.Name end
  Wire.fire(payload)
  task.delay(0.08, function() if L.live() then Wire.fire({ Goal = "LeftClickRelease" }) end end)
end

-- The awakening (every kit, key G) takes MoveDirection, never MousePos.
function Wire.ult()
  local _, hum = Game.body(LP)
  local move = (hum and hum.MoveDirection) or Vector3.zero
  return Wire.fire({ Goal = "KeyPress", Key = Enum.KeyCode.G, MoveDirection = move })
end

function TSB.selfReady(me)
  if not me or me.gone or not me.alive then return false end
  if me.frozen or me.ragdoll or me.seated or me.anchored then return false end
  return true
end


end

-- Giorgio TSB Stand tab. Embedded by integrate.py after the TSB adapter, so the
-- addon chunk's locals (L, C, T, K, R, Players, LP) and R.TSB (the game reads and
-- input wire) are already in scope.
--
-- The stand is this client's character. An owner, chosen on the tab, commands it
-- from chat. Every latch -- beside the owner, in front of the owner, behind a
-- target, hidden below the owner -- is a PhysicsRepRootPart binding and nothing
-- else: no BodyPosition, no weld, no world-space CFrame chase.
--
-- MEASURED ON THE RIG (TSB place 10449761463, version 17455, 2026-09-23):
--   * While our root's PhysicsRepRootPart is the anchor's root, every other client
--     sees us at anchorRoot.CFrame * (our root's LOCAL CFrame). Writing the usual
--     world mount (anchor.CFrame * offset) read 0.00 studs locally and 452.9 studs
--     on the owner's screen.
--   * Writing the raw offset as our local CFrame held rel(-3.0, 2.5, 4.0) on the
--     owner's screen at every sample through 240 studs of live walking. The
--     server composes, so there is no follow lag. Rotation composes too.
--   * The binding reads back changed almost every frame (578 rebinds in ~10 s),
--     so it is written every Heartbeat.
--   * Hits resolve at the composed position: an M1 fired while latched in front
--     of the owner took 100 -> 97 HP.
--   * Skills: a KeyPress only equips on keyboard. "Console Move" with the tool
--     runs the move with nothing equipped, latched, accepted in 0.08-0.10 s. A
--     move sent while another is still animating is ignored, so the next one is
--     re-sent until the hotbar shows its Cooldown marker.
--   * M1 fired the instant M1Ready flips registers at the game's own pace (4 in
--     3 s); faster sends are dropped by the server.
--   * The latched body has no floor under its local position, so it sat in
--     Freefall playing FallAnim (arms up), and that state's flicker kept
--     stopping any pose track. With Freefall held off the humanoid stays in
--     Running, TSB's own Animate plays its idle guard, and a pose track played
--     10/10 samples with 0 stops. PlatformStand is off by default: it stops both.
-- Consequence: our LOCAL body sits at the raw pose coordinates, near the world
-- origin, while everyone else sees it on the anchor. The camera stays on the
-- owner and a local marker shows where the stand really is.
--
-- MEASURED ON THE RIG (same place, 2026-09-24), the carry law this file's grab
-- combo rests on. Stand on the Hunter kit, victim the owner's alt:
--   * A grab that connects CARRIES the victim on our composed position. The
--     victim's model gains BeingGrabbed, RootAnchor, NoRotate, Freeze and a
--     ForceField together and loses them together; BeingGrabbed is the edge.
--   * Latching to the owner during a grab delivered the victim from 22 studs
--     away to 8 studs from the owner and held it for the whole grab. That is
--     the bring.
--   * A PACED descent past TSB's own -500 kill plane kills: over one 1.5 s
--     Flowing Water hold the victim's own client read 441 -> 428 -> 309 -> 130
--     -> -215 -> -546 and Died fired at -546. Our own HP never moved.
--   * Snapping the whole distance in one frame does NOT: the carry is slew
--     limited (it tracked at ~900 studs/s), the victim was left behind and put
--     back on the map at release. So the drop is spread across the hold, and
--     the hold is whatever this move has been watched to be.
--   * Hold windows: Flowing Water 1.50-1.64 s, Lethal Whirlwind Stream 0.46 s.
--     A grab connects ~0.59 s after the Console Move is taken.
--   * Our own body survives below -500 only while the ragebot's void gate is
--     closed (measured 100 HP at composed -660), so the deep hide and the void
--     drop both arm it first and quietly stay shallow when they cannot.
--   * Our own client LIES about a carried victim's position -- it draws them
--     beside our local body near the origin, so it read y=0 while their client
--     read y=441. Nothing here judges a carry from our own view of the target;
--     it reads the marker, and checks the outcome only after the release.
do
local RS, UIS = L.RunService, L.UIS or game:GetService("UserInputService")
local TCS = game:GetService("TextChatService")
local shp = rawget(getgenv(), "sethiddenproperty") or rawget(getgenv(), "sethiddenprop")
local ghp = rawget(getgenv(), "gethiddenproperty") or rawget(getgenv(), "gethiddenprop")

local POSE_KEYS = { "x", "y", "z", "pitch", "yaw", "roll" }
local POSE_NAMES = { "Idle", "Front", "Strike", "Hidden", "Bring" }
local POSE_INFO = {
  Idle = "Beside the owner while summoned. Offsets are owner-local.",
  Front = "In front of the owner for commanded skills and the barrage, facing where the owner faces.",
  Strike = "On the target while attacking. Target-local: +Z is behind them; yaw 0 faces their back, 180 faces them. The attack angle above drives these.",
  Hidden = "The void under the owner: dismissed, or waiting for a target to respawn. Deep hide replaces it with its own depth and distance.",
  Bring = "Where a carried player is delivered. Directly in front of the owner and far enough out that the grab's own damage does not reach them -- the stand rides here still holding them, so they land where it lands.",
}
local POSE_DEFAULTS = {
  Idle   = { x = 3, y = 2.5,  z = 4,    pitch = 0, yaw = 0,   roll = 0 },
  Front  = { x = 0, y = 0.1,  z = -5.5, pitch = 0, yaw = 0,   roll = 0 },
  Strike = { x = 0, y = 0,    z = 3,    pitch = 0, yaw = 0,   roll = 0 },
  Hidden = { x = 0, y = -300, z = 0,    pitch = 0, yaw = 0,   roll = 0 },
  -- Straight out in front of the owner. The first version delivered at z -4 and
  -- that was too literal: the grab's finisher damages and knocks down whatever
  -- is around the stand, so the owner was landing inside their own delivery.
  Bring  = { x = 0, y = 0.5,  z = -14,  pitch = 0, yaw = 180, roll = 0 },
}
-- The Strike pose said as an angle around the target. 0 is directly behind them,
-- 90 their right, 180 in front, 270 their left. Rotating the behind-offset
-- (0, h, r) by yaw t gives (r sin t, h, r cos t), and a body turned by that same
-- yaw looks straight back down the offset -- so one number places and aims it.
local APPROACH_NAMES = { "Behind", "Behind left", "Behind right", "Left flank", "Right flank",
  "In front", "Above", "Below", "Point blank", "Custom" }
-- The ring presets stand at the hunt distance; Above, Below and Point blank
-- keep their own. MEASURED 2026-09-30 (Purple kit, victim's HP read from a
-- third client): M1s from 6.1 studs root-to-root landed 3 of 3, and one from
-- 6.8 landed too -- so 6.1 is real reach, with room to spare.
-- New helpers live in one table: the module shares Luau's 200-local limit with
-- whatever chunk embeds it (Giorgio's addon is already large).
local Q = {}
Q.HUNT_DISTANCE = 6.1
local APPROACH_PRESETS = {
  ["Behind"]       = { angle = 0 },
  ["Behind left"]  = { angle = 315 },
  ["Behind right"] = { angle = 45 },
  ["Left flank"]   = { angle = 270 },
  ["Right flank"]  = { angle = 90 },
  ["In front"]     = { angle = 180 },
  ["Above"]        = { angle = 0,   radius = 1.5, height = 5 },
  ["Below"]        = { angle = 0,   radius = 1.5, height = -4 },
  ["Point blank"]  = { angle = 0,   radius = 1,   height = 0 },
}
-- The most stands that hunt one target together; the rest wait beside the
-- owner as backup and step in the moment a hunter leaves or dies.
Q.MAX_HUNTERS = 4
local FACINGS = { "Face them", "Face away" }
local FAN_MODES = { "Ring", "Arc" }
-- The poses a squad shares, and so the ones the fan turns.
local FANNED = { Idle = true, Front = true, Strike = true }
-- The carry. TSB's own CharacterHandler.Client zeroes a player's Health when
-- THEIR root drops below this, which is what a void drop spends.
local KILL_PLANE = -500
local GRAB_WAIT = 1.6           -- a sent grab has this long to take hold
local GRAB_TIMEOUT = 4          -- a grab that could not even be sent is dropped after this
local GRAB_HOLD_DEFAULT = 1.35  -- assumed hold until one has been watched
local CARRY_RATE = { 150, 2500 }
-- The paced rate never goes above what the carry was watched to track: ~900
-- studs/s on the rig, with the lag already ~190 studs at 776. Faster than this
-- the victim is left behind and put back on the map, however short the hold.
local CARRY_SAFE = 900
local GRAB_MARKS = { "BeingGrabbed", "RootAnchor" }
-- Names that give a grab away before we have ever watched one connect. Anything
-- else has to earn the label by actually taking hold of someone.
local GRAB_HINTS = { "grasp", "grab", "flowing water", "snatch", "seize", "choke", "carry", "drag", "head first" }
local GRAB_GIVE_UP = 3          -- hinted move that never holds after this many takes
local BRING_LINGER = 0.3        -- stay at the delivery while the release resolves
local SIDES = {
  right  = { x = 3,  y = 2.5, z = 4 },
  left   = { x = -3, y = 2.5, z = 4 },
  behind = { x = 0,  y = 2,   z = 5 },
  above  = { x = 0,  y = 6,   z = 0.5 },
}
local RANGE = { x = { -40, 40 }, y = { -450, 60 }, z = { -40, 40 },
  pitch = { -180, 180 }, yaw = { -180, 180 }, roll = { -180, 180 } }
-- Our local Y is the pose's Y. TSB's CharacterHandler.Client zeroes Health when
-- the local root drops below Y -500, so nothing we write may go under this.
local SAFE_Y = -450
-- The idle pose. Every id here was load-tested on TSB's own R6 rig on
-- 2026-09-24 and came back with a real length; the ones that are refused to us
-- (Aka Stance, Those Who Know, Take Me On, Superhero) are left out rather than
-- shipped as a stance that silently does nothing. They are the game's own emote
-- idles, read out of ReplicatedStorage.Emotes, so they are looping stances
-- built to be stood in -- unlike the old default, which is TSB's idle guard and
-- is really just a breathing pose with the arms hanging down (measured from the
-- owner's screen: shoulders never leaving -3 to -8 degrees).
local STANCES = { "Perfect Concentration", "The Shadow", "Chosen", "Arms crossed", "Honored",
  "First Rule", "Behold", "Hunter pose", "Ready to strike", "Found you", "By my sword",
  "Shadow", "Into the void", "Fighting stance", "Calm float", "Off", "Custom" }
local STANCE_IDS = {
  ["Perfect Concentration"] = "102959457211902", -- 6.67 s, head bowed, focused
  ["The Shadow"] = "84711944358577",             -- 6.00 s
  ["Chosen"] = "18897538537",                    -- 20.00 s, the longest loop here
  ["Arms crossed"] = "16524243757",              -- 5.50 s ("Cross")
  ["Honored"] = "15503060948",                   -- 5.83 s
  ["First Rule"] = "15503546989",                -- 7.33 s
  ["Behold"] = "121985820220625",                -- 4.17 s
  ["Hunter pose"] = "123794818363362",           -- 2.00 s
  ["Ready to strike"] = "18897713456",           -- 4.50 s ("Attack")
  ["Found you"] = "124365816989281",             -- 3.00 s
  ["By my sword"] = "102174454129081",           -- 4.00 s
  ["Shadow"] = "18897705219",                    -- 1.75 s
  ["Into the void"] = "18459183268",             -- 1.73 s ("Void")
  ["Fighting stance"] = "14516273501",           -- 8.97 s, TSB's own idle guard
  ["Calm float"] = "180435571",                  -- 1.00 s, Roblox's R6 idle
}
-- A new pose reaches the server one physics send later; swing after it has.
local SETTLE = 0.08
local RESEND, GIVE_UP = 0.08, 1.2

local function finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
local function feat(key, default) return L.Cfg.feat("stand." .. key, default) end
local function saveFeat(key, value) L.Cfg.setFeat("stand." .. key, value) end
local function number(key, default, min, max)
  local v = feat(key, default)
  return finite(v) and math.clamp(v, min, max) or default
end
local function flag(key, default)
  local v = feat(key, default)
  if type(v) ~= "boolean" then return default end
  return v
end
local function text(key, default)
  local v = feat(key, default)
  return type(v) == "string" and v or default
end

local S = {
  owner = nil, ownerName = text("owner", ""), prefix = text("prefix", "."),
  listen = flag("listen", true),
  mode = "off",            -- off | summoned | hidden | attacking
  target = nil, engaged = nil, waiting = nil, kills = 0,
  frontUntil = 0, barrage = false, pauseUntil = 0, lowHidden = false,
  requests = {}, pending = nil, rotation = 1,
  poses = {}, editing = "Idle",
  float = number("float", 0.35, 0, 2), upright = flag("upright", true),
  -- A new key: PlatformStand stops TSB's own animations, so the old default of
  -- "on" (saved as stand.hover by the first release) must not carry over.
  hover = flag("platformStand", false), camera = flag("camera", true), preview = flag("preview", true),
  stance = text("stance", "Perfect Concentration"), stanceCustom = text("stanceCustom", ""),
  useSkills = flag("useSkills", true), useM1 = flag("useM1", true), autoUlt = flag("autoUlt", false),
  dashSpam = flag("dashSpam", true), dashGap = number("dashGap", 0.35, 0.2, 3),
  waitShield = flag("waitShield", true), lowHP = number("lowHP", 25, 0, 90),
  -- attack angle, and the fan when several stands share one target
  huntDistance = number("huntDistance", Q.HUNT_DISTANCE, 0.5, 30),
  approach = { angle = number("approach.angle", 0, -180, 360), radius = number("approach.radius", Q.HUNT_DISTANCE, 0.5, 30),
    height = number("approach.height", 0, -20, 20) },
  approachPreset = text("approach.preset", "Behind"), facing = text("approach.facing", "Face them"),
  squadOn = flag("squad.on", true), squadNames = text("squad.names", ""),
  squadAuto = flag("squad.auto", true), fanMode = text("squad.mode", "Ring"),
  squadArc = number("squad.arc", 140, 20, 340), squadGap = number("squad.gap", 45, 10, 180),
  squadSlot = 1, squadCount = 1, squadAt = 0, squadSet = {},
  -- Two rosters, one per anchor: who hunts our target with us (the Strike fan)
  -- and who waits on our owner with us (the Idle wing and the Front line).
  strikeSlot = 1, strikeCount = 1, idleSlot = 1, idleCount = 1, hunters = {}, reserve = false, engageAt = -math.huge,
  maxHunters = number("maxHunters", Q.MAX_HUNTERS, 1, 8),
  -- Step into the void while a squadmate has the prey in a locked frame.
  yieldOn = flag("yield", true), yield = nil, yieldClearAt = 0, lastSkillAt = -math.huge, lastSkillName = nil,
  -- Owner gone (dead, respawning or left): the hunt goes on.
  huntAlone = flag("huntAlone", true), resumeOnReturn = false, ownerStatus = "none",
  -- How fast it glides between spots on one anchor; 1 is an instant snap.
  smooth = number("followSpeed", 1, 0.02, 1),
  orbitOn = flag("orbit", false), orbitSpeed = number("orbitSpeed", 2, -20, 20), orbitHeight = number("orbitHeight", 3, -10, 20),
  previewAngles = flag("previewAngles", true), previewWho = text("previewWho", ""),
  -- the deep hide
  hideDeep = flag("hideDeep", true), hideDepth = number("hideDepth", 900, 60, 1500),  -- MEASURED 2026-09-30: a stand hidden at 4040 died there
  hideAway = number("hideAway", 250, 0, 2000), voidAt = 0, voidReady = false,
  -- the grab carry
  combo = nil, verify = nil, comboOn = flag("combo", true), comboTries = number("comboTries", 3, 1, 8),
  comboEvery = number("comboEvery", 4, 0, 60), lastCombo = -math.huge,
  voidMargin = number("voidMargin", 80, 20, 400), carryRate = number("carryRate", 700, CARRY_RATE[1], CARRY_RATE[2]),
  carryAdapt = flag("carryAdapt", true), voidLinger = number("voidLinger", 0.35, 0, 3),
  grabMoves = {}, grabMisses = {}, carried = 0, comboState = "idle",
  -- Carries spent on one body of one target. It outlives each carry, so the
  -- attempt budget holds however the next grab gets started.
  attempts = { target = nil, body = nil, n = 0 },
  flingAssist = flag("flingAssist", false), flingBelow = number("flingBelow", 40, 1, 100),
  flingEvery = number("flingEvery", 10, 2, 60), flingDrive = number("flingDrive", 1.2, 0.3, 6),
  flingBusy = false, lastFling = -math.huge,
  speak = flag("speak", true),
  lines = {
    summon = text("line.summon", "At your service."),
    dismiss = text("line.dismiss", "Understood."),
    attack = text("line.attack", "Target acquired."),
    done = text("line.done", "Target down."),
    carry = text("line.carry", "Going down."),
    bring = text("line.bring", "Delivered."),
  },
  active = false, anchorRoot = nil, pose = nil, poseSince = 0, blocked = nil,
  lastWorld = nil, lastOwnerFrame = nil,
  lastCommand = "none", controls = {}, sliders = {},
}
if not table.find(STANCES, S.stance) then S.stance = "Fighting stance" end
if not table.find(APPROACH_NAMES, S.approachPreset) then S.approachPreset = "Behind" end
if not table.find(FACINGS, S.facing) then S.facing = "Face them" end
if not table.find(FAN_MODES, S.fanMode) then S.fanMode = "Ring" end
-- What each move has been watched to do, carried across sessions: a hold in
-- seconds for one that took someone, false for a hinted name that never did.
do
  local saved = feat("grabMoves", nil)
  if type(saved) == "table" then
    for name, hold in pairs(saved) do
      if type(name) == "string" and (hold == false or (type(hold) == "number" and hold > 0 and hold < 30)) then
        S.grabMoves[name] = hold
      end
    end
  end
end
R.Stand = S
-- Events for whatever interface is watching (StandCore's API, a future panel).
-- Nothing is hooked inside Giorgio, so this is a no-op there.
local function emit(event, ...)
  local hook = S.hook
  if hook then pcall(hook, event, ...) end
end

for _, name in ipairs(POSE_NAMES) do
  local pose = {}
  for _, key in ipairs(POSE_KEYS) do
    local range = RANGE[key]
    pose[key] = number("pose." .. name .. "." .. key, POSE_DEFAULTS[name][key], range[1], range[2])
  end
  S.poses[name] = pose
end
-- The first release struck from in front, and saved that default verbatim. A
-- Strike pose still exactly at it was never tuned, so it moves to the new
-- default, behind the target; any pose someone actually edited is left alone.
do
  local old, strike = { x = 0, y = 0, z = -3, pitch = 0, yaw = 180, roll = 0 }, S.poses.Strike
  local untouched = true
  for _, key in ipairs(POSE_KEYS) do if strike[key] ~= old[key] then untouched = false end end
  if untouched then
    for _, key in ipairs(POSE_KEYS) do
      strike[key] = POSE_DEFAULTS.Strike[key]
      saveFeat("pose.Strike." .. key, strike[key])
    end
  end
end

-- ---------------------------------------------------------------- players
local function body(player)
  local ch = player and player.Character
  local hum = ch and ch:FindFirstChildOfClass("Humanoid")
  local root = hum and hum.RootPart
  if hum and root and root.Parent and hum.Health > 0 and R.validPosition(root.Position) then
    return ch, hum, root
  end
end

-- ---------------------------------------------------------------- the squad
-- Several stands, one target, and not one message between them. Every stand
-- sees the same server, so each sorts the squad by UserId, finds itself, and
-- takes that slot of the fan. Slot i of n lands on the same angle on every
-- client, and a stand that dies, leaves or joins just re-packs the list on the
-- next scan -- there is no handshake to lose and nothing to replicate. (A
-- client-made instance never reaches another client, so a handshake would have
-- had to go through chat; this needs no channel at all.)
local function squadNameSet()
  local names = {}
  for word in tostring(S.squadNames or ""):gmatch("[^,%s]+") do names[word:lower():gsub("^@", "")] = true end
  return names
end

-- Who else is standing here. MEASURED on the rig 2026-09-27: a root's
-- PhysicsRepRootPart REPLICATES and reads back on another client. From one
-- stand's client the other stand's root read the owner's HumanoidRootPart,
-- while the owner's own root and a stranger's both read nil. So a squadmate is
-- simply anyone latched to the same body we are -- no roster to type, no
-- handshake to lose, and nothing sent between clients at all.
local function latchedTo(player)
  if type(ghp) ~= "function" then return nil end
  local _, _, root = body(player)
  if not root then return nil end
  local ok, value = pcall(ghp, root, "PhysicsRepRootPart")
  if ok and typeof(value) == "Instance" then return value end
  return nil
end

-- When each squadmate was last seen latched to our target. A hunter that steps
-- into the void for a moment (yielding to a squadmate's locked move, or waiting
-- out a respawn) keeps its slot for a few seconds, so the stands still on the
-- target never re-pack under it: re-packing moves a stand, and moving a stand
-- that is holding someone drags the victim along with it.
Q.seenOnTarget = setmetatable({}, { __mode = "k" })
Q.hunterAnchor = setmetatable({}, { __mode = "k" })
Q.GRACE, Q.ENGAGE = 4, 1.5

-- Two rosters, one per anchor. The Strike fan counts who hunts OUR target
-- (latched to it now, or within the grace); the Idle wing and the Front line
-- count who waits on OUR owner. Counting everyone for both used to turn a lone
-- hunter to the front of its target just because another stand was idling
-- beside the owner. For the first moments of an engagement the stands still on
-- the owner count as hunters too: every stand hears one command in the same
-- frame and switches together, so that is who is about to arrive.
local function refreshSquad()
  if not S.squadOn then
    S.squadSlot, S.squadCount, S.squadSet, S.reserve = 1, 1, {}, false
    S.strikeSlot, S.strikeCount, S.idleSlot, S.idleCount, S.hunters = 1, 1, 1, 1, {}
    table.clear(Q.hunterAnchor)
    return
  end
  local names = squadNameSet()
  local _, _, ownerRoot = body(S.owner)
  local _, _, targetRoot = nil, nil, nil
  if S.mode == "attacking" then _, _, targetRoot = body(S.target) end
  local now = os.clock()
  local engaging = now - S.engageAt < Q.ENGAGE
  local set, strike, idle = {}, { LP }, { LP }
  table.clear(Q.hunterAnchor)
  for _, p in ipairs(Players:GetPlayers()) do
    if p ~= LP and p ~= S.owner then
      local named = names[p.Name:lower()] == true
      local anchor = S.squadAuto and latchedTo(p) or nil
      local onOwner = anchor ~= nil and anchor == ownerRoot
      local onTarget = anchor ~= nil and anchor == targetRoot
      if onTarget then Q.seenOnTarget[p] = now; Q.hunterAnchor[p] = anchor; Q.watchMate(p) end
      local recent = Q.seenOnTarget[p] ~= nil and now - Q.seenOnTarget[p] < Q.GRACE and (onOwner or onTarget)
      if named or onOwner or onTarget or (anchor ~= nil and anchor == S.anchorRoot) then set[p] = true end
      if named or onTarget or recent or (engaging and onOwner) then strike[#strike + 1] = p end
      if named or onOwner then idle[#idle + 1] = p end
    end
  end
  local function byId(a, b) return a.UserId < b.UserId end
  table.sort(strike, byId)
  table.sort(idle, byId)
  local index = table.find(strike, LP) or 1
  local hunting = math.max(math.min(#strike, S.maxHunters), 1)
  local wasReserve = S.reserve
  S.reserve = S.mode == "attacking" and index > S.maxHunters
  -- A stand inside its own locked move keeps its slot until the move ends:
  -- its composed position IS where its victim is being held.
  if not S.slotFrozen then S.strikeSlot, S.strikeCount = math.min(index, hunting), hunting end
  S.idleSlot, S.idleCount = table.find(idle, LP) or 1, math.max(#idle, 1)
  S.hunters, S.squadSet = strike, set
  if S.mode == "attacking" then S.squadSlot, S.squadCount = S.strikeSlot, S.strikeCount
  else S.squadSlot, S.squadCount = S.idleSlot, S.idleCount end
  if S.reserve ~= wasReserve then emit("squad", S.reserve and "reserve" or "hunting") end
  local sig = (S.mode == "attacking" and "h" or "i") .. S.squadCount .. "/" .. S.squadSlot
  if sig ~= S.squadSig then
    S.squadSig = sig
    emit("squad", "roster")
  end
end

-- Slot i of n, fanned across the arc and centred on the chosen angle. Stands
-- packed closer than the minimum gap widen the fan instead of overlapping, so
-- two of them never end up inside each other's swing; the fan never closes the
-- full circle, so the first and last are not on top of each other either.
local function spread(slot, count)
  if not S.squadOn or count <= 1 then return 0 end
  if S.fanMode == "Ring" then
    -- Round the prey, turned from the chosen angle (behind by default). Two
    -- stands take its sides -- one on its right, one on its left (the user's
    -- call, 2026-09-30: nobody stands in front of the prey's own swings).
    -- Three take the back and both sides; four take all four quarters.
    if count == 2 then return slot == 1 and 90 or -90 end
    if count == 3 then return ({ 0, 90, -90 })[slot] or 0 end
    return 360 * (slot - 1) / count
  end
  -- Arc: everyone stays near the chosen angle, fanned out just far enough not
  -- to share a swing. Better when you want them all behind the target.
  local arc = math.clamp(math.max(S.squadArc, S.squadGap * (count - 1)), 0, 360 - 360 / count)
  return arc * ((slot - 1) / (count - 1) - 0.5)
end
S.spread = spread

local function excluded(player)
  if K.whitelist and K.whitelist[player.Name:lower()] == true then return true end
  -- A squadmate is another stand, never a target -- whether it was typed in or
  -- found by its latch. The set is refreshed with the fan, four times a second.
  if S.squadOn and player ~= LP then
    if S.squadSet and S.squadSet[player] then return true end
    if squadNameSet()[player.Name:lower()] then return true end
  end
  return false
end

-- Exact username first, then a unique prefix of username or display name.
local function findPlayer(query, skip)
  query = tostring(query or ""):gsub("^@", ""):lower()
  if query == "" then return nil end
  for _, p in ipairs(Players:GetPlayers()) do
    if not skip[p] and p.Name:lower() == query then return p end
  end
  local found
  for _, p in ipairs(Players:GetPlayers()) do
    if not skip[p] and (p.Name:lower():sub(1, #query) == query or p.DisplayName:lower():sub(1, #query) == query) then
      if found then return nil, "more than one player matches" end
      found = p
    end
  end
  return found
end

local function nearestToOwner()
  local _, _, ownerRoot = body(S.owner)
  -- a dead owner can still give orders from chat: measure from where they fell
  local from = ownerRoot and ownerRoot.Position or (S.lastOwnerFrame and S.lastOwnerFrame.Position)
  if not from then return nil end
  local best, bestDistance
  for _, p in ipairs(Players:GetPlayers()) do
    if p ~= LP and p ~= S.owner and not excluded(p) then
      local _, _, root = body(p)
      if root then
        local distance = (root.Position - from).Magnitude
        if distance <= 250 and (not best or distance < bestDistance) then best, bestDistance = p, distance end
      end
    end
  end
  return best
end

-- Why the target cannot be hit right now, or nil when it can. A respawned body
-- gets its ForceField a moment after it appears (measured: one sample latched
-- onto a fresh body before its shield showed), so a new body is given a short
-- grace first. The body the attack began on gets none.
local lastBody = setmetatable({}, { __mode = "k" })
local respawnedAt = setmetatable({}, { __mode = "k" })
local RESPAWN_GRACE = 0.75
-- Is someone in a grab right now? Measured: a hold puts BeingGrabbed and
-- RootAnchor on the model together and takes them off together.
local function heldBy(model)
  if not model then return false end
  for _, mark in ipairs(GRAB_MARKS) do
    if model:FindFirstChild(mark) then return true end
  end
  return false
end

local function targetState(target)
  if not target or target.Parent ~= Players then return "left" end
  local ch, hum = body(target)
  if not ch then
    -- A living body we cannot place (a NaN or runaway position) is not a kill;
    -- counting it as one scored a death for a read glitch.
    local model = target.Character
    local living = model and model:FindFirstChildOfClass("Humanoid")
    if living and living.Health > 0 and living:GetAttribute("Dead") ~= true then return "out of reach" end
    return "waiting for respawn"
  end
  if hum:GetAttribute("Dead") == true then return "waiting for respawn" end
  local previous = lastBody[target]
  if previous ~= ch then
    if previous ~= nil then respawnedAt[ch] = os.clock() end
    lastBody[target] = ch
  end
  -- A grab hands its victim a ForceField for the whole hold (measured), which
  -- read as spawn protection and sent the stand to the void -- away from the
  -- one window it exists to use. A held body is never shielded, it is caught.
  if S.waitShield and not heldBy(ch) then
    if respawnedAt[ch] and os.clock() - respawnedAt[ch] < RESPAWN_GRACE then return "spawn protection" end
    -- TSB's hitboxes skip any body carrying a ForceField (read out of
    -- EventTypes.Hitboxes.Standard: passesIframes), so every one of them means
    -- the swing is wasted -- the respawn shield, a move's IFrames, and the
    -- AbsoluteImmortal of a cinematic alike.
    local shield = ch:FindFirstChildOfClass("ForceField")
    if shield then return shield.Name == "ForceField" and "spawn protection" or "untouchable" end
  end
  return nil
end

-- ---------------------------------------------------------------- locked frames
-- A squad on one prey must not trample a squadmate's locked move. MEASURED
-- 2026-09-30, Purple kit on the user's alt, watched from a THIRD client (the
-- view every other stand has):
--   * Head First is a 3 s cinematic grab: the attacker AND the victim both get
--     an AbsoluteImmortal ForceField; the victim BeingGrabbed, RootAnchor, root
--     anchored. Nothing can hit either of them until it ends.
--   * Whirlwind Drop pins the attacker itself for ~1 s (RootAnchor, anchored).
--   * Bullet Barrage ends in a 0.86 s grab with no ForceField at all.
--   * EVERY hit puts Freeze on its victim and every move puts Freeze on its
--     user, so Freeze says nothing about a lock and is never read here.
--   * The victim's LastHit attribute names whoever damaged it last; at the
--     frame a hold begins, that is the one holding.
function Q.iframed(model) return model ~= nil and model:FindFirstChildOfClass("ForceField") ~= nil end
function Q.pinned(model)
  if not model then return false end
  if model:FindFirstChild("RootAnchor") then return true end
  local root = model:FindFirstChild("HumanoidRootPart")
  return root ~= nil and root.Anchored == true
end
-- We are the one locked in: our own carry, or our own body i-framed or Q.pinned
-- by the move we are doing. A stand never yields to its own move.
function Q.selfLocked()
  if S.combo then return true end
  local me = LP.Character
  return me ~= nil and (Q.iframed(me) or me:FindFirstChild("RootAnchor") ~= nil)
end
S.selfLocked = Q.selfLocked

Q.lockEdge = { model = nil, holder = nil, since = 0, read = false }
-- MEASURED 2026-09-30: a grab's markers reach the victim a moment BEFORE its own
-- damage does (RootAnchor and BeingGrabbed at t, LastDamage at t + 2 ms), so on
-- the hold's first frame LastHit still names whoever hit them before -- live,
-- that taught a stand two moves that never grab. The holder is read once the
-- hold is this old instead.
Q.HOLD_READ = 0.15
function Q.isHunter(name)
  for _, p in ipairs(S.hunters or {}) do if p ~= LP and p.Name == name then return true end end
  return false
end
-- ---------------------------------------------------------------- friendly fire
-- TSB's hitboxes do not know sides. MEASURED 2026-09-30 with two stands on one
-- prey, front and back at 6.1: each stand's LastHit named the OTHER stand, and
-- one of them was killed by it -- a long move thrown through the prey lands on
-- whoever stands on the far side. Every client can see which move a player is
-- in (a "Holding<Move>" attribute goes true as it starts) and whether it is
-- still going (the mover carries Freeze or Slowed until it ends). So a move
-- that has hit this stand once is remembered (and saved), and whenever a
-- squadmate starts it again this stand steps into the void until it is over.
-- A friendly hit from anything else still earns a short step aside.
Q.mateMove = setmetatable({}, { __mode = "k" })     -- player -> { name, at }
Q.watchedMate = setmetatable({}, { __mode = "k" })  -- character -> connection
Q.harmful, Q.hitUntil, Q.hitBy = {}, 0, nil
do
  local saved = feat("friendlyMoves", nil)
  if type(saved) == "table" then for name, on in pairs(saved) do if type(name) == "string" and on == true then Q.harmful[name] = true end end end
end
function Q.watchMate(p)
  local ch = p.Character
  if not ch or Q.watchedMate[ch] then return end
  Q.watchedMate[ch] = ch.AttributeChanged:Connect(function(attr)
    if attr:sub(1, 7) == "Holding" and attr ~= "HoldingM1" and attr ~= "HoldingSpace" and ch:GetAttribute(attr) == true then
      Q.mateMove[p] = { name = attr:sub(8), at = os.clock() }
    end
  end)
end
function Q.moving(model) return model ~= nil and (model:FindFirstChild("Freeze") ~= nil or model:FindFirstChild("Slowed") ~= nil) end
-- Our own LastHit naming a squadmate is a friendly hit.
function Q.friendlyHit(byName)
  local now = os.clock()
  for _, p in ipairs(S.hunters or {}) do
    if p ~= LP and p.Name == byName then
      Q.hitUntil, Q.hitBy = now + 1.2, byName
      local mv = Q.mateMove[p]
      if mv and now - mv.at < 4 and not Q.harmful[mv.name] then
        Q.harmful[mv.name] = true
        saveFeat("friendlyMoves", Q.harmful)
        emit("squad", "friendly", byName, mv.name)
      end
      return true
    end
  end
  return false
end
function Q.watchSelf(ch)
  if not ch or typeof(ch) ~= "Instance" and not ch.AttributeChanged then return end
  -- Every hit stamps LastDamage; LastHit only changes when the attacker does.
  -- Live, a squadmate hitting a stand it had already hit changed nothing on
  -- LastHit, so its later hits went unnoticed. Either one now counts.
  ch.AttributeChanged:Connect(function(attr)
    if attr == "LastHit" or attr == "LastDamage" then
      local by = ch:GetAttribute("LastHit")
      if type(by) == "string" then Q.friendlyHit(by) end
    end
  end)
end
Q.watchSelf(LP.Character)
L.hold(LP.CharacterAdded:Connect(function(ch) Q.watchSelf(ch) end))

-- Why this stand should step into the void right now, or nil.
function Q.lockReason(now)
  if not S.yieldOn or S.mode ~= "attacking" or not S.target or Q.selfLocked() then return nil end
  -- a fellow hunter on our prey, pinned or i-framed by its own move, or in a
  -- move that has hit this side before; and just after any friendly hit
  if now < Q.hitUntil and Q.hitBy then return "hit by " .. Q.hitBy .. ", stepping clear" end
  for p in pairs(Q.hunterAnchor) do
    local m = p.Character
    if m and m.Parent then
      if Q.iframed(m) or m:FindFirstChild("RootAnchor") then return p.Name .. " is in a locked move" end
      local mv = Q.mateMove[p]
      if mv and Q.harmful[mv.name] and now - mv.at < 4 and Q.moving(m) then
        return p.Name .. "'s " .. mv.name .. " reaches this side"
      end
    end
  end
  local victim = S.target.Character
  if victim and heldBy(victim) then
    local edge = Q.lockEdge
    if edge.model ~= victim then edge.model, edge.since, edge.holder, edge.read = victim, now, nil, false end
    if not edge.read then
      if now - edge.since < Q.HOLD_READ then return nil end
      local lastHit = victim:GetAttribute("LastHit")
      edge.holder, edge.read = type(lastHit) == "string" and lastHit or nil, true
    end
    local holder = edge.holder
    if holder == LP.Name then return nil end
    if holder and Q.isHunter(holder) then return holder .. " has them in a grab" end
    -- Nobody named: a move of ours taken just now is the likeliest holder.
    if now - S.lastSkillAt < 2 then return nil end
    if (S.strikeCount or 1) > 1 then return "a squadmate has them in a grab" end
    return nil
  end
  Q.lockEdge.model, Q.lockEdge.holder, Q.lockEdge.read = nil, nil, false
  return nil
end
S.lockReason = Q.lockReason

-- ---------------------------------------------------------------- voice
local lastSay, queued = 0, nil
local function send(message)
  emit("say", message)
  lastSay = os.clock()
  task.spawn(function()
    pcall(function()
      local channel = TCS.ChatInputBarConfiguration.TargetTextChannel
      if not channel then
        local channels = TCS:FindFirstChild("TextChannels")
        channel = channels and channels:FindFirstChild("RBXGeneral")
      end
      if channel then channel:SendAsync(message) end
    end)
  end)
end
-- One line a second keeps clear of chat's rate limit. A line inside that second
-- is held, not dropped, and a newer one replaces it: the latest news wins.
local function say(message, force)
  if not S.speak and not force then return end
  message = tostring(message or ""):sub(1, 180)
  if message == "" then return end
  local wait = 1 - (os.clock() - lastSay)
  if wait <= 0 and not queued then send(message); return end
  local first = queued == nil
  queued = message
  if first then
    task.delay(math.max(wait, 0), function()
      local line = queued
      queued = nil
      if line and L.live() then send(line) end
    end)
  end
end

local lastRefusal = 0
local function refuse(message)
  if os.clock() - lastRefusal < 3 then return end
  lastRefusal = os.clock()
  say(message)
end

-- ---------------------------------------------------------------- the latch
local function poseFrame(name)
  local p = S.poses[name]
  return CFrame.new(p.x, p.y, p.z) * CFrame.Angles(math.rad(p.pitch), math.rad(p.yaw), math.rad(p.roll))
end

-- The void gate lives in the TSB adapter and is shared with the Combat tab. We
-- only ever close it for ourselves and hand it back when that tab is not using
-- it. Nothing here assumes it worked: floorY asks every time.
local function voidAPI()
  local adapter = R.TSB
  return adapter and adapter.Void or nil
end

local function voidSafe()
  local void = voidAPI()
  return void ~= nil and void.safe() == true
end

local function wantVoid(on)
  local void = voidAPI()
  if not void then S.voidReady = false; return false end
  -- Only TSB has a kill plane worth closing. Anywhere else the gate's fallback
  -- is a __newindex hook and a NaN FallenPartsDestroyHeight -- a footprint for
  -- nothing, since outside TSB the stand never goes below the safe floor anyway.
  local adapter = R.TSB
  if on and not (adapter and adapter.supported and adapter.supported()) then on = false end
  if on then
    if not void.wanted then void.set(true) else void.tick() end
    S.voidReady = void.safe() == true
    return S.voidReady
  end
  local shared = adapter and adapter.cfg and adapter.cfg.enabled and adapter.cfg.voidImmunity
  if void.wanted and not shared then void.set(false) end
  S.voidReady = false
  return false
end

-- How low our LOCAL root may go. TSB zeroes our Health below -500, so -450 is
-- the floor until the gate is closed; with it closed the rig held 100 HP at
-- -660, and the deep hide and the void drop get the room they need. Losing the
-- gate does not kill the stand -- it just quietly stops going deep.
local function floorY()
  return voidSafe() and -9000 or SAFE_Y
end

local function clampY(frame)
  local limit = floorY()
  if frame.Position.Y < limit then return frame + Vector3.new(0, limit - frame.Position.Y, 0) end
  return frame
end

-- Where slot i of n stands for one pose. Only Strike is turned round the anchor
-- by the fan: turning the owner-side poses the same way was a bug -- in a ring of
-- two, the second stand's Idle landed in the owner's face and its Front landed
-- BEHIND the owner, facing away, so every .1-.4 it fired went into empty air.
--   Idle   a wing: the shoulders first, mirrored, then a row further back for
--          each further pair.
--   Front  a line abreast across the owner's front, all facing the same way.
local WING_ROW, LINE_GAP = 3.5, 4
local function formation(name, slot, count)
  if not S.squadOn or count <= 1 then return poseFrame(name) end
  local p = S.poses[name]
  if name == "Strike" then
    local delta = spread(slot, count)
    return CFrame.Angles(0, math.rad(delta), 0) * poseFrame(name)
  elseif name == "Idle" then
    local k = slot - 1
    local home = p.x >= 0 and 1 or -1
    local side = k % 2 == 0 and home or -home
    local yaw, roll = p.yaw, p.roll
    if side ~= home then yaw, roll = -yaw, -roll end
    return CFrame.new(side * math.max(math.abs(p.x), 2.5), p.y, p.z + (k // 2) * WING_ROW)
      * CFrame.Angles(math.rad(p.pitch), math.rad(yaw), math.rad(roll))
  elseif name == "Front" then
    return CFrame.new((slot - (count + 1) / 2) * LINE_GAP, 0, 0) * poseFrame(name)
  end
  return poseFrame(name)
end
S.formation = formation

-- The anchor's horizontal heading. A body lying flat has no horizontal look
-- vector; its up axis then carries the heading, and failing that the last good
-- heading for this anchor is kept, so a ragdoll never swings the stand around.
local headings = setmetatable({}, { __mode = "k" })
local function heading(anchorRoot, frame)
  local look = frame.LookVector
  local flat = Vector3.new(look.X, 0, look.Z)
  if flat.Magnitude >= 0.2 then
    local yaw = math.atan2(-flat.X, -flat.Z)
    headings[anchorRoot] = yaw
    return yaw
  end
  if headings[anchorRoot] then return headings[anchorRoot] end
  local up = frame.UpVector
  flat = Vector3.new(up.X, 0, up.Z)
  if flat.Magnitude >= 0.2 then return math.atan2(-flat.X, -flat.Z) end
  return nil
end

-- The LOCAL CFrame that the server will compose with the anchor. With "keep
-- upright" a tilted or ragdolled anchor still gets an upright stand: we pre-undo
-- the anchor's tilt and keep only its heading. For an upright anchor this is the
-- raw pose, exactly what the rig measured.
-- The pose before the anchor's tilt is taken out. Three of them are not simply
-- their saved sliders: the deep hide swaps in its own depth and distance, the
-- void drop is ramped frame by frame by the carry, and Strike is turned by this
-- stand's share of the squad fan.
local function baseFrame(name)
  if name == "Hidden" and S.hideDeep then
    return CFrame.new(0, -S.hideDepth, S.hideAway)
  end
  if name == "Void" then
    -- Straight down from where the prey was taken, not from the owner's own
    -- spot: MEASURED 2026-09-30 the ride used to start at depth 0 ON the owner,
    -- dragging the victim across to them first, and the grab's own hits landed
    -- on the owner (80 HP, LastHit = the stand). Kept at least 12 studs clear.
    local combo = S.combo
    local from = combo and combo.rideFrom
    return CFrame.new(from and from.X or 0, -((combo and combo.depth) or S.hideDepth), from and from.Z or 0)
  end
  -- Optional, off unless asked for: circle the owner while waiting, the squad
  -- spread evenly round the same circle.
  if name == "Idle" and S.orbitOn then
    local p = S.poses.Idle
    local r = math.max(math.sqrt(p.x * p.x + p.z * p.z), 2.5)
    local a = os.clock() * S.orbitSpeed + 2 * math.pi * (S.idleSlot - 1) / math.max(S.idleCount, 1)
    return CFrame.new(math.sin(a) * r, S.orbitHeight, math.cos(a) * r)
      * CFrame.Angles(math.rad(p.pitch), math.rad(p.yaw), math.rad(p.roll))
  end
  -- Everywhere the squad stands together gets its own formation: waiting beside
  -- the owner, stepping in front of them, and on the target -- each counted
  -- among the stands on that same anchor. The void, the hold and the delivery
  -- are left alone: those are places to be exact, not spread.
  if name == "Strike" then return formation(name, S.strikeSlot, S.strikeCount) end
  if FANNED[name] then return formation(name, S.idleSlot, S.idleCount) end
  return poseFrame(name)
end

local function localFrame(anchorRoot, anchorFrame, name, bob)
  local frame = CFrame.new(0, bob or 0, 0) * baseFrame(name)
  if S.upright then
    local yaw = heading(anchorRoot, anchorFrame)
    -- A delivery is aimed ONCE, when the grab takes hold, and keeps that
    -- bearing. Re-deriving it from the owner's live facing every frame carries
    -- the body around them as they turn to watch -- which reads as the stand
    -- circling behind the owner instead of holding station out in front.
    local combo = S.combo
    if (name == "Bring" or name == "Void") and combo and combo.dropYaw then yaw = combo.dropYaw end
    if yaw then frame = anchorFrame.Rotation:Inverse() * CFrame.Angles(0, yaw, 0) * frame end
  end
  return clampY(frame)
end

-- Every state that can take the pose away from us. Freefall and FallingDown are
-- the ones a floating body falls into by itself; GettingUp is the one a MOVE
-- leaves behind. MEASURED from the owner's screen on 2026-09-24: the stand
-- replicated as FallingDown while idle, and after a .a then .s cycle it sat in
-- GettingUp for good -- the pose looked wrong from outside even though our own
-- client read Running and the stance track was still playing at full weight.
local HELD_STATES = { Enum.HumanoidStateType.Freefall, Enum.HumanoidStateType.FallingDown,
  Enum.HumanoidStateType.GettingUp, Enum.HumanoidStateType.Ragdoll }
local latch = { character = nil, root = nil, hum = nil, platform = false, states = {}, parts = {}, conns = {},
  camera = nil, subject = nil, cameraSet = nil, home = nil }
local stance = { track = nil, id = nil, hum = nil, anim = nil }
local stateNudged = 0

local function stanceId()
  if S.stance == "Off" then return nil end
  if S.stance == "Custom" then
    local id = tostring(S.stanceCustom or ""):match("%d+")
    return id
  end
  return STANCE_IDS[S.stance] or STANCE_IDS["Fighting stance"]
end

-- Movement priority: above the Core fall animation the latched body is stuck in,
-- below the Action tracks that M1s and skills play. TSB stops other tracks when a
-- move starts, which used to leave the stand posing wrong after an attack; the
-- track is checked every frame and brought straight back when it has stopped.
local function setStance(hum)
  local want = hum and stanceId() or nil
  if want ~= stance.id or hum ~= stance.hum then
    if stance.track then
      local old = stance.track
      pcall(function() old:Stop(0.2) end)
    end
    -- Each swap made a new Animation and never let the old one go.
    if stance.anim then
      local old = stance.anim
      pcall(function() old:Destroy() end)
    end
    -- Recorded before loading, so a refused asset is not retried every frame.
    stance.track, stance.id, stance.hum, stance.anim = nil, want, hum, nil
    if not want then return end
    local animator = hum:FindFirstChildOfClass("Animator")
    if not animator then return end
    local animation = Instance.new("Animation")
    stance.anim = animation
    animation.AnimationId = "rbxassetid://" .. want
    local ok, track = pcall(animator.LoadAnimation, animator, animation)
    if not ok or not track then return end
    track.Priority = Enum.AnimationPriority.Movement
    track.Looped = true
    stance.track = track
  end
  local track = stance.track
  if track and not track.IsPlaying then
    pcall(function()
      track:Play(0.15)
      track:AdjustWeight(1)
    end)
  end
end

-- Where the latch wants to be: the anchor player and the pose. "Hold" is the
-- unbound deep hold, for when there is nobody to ride.
--
-- The hunt does not stop for the owner. The owner dying used to send every
-- stand into the void until they respawned -- the fight paused on the one
-- player who is not in it. Now only the Strike needs the target; the owner is
-- needed just for the places that ride the owner (waiting beside them, hiding
-- under them, the carry's ride down). With the owner dead or respawning the
-- stand waits out a target's respawn in the unbound hold instead, and if the
-- owner LEAVES the server it keeps hunting (unless told not to) until the
-- target is gone.
local function wanted()
  if S.mode == "off" then return nil end
  local ownerHere = body(S.owner) ~= nil
  -- A carry owns the latch while it lasts: on the target until the grab takes
  -- hold, then on the owner, riding down to the void or in to the delivery.
  local combo = S.combo
  if combo then
    if not combo.grabAt then
      if body(combo.target) then return combo.target, "Strike" end
      if ownerHere then return S.owner, "Idle" end
      return nil, "Hold"
    end
    if ownerHere then return S.owner, combo.kind == "bring" and "Bring" or "Void" end
    return nil, "Hold"
  end
  if S.mode == "attacking" then
    local mayHunt = S.owner ~= nil or S.huntAlone
    if mayHunt and not S.reserve and not S.yield and not targetState(S.target) then return S.target, "Strike" end
    if not ownerHere then return nil, "Hold" end
    -- backup stands wait beside the owner; the rest wait under them
    if S.reserve then return S.owner, "Idle" end
    return S.owner, "Hidden"
  end
  if not ownerHere then return nil, "Hold" end
  if S.mode == "hidden" then return S.owner, "Hidden" end
  if S.barrage or os.clock() < S.frontUntil then return S.owner, "Front" end
  return S.owner, "Idle"
end

local function blockedReason()
  if not R.repRoot then return "Rep Root is off" end
  if type(shp) ~= "function" then return "this executor has no sethiddenproperty" end
  if S.flingBusy then return "fling assist is running" end
  -- The ragebot frees the stand when it starts, but the owner's chat could summon
  -- it straight back and the two would fight over one root binding every frame.
  if R.Rage and R.Rage.running then return "the ragebot is running" end
  if os.clock() < S.pauseUntil then return "paused" end
  if K.flinging or K.activeCleanup or K.returningHome then return "a Rep Root fling is running" end
  if R.queue then return "the Targets loop is running" end
  if R.tuning then return "auto-tune is running" end
  local universal = L.Universal and L.Universal.want
  if universal and universal.fly then return "fly is on" end
  local move = L.Move and L.Move.want
  if move and (move.freeze or move.spin) then return "freeze or spin is on" end
  return nil
end

local function restoreCamera()
  local camera = latch.camera
  if camera and camera == workspace.CurrentCamera and latch.cameraSet and camera.CameraSubject == latch.cameraSet then
    local own = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
    pcall(function() camera.CameraSubject = own or latch.subject end)
  end
  latch.camera, latch.subject, latch.cameraSet = nil, nil, nil
end

local function dropConnections()
  for _, conn in ipairs(latch.conns) do conn:Disconnect() end
  table.clear(latch.conns)
end

-- Where a released stand is put down: beside the owner (their last living
-- position if they are dead), never the pose's own world spot, which for the
-- hidden pose is 300 studs under the map.
local function stepOut()
  local _, _, ownerRoot = body(S.owner)
  local base = ownerRoot and ownerRoot.CFrame or S.lastOwnerFrame
  local out = base and base * CFrame.new(S.poses.Idle.x, 0, S.poses.Idle.z)
  -- Never the void, the hide or a hold: those world spots are the ones that
  -- kill once the gate reopens. Failing everything else, where the body stood
  -- before it was latched -- leaving it at the raw pose, which for the deep hide
  -- is thousands of studs under the map, was the one release that could kill.
  local deep = S.pose == "Hidden" or S.pose == "Void" or S.pose == "Hold"
  if not out and S.lastWorld and not deep then out = S.lastWorld end
  if not out then out = latch.home end
  if not out then return nil end
  local look = out.LookVector
  local flat = Vector3.new(look.X, 0, look.Z)
  out = flat.Magnitude > 0.2 and CFrame.lookAt(out.Position, out.Position + flat) or CFrame.new(out.Position)
  return clampY(out)
end

-- Everything the latch changed, undone. Safe to call twice and after a death.
local function release(why)
  if not S.active then return end
  S.active = false
  dropConnections()
  setStance(nil)
  local root, hum = latch.root, latch.hum
  if root and root.Parent and LP.Character == latch.character then
    pcall(shp, root, "PhysicsRepRootPart", nil)
    local out = stepOut()
    pcall(function()
      if out then root.CFrame = out end
      root.AssemblyLinearVelocity = Vector3.zero
      root.AssemblyAngularVelocity = Vector3.zero
    end)
    for part, was in pairs(latch.parts) do
      pcall(function() if part.Parent then part.CanCollide = was end end)
    end
    pcall(function()
      if hum.Parent then
        hum.PlatformStand = latch.platform
        for state, was in pairs(latch.states) do hum:SetStateEnabled(state, was) end
      end
    end)
  end
  table.clear(latch.parts)
  restoreCamera()
  S.anchorRoot, S.pose, S.pending = nil, nil, nil
  if why then L.note("stand", "released: " .. tostring(why)) end
end
S.release = release

local function begin(ch, hum, root)
  table.clear(latch.parts)
  dropConnections()
  for _, d in ipairs(ch:GetDescendants()) do
    if d:IsA("BasePart") then latch.parts[d] = d.CanCollide end
  end
  latch.character, latch.root, latch.hum = ch, root, hum
  latch.platform = hum.PlatformStand
  local here = root.CFrame
  latch.home = (R.validPosition(here.Position) and here.Position.Y > SAFE_Y) and here or nil
  -- The latched body has no floor under its local position, so it would sit in
  -- Freefall, whose animation (arms up) overrides everything and whose flicker
  -- kept stopping the pose track (measured: never stopped once the state held).
  latch.states = {}
  for _, state in ipairs(HELD_STATES) do
    latch.states[state] = hum:GetStateEnabled(state)
    hum:SetStateEnabled(state, false)
  end
  latch.conns[1] = ch.DescendantAdded:Connect(function(d)
    if d:IsA("BasePart") and latch.parts[d] == nil then latch.parts[d] = d.CanCollide end
  end)
  latch.conns[2] = ch.DescendantRemoving:Connect(function(d) latch.parts[d] = nil end)
  S.active = true
end

local born = setmetatable({}, { __mode = "k" })
L.hold(LP.CharacterAdded:Connect(function(ch) born[ch] = os.clock() end))

local function hold(frame, anchorRoot, poseName, ch, hum, root)
  if not S.active then begin(ch, hum, root) end
  local ok = pcall(shp, root, "PhysicsRepRootPart", anchorRoot)
  if not ok then return false end
  for part in pairs(latch.parts) do
    if part.Parent then part.CanCollide = false end
  end
  if S.hover and not hum.PlatformStand then hum.PlatformStand = true end
  if not S.hover then
    -- Held every frame, not just at the latch. The game re-enables these after
    -- its own moves, and one frame in a disabled state is enough to replicate
    -- it: the stand then sits in GettingUp on everyone else's screen until the
    -- next latch. Anything that is not Running is put back to Running, so the
    -- pose outside matches the pose we are playing.
    for _, state in ipairs(HELD_STATES) do
      if hum:GetStateEnabled(state) then hum:SetStateEnabled(state, false) end
    end
    if hum:GetState() ~= Enum.HumanoidStateType.Running then
      hum:ChangeState(Enum.HumanoidStateType.Running)
    end
    -- A state written while the humanoid already holds it does not replicate:
    -- measured both ways, our client read Running for 120 straight frames while
    -- the owner's still showed the Freefall it drifted into during a move. A
    -- real transition does replicate, so the state is nudged through Landed
    -- every couple of seconds and the line above walks it back to Running on
    -- the next frame. Invisible here, and it keeps the body standing over there.
    if os.clock() - stateNudged >= 2 then
      stateNudged = os.clock()
      hum:ChangeState(Enum.HumanoidStateType.Landed)
    end
  end
  root.CFrame = frame
  root.AssemblyLinearVelocity = Vector3.zero
  root.AssemblyAngularVelocity = Vector3.zero
  if S.pose ~= poseName or S.anchorRoot ~= anchorRoot then S.poseSince = os.clock() end
  S.anchorRoot, S.pose = anchorRoot, poseName
  setStance(hum)
  return true
end

Q.SMOOTHED = { Idle = true, Front = true, Strike = true }
local function step(dt)
  local _, _, ownerRoot = body(S.owner)
  if ownerRoot then S.lastOwnerFrame = ownerRoot.CFrame end
  if S.mode == "off" then
    if S.active then release("off") end
    if S.voidReady then wantVoid(false) end
    S.blocked, S.yield = nil, nil
    return
  end
  local now = os.clock()
  S.slotFrozen = S.mode == "attacking" and Q.selfLocked()
  -- Who else is standing here, ten times a second: joins, deaths and leaves
  -- re-pack the fan, and a squadmate's locked move is noticed within a frame
  -- or two of it showing (the markers themselves are read every frame below).
  if now - S.squadAt >= 0.1 then S.squadAt = now; refreshSquad() end
  -- Step aside for a squadmate's locked frame, and come back 0.12 s after the
  -- last sign of it -- quick, but not so eager that one flickering marker
  -- bounces the stand in and out of the void.
  local lock = Q.lockReason(now)
  if lock then
    if S.yield ~= lock then emit("yield", lock) end
    S.yield, S.yieldSeen = lock, now
  elseif S.yield and now - (S.yieldSeen or 0) >= 0.12 then
    S.yield = nil
    emit("yield", nil)
  end
  -- The gate is closed ahead of time, not at the moment it is needed: locating
  -- TSB's kill-plane closure takes a tick, and a carry cannot wait for it.
  if now - S.voidAt >= 0.2 then
    S.voidAt = now
    wantVoid((S.hideDeep or S.comboOn) and S.mode ~= "off")
  end
  local reason = blockedReason()
  local ch, hum, root = body(LP)
  if not reason then
    if not ch then reason = "waiting for your character"
    elseif born[ch] and os.clock() - born[ch] < 1.5 then reason = "respawning" end
  end
  -- A stand that dies mid-carry has nothing left to carry with. Left running,
  -- the carry read the vanished marker as a release and learned a bogus hold.
  if S.combo and (not ch or (S.active and latch.character ~= ch)) then S.endCombo("the stand went down") end
  if reason then
    if S.active then release(reason) end
    S.blocked = reason
    return
  end
  S.blocked = nil
  -- A death ends the old latch with nothing left to restore.
  if S.active and (latch.character ~= ch or latch.root ~= root) then
    S.active = false
    dropConnections()
    table.clear(latch.parts)
    restoreCamera()
  end

  local anchorPlayer, poseName = wanted()
  if poseName == "Hold" then
    -- Nobody to ride: the owner is dead, respawning or gone, and there is no
    -- target to be on right now. Wait in the void, unbound and Q.pinned. The deep
    -- hide applies here too, so it is not left hanging in plain sight three
    -- hundred studs under the map.
    hold(clampY(CFrame.new(baseFrame("Hidden").Position)), nil, "Hold", ch, hum, root)
    S.lastWorld = nil
    return
  end
  local _, _, anchorRoot = body(anchorPlayer)
  if not anchorRoot then return end

  local anchorFrame = anchorRoot.CFrame
  local bob = S.float > 0 and poseName ~= "Strike" and math.sin(os.clock() * 2.2) * S.float or 0
  local frame = localFrame(anchorRoot, anchorFrame, poseName, bob)
  -- Glide between spots on the same anchor (the fan re-packing, the angle being
  -- turned) instead of snapping. The latch composes on the server, so this
  -- never adds follow lag -- only the offset itself eases.
  if S.smooth < 1 and Q.SMOOTHED[poseName] and S.pose == poseName and S.anchorRoot == anchorRoot and S.lastLocal then
    frame = S.lastLocal:Lerp(frame, 1 - (1 - S.smooth) ^ ((dt or 1 / 60) * 60))
  end
  S.lastLocal = frame
  if not hold(frame, anchorRoot, poseName, ch, hum, root) then
    release("rep-root write refused")
    S.blocked = "rep-root write refused"
    return
  end
  S.lastWorld = anchorFrame * frame
  -- a new body under us (the first engage, or back after a kill) opens the
  -- engage window, so the squad re-forms together instead of stacking up
  if poseName == "Strike" and S.target and S.engaged ~= S.target.Character then
    S.engaged, S.engageAt = S.target.Character, now
  end
  if latch.cameraSet and not S.camera then restoreCamera() end
end

-- TSB puts the camera back on our own humanoid every frame (measured: a
-- Heartbeat write never held). Writing just before the camera module updates
-- means the frame is always rendered on the owner, whoever reset it in between.
local function aimCamera()
  if not S.camera or not S.active then return end
  local _, ownerHum = body(S.owner)
  -- no owner to watch (dead, respawning, gone) while hunting: watch the hunt
  if not ownerHum and S.mode == "attacking" then _, ownerHum = body(S.target) end
  local camera = workspace.CurrentCamera
  if not ownerHum or not camera or camera.CameraSubject == ownerHum then return end
  if latch.camera ~= camera then latch.camera, latch.subject = camera, camera.CameraSubject end
  pcall(function() camera.CameraSubject = ownerHum end)
  latch.cameraSet = ownerHum
end

-- ---------------------------------------------------------------- combat
local function tsb()
  local adapter = R.TSB
  return adapter and adapter.supported() and adapter or nil
end

local function lowHealth()
  if S.lowHP <= 0 then return false end
  local _, hum = body(LP)
  return hum ~= nil and hum.Health / math.max(hum.MaxHealth, 1) * 100 <= S.lowHP
end

local lastM1, lastDash, lastUlt = 0, 0, 0

local function settled(poseName)
  return S.active and S.pose == poseName and os.clock() - S.poseSince >= SETTLE
end

-- ---------------------------------------------------------------- the carry
-- What a move has been watched to do. A hold in seconds means it took someone
-- and held them that long; false means a hinted name that kept failing to. The
-- table is saved, so a kit is only learned once.
local function saveGrabMoves()
  saveFeat("grabMoves", S.grabMoves)
end

local function learnGrab(name, hold)
  if not name then return end
  local known = S.grabMoves[name]
  -- Averaged, so one clipped sample cannot ruin a good pace.
  local value = type(known) == "number" and (known * 0.6 + hold * 0.4) or hold
  S.grabMoves[name] = math.clamp(value, 0.15, 10)
  S.grabMisses[name] = nil
  saveGrabMoves()
end

local function missedGrab(name)
  if not name or type(S.grabMoves[name]) == "number" then return end
  local misses = (S.grabMisses[name] or 0) + 1
  S.grabMisses[name] = misses
  if misses >= GRAB_GIVE_UP then S.grabMoves[name] = false; saveGrabMoves() end
end

local function canGrab(name)
  if not name then return false end
  local known = S.grabMoves[name]
  if known ~= nil then return known ~= false end
  local lower = name:lower()
  for _, hint in ipairs(GRAB_HINTS) do
    if lower:find(hint, 1, true) then return true end
  end
  return false
end
S.canGrab = canGrab

local function grabHold(name)
  local known = name and S.grabMoves[name]
  return type(known) == "number" and known or GRAB_HOLD_DEFAULT
end

-- The ready slot that can take hold, longest hold first: every extra tenth of a
-- second of hold is another ~70 studs of descent budget.
local function grabSlot(slots)
  local best
  for index = 1, 4 do
    local slot = slots[index]
    if slot and slot.name and not slot.cooling and canGrab(slot.name) then
      if not best or grabHold(slot.name) > grabHold(slots[best].name) then best = index end
    end
  end
  return best
end

-- The carries spent on this life of this target. A respawn or a new target
-- starts the count again.
local function attemptsFor(target)
  local a = S.attempts
  local model = target and target.Character
  if a.target ~= target or a.body ~= model then a.target, a.body, a.n = target, model, 0 end
  return a
end

-- Could a carry actually open soon? Only then are grabs held back for it. A
-- verdict still out counts: if they lived, the retry needs that grab. Only the
-- squad leader ever carries, so only the leader holds grabs back -- live, the
-- second stand was saving its grabs for a carry it would never be allowed.
local function carryPending(now)
  return S.comboOn and S.mode == "attacking" and S.voidReady and (S.strikeSlot or 1) == 1
    and attemptsFor(S.target).n < S.comboTries
    and (S.verify ~= nil or now - S.lastCombo >= S.comboEvery - 1.5)
end

-- The rotation never spends a grab while the carry wants one: a grab put on
-- cooldown as an ordinary move is a combo that cannot open. An owner asking for
-- a slot by number still gets it -- that goes through requests. Grabs are held
-- back ONLY while a carry could open: before, a void gate that never armed (or
-- a spent attempt budget) left every grab in the kit unused for the whole fight.
local function nextReady(slots)
  local reserve = carryPending(os.clock())
  for offset = 0, 3 do
    local index = (S.rotation + offset - 1) % 4 + 1
    local slot = slots[index]
    if slot and slot.name and not slot.cooling and not (reserve and canGrab(slot.name)) then return index end
  end
  return nil
end

-- The owner's own requests go first, oldest first; otherwise, while attacking,
-- the rotation's next ready slot. A requested slot already cooling is refused.
local function chooseSlot(slots, now, attacking)
  local best, bestAt
  for index, request in pairs(S.requests) do
    if now > request.untilAt then S.requests[index] = nil
    else
      local slot = slots[index]
      if not slot or not slot.name then S.requests[index] = nil; refuse("Slot " .. index .. " is empty.")
      elseif slot.cooling and not request.sent then S.requests[index] = nil; refuse(slot.name .. " is on cooldown.")
      elseif not slot.cooling and (not best or request.at < bestAt) then best, bestAt = index, request.at end
    end
  end
  if best then return best end
  if attacking and S.useSkills then return nextReady(slots) end
  return nil
end

-- One carry, from the send to the verdict:
--   casting     the grab is sent and re-sent until the server takes it, then
--               watched until it takes hold
--   carrying    it has hold, so the latch moves to the owner and the stand
--               either ramps down into the void or rides straight to delivery
--   letting go  the hold ended; stay put a moment so the release lands here
-- Nothing is judged while the grab is up -- our client draws a carried body
-- beside our local root, not where it really is -- so the verdict waits for the
-- release and is read from the target's own state.
local function endCombo(why, verdict)
  local combo = S.combo
  if not combo then return end
  S.combo, S.comboState = nil, "idle"
  S.lastCombo = os.clock()
  if verdict and combo.kind == "void" and not combo.died then
    S.verify = { target = combo.target, at = os.clock() + 0.6 }
  end
  emit("carry", "end", combo.target, why, combo.died == true)
  if why then L.note("stand", "carry ended: " .. tostring(why)) end
end
S.endCombo = endCombo

local function beginCombo(kind, target)
  if S.combo then return false, "already carrying someone" end
  if not S.owner or not body(S.owner) then return false, "the owner is not here" end
  local adapter = tsb()
  if not adapter then return false, "carries need The Strongest Battlegrounds" end
  if not target or not body(target) then return false, "no one to take" end
  local why = targetState(target)
  if why then return false, why end
  local slots = adapter.Game.hotbar()
  local index = grabSlot(slots)
  if not index then return false, "no grab is ready" end
  if kind == "void" and not wantVoid(true) then
    return false, "void immunity is not armed"
  end
  local tries = 1
  if kind == "void" then
    local spent = attemptsFor(target)
    spent.n += 1
    tries = spent.n
  end
  S.combo = { kind = kind, target = target, slot = index, name = slots[index].name,
    firstAt = os.clock(), sentAt = -math.huge, sends = 0, tries = tries, casts = 1, depth = 0,
    -- Somebody else's grab already on them is not ours to take credit for:
    -- a hold only counts once the target has been seen free since we began.
    clearSeen = not heldBy((adapter.Game.body(target))) }
  S.comboState = "casting"
  emit("carry", "begin", target, kind)
  return true
end
S.beginCombo = beginCombo

-- True while the carry owns the frame: no swings, no dashes, no rotation.
local function comboStep(now, adapter, slots)
  local combo = S.combo
  local target = combo.target
  local model, victim = adapter.Game.body(target)

  if not combo.grabAt then
    S.comboState = "casting " .. tostring(combo.name)
    local held = heldBy(model)
    if not held then combo.clearSeen = true end
    -- The hotbar's Cooldown marker is the server taking the move (measured,
    -- ~0.1 s). After that re-sending only burns the remote budget the dashes
    -- and M1s share -- a taken move sent again is simply ignored.
    local slot = slots[combo.slot]
    if combo.sends > 0 and slot and slot.cooling and not combo.acceptedAt then combo.acceptedAt = now end
    -- Ours only if we sent it and they were free at some point since: a
    -- squadmate's grab on the same target, or one already on them, used to be
    -- taken for our own -- and its hold learned as this move's.
    if held and combo.clearSeen and combo.sends > 0 then
      combo.grabAt = now
      combo.body = model
      combo.hold = grabHold(combo.name)
      local _, _, ownerRoot = body(S.owner)
      combo.ownerY = ownerRoot and ownerRoot.Position.Y or 0
      combo.dropYaw = ownerRoot and heading(ownerRoot, ownerRoot.CFrame) or nil
      -- where we are right now, in the owner's upright heading frame: the ride
      -- down starts here, so the victim is never dragged sideways at all
      if ownerRoot and combo.dropYaw and S.lastWorld then
        local frame = CFrame.new(ownerRoot.Position) * CFrame.Angles(0, combo.dropYaw, 0)
        local here = frame:PointToObjectSpace(S.lastWorld.Position)
        local flat = Vector3.new(here.X, 0, here.Z)
        if flat.Magnitude < 12 then flat = (flat.Magnitude > 0.1 and flat.Unit or Vector3.new(0, 0, 1)) * 12 end
        combo.rideFrom = flat
      end
      if combo.kind == "void" then
        -- The whole descent has to fit inside this one hold: between grabs the
        -- victim is returned to the map, which spends the progress. So aim past
        -- the kill plane with margin and pace it to arrive just before the hold
        -- is due to end (measured: 1041 studs over a 1.5 s hold killed). The
        -- pace is capped at what the carry was watched to track.
        combo.need = math.max(combo.ownerY - (KILL_PLANE - S.voidMargin), 50)
        combo.rate = S.carryAdapt
          and math.clamp(combo.need / math.max(combo.hold - 0.15, 0.3), CARRY_RATE[1], CARRY_SAFE)
          or S.carryRate
        say(S.lines.carry)
      end
      emit("carry", "hold", target, combo.name)
      return true
    end
    local state = targetState(target)
    if state == "left" then endCombo("they left"); return false end
    -- Dead before the grab landed: not a miss, and nothing left to take.
    if state == "waiting for respawn" then endCombo("they went down"); return false end
    local waited = combo.firstSend ~= nil and now - combo.firstSend > GRAB_WAIT
    if waited or now - combo.firstAt > GRAB_TIMEOUT then
      -- Only a move the server actually took and that still held nobody is
      -- evidence it is not a grab. One never sent (the stand was blocked, or
      -- the pose never settled) used to count as a miss too, and three of
      -- those marked a real grab "not a grab" for good -- saved to config.
      if combo.acceptedAt then missedGrab(combo.name) end
      local more
      if combo.kind == "void" then more = attemptsFor(target).n < S.comboTries
      else more = combo.casts < S.comboTries end
      local index = more and grabSlot(slots) or nil
      if index then
        if combo.kind == "void" then
          local spent = attemptsFor(target)
          spent.n += 1
          combo.tries = spent.n
        end
        combo.slot, combo.name, combo.casts = index, slots[index].name, combo.casts + 1
        combo.firstAt, combo.sentAt, combo.sends, combo.firstSend, combo.acceptedAt = now, -math.huge, 0, nil, nil
        return true
      end
      endCombo("nothing took hold")
      return false
    end
    if not combo.acceptedAt and now - combo.sentAt >= RESEND and settled("Strike") then
      adapter.Wire.skill(combo.slot)
      S.lastSkillAt, S.lastSkillName = now, combo.name
      combo.sentAt = now
      combo.sends += 1
      combo.firstSend = combo.firstSend or now
    end
    return true
  end

  -- The ride is on the owner. With them gone mid-hold there is nothing to ride
  -- to, and snapping to the unbound hold does not carry anyone (measured: a
  -- snap leaves the victim behind), so let go cleanly.
  if not combo.releasedAt and not body(S.owner) then endCombo("the owner went down"); return false end
  if not combo.releasedAt and heldBy(model) and model == combo.body then
    S.comboState = combo.kind == "bring" and "carrying them in" or "carrying them down"
    if combo.kind == "void" then
      -- MEASURED the hard way: the victim descends only while WE are descending,
      -- at our rate and a little behind us. A run that reached its depth early
      -- and parked for the last 0.4 s of the hold gained nothing in that time
      -- and stopped 191 studs above the kill plane. So the ramp never stops
      -- while the hold lasts; the depth we aimed for only sets the pace.
      combo.depth = math.min((now - combo.grabAt) * combo.rate, combo.need * 2)
    end
    -- A marker that never clears is not a hold any move has: let go.
    if now - combo.grabAt > math.max(combo.hold * 3, 6) then endCombo("the hold never ended") end
    return true
  end

  if not combo.releasedAt then
    combo.releasedAt = now
    -- A victim who DIED in the hold took the marker with them early. Learning
    -- that as the move's hold shortened it after every kill, the pace rose to
    -- match, and past the carry's tracking rate the next victim is left behind
    -- -- a combo that worked stopped working the more it killed. So only a
    -- hold that ran its course, on a body still alive, is learned.
    local died = model ~= combo.body or not victim or victim.Health <= 0
      or victim:GetAttribute("Dead") == true or target.Parent ~= Players
    combo.died = died
    if not died then learnGrab(combo.name, now - combo.grabAt) end
    S.carried += 1
    if combo.kind == "bring" then say(S.lines.bring) end
  end
  S.comboState = "letting go"
  -- A delivery holds station for a moment too: the finisher's knockback lands
  -- where the stand is standing, so it must not be halfway home by then.
  local linger = combo.kind == "void" and S.voidLinger or BRING_LINGER
  if now - combo.releasedAt >= linger then endCombo("released", true) end
  return true
end

-- The verdict, and the retry the owner asked for: if they are not down, take
-- them again until the attempt budget runs out. The budget is counted on the
-- target, not on the carry: the retry used to be started here only if a grab
-- happened to be off cooldown 0.6 s after the last one (it never is), and the
-- next carry then began again at attempt 1 -- so the budget was never spent.
local function verifyStep(now)
  local verify = S.verify
  if not verify or now < verify.at then return end
  S.verify = nil
  local state = targetState(verify.target)
  if state == "waiting for respawn" or state == "left" then return end
  if not S.comboOn or S.mode ~= "attacking" or S.target ~= verify.target then return end
  local spent = attemptsFor(verify.target)
  if spent.n >= S.comboTries then
    refuse("They slipped it. Going back to the fists.")
    spent.n = 0
    S.lastCombo = now + math.max(S.comboEvery, 2)
    return
  end
  -- They lived: the next grab to come off cooldown opens the next carry.
  S.lastCombo = -math.huge
end

-- Fling assist: the proven Rep Root transaction, once, on the target. The latch
-- is handed over by the R.runOne wrapper below and comes back when it ends.
local function flingNow(target)
  if S.flingBusy then return false, "already flinging" end
  if not target or not body(target) then return false, "no target to fling" end
  if not R.repRoot then return false, "Rep Root is off" end
  if K.flinging or R.queue or R.tuning then return false, "Rep Root is busy" end
  S.flingBusy, S.lastFling = true, os.clock()
  local saved = { fling = R.fling, duration = K.cfg.flingDuration, returnHome = K.cfg.returnHome }
  R.fling = true
  K.cfg.flingDuration = S.flingDrive
  K.cfg.returnHome = true
  -- Its own thread: startFling can yield up to 1.5 s while a previous attempt
  -- recovers, and the stand's frame loop must never wait on that.
  task.spawn(function()
    local ok, why = pcall(R.runOne, target.Name)
    if not ok or why == false then L.note("stand", "fling assist refused: " .. tostring(why)) end
    local deadline = os.clock() + S.flingDrive + 8
    task.wait(0.1)
    while L.live() and (K.flinging or K.activeCleanup or K.returningHome) and os.clock() < deadline do task.wait(0.05) end
    K.cfg.flingDuration, K.cfg.returnHome = saved.duration, saved.returnHome
    -- setFling re-syncs every control and saved value from the restored config.
    if R.setFling then R.setFling(saved.fling) else R.fling = saved.fling end
    S.flingBusy = false
    S.pauseUntil = os.clock() + 0.2
  end)
  return true
end
S.flingNow = flingNow

-- Grabs learned by watching, not by name. Most kits' grabs are not called
-- anything like "grab" -- the Purple kit's are Head First and the end of Bullet
-- Barrage -- so a hold that one of OUR moves opened on our target is learned the
-- same way a carry learns it: from BeingGrabbed appearing to it disappearing,
-- on a victim still alive at the end. Whose hold it is comes from the victim's
-- LastHit at the frame it begins (measured: the grab's own damage lands in that
-- frame), or, with nobody named, from one of our moves taken moments before.
Q.ownGrab = { model = nil, since = 0, name = nil }
function Q.watchOwnGrab(now)
  local victim = S.mode == "attacking" and S.target and S.target.Character or nil
  local held = victim ~= nil and heldBy(victim)
  local g = Q.ownGrab
  if held and g.model ~= victim then
    g.model, g.since, g.read, g.name = victim, now, false, nil
    -- Alone only: with a squadmate hitting the same victim, its LastHit cannot
    -- say whose hold it is (live, that taught two moves that never grab), and
    -- only a real BeingGrabbed counts -- a pinned attacker is not a grab.
    local solo = (S.strikeCount or 1) <= 1 and victim:FindFirstChild("BeingGrabbed") ~= nil
    g.candidate = (solo and now - S.lastSkillAt < 2.5 and not S.combo) and S.lastSkillName or nil
  end
  -- ours only if WE are the one damaging them once the hold has settled
  if held and not g.read and now - g.since >= Q.HOLD_READ then
    g.read = true
    g.name = victim:GetAttribute("LastHit") == LP.Name and g.candidate or nil
  end
  if not held and g.model then
    local model, name, since = Q.ownGrab.model, Q.ownGrab.name, Q.ownGrab.since
    Q.ownGrab.model = nil
    local hum = model:FindFirstChildOfClass("Humanoid")
    if name and hum and hum.Health > 0 and now - since >= 0.3 then
      learnGrab(name, now - since)
      emit("grab", name, now - since)
    end
  end
end

local function combat()
  local now = os.clock()
  if S.mode == "attacking" then
    local state = targetState(S.target)
    if state == "left" then
      S.mode, S.target, S.engaged, S.waiting = "summoned", nil, nil, nil
      say("They left.")
      return
    end
    if state == "waiting for respawn" and S.engaged then
      -- The body we were fighting is gone: a kill. Wait in the void for the next one.
      S.kills += 1
      emit("kill", S.target)
      S.engaged = nil
      say(S.lines.done)
    end
    S.waiting = state
  end
  if S.mode ~= "off" and S.mode ~= "hidden" and lowHealth() then
    S.mode, S.target, S.engaged, S.barrage, S.lowHidden = "hidden", nil, nil, false, true
    table.clear(S.requests)
    endCombo("too hurt to carry")
    S.verify = nil
    say("I need to recover.")
    return
  end
  local adapter = tsb()
  if not adapter or not S.active then S.gate = adapter and "latch off" or "not in TSB"; return end
  -- A send the server never took expires even while we cannot act, so one
  -- stuck move can never wedge the rotation.
  if S.pending and now - S.pending.at > GIVE_UP then
    S.rotation = S.pending.slot % 4 + 1
    S.requests[S.pending.slot] = nil
    S.pending = nil
  end
  -- Once a grab has hold the carry sends nothing -- it only moves the latch -- so
  -- it must not wait on our own body being "ready". If the grabber is frozen by
  -- its own move for part of the hold, the ramp used to stall there, and a ramp
  -- that stops is a victim who stops sinking (measured: parked 0.4 s = no kill).
  if S.combo and S.combo.grabAt then
    comboStep(now, adapter, adapter.Game.hotbar())
    S.gate = nil
    return
  end
  local me = adapter.Game.read(LP)
  if not adapter.selfReady(me) then
    S.gate = me.frozen and "stand frozen" or me.ragdoll and "stand knocked down" or me.seated and "stand seated"
      or me.anchored and "stand anchored" or "stand cannot act"
    return
  end

  local slots = adapter.Game.hotbar()
  verifyStep(now)
  if not S.combo then Q.watchOwnGrab(now) end
  if S.combo and comboStep(now, adapter, slots) then S.gate = nil; return end

  local attacking = S.mode == "attacking" and not S.waiting and settled("Strike")
  local fronting = S.mode == "summoned" and settled("Front")
  local other = attacking and adapter.Game.read(S.target) or nil
  if other and (other.gone or not other.valid) then S.gate = "target unreadable"; return end
  if other and other.countering then S.gate = "target countering"; return end
  S.gate = S.yield and ("stepping aside: " .. S.yield) or S.reserve and "backup: the squad is full" or nil
  local aimAt = other and other.position
  if not aimAt then
    local _, _, ownerRoot = body(S.owner)
    aimAt = ownerRoot and (ownerRoot.CFrame * CFrame.new(0, 0, -25)).Position
  end
  local aim = aimAt and CFrame.new(aimAt) or nil

  -- A grab is worth more than the next move in the rotation: it is the whole
  -- combo. Only while actually on them, and only once the void can hold us.
  -- Not while someone else's grab has them: it is not ours to ride, and a grab
  -- sent into a hold is a cooldown spent on nothing. With a squad on one prey
  -- only the leader (slot 1) carries: two stands casting grabs into one victim
  -- both took the hold for their own and rode down together. The others keep
  -- hunting, and step aside while the leader has them.
  local leader = (S.strikeSlot or 1) == 1
  local asked = S.voidAsked ~= nil and now - S.voidAsked < 8
  if attacking and (S.comboOn or asked) and leader and not S.pending and (asked or now - S.lastCombo >= S.comboEvery)
    and not other.grabbed and attemptsFor(S.target).n < S.comboTries and grabSlot(slots) then
    if beginCombo("void", S.target) then S.voidAsked = nil; return end
    S.lastCombo = now   -- refused (no owner, no void gate): wait out the interval
  end

  -- Dashes run on their own clock, weaving between and around every move. One
  -- still on TSB's cooldown is simply refused, so trying often costs nothing.
  if S.dashSpam and (attacking or (fronting and S.barrage)) and now - lastDash >= S.dashGap then
    adapter.Wire.dash(Enum.KeyCode.W, aim) -- forward: straight at the target's back
    lastDash = now
  end

  if attacking and S.flingAssist and not S.flingBusy and now - S.lastFling >= S.flingEvery then
    local health = other.health and other.maxHealth and other.health / other.maxHealth * 100 or 100
    if health <= S.flingBelow or (other.ragdoll and not nextReady(slots)) then flingNow(S.target); return end
  end

  -- A skill that has not been taken yet is re-sent until its cooldown shows.
  if S.pending then
    local slot = slots[S.pending.slot]
    if slot and slot.cooling then
      -- taken: this is the moment a hold of ours can start from
      S.lastSkillAt, S.lastSkillName = now, slot.name
      S.rotation = S.pending.slot % 4 + 1
      if S.requests[S.pending.slot] then S.requests[S.pending.slot] = nil end
      if S.mode == "summoned" then S.frontUntil = math.max(S.frontUntil, now + 0.9) end
      S.pending = nil
    else
      if now - S.pending.sentAt >= RESEND and (attacking or fronting) then
        adapter.Wire.skill(S.pending.slot)
        S.pending.sentAt = now
      end
      return
    end
  end

  if attacking or fronting then
    local index = chooseSlot(slots, now, attacking)
    if index then
      if S.requests[index] then S.requests[index].sent = true end
      adapter.Wire.skill(index)
      S.lastSkillAt, S.lastSkillName = now, slots[index] and slots[index].name
      S.pending = { slot = index, at = now, sentAt = now }
      if S.mode == "summoned" then S.frontUntil = math.max(S.frontUntil, now + 1.2) end
      return
    end
  end

  if attacking and S.autoUlt and adapter.Game.ultimateReady() and now - lastUlt > 2 then
    adapter.Wire.ult(); lastUlt = now; return
  end

  local punching = (attacking and S.useM1) or (fronting and S.barrage)
  if punching and aim and now - lastM1 >= 0.12 and LP.Character and LP.Character:GetAttribute("M1Ready") ~= false then
    adapter.Wire.m1(aim)
    lastM1 = now
  end
end

-- ---------------------------------------------------------------- actions
function S.summon()
  if not S.owner then return false, "Choose an owner first" end
  if lowHealth() then refuse("Too hurt to come out."); return false, "health below the dismiss threshold" end
  S.target, S.engaged, S.waiting, S.barrage, S.lowHidden = nil, nil, nil, false, false
  -- "Come here" calls off a void run; a delivery already under way is to the
  -- owner anyway and is left to land.
  if S.combo and S.combo.kind == "void" then S.endCombo("summoned back"); S.verify = nil end
  if S.mode ~= "summoned" then S.mode = "summoned"; say(S.lines.summon) end
  return true
end

function S.dismiss()
  if not S.owner then return false, "Choose an owner first" end
  S.target, S.engaged, S.waiting, S.barrage, S.frontUntil = nil, nil, nil, false, 0
  table.clear(S.requests)
  S.endCombo("dismissed"); S.verify = nil
  if S.mode ~= "hidden" then S.mode = "hidden"; say(S.lines.dismiss) end
  return true
end

function S.stop()
  S.barrage, S.frontUntil = false, 0
  table.clear(S.requests)
  S.endCombo("stopped"); S.verify = nil
  if S.mode == "attacking" then S.mode, S.target, S.engaged, S.waiting = "summoned", nil, nil, nil end
  return true
end

-- The UI's full release: stand goes back to being an ordinary character.
function S.free(why)
  S.mode, S.target, S.engaged, S.waiting, S.barrage, S.frontUntil = "off", nil, nil, nil, false, 0
  table.clear(S.requests)
  S.endCombo(why or "released"); S.verify = nil
  release(why or "released")
  -- Hand the kill plane back now, not on the next frame: on unload there is no
  -- next frame, and the gate stayed closed (and FallenPartsDestroyHeight NaN)
  -- for the rest of the session -- a later ordinary fall would never end.
  wantVoid(false)
  return true
end

local function pickTarget(query)
  local target, why
  if query and query ~= "" then target, why = findPlayer(query, { [LP] = true, [S.owner] = true })
  else target = nearestToOwner() end
  if not target then return nil, why or "no one in range" end
  if target == S.owner or target == LP then return nil, "not them" end
  if excluded(target) then return nil, "they are on the whitelist" end
  return target
end

function S.attack(query)
  if not S.owner then return false, "Choose an owner first" end
  if lowHealth() then refuse("Too hurt to fight."); return false, "health below the dismiss threshold" end
  local target, why = pickTarget(query)
  if not target then refuse("No target: " .. tostring(why) .. "."); return false, why end
  S.target, S.mode, S.barrage, S.engaged, S.waiting = target, "attacking", false, nil, nil
  S.endCombo("new target"); S.verify = nil
  -- Every stand hears the command in the same frame: form up at once, counting
  -- the ones still on the owner as the hunters they are about to be.
  S.engageAt = os.clock()
  refreshSquad()
  -- Each stand starts the rotation on its own slot, so a squad opening on one
  -- target does not fire four copies of the same move into the same frame.
  S.rotation, S.pending = (S.strikeSlot - 1) % 4 + 1, nil
  S.lastCombo = -math.huge
  say(S.lines.attack)
  return true
end

-- Take them and carry them somewhere. "void" rides them past TSB's own kill
-- plane; "bring" delivers them to the owner. Both are the same measured trick.
--
-- Neither of these acquires a target the way .a does. .a is the hunt: say it
-- bare and it picks the nearest. A carry is a single errand on someone you
-- name, so a bare one only works on whoever is already being fought, and
-- otherwise asks who -- being handed the nearest stranger is not what "bring
-- him here" means. A bring is not a hunt either: it does not take the target
-- over, and the stand goes straight back beside the owner once they are down.
local function carry(kind, query)
  if not S.owner then return false, "Choose an owner first" end
  if lowHealth() then refuse("Too hurt for that."); return false, "health below the dismiss threshold" end
  local target, why
  if query and query ~= "" then target, why = pickTarget(query)
  elseif S.target then target = S.target
  else why = kind == "bring" and "say who to bring" or "say who" end
  if not target then refuse("Who? " .. tostring(why) .. "."); return false, why end
  if kind == "void" then
    if S.mode ~= "attacking" or S.target ~= target then
      S.target, S.mode, S.barrage, S.engaged, S.waiting = target, "attacking", false, nil, nil
      S.engageAt = os.clock()
      refreshSquad()
      S.rotation, S.pending = (S.strikeSlot - 1) % 4 + 1, nil
    end
    -- A squad hunts them together and only the leader takes hold: the others
    -- keep hitting, and step aside the moment the leader has them.
    if (S.strikeSlot or 1) ~= 1 then return true, "the squad leader carries" end
  elseif S.mode ~= "attacking" and S.mode ~= "summoned" then
    local ok, reason = S.summon()
    if not ok then return false, reason end
  end
  local ok, reason = beginCombo(kind, target)
  if not ok then
    -- no grab off cooldown yet: open with one the moment it is
    if kind == "void" and reason == "no grab is ready" then S.voidAsked = os.clock() end
    refuse("Can't take them: " .. tostring(reason) .. ".")
  end
  return ok, reason
end

function S.bring(query) return carry("bring", query) end
function S.voidDrop(query) return carry("void", query) end

function S.skill(index)
  if not S.owner then return false, "Choose an owner first" end
  if not tsb() then refuse("Skills need The Strongest Battlegrounds."); return false end
  if S.mode ~= "attacking" and S.mode ~= "summoned" then
    local ok, why = S.summon()
    if not ok then return false, why end
  end
  local now = os.clock()
  S.requests[index] = { at = now, untilAt = now + 2 }
  if S.mode == "summoned" then S.frontUntil = math.max(S.frontUntil, now + 1.2) end
  return true
end

function S.toggleBarrage()
  if not S.owner then return false, "Choose an owner first" end
  if S.mode == "attacking" then return false, "already attacking" end
  if S.mode ~= "summoned" then local ok, why = S.summon(); if not ok then return false, why end end
  S.barrage = not S.barrage
  return true
end

function S.toggleDash()
  S.dashSpam = not S.dashSpam
  saveFeat("dashSpam", S.dashSpam)
  if S.controls.dashSpam then S.controls.dashSpam:set(S.dashSpam, true) end
  say(S.dashSpam and "Dashing." or "No more dashing.")
  return true
end

function S.ult()
  local adapter = tsb()
  if not adapter then refuse("Awakening needs The Strongest Battlegrounds."); return false end
  if not adapter.Game.ultimateReady() then refuse("Not ready yet."); return false end
  adapter.Wire.ult(); lastUlt = os.clock()
  return true
end

function S.fling(query)
  if not S.owner then return false, "Choose an owner first" end
  local target, why
  if (not query or query == "") and S.mode == "attacking" and S.target then target = S.target
  else target, why = pickTarget(query) end
  if not target then refuse("No target: " .. tostring(why) .. "."); return false, why end
  local ok, reason = flingNow(target)
  if not ok then refuse("Can't fling: " .. tostring(reason) .. ".") end
  return ok, reason
end

local function refreshSliders()
  local pose = S.poses[S.editing]
  for key, control in pairs(S.sliders) do control:set(pose[key], true) end
  if S.poseInfo then S.poseInfo.Text = POSE_INFO[S.editing] end
end

local function setPose(name, values)
  local pose = S.poses[name]
  for key, value in pairs(values) do
    local range = RANGE[key]
    if range and finite(value) then
      pose[key] = math.clamp(value, range[1], range[2])
      saveFeat("pose." .. name .. "." .. key, pose[key])
    end
  end
  if S.editing == name then refreshSliders() end
end

function S.side(which)
  local values = SIDES[tostring(which or ""):lower()]
  if not values then refuse("Sides: right, left, behind, above."); return false end
  setPose("Idle", values)
  return true
end

-- The attack angle is written straight into the Strike pose, so the latch, the
-- sliders, the preview and the saved config all keep seeing one pose and
-- nothing else. The squad fan is applied on top of it at latch time, because it
-- depends on who else is standing here and must not be saved.
local function applyApproach()
  local a = S.approach
  local t = math.rad(a.angle)
  local yaw = S.facing == "Face away" and a.angle + 180 or a.angle
  setPose("Strike", { x = math.sin(t) * a.radius, y = a.height, z = math.cos(t) * a.radius,
    pitch = 0, yaw = (yaw + 180) % 360 - 180, roll = 0 })
end

function S.setApproach(values, keepPreset)
  for key, value in pairs(values) do
    if finite(value) then
      if key == "angle" then S.approach.angle = (value % 360 + 360) % 360
      elseif key == "radius" then S.approach.radius = math.clamp(value, 0.5, 30)
      elseif key == "height" then S.approach.height = math.clamp(value, -20, 20) end
    end
  end
  for key, value in pairs(S.approach) do saveFeat("approach." .. key, value) end
  if not keepPreset then
    S.approachPreset = "Custom"
    saveFeat("approach.preset", "Custom")
    pcall(function() if S.controls.preset then S.controls.preset:set("Custom", true) end end)
  end
  pcall(function()
    for key, control in pairs(S.angleControls or {}) do
      if S.approach[key] then control:set(S.approach[key], true) end
    end
  end)
  applyApproach()
  return true
end

function S.setFacing(value)
  if not table.find(FACINGS, value) then return false, "Face them or Face away" end
  S.facing = value
  saveFeat("approach.facing", value)
  applyApproach()
  return true
end

-- One word from chat picks a ready-made angle.
function S.angle(which)
  local query = tostring(which or ""):lower():gsub("%s+", " "):match("^%s*(.-)%s*$")
  local name
  for _, candidate in ipairs(APPROACH_NAMES) do
    if candidate:lower() == query then name = candidate end
  end
  if not name then
    for _, candidate in ipairs(APPROACH_NAMES) do
      if candidate ~= "Custom" and candidate:lower():sub(1, #query) == query and query ~= "" then name = name or candidate end
    end
  end
  local preset = name and APPROACH_PRESETS[name]
  if not preset then
    refuse("Angles: behind, behind left, behind right, left flank, right flank, in front, above, below, point blank.")
    return false, "unknown angle"
  end
  S.approachPreset = name
  saveFeat("approach.preset", name)
  pcall(function() if S.controls.preset then S.controls.preset:set(name, true) end end)
  -- the ring presets stand at the hunt distance; the special ones bring their own
  S.setApproach({ angle = preset.angle, radius = preset.radius or S.huntDistance, height = preset.height or 0 }, true)
  return true
end

-- How far from the prey the ring presets stand. The measured default is 6.1.
-- One knob for the distance, whichever way it is turned (the loader's
-- HUNT_DISTANCE, .dist in chat, the console's slider): every ring angle and a
-- hand-tuned one stand at it; Above, Below and Point blank keep their own.
function S.setHuntDistance(value)
  if not finite(value) then return false, "a number of studs" end
  S.huntDistance = math.clamp(value, 0.5, 30)
  saveFeat("huntDistance", S.huntDistance)
  local preset = APPROACH_PRESETS[S.approachPreset]
  if not (preset and preset.radius) then S.setApproach({ radius = S.huntDistance }, true) end
  return true
end

-- A saved preset owns the Strike pose, re-applied at the hunt distance (a pose
-- saved at the old 3-stud default moves out to 6.1); a hand-tuned one
-- ("Custom") is left exactly as it was saved, so nobody's tuning is overwritten.
if S.approachPreset ~= "Custom" then
  local preset = APPROACH_PRESETS[S.approachPreset]
  S.approach.angle, S.approach.radius, S.approach.height = preset.angle, preset.radius or S.huntDistance, preset.height or 0
  applyApproach()
end

-- ---------------------------------------------------------------- commands
-- One table drives the chat parser, the tab's list and the in-chat summary.
local COMMANDS, LOOKUP = {}, {}
local function command(names, args, desc, fn)
  local entry = { names = names, args = args, desc = desc, fn = fn }
  COMMANDS[#COMMANDS + 1] = entry
  for _, name in ipairs(names) do LOOKUP[name] = entry end
end
command({ "s", "summon" }, "", "summon the stand beside you", function() S.summon() end)
command({ "d", "dismiss" }, "", "hide the stand in the void under you", function() S.dismiss() end)
command({ "a", "attack" }, "[name]", "hunt a player from behind until you say stop; nearest to you if blank", function(rest) S.attack(rest) end)
command({ "stop" }, "", "stop attacking or punching and come back", function() S.stop() end)
command({ "1", "2", "3", "4" }, "", "use that skill now, on the target or in front of you", function(_, word) S.skill(tonumber(word)) end)
command({ "m1" }, "", "punch barrage in front of you; say it again to stop", function() S.toggleBarrage() end)
command({ "dash" }, "", "turn dash spam on or off", function() S.toggleDash() end)
command({ "ult" }, "", "awaken when the bar is full", function() S.ult() end)
command({ "b", "bring" }, "name", "take hold of that player and carry them to you", function(rest) S.bring(rest) end)
command({ "v", "void" }, "name", "take hold of that player and carry them under the kill plane", function(rest) S.voidDrop(rest) end)
command({ "angle" }, "behind | left flank | in front | above | ...", "the angle the stand strikes from", function(rest) S.angle(rest) end)
command({ "dist", "distance" }, "studs", "how far the stand keeps from its prey (6.1 is measured M1 reach)", function(rest)
  local n = tonumber((tostring(rest or "")):match("%-?[%d%.]+"))
  if not n then refuse("Distance: a number of studs, like .dist 6.1"); return end
  S.setHuntDistance(n)
  say(string.format("Keeping %.1f studs.", S.huntDistance))
end)
command({ "auto" }, "", "find the other stands by themselves and take a slot each", function() S.toggleAuto() end)
command({ "fan" }, "ring | arc", "spread all the way round, or keep everyone near one angle", function(rest) S.setFan(rest) end)
command({ "squad" }, "[name, name]", "name other stands by hand; blank clears the list", function(rest) S.setSquad(rest) end)
command({ "fling" }, "[name]", "one Rep Root fling; the current target if blank", function(rest) S.fling(rest) end)
command({ "pose" }, "right | left | behind | above", "where the stand waits beside you", function(rest) S.side(rest) end)
command({ "say" }, "text", "make the stand talk", function(rest) say(rest, true) end)
-- Built from the table itself, so commands added later (.gui, .black) are listed.
command({ "cmds" }, "", "the stand lists these in chat", function()
  local p, parts, seenOne = S.prefix, {}, false
  for _, entry in ipairs(COMMANDS) do
    local name = entry.names[1]
    if tonumber(name) then
      if not seenOne then seenOne = true; parts[#parts + 1] = p .. "1-4" end
    else
      local arg = entry.args:find("name", 1, true) and " name" or entry.args == "studs" and " n" or ""
      parts[#parts + 1] = p .. name .. arg
    end
  end
  say(table.concat(parts, " "), true)
end)
S.COMMANDS = COMMANDS
-- Extra commands from whoever embeds the stand (StandCore adds .gui).
S.addCommand = function(names, args, desc, fn)
  command(names, args, desc, fn)
  if S.refreshCommands then S.refreshCommands() end
end

-- The roster the fan is computed from. Typed as names, kept as typed, matched
-- case-insensitively against whoever is actually in the server.
function S.toggleAuto()
  S.squadAuto = not S.squadAuto
  saveFeat("squad.auto", S.squadAuto)
  pcall(function() if S.controls.auto then S.controls.auto:set(S.squadAuto, true) end end)
  refreshSquad()
  say(S.squadAuto and ("Spreading out. " .. S.squadCount .. " of us.") or "On my own angle.")
  return true
end

function S.setFan(value)
  local want = tostring(value or ""):lower()
  local mode = want:sub(1, 1) == "a" and "Arc" or want:sub(1, 1) == "r" and "Ring" or nil
  if not mode then refuse("Fan: ring or arc."); return false, "ring or arc" end
  S.fanMode = mode
  saveFeat("squad.mode", mode)
  pcall(function() if S.controls.fan then S.controls.fan:set(mode, true) end end)
  return true
end

function S.setSquad(value)
  value = tostring(value or ""):gsub("[^%w_,@%s]", ""):sub(1, 200)
  S.squadNames = value
  saveFeat("squad.names", value)
  pcall(function() if S.controls.squad then S.controls.squad:set(value) end end)
  refreshSquad()
  return true
end

function S.handle(message, fromUI)
  if not S.listen and not fromUI then return false end
  message = tostring(message or ""):match("^%s*(.-)%s*$")
  local prefix = S.prefix or ""
  if prefix ~= "" then
    if message:sub(1, #prefix):lower() ~= prefix:lower() then return false end
    message = message:sub(#prefix + 1)
  end
  local word, rest = message:match("^(%S+)%s*(.-)$")
  if not word then return false end
  word = word:lower()
  local entry = LOOKUP[word]
  if not entry then return false end
  S.lastCommand = prefix .. word .. (rest ~= "" and (" " .. rest) or "")
  emit("command", word, rest, fromUI == true)
  local ok, err = pcall(entry.fn, rest, word)
  if not ok then L.fault("stand.command", err) end
  return ok
end

-- Both chat paths deliver the owner's message to this client in the same frame
-- (measured), so each message is handled once. The window is far shorter than
-- anyone can type and send the same command twice.
local recent = {}
local function heard(player, message)
  if not player or player == LP or player ~= S.owner or type(message) ~= "string" then return end
  local key = player.UserId .. "\0" .. message
  local now = os.clock()
  if recent[key] and now - recent[key] < 0.25 then return end
  recent[key] = now
  for k, at in pairs(recent) do if now - at > 5 then recent[k] = nil end end
  S.handle(message)
end
L.hold(TCS.MessageReceived:Connect(function(msg)
  if msg.Status ~= Enum.TextChatMessageStatus.Success then return end
  local source = msg.TextSource
  if source then heard(Players:GetPlayerByUserId(source.UserId), msg.Text) end
end))
local function hookChat(player)
  L.hold(player.Chatted:Connect(function(message) heard(player, message) end))
end
for _, player in ipairs(Players:GetPlayers()) do hookChat(player) end

-- ---------------------------------------------------------------- owner
local ownerItems = { "None" }
local function refreshOwnerItems()
  table.clear(ownerItems)
  ownerItems[1] = "None"
  local names = {}
  for _, p in ipairs(Players:GetPlayers()) do if p ~= LP then names[#names + 1] = p.Name end end
  table.sort(names, function(a, b) return a:lower() < b:lower() end)
  for _, name in ipairs(names) do ownerItems[#ownerItems + 1] = name end
end

local function refreshCommands()
  local label = S.commandLabel
  if not label then return end
  if not S.owner then
    label.Text = S.ownerName ~= "" and (S.ownerName .. " is not in this server. Their commands appear here when they join.")
      or "Choose an owner above. Their chat commands appear here."
    return
  end
  local p = S.prefix
  local lines = { "@" .. S.owner.Name .. " types these in chat" .. (p ~= "" and "" or " (no prefix)") .. ":" }
  for _, entry in ipairs(COMMANDS) do
    local names = {}
    for _, name in ipairs(entry.names) do names[#names + 1] = p .. name end
    local usage = table.concat(names, "  ") .. (entry.args ~= "" and ("  " .. entry.args) or "")
    lines[#lines + 1] = usage .. "   -   " .. entry.desc
  end
  label.Text = table.concat(lines, "\n")
end
S.refreshCommands = refreshCommands

-- The owner, found the forgiving way. The configured name is kept as given;
-- the match tries the exact username, then a user id, then the same name in
-- other letter case, then a display name -- and says which it used, so a
-- wrong-case name is fixed and reported instead of silently never matching.
Q.MATCH_RANK = { exact = 1, ["user id"] = 2, case = 3, ["display name"] = 4 }
function Q.ownerMatch(player, name)
  if not player or player == LP or name == "" then return nil end
  local q = name:gsub("^@", "")
  if player.Name == q then return "exact" end
  if tonumber(q) and player.UserId == tonumber(q) then return "user id" end
  if player.Name:lower() == q:lower() then return "case" end
  if player.DisplayName:lower() == q:lower() then return "display name" end
  return nil
end
function Q.resolveOwner(name)
  local best, how
  for _, p in ipairs(Players:GetPlayers()) do
    local m = Q.ownerMatch(p, name)
    if m and (not how or Q.MATCH_RANK[m] < Q.MATCH_RANK[how]) then best, how = p, m end
  end
  return best, how
end
S.resolveOwner = Q.resolveOwner

function S.setOwner(name)
  name = tostring(name or ""):match("^%s*(.-)%s*$")
  if name == "None" then name = "" end
  -- never ourselves
  if name ~= "" and (LP.Name:lower() == name:gsub("^@", ""):lower() or tostring(LP.UserId) == name) then name = "" end
  local player, how
  if name ~= "" then player, how = Q.resolveOwner(name) end
  if player ~= S.owner or name ~= S.ownerName then S.free("owner changed"); S.lastOwnerFrame = nil end
  S.owner, S.ownerName, S.ownerMatch = player, name, how
  S.ownerStatus = name == "" and "none" or player and "here" or "away"
  saveFeat("owner", name)
  refreshCommands()
  emit("owner", name == "" and "cleared" or player and "found" or "missing", player, how)
  return true
end

function S.setPrefix(value)
  value = tostring(value or ""):gsub("%s", ""):sub(1, 3)
  S.prefix = value
  saveFeat("prefix", value)
  if S.controls.prefix then S.controls.prefix:set(value) end
  refreshCommands()
end

L.hold(Players.PlayerAdded:Connect(function(player)
  hookChat(player)
  refreshOwnerItems()
  if S.ownerName ~= "" and not S.owner then
    local how = Q.ownerMatch(player, S.ownerName)
    if how then
      S.owner, S.ownerMatch, S.ownerStatus = player, how, "here"
      refreshCommands()
      emit("owner", "joined", player, how)
      -- they left while it was beside them: be beside them again
      if S.resumeOnReturn and S.mode == "off" then S.resumeOnReturn = false; S.summon() end
    end
  end
end))
L.hold(Players.PlayerRemoving:Connect(function(player)
  if player == S.owner then
    S.owner, S.ownerStatus = nil, "left"
    if S.mode == "attacking" and S.huntAlone then
      -- The hunt goes on without them (the user's call, 2026-09-30). Nothing
      -- rides the owner any more, so a carry lets go; kills still loop.
      S.endCombo("the owner left"); S.verify = nil
      emit("owner", "left-hunting", player)
    else
      S.resumeOnReturn = S.mode ~= "off"
      S.free("owner left")
      emit("owner", "left", player)
    end
    task.defer(refreshCommands)
  elseif player == S.target then
    S.mode, S.target, S.engaged, S.waiting = "summoned", nil, nil, nil
  end
  task.defer(refreshOwnerItems)
end))
refreshOwnerItems()
do
  if S.ownerName ~= "" then
    local p, how = Q.resolveOwner(S.ownerName)
    S.owner, S.ownerMatch, S.ownerStatus = p, how, p and "here" or "away"
  end
end

-- ---------------------------------------------------------------- lifecycle
-- Every Rep Root transaction owns the binding while it runs, and records the
-- body's position as "home" when it starts. Hand the body back first, standing
-- beside the owner, so home is never the raw pose coordinates under the map.
local baseRunOne = R.runOne
function R.runOne(name)
  if S.active then release("Rep Root fling started") end
  S.pauseUntil = os.clock() + 0.5
  return baseRunOne(name)
end
local baseBeginQueue = R.beginQueue
if baseBeginQueue then
  function R.beginQueue(name)
    if S.active then release("Targets loop started") end
    S.pauseUntil = os.clock() + 0.5
    return baseBeginQueue(name)
  end
end

L.bind("GiorgioStandCamera", Enum.RenderPriority.Camera.Value - 1, function()
  if L.live() then pcall(aimCamera) end
end)

L.hold(RS.Heartbeat:Connect(function(dt)
  if not L.live() then return end
  local ok, err = pcall(step, dt)
  if not ok then L.fault("stand.step", err); release("error") end
  ok, err = pcall(combat)
  if not ok then L.fault("stand.combat", err) end
end))

-- Where the stand really is. Our own body sits at the raw pose coordinates, so
-- without this the operator never sees their stand beside the owner.
local marker
-- ... and where it is going to stand on the target. The angle rig is drawn on a
-- live body, so turning the dial moves a real mark on a real player: our own
-- slot solid, every other stand's slot a ghost, and a ring for the scale. This
-- is the only way to see, before committing, that no two stands in the fan are
-- inside each other's swing.
local rig = { parts = {}, on = false }
local RING_DOTS = 16
local function rigPart(key, size, transparency, colour)
  local part = rig.parts[key]
  if not part or not part.Parent then
    part = L.mk("Part", { Name = "GiorgioStandAngle", Anchored = true, CanCollide = false, CanTouch = false,
      CanQuery = false, Material = Enum.Material.Neon, Parent = workspace })
    L.own(part)
    rig.parts[key] = part
  end
  part.Size = size
  part.Transparency = transparency
  part.Color = colour or T.c.accent
  return part
end

local function clearRig()
  if not rig.on then return end
  for key, part in pairs(rig.parts) do
    pcall(function() part:Destroy() end)
    rig.parts[key] = nil
  end
  rig.on = false
end

-- The body the angles are drawn on: whoever is being fought, else the player
-- named for the preview, else the nearest one to the owner.
local function previewBody()
  if S.mode == "attacking" and S.target then
    local _, _, root = body(S.target)
    if root then return root end
  end
  if S.previewWho ~= "" then
    local named = Players:FindFirstChild(S.previewWho)
    if named and named ~= LP then
      local _, _, root = body(named)
      if root then return root end
    end
  end
  local near = nearestToOwner()
  if near then return (select(3, body(near))) end
  return nil
end

local function drawRig()
  if not (S.previewAngles and S.mode ~= "off") then clearRig(); return end
  local targetRoot = previewBody()
  if not targetRoot then clearRig(); return end
  rig.on = true
  local frame = targetRoot.CFrame
  local a = S.approach
  -- the scale ring, at the chosen radius and height
  for dot = 1, RING_DOTS do
    local t = math.rad((dot - 1) * 360 / RING_DOTS)
    local part = rigPart("ring" .. dot, Vector3.new(0.35, 0.35, 0.35), 0.75, T.c.accent)
    part.CFrame = frame * CFrame.new(math.sin(t) * a.radius, a.height, math.cos(t) * a.radius)
  end
  -- one block per stand in the fan; ours is the solid one
  local count = math.max(S.squadCount, 1)
  for slot = 1, count do
    local delta = spread(slot, count)
    local pose = CFrame.Angles(0, math.rad(delta), 0) * poseFrame("Strike")
    local mine = slot == S.squadSlot
    local block = rigPart("slot" .. slot, Vector3.new(1.6, 3, 1), mine and 0.35 or 0.8, T.c.accent)
    block.CFrame = frame * pose
    -- a nose on each, so the facing is readable at a glance
    local nose = rigPart("nose" .. slot, Vector3.new(0.3, 0.3, 1.6), mine and 0.35 or 0.85, T.c.accent)
    nose.CFrame = frame * pose * CFrame.new(0, 0, -1.3)
  end
  for slot = count + 1, 8 do
    for _, key in ipairs({ "slot" .. slot, "nose" .. slot }) do
      local part = rig.parts[key]
      if part then pcall(function() part:Destroy() end); rig.parts[key] = nil end
    end
  end
end

L.hold(RS.RenderStepped:Connect(function()
  if not L.live() then return end
  local frame
  if S.preview then
    if S.active and S.anchorRoot and S.lastWorld then frame = S.lastWorld
    elseif not S.active and S.owner then
      local _, _, ownerRoot = body(S.owner)
      if ownerRoot then frame = ownerRoot.CFrame * localFrame(ownerRoot, ownerRoot.CFrame, S.editing, 0) end
    end
  end
  if frame then
    if not marker then
      marker = L.mk("Part", { Name = "GiorgioStandMarker", Anchored = true, CanCollide = false, CanTouch = false,
        CanQuery = false, Transparency = 0.7, Color = T.c.accent, Material = Enum.Material.Neon,
        Size = Vector3.new(2, 2, 1), Parent = workspace })
      L.own(marker)
    end
    marker.CFrame = frame
  elseif marker then
    marker:Destroy(); marker = nil
  end
  local ok, err = pcall(drawRig)
  if not ok then L.fault("stand.preview", err); S.previewAngles = false end
end))

L.hold(UIS.InputBegan:Connect(function(input, processed)
  if not L.live() or processed or UIS:GetFocusedTextBox() then return end
  if input.KeyCode == Enum.KeyCode.Backspace and S.mode ~= "off" then S.free("emergency stop") end
end))
L.cleanup(function() S.free("unloaded") end, 140)

-- ---------------------------------------------------------------- the tab
function S.build(win)
  S.controls, S.sliders = {}, {}
  local page = win:tab({ name = "Stand", chrome = "compass",
    desc = "A TSB stand your owner commands from chat. Every latch is Rep Root." }).body
  C.ctx("stand")
  local tiles = C.tiles(page, { { key = "owner", label = "Owner", value = "None" },
    { key = "mode", label = "Stand", value = "Off" }, { key = "latch", label = "Latch", value = "Free" },
    { key = "kills", label = "Kills", value = "0" }, { key = "carry", label = "Carry", value = "idle" } })

  C.section(page, "owner")
  S.controls.owner = C.dropdown(page, { id = "stand.owner", persist = false, text = "Owner",
    items = ownerItems, default = S.ownerName ~= "" and S.ownerName or "None",
    callback = function(v) return S.setOwner(v) end })
  S.controls.prefix = C.input(page, { id = "stand.prefix", persist = false, text = "Command prefix",
    desc = "Typed before every command; press Enter to apply. Leave blank for bare words.", placeholder = "none",
    default = S.prefix, callback = function(v) S.setPrefix(v) end })
  C.toggle(page, { id = "stand.listen", text = "Take orders from the owner",
    desc = "Only the owner's chat is read. Backspace frees the stand.", default = S.listen,
    callback = function(v) S.listen = v == true end })
  local function run(fn, ...)
    local ok, why = fn(...)
    if ok == false and why then L.Toast.warn("Stand", tostring(why)) end
  end
  C.actions(page, {
    { text = "Summon", primary = true, callback = function() run(S.summon) end },
    { text = "Dismiss", callback = function() run(S.dismiss) end },
    { text = "Stop", callback = function() run(S.stop) end },
    { text = "Free stand", callback = function() run(S.free, "freed from the tab") end },
  })

  C.section(page, "commands")
  S.commandLabel = C.paragraph(page, ""):FindFirstChildWhichIsA("TextLabel", true)
  refreshCommands()

  C.section(page, "pose")
  C.dropdown(page, { id = "stand.editing", persist = false, text = "Editing pose", items = POSE_NAMES,
    default = S.editing, callback = function(v) S.editing = v; refreshSliders() end })
  S.poseInfo = C.paragraph(page, POSE_INFO[S.editing]):FindFirstChildWhichIsA("TextLabel", true)
  local labels = {
    x = { "Offset X", "Anchor-local left / right" }, y = { "Offset Y", "Anchor-local down / up" },
    z = { "Offset Z", "Anchor-local forward (-) / behind (+)" }, pitch = { "Pitch", "X rotation in degrees" },
    yaw = { "Yaw", "Y rotation in degrees; 180 turns to face the anchor" }, roll = { "Roll", "Z rotation in degrees" },
  }
  for _, key in ipairs(POSE_KEYS) do
    local range = RANGE[key]
    S.sliders[key] = C.slider(page, { id = "stand.edit." .. key, persist = false, text = labels[key][1],
      desc = labels[key][2], min = range[1], max = range[2], step = (key == "x" or key == "y" or key == "z") and 0.01 or 0.1,
      default = S.poses[S.editing][key], callback = function(v)
        if not finite(v) then return false end
        setPose(S.editing, { [key] = v })
      end })
  end
  C.actions(page, {
    { text = "Reset pose", callback = function() setPose(S.editing, POSE_DEFAULTS[S.editing]) end },
    { text = "Idle right", callback = function() S.side("right") end },
    { text = "Idle left", callback = function() S.side("left") end },
    { text = "Idle behind", callback = function() S.side("behind") end },
    { text = "Idle above", callback = function() S.side("above") end },
  })
  C.dropdown(page, { id = "stand.stance", text = "Idle pose", items = STANCES, default = S.stance,
    callback = function(v) S.stance = v end })
  C.paragraph(page, "The game's own emote stances, every one load-tested on this rig. Perfect Concentration is the default: head bowed, still, the way a stand waits. Fighting stance and Calm float are the old two -- the first is TSB's idle guard, which is really just breathing with the arms down. The pose is held every frame and the humanoid is Q.pinned to Running, so a move can no longer leave it standing wrong afterwards.")
  C.input(page, { id = "stand.stanceCustom", text = "Custom animation ID", desc = "Used when the animation is Custom",
    placeholder = "rbxassetid", default = S.stanceCustom, callback = function(v) S.stanceCustom = tostring(v or "") end })
  C.slider(page, { id = "stand.float", text = "Float motion", desc = "Studs of gentle bob; 0 holds still",
    min = 0, max = 2, step = 0.05, default = S.float, callback = function(v) if finite(v) then S.float = v end end })
  C.toggle(page, { id = "stand.upright", text = "Keep upright", desc = "Ignores the anchor's tilt and ragdolls; keeps its heading",
    default = S.upright, callback = function(v) S.upright = v == true end })
  C.toggle(page, { id = "stand.platformStand", text = "PlatformStand", desc = "Stiff hover. Off keeps TSB's own idle animation and the pose above; on stops both",
    default = S.hover, callback = function(v)
      S.hover = v == true
      if not S.hover and S.active and latch.hum and latch.hum.Parent then latch.hum.PlatformStand = latch.platform end
    end })
  C.toggle(page, { id = "stand.preview", text = "Show where others see it", desc = "Local marker at the stand's real position, or at the pose you are editing",
    default = S.preview, callback = function(v) S.preview = v == true end })
  C.toggle(page, { id = "stand.camera", text = "Camera on the owner", desc = "Your own body sits far from the stand; this keeps your view on the owner",
    default = S.camera, callback = function(v) S.camera = v == true end })

  C.section(page, "attack angle")
  C.paragraph(page, "Where the stand stands on its target. 0 is directly behind them, 90 their right, 180 in front, 270 their left; it turns to face them from wherever you put it. Turn on the preview below and the angle is drawn on a live body while you move the dial.")
  S.angleControls = {}
  S.controls.preset = C.dropdown(page, { id = "stand.approachPreset", text = "Ready angle", items = APPROACH_NAMES,
    default = S.approachPreset, callback = function(v)
      if v == "Custom" then S.approachPreset = "Custom"; return end
      return S.angle(v)
    end })
  S.angleControls.angle = C.slider(page, { id = "stand.approach.angle", persist = false, text = "Angle around them",
    desc = "Degrees clockwise from directly behind", min = 0, max = 359, step = 1, default = S.approach.angle,
    callback = function(v) if not finite(v) then return false end; S.setApproach({ angle = v }) end })
  S.angleControls.radius = C.slider(page, { id = "stand.approach.radius", persist = false, text = "Distance from them",
    desc = "Studs", min = 0.5, max = 30, step = 0.1, default = S.approach.radius,
    callback = function(v) if not finite(v) then return false end; S.setApproach({ radius = v }) end })
  S.angleControls.height = C.slider(page, { id = "stand.approach.height", persist = false, text = "Height on them",
    desc = "Studs above or below their root", min = -20, max = 20, step = 0.1, default = S.approach.height,
    callback = function(v) if not finite(v) then return false end; S.setApproach({ height = v }) end })
  C.dropdown(page, { id = "stand.approach.facing", text = "Facing", items = FACINGS, default = S.facing,
    callback = function(v) return S.setFacing(v) end })
  C.toggle(page, { id = "stand.previewAngles", text = "Live angle preview",
    desc = "Draws every stand's slot on the target while you tune: yours solid, the rest ghosts, with a ring for the distance",
    default = S.previewAngles, callback = function(v) S.previewAngles = v == true end })
  C.input(page, { id = "stand.previewWho", text = "Preview on", desc = "A player to draw the angles on while nothing is being attacked; blank uses the nearest",
    placeholder = "nearest", default = S.previewWho, callback = function(v) S.previewWho = tostring(v or "") end })

  C.section(page, "squad")
  C.paragraph(page, "Several stands, one owner, and nothing sent between them. A root's PhysicsRepRootPart replicates and reads back on other clients (measured on the rig), so each stand simply looks at who else is latched to the same body, sorts that list by user id, finds itself and takes that slot. Every stand computes the same layout, and one that joins, dies or leaves just re-packs it. Squad members are never targeted, and each starts the skill rotation on its own slot so they do not all fire the same move into the same frame.")
  C.toggle(page, { id = "stand.squad.on", text = "Fan out", default = S.squadOn,
    callback = function(v) S.squadOn = v == true; refreshSquad() end })
  S.controls.auto = C.toggle(page, { id = "stand.squad.auto", text = "Find the other stands",
    desc = "Detects every stand latched to the same owner and gives each one its own slot. Off falls back to the names below",
    default = S.squadAuto, callback = function(v) S.squadAuto = v == true; refreshSquad() end })
  S.controls.fan = C.dropdown(page, { id = "stand.squad.mode", text = "Fan", items = FAN_MODES, default = S.fanMode,
    desc = "Ring spreads all the way round -- two stands take behind and in front. Arc keeps everyone near the chosen angle",
    callback = function(v) return S.setFan(v) end })
  S.controls.squad = C.input(page, { id = "stand.squad.names", text = "Other stands by name",
    desc = "Only needed when the detection above is off, or to add a stand it cannot see. Comma separated.", placeholder = "found automatically",
    default = S.squadNames, callback = function(v) S.setSquad(v) end })
  C.slider(page, { id = "stand.squad.arc", text = "Fan width", desc = "Degrees the stands are spread across, centred on the angle above",
    min = 20, max = 340, step = 5, default = S.squadArc, callback = function(v) if finite(v) then S.squadArc = v end end })
  C.slider(page, { id = "stand.squad.gap", text = "Smallest gap between stands", desc = "The fan widens rather than let two stands share a swing",
    min = 10, max = 180, step = 5, default = S.squadGap, callback = function(v) if finite(v) then S.squadGap = v end end })

  C.section(page, "the carry")
  C.paragraph(page, "Measured on the rig on 2026-09-24: while a grab holds, the victim rides the stand's replicated position. So the stand takes hold and then moves -- down past The Strongest Battlegrounds' own -500 kill plane, which their client enforces on itself, or in to the owner. The descent is paced across the hold the move has been watched to have, because snapping the whole distance leaves them behind and they are simply put back on the map. It learns which moves grab by watching which ones take hold, and remembers them.")
  C.toggle(page, { id = "stand.combo", text = "Carry to the void while attacking",
    desc = "Opens with a grab whenever one is ready, rides them under the kill plane, and takes them again if they survive",
    default = S.comboOn, callback = function(v) S.comboOn = v == true end })
  C.slider(page, { id = "stand.comboTries", text = "Attempts per target", min = 1, max = 8, step = 1, default = S.comboTries,
    callback = function(v) if finite(v) then S.comboTries = v end end })
  C.slider(page, { id = "stand.comboEvery", text = "Seconds between carries", min = 0, max = 60, step = 0.5, default = S.comboEvery,
    callback = function(v) if finite(v) then S.comboEvery = v end end })
  C.slider(page, { id = "stand.voidMargin", text = "Studs past the kill plane", desc = "How far below -500 to aim; the rig killed at -546",
    min = 20, max = 400, step = 5, default = S.voidMargin, callback = function(v) if finite(v) then S.voidMargin = v end end })
  C.toggle(page, { id = "stand.carryAdapt", text = "Pace the drop to the move",
    desc = "Spreads the descent across the hold this move has been measured to have; off uses the fixed rate below",
    default = S.carryAdapt, callback = function(v) S.carryAdapt = v == true end })
  C.slider(page, { id = "stand.carryRate", text = "Descent rate (studs/second)", desc = "Used when the pacing above is off; the carry tracked ~900/s on the rig",
    min = CARRY_RATE[1], max = CARRY_RATE[2], step = 10, default = S.carryRate,
    callback = function(v) if finite(v) then S.carryRate = v end end })
  C.slider(page, { id = "stand.voidLinger", text = "Seconds to wait down there", desc = "Held after the grab lets go, so the release happens where the stand is",
    min = 0, max = 3, step = 0.05, default = S.voidLinger, callback = function(v) if finite(v) then S.voidLinger = v end end })
  C.slider(page, { id = "stand.bringDistance", text = "Delivery distance",
    desc = "Studs in front of the owner a brought player is dropped. The grab's finisher hurts and knocks down whatever is near the stand, so this is the owner's clearance from their own delivery -- the bearing is fixed when the grab lands, so turning to watch does not swing it around them",
    min = 4, max = 40, step = 0.5, default = -S.poses.Bring.z,
    callback = function(v) if not finite(v) then return false end; setPose("Bring", { z = -v }) end })
  C.actions(page, {
    { text = "Forget learned grabs", callback = function()
      S.grabMoves, S.grabMisses = {}, {}
      saveFeat("grabMoves", {})
      L.Toast.warn("Stand", "Grab moves forgotten; it will learn them again.")
    end },
  })

  C.section(page, "the deep hide")
  C.paragraph(page, "Dismissed, or waiting out a respawn, the stand goes further than under the owner's feet. It needs the same void immunity the carry does; without it the stand quietly stays above -450 rather than killing itself.")
  C.toggle(page, { id = "stand.hideDeep", text = "Hide deep", default = S.hideDeep,
    callback = function(v) S.hideDeep = v == true end })
  C.slider(page, { id = "stand.hideDepth", text = "Depth below the owner", min = 60, max = 1500, step = 20, default = S.hideDepth,
    callback = function(v) if finite(v) then S.hideDepth = v end end })
  C.slider(page, { id = "stand.hideAway", text = "Distance behind the owner", min = 0, max = 2000, step = 10, default = S.hideAway,
    callback = function(v) if finite(v) then S.hideAway = v end end })

  C.section(page, "combat")
  if not (R.TSB and R.TSB.supported()) then
    C.paragraph(page, "Summon, dismiss, poses and attack latches work anywhere. Skills, M1, dashes and awakening fire through The Strongest Battlegrounds' own input remote, so they only run there.")
  end
  C.paragraph(page, "While attacking the stand rotates skills 1, 2, 3, 4, re-firing each the moment its cooldown ends, and fills every gap with M1s at the game's own pace. A kill sends it to the void until the target respawns.")
  C.toggle(page, { id = "stand.useSkills", text = "Rotate skills", default = S.useSkills,
    callback = function(v) S.useSkills = v == true end })
  C.toggle(page, { id = "stand.useM1", text = "M1 between skills", default = S.useM1,
    callback = function(v) S.useM1 = v == true end })
  S.controls.dashSpam = C.toggle(page, { id = "stand.dashSpam", text = "Dash spam", desc = "Forward dashes while attacking or in the barrage, as often as the game allows",
    default = S.dashSpam, callback = function(v) S.dashSpam = v == true end })
  C.slider(page, { id = "stand.dashGap", text = "Seconds between dashes", min = 0.2, max = 3, step = 0.05, default = S.dashGap,
    callback = function(v) if finite(v) then S.dashGap = v end end })
  C.toggle(page, { id = "stand.autoUlt", text = "Awaken automatically", desc = "Fires the awakening when the bar is full during an attack",
    default = S.autoUlt, callback = function(v) S.autoUlt = v == true end })
  C.toggle(page, { id = "stand.waitShield", text = "Wait out spawn protection", desc = "After a respawn, stay in the void until the target's ForceField drops",
    default = S.waitShield, callback = function(v) S.waitShield = v == true end })
  C.slider(page, { id = "stand.lowHP", text = "Hide below health %", desc = "The stand dismisses itself here and refuses to fight until healed; 0 turns it off",
    min = 0, max = 90, step = 1, default = S.lowHP, callback = function(v) if finite(v) then S.lowHP = v end end })

  C.section(page, "fling assist")
  C.paragraph(page, "Optional, off by default. Hands the target to Giorgio's Rep Root fling (your Rep Root drive and void-aim settings) for one short burst, then comes straight back and restores your Rep Root settings. Measured in TSB on 2026-09-23: the handover works, but the Rep Root fling itself moved the target 0 studs/s, with or without the stand, so for now this adds nothing in TSB.")
  C.toggle(page, { id = "stand.flingAssist", text = "Fling assist", default = S.flingAssist,
    callback = function(v) S.flingAssist = v == true end })
  C.slider(page, { id = "stand.flingBelow", text = "Fling when target health is below %", desc = "Also flings a knocked-down target once every skill is cooling",
    min = 1, max = 100, step = 1, default = S.flingBelow, callback = function(v) if finite(v) then S.flingBelow = v end end })
  C.slider(page, { id = "stand.flingEvery", text = "Seconds between flings", min = 2, max = 60, step = 0.5, default = S.flingEvery,
    callback = function(v) if finite(v) then S.flingEvery = v end end })
  C.slider(page, { id = "stand.flingDrive", text = "Fling drive (seconds)", min = 0.3, max = 6, step = 0.05, default = S.flingDrive,
    callback = function(v) if finite(v) then S.flingDrive = v end end })

  C.section(page, "voice")
  C.toggle(page, { id = "stand.speak", text = "Stand speaks", desc = "Short replies in chat; say still works when this is off",
    default = S.speak, callback = function(v) S.speak = v == true end })
  for _, entry in ipairs({ { "summon", "Summon line" }, { "dismiss", "Dismiss line" }, { "attack", "Attack line" },
    { "done", "Kill line" }, { "carry", "Carry line" }, { "bring", "Delivery line" } }) do
    C.input(page, { id = "stand.line." .. entry[1], text = entry[2], default = S.lines[entry[1]],
      callback = function(v) S.lines[entry[1]] = tostring(v or "") end })
  end

  C.section(page, "status")
  local statusFrame = C.paragraph(page, "Idle.")
  local status = statusFrame:FindFirstChildWhichIsA("TextLabel", true)
  local modes = { off = "Off", summoned = "Summoned", hidden = "Hidden", attacking = "Attacking" }
  local acc = 0
  local conn
  conn = RS.Heartbeat:Connect(function(dt)
    if not statusFrame.Parent or not L.live() then conn:Disconnect(); return end
    acc += dt; if acc < 0.2 then return end; acc = 0
    tiles:set("owner", S.owner and S.owner.Name or (S.ownerName ~= "" and "Away" or "None"))
    tiles:set("mode", S.flingBusy and "Flinging" or (modes[S.mode] or S.mode))
    tiles:set("latch", S.active and (S.pose or "On") or (S.blocked and "Paused" or "Free"))
    tiles:set("kills", tostring(S.kills))
    tiles:set("carry", S.combo and (S.comboState or "on") or (S.squadCount > 1 and ("slot " .. S.squadSlot .. "/" .. S.squadCount) or "idle"))
    local lines = {}
    lines[#lines + 1] = "Owner: " .. (S.owner and ("@" .. S.owner.Name) or (S.ownerName ~= "" and (S.ownerName .. " (not in server)") or "none"))
    lines[#lines + 1] = "Stand: " .. (modes[S.mode] or S.mode)
      .. (S.mode == "attacking" and S.target and (" @" .. S.target.Name) or "")
      .. (S.waiting and ("  |  " .. S.waiting) or "")
      .. (S.barrage and "  |  barrage" or "") .. (S.dashSpam and "  |  dash spam" or "")
    lines[#lines + 1] = "Latch: " .. (S.active and (S.anchorRoot and ("PhysicsRepRootPart -> " .. (S.anchorRoot.Parent and S.anchorRoot.Parent.Name or "?") .. ", pose " .. tostring(S.pose)) or "holding in the void (owner is down)") or "free")
    lines[#lines + 1] = "Skills: next " .. S.rotation .. (S.pending and ("  |  sending " .. S.pending.slot) or "")
      .. (S.gate and ("  |  holding: " .. S.gate) or "")
    lines[#lines + 1] = string.format("Angle: %s  %.0f deg, %.1f studs, %+.1f up  |  %s", S.approachPreset,
      S.approach.angle, S.approach.radius, S.approach.height, S.facing)
    lines[#lines + 1] = "Squad: slot " .. S.squadSlot .. " of " .. S.squadCount
      .. (S.squadCount > 1 and string.format("  |  my share %+.0f deg", spread(S.squadSlot, S.squadCount)) or "  |  alone")
    local learned = {}
    for name, hold in pairs(S.grabMoves) do
      if type(hold) == "number" then learned[#learned + 1] = string.format("%s %.2fs", name, hold) end
    end
    table.sort(learned)
    lines[#lines + 1] = "Carry: " .. (S.combo and (S.comboState .. " @" .. S.combo.target.Name
        .. (S.combo.kind == "void" and string.format("  |  %.0f / %.0f studs down", S.combo.depth or 0, S.combo.need or 0) or "")
        .. "  |  try " .. S.combo.tries)
      or (S.verify and "checking the drop" or "idle"))
      .. "  |  carried " .. S.carried .. "  |  void " .. (S.voidReady and "armed" or "not armed")
    lines[#lines + 1] = "Grabs known: " .. (#learned > 0 and table.concat(learned, ", ") or "none yet")
    if S.blocked then lines[#lines + 1] = "Waiting: " .. S.blocked end
    lines[#lines + 1] = "Last command: " .. S.lastCommand
    status.Text = table.concat(lines, "\n")
  end)
  L.hold(conn)
end

end

-- StandCore's public face: everything an interface needs, nothing it must know
-- about the stand's insides. Poll Core.status() for the dashboard; subscribe
-- with Core.on(event, fn) for the live feed:
--   "say"      (message)                    a line the stand spoke
--   "command"  (word, rest, fromInterface)  a command it accepted
--   "kill"     (player)                     the target went down
--   "carry"    ("begin"|"hold"|"end", player, detail, died)
--   "owner"    ("found"|"missing"|"joined"|"left"|"left-hunting"|"cleared", player, how)
--   "squad"    ("roster"|"reserve"|"hunting")
--   "yield"    (reason or nil)                stepping aside for a squadmate's locked move
--   "grab"     (move, hold)                   a grab learned by watching one of ours
--   "notify"   (title, text)                  what the native notifications show
--   "note" / "fault" / "toast" / "setting" / "unloaded"
do
  local S = R.Stand
  local I = Core._internal
  Core.S = S
  S.hook = emit

  local function name(player) return player and player.Name or nil end

  function Core.status()
    local combo = S.combo
    return {
      mode = S.mode, active = S.active, pose = S.pose, blocked = S.blocked, gate = S.gate,
      owner = name(S.owner), ownerName = S.ownerName, target = name(S.target), waiting = S.waiting,
      anchor = S.anchorRoot and S.anchorRoot.Parent and S.anchorRoot.Parent.Name or nil,
      kills = S.kills, carried = S.carried, barrage = S.barrage, dashSpam = S.dashSpam,
      rotation = S.rotation, sending = S.pending and S.pending.slot or nil,
      squadSlot = S.squadSlot, squadCount = S.squadCount, voidReady = S.voidReady,
      angle = { preset = S.approachPreset, angle = S.approach.angle, radius = S.approach.radius,
        height = S.approach.height, facing = S.facing },
      carry = combo and { kind = combo.kind, state = S.comboState, target = name(combo.target),
        depth = combo.depth, need = combo.need, tries = combo.tries } or nil,
      lastCommand = S.lastCommand, supported = R.TSB and R.TSB.supported() or false,
      prefix = S.prefix, fan = S.fanMode, squadOn = S.squadOn, squadAuto = S.squadAuto,
      comboOn = S.comboOn, comboTries = S.comboTries, attempts = S.attempts and S.attempts.n or 0,
      ownerId = S.owner and S.owner.UserId or nil, targetId = S.target and S.target.UserId or nil,
      ultimate = (function() local v = LP:GetAttribute("Ultimate"); return type(v) == "number" and v or nil end)(),
      yield = S.yield, reserve = S.reserve, strikeSlot = S.strikeSlot, strikeCount = S.strikeCount,
      idleSlot = S.idleSlot, idleCount = S.idleCount, ownerStatus = S.ownerStatus, ownerMatch = S.ownerMatch,
      huntDistance = S.huntDistance, maxHunters = S.maxHunters,
    }
  end

  -- The hotbar as the stand sees it, with what it knows about each move.
  -- grab: a learned hold in seconds, false (watched, never held), "hint" (the
  -- name gives it away, not yet watched) or nil (an ordinary move).
  function Core.slots()
    local adapter = R.TSB
    if not (adapter and adapter.supported()) then return nil end
    local ok, bar = pcall(adapter.Game.hotbar)
    if not ok or type(bar) ~= "table" then return nil end
    local out = {}
    for index = 1, 4 do
      local slot = bar[index] or {}
      local known = slot.name and S.grabMoves[slot.name]
      local grab = known
      if known == nil and slot.name and S.canGrab(slot.name) then grab = "hint" end
      out[index] = { name = slot.name, cooling = slot.cooling == true, remaining = slot.remaining or 0, grab = grab }
    end
    return out
  end

  -- Learned grabs, longest hold first.
  function Core.grabs()
    local list = {}
    for moveName, hold in pairs(S.grabMoves) do list[#list + 1] = { name = moveName, hold = hold } end
    table.sort(list, function(a, b)
      local ha, hb = type(a.hold) == "number" and a.hold or -1, type(b.hold) == "number" and b.hold or -1
      if ha ~= hb then return ha > hb end
      return a.name < b.name
    end)
    return list
  end
  function Core.forgetGrab(moveName)
    if moveName == nil then S.grabMoves, S.grabMisses = {}, {}
    else S.grabMoves[moveName], S.grabMisses[moveName] = nil, nil end
    I.Cfg.setFeat("stand.grabMoves", S.grabMoves)
    return true
  end

  -- Who is in the squad, in slot order.
  function Core.squad()
    local list = {}
    for p in pairs(S.squadSet or {}) do list[#list + 1] = p end
    table.sort(list, function(a, b) return a.UserId < b.UserId end)
    local out = {}
    for index, p in ipairs(list) do out[index] = { name = p.Name, id = p.UserId, mine = p == LP } end
    return out
  end
  -- Who hunts our target with us, in fan order (slot 1 leads the carries).
  function Core.hunters()
    local out = {}
    for index, p in ipairs(S.hunters or {}) do out[index] = { name = p.Name, id = p.UserId, mine = p == LP } end
    return out
  end

  -- Where every slot of the squad stands for one pose, in the anchor's frame:
  -- x right, z behind (+) / in front (-), yaw in degrees. The same maths the
  -- latch uses, so a drawing of this is where the stands really are.
  function Core.layout(view, count)
    local mySlot = view == "Strike" and S.strikeSlot or S.idleSlot
    count = math.max(count or (view == "Strike" and S.strikeCount or S.idleCount) or 1, 1)
    local out = {}
    for slot = 1, count do
      local cf = S.formation(view, slot, count)
      local look = cf.LookVector
      out[slot] = { x = cf.Position.X, y = cf.Position.Y, z = cf.Position.Z,
        yaw = math.deg(math.atan2(-look.X, -look.Z)), mine = slot == (mySlot or 1) }
    end
    return out
  end

  function Core.players()
    local names = {}
    for _, p in ipairs(Players:GetPlayers()) do
      if p ~= LP then names[#names + 1] = { name = p.Name, display = p.DisplayName, id = p.UserId } end
    end
    table.sort(names, function(a, b) return a.name:lower() < b.name:lower() end)
    return names
  end

  -- The whole command set, for a help screen or an autocomplete.
  function Core.commands()
    local list = {}
    for _, entry in ipairs(S.COMMANDS) do
      list[#list + 1] = { names = table.clone(entry.names), args = entry.args, desc = entry.desc }
    end
    return list
  end

  -- Anything the owner could type, typed by the operator instead: "a bob", "3".
  function Core.command(text)
    local prefix = S.prefix or ""
    return S.handle(prefix .. tostring(text or ""), true)
  end

  for _, fn in ipairs({ "setOwner", "setPrefix", "summon", "dismiss", "stop", "free", "attack", "bring",
    "voidDrop", "skill", "toggleBarrage", "toggleDash", "ult", "angle", "setApproach", "setFacing",
    "setFan", "setSquad", "toggleAuto", "side", "setHuntDistance" }) do
    Core[fn] = function(...) return S[fn](...) end
  end

  -- Any stand setting by its short key ("float", "comboOn", "hideDepth" ...).
  -- Written live and saved under the same config key the stand reads.
  function Core.get(key) return S[key] end
  function Core.set(key, value, configKey)
    S[key] = value
    if configKey then I.Cfg.setFeat("stand." .. configKey, value) end
    return true
  end

  function Core.whitelist(playerName, on)
    playerName = tostring(playerName or ""):lower()
    if playerName == "" then return false end
    I.K.whitelist[playerName] = on ~= false and true or nil
    return true
  end

  -- ------------------------------------------------------------ notifications
  -- With the console off (the default), the stand still tells its operator what
  -- it is doing: Roblox's own corner notifications plus a console line. At most
  -- one every 1.5 s; a newer message replaces one still waiting.
  local StarterGui = game:GetService("StarterGui")
  local lastNote, pendingNote = 0, nil
  local function showNote(title, text)
    lastNote = os.clock()
    print("[Stand] " .. title .. (text and text ~= "" and (": " .. text) or ""))
    emit("notify", title, text)
    if Core.config.NOTIFY == false then return end
    task.spawn(function()
      for _ = 1, 5 do
        local ok = pcall(StarterGui.SetCore, StarterGui, "SendNotification", { Title = title, Text = text or "", Duration = 5 })
        if ok then return end
        task.wait(0.5)
      end
    end)
  end
  function Core.notify(title, text)
    local wait = 1.5 - (os.clock() - lastNote)
    if wait <= 0 then showNote(title, text); return end
    local first = pendingNote == nil
    pendingNote = { title, text }
    if first then
      task.delay(wait, function()
        local n = pendingNote
        pendingNote = nil
        if n and I.L.live() then showNote(n[1], n[2]) end
      end)
    end
  end

  -- ------------------------------------------------------------ where is the host?
  -- In this server, it is simply found (the stand's own matching). Not here:
  -- does that account exist at all, and -- when it is on this account's friends
  -- list -- is it in another server of this game, another game, or offline?
  function Core.locateHost()
    local wanted = S.ownerName
    if wanted == "" or S.owner then return end
    task.spawn(function()
      local query = wanted:gsub("^@", "")
      local ok, id = pcall(Players.GetUserIdFromNameAsync, Players, query)
      if not ok or type(id) ~= "number" then
        Core.notify("Host not found", "No Roblox account is called \"" .. query .. "\". Check HOST_USERNAME.")
        return
      end
      if S.owner then return end
      local where
      local okF, friends = pcall(function() return LP:GetFriendsOnline(200) end)
      if okF and type(friends) == "table" then
        for _, f in ipairs(friends) do
          if f.VisitorId == id then
            if f.PlaceId == game.PlaceId and f.GameId and f.GameId ~= game.JobId then where = "is in ANOTHER server of this game"
            elseif f.PlaceId == game.PlaceId then where = "is joining this server"
            elseif f.PlaceId then where = "is playing a different game"
            else where = "is online but not in a game" end
            break
          end
        end
        if not where then
          local okFr, isFriend = pcall(function() return LP:IsFriendsWith(id) end)
          if okFr and isFriend then where = "is offline" end
        end
      end
      Core.notify("Waiting for " .. query, where and (query .. " " .. where .. ". The stand waits for them here.")
        or (query .. " is not in this server. The stand waits for them here."))
    end)
  end

  Core.on("owner", function(kind, player, how)
    local who = player and player.Name or S.ownerName
    if kind == "found" or kind == "joined" then
      local note = how == "case" and (" (matched \"" .. S.ownerName .. "\", the capitals differ)")
        or how == "display name" and (" (matched by display name \"" .. S.ownerName .. "\")") or ""
      Core.notify(kind == "joined" and "Host joined" or "Host found", "@" .. who .. note)
    elseif kind == "missing" then
      Core.notify("Host not in this server", "Waiting for " .. tostring(S.ownerName) .. ".")
      Core.locateHost()
    elseif kind == "left" then
      Core.notify("Host left", "The stand waits here and comes back beside them when they rejoin.")
    elseif kind == "left-hunting" then
      Core.notify("Host left", "Still hunting " .. (S.target and S.target.Name or "the target") .. " until it leaves.")
    end
  end)
  -- Announced only once a change has STAYED: a new stand after 2 s, one gone
  -- after 60 s. Measured on a .v loop: every kill takes the other stand off
  -- this one's roster for 14-29 s (the carry, the respawn, the shield), which
  -- fired "Alone again" and then "2 stands" once per kill. That is still the
  -- squad, not a departure.
  local GONE, ARRIVED = 60, 2
  local announced, change = nil, 0
  local function squadNames()
    local names = {}
    for p in pairs(S.squadSet or {}) do names[#names + 1] = p.Name end
    table.sort(names)
    return names
  end
  local function countOf(sig) return (sig == nil or sig == "") and 0 or #string.split(sig, ",") end
  local function announce(sig)
    local names = squadNames()
    if table.concat(names, ",") ~= sig or sig == announced then return end
    local before = countOf(announced)
    announced = sig
    if #names > 0 and #names >= before then
      Core.notify((#names + 1) .. " stands on @" .. tostring(S.owner and S.owner.Name or S.ownerName),
        "With " .. table.concat(names, ", ") .. ". A shared prey is split evenly round it; slot 1 leads the carries.")
    elseif #names == 0 then
      Core.notify("Alone again", "No other stand is with the host now.")
    else
      Core.notify(#names + 1 .. " stands now", "With " .. table.concat(names, ", ") .. ".")
    end
  end
  Core.on("squad", function(kind)
    if kind == "reserve" then
      Core.notify("Squad full", S.maxHunters .. " stands are hunting. This one waits beside the host as backup.")
    elseif kind == "hunting" then
      Core.notify("Stepping in", "A hunter left, so this stand takes its place.")
    elseif kind == "roster" then
      -- every roster change restarts the wait: a timer from an earlier absence
      -- never fires into a later, shorter one
      change += 1
      local names = squadNames()
      local sig = table.concat(names, ",")
      if sig == announced then return end
      if announced == nil and #names == 0 then announced = sig; return end
      local mine = change
      task.delay(#names < countOf(announced) and GONE or ARRIVED, function()
        if change == mine then announce(sig) end
      end)
    end
  end)
  Core.on("grab", function(move, hold)
    Core.notify("Grab learned", string.format("%s holds for %.2f s. .v can carry with it now.", tostring(move), hold or 0))
  end)

  -- ------------------------------------------------------------ the console
  -- Off by default. ".gui" (from the owner's chat, or typed by the operator)
  -- or _G.GUI = true opens it; the build that carries a console sets
  -- Core.startUI. Its fonts and icons come from the executor's workspace, and
  -- with _G.ASSETS set to a raw folder URL they are fetched there on first open.
  local ASSET_ROOT = "StandDosCintoes"
  function Core.fetchAssets(base, files)
    if type(base) ~= "string" or base == "" or type(files) ~= "table" then return 0 end
    if base:sub(-1) ~= "/" then base ..= "/" end
    local fetched = 0
    pcall(function() if not isfolder(ASSET_ROOT) then makefolder(ASSET_ROOT) end end)
    for _, sub in ipairs({ "icons", "fonts" }) do
      pcall(function() if not isfolder(ASSET_ROOT .. "/" .. sub) then makefolder(ASSET_ROOT .. "/" .. sub) end end)
    end
    for _, path in ipairs(files) do
      local full = ASSET_ROOT .. "/" .. path
      local have = false
      pcall(function() have = isfile(full) end)
      if not have then
        local ok, body = pcall(function() return game:HttpGet(base .. path) end)
        if ok and type(body) == "string" and #body > 0 and not body:find("^%s*<") and body ~= "404: Not Found" then
          pcall(writefile, full, body)
          fetched += 1
        end
      end
    end
    return fetched
  end
  function Core.openGui()
    if Core.UI then
      if Core.UI.toggleWindow then Core.UI.toggleWindow() end
      return true
    end
    if type(Core.startUI) ~= "function" then
      Core.notify("No console in this build", "This copy of the stand runs without its interface.")
      return false
    end
    if Core.uiStarting then return true end
    Core.uiStarting = true
    task.spawn(function()
      if type(Core.config.ASSETS) == "string" then
        local n = Core.fetchAssets(Core.config.ASSETS, Core.ASSET_FILES)
        if n > 0 then print("[Stand] fetched " .. n .. " interface files") end
      end
      local ok, err = pcall(Core.startUI)
      Core.uiStarting = false
      if not ok then
        warn("[Stand] the console failed to open: " .. tostring(err))
        Core.notify("Console failed to open", tostring(err):sub(1, 120))
      end
    end)
    return true
  end
  S.addCommand({ "gui" }, "", "open or close the stand's console on its own screen", function() Core.openGui() end)

  local unloaded = false
  function Core.unload()
    if unloaded then return end
    unloaded = true
    table.sort(I.cleanups, function(a, b) return a.order > b.order end)
    for _, entry in ipairs(I.cleanups) do pcall(entry.fn) end
    I.setAlive(false)
    for _, conn in ipairs(I.conns) do pcall(function() conn:Disconnect() end) end
    for _, bind in ipairs(I.renderBinds) do pcall(function() I.L.RunService:UnbindFromRenderStep(bind) end) end
    for _, inst in ipairs(I.owned) do pcall(function() inst:Destroy() end) end
    if I.Cfg.dirty then I.Cfg.save() end
    S.hook = nil
    if rawget(getgenv(), "StandCore") == Core then getgenv().StandCore = nil end
    emit("unloaded")
  end

  local owner = S.owner and S.owner.Name or (S.ownerName ~= "" and (S.ownerName .. " (not here yet)")) or "none"
  print(string.format("[StandCore %s] loaded. Owner: %s. %s", Core.version, owner,
    S.owner and "They command it from chat; Backspace frees it." or
      'Set one with _G.HOST_USERNAME = "name" above the loadstring.'))
  for _, problem in ipairs(Core.configProblems) do warn("[Stand] config: " .. problem) end
  -- the load report, as a notification
  task.defer(function()
    if S.ownerName == "" then
      Core.notify("Stand loaded", "No host set. Put _G.HOST_USERNAME = \"YourMain\" above the loadstring.")
    elseif S.owner then
      local how = S.ownerMatch
      Core.notify("Stand ready", "Host @" .. S.owner.Name .. (how == "case" and " (capitals fixed)" or how == "display name" and " (by display name)" or "")
        .. " | " .. S.prefix .. "cmds lists the commands")
    else
      Core.notify("Stand loaded", "Host " .. S.ownerName .. " is not in this server yet. Waiting.")
      Core.locateHost()
    end
    if Core.config.GUI == true then Core.openGui() end
  end)
end

-- The alt screen. A stand running on an alt needs no picture at all: this
-- blacks the window out, turns 3D rendering off -- scripts, physics and the
-- latch carry on exactly as before, only drawing the world stops, which is
-- most of what a Roblox client costs -- and shows a handful of numbers instead.
-- On by default on an alt (a host is set and it is not this account);
-- _G.BLACK_SCREEN = false keeps the normal view. F6 on that window, or
-- ".black" (".black on" / ".black off") from the host, toggles it.
do
  local S = R.Stand
  local RunService = game:GetService("RunService")
  local UIS = game:GetService("UserInputService")
  local Screen = { on = false }
  Core.screen = Screen
  local started = os.clock()
  local lastNote = "Loaded."
  Core.on("notify", function(title, text)
    lastNote = tostring(title) .. ((text and text ~= "") and (": " .. tostring(text)) or "")
  end)

  local INK, PAPER, MUTE, FAINT = Color3.fromRGB(0, 0, 0), Color3.fromRGB(236, 232, 224), Color3.fromRGB(150, 146, 158), Color3.fromRGB(96, 92, 104)
  local MODE_COLOR = { attacking = Color3.fromRGB(255, 110, 125), summoned = Color3.fromRGB(110, 220, 170),
    hidden = Color3.fromRGB(183, 123, 255), off = MUTE }

  local function host()
    if type(gethui) == "function" then
      local ok, h = pcall(gethui)
      if ok and h then return h end
    end
    local ok, cg = pcall(game.GetService, game, "CoreGui")
    if ok and cg then return cg end
    return LP:FindFirstChildOfClass("PlayerGui")
  end
  local function new(class, props, parent)
    local inst = Instance.new(class)
    for k, v in pairs(props) do inst[k] = v end
    inst.Parent = parent
    return inst
  end
  local function text(parent, size, color, order, font)
    return new("TextLabel", { BackgroundTransparency = 1, BorderSizePixel = 0, Text = "", TextSize = size, TextColor3 = color,
      Font = font or Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, size + 6),
      TextTruncate = Enum.TextTruncate.AtEnd, LayoutOrder = order }, parent)
  end
  -- lines that can run long wrap instead of being cut off on a small window
  local function wrap(label)
    label.TextWrapped, label.TextTruncate = true, Enum.TextTruncate.None
    label.Size, label.AutomaticSize = UDim2.new(1, 0, 0, 0), Enum.AutomaticSize.Y
    return label
  end

  local gui, column, scale, nameLabel, statusLabel, noteLabel, rows = nil, nil, nil, nil, nil, nil, {}
  local ROWS = { "Host", "Kills", "Carried", "Health", "Squad", "FPS", "Ping", "Up" }
  local function build()
    if gui then return end
    gui = new("ScreenGui", { Name = "ScreenGui", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 8000,
      ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Enabled = false }, nil)
    local bg = new("Frame", { BackgroundColor3 = INK, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1) }, gui)
    column = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
      Size = UDim2.fromOffset(460, 0), AutomaticSize = Enum.AutomaticSize.Y }, bg)
    scale = new("UIScale", { Scale = 1 }, column)
    new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, column)
    local head = text(column, 13, FAINT, 1, Enum.Font.GothamMedium)
    head.Text = "STAND DOS CINTOE'S  ·  alt screen"
    nameLabel = text(column, 40, PAPER, 2, Enum.Font.GothamBlack)
    nameLabel.Text = LP.Name
    statusLabel = wrap(text(column, 18, MODE_COLOR.off, 3, Enum.Font.GothamMedium))
    new("Frame", { BackgroundColor3 = FAINT, BackgroundTransparency = 0.6, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 1), LayoutOrder = 4 }, column)
    local grid = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 5 }, column)
    new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, grid)
    for i, key in ipairs(ROWS) do
      local row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 22), LayoutOrder = i }, grid)
      local k = text(row, 15, MUTE, 0, Enum.Font.Gotham)
      k.Size = UDim2.new(0, 120, 1, 0)
      k.Text = key
      local v = text(row, 15, PAPER, 0, Enum.Font.RobotoMono)
      v.Size, v.Position = UDim2.new(1, -120, 1, 0), UDim2.fromOffset(120, 0)
      rows[key] = v
    end
    noteLabel = wrap(text(column, 13, MUTE, 6, Enum.Font.Gotham))
    local foot = wrap(text(column, 12, FAINT, 7, Enum.Font.Gotham))
    foot.Text = "3D rendering is off to save this PC  ·  F6 or .black toggles this screen"
    gui.Parent = host()
    L.own(gui)
  end

  local function statusText()
    local target = S.target and S.target.Name or "?"
    if S.mode == "off" then return "Off", MODE_COLOR.off end
    if S.combo then return "Carrying @" .. (S.combo.target and S.combo.target.Name or "?"), MODE_COLOR.attacking end
    if S.mode == "attacking" then
      if S.reserve then return "Backup: the squad is full", MODE_COLOR.hidden end
      if S.yield then return "Stepping aside: " .. S.yield, MODE_COLOR.hidden end
      if S.waiting then return "Waiting (" .. S.waiting .. ") on @" .. target, MODE_COLOR.hidden end
      return "Hunting @" .. target, MODE_COLOR.attacking
    end
    if S.mode == "hidden" then return "Hidden in the void", MODE_COLOR.hidden end
    return "Beside @" .. (S.owner and S.owner.Name or S.ownerName), MODE_COLOR.summoned
  end

  local frames, fpsAt, fps, acc = 0, os.clock(), 0, 1
  L.hold(RunService.RenderStepped:Connect(function(dt)
    if not Screen.on or not L.live() then return end
    frames += 1
    acc += dt
    if acc < 0.5 then return end
    acc = 0
    local now = os.clock()
    fps = frames / math.max(now - fpsAt, 1e-3)
    frames, fpsAt = 0, now
    local status, color = statusText()
    statusLabel.Text, statusLabel.TextColor3 = status, color
    local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
    local ping
    pcall(function() ping = LP:GetNetworkPing() end)
    local up = math.floor(now - started)
    rows.Host.Text = S.owner and ("@" .. S.owner.Name) or (S.ownerName ~= "" and (S.ownerName .. " (not in this server)") or "none set")
    rows.Kills.Text = tostring(S.kills or 0)
    rows.Carried.Text = tostring(S.carried or 0)
    rows.Health.Text = hum and string.format("%d / %d", math.floor(hum.Health + 0.5), math.floor(hum.MaxHealth + 0.5)) or "respawning"
    rows.Squad.Text = (S.squadCount or 1) > 1 and string.format("slot %d of %d", S.squadSlot or 1, S.squadCount) or "alone"
    rows.FPS.Text = tostring(math.floor(fps + 0.5))
    rows.Ping.Text = ping and (math.floor(ping * 1000 + 0.5) .. " ms") or "?"
    rows.Up.Text = string.format("%d:%02d:%02d", up // 3600, up // 60 % 60, up % 60)
    noteLabel.Text = lastNote
    local cam = workspace.CurrentCamera
    if cam and cam.ViewportSize then scale.Scale = math.clamp(cam.ViewportSize.Y / 1080, 0.7, 1.6) end
  end))

  function Screen.set(on)
    on = on == true
    build()
    Screen.on = on
    gui.Enabled = on
    -- the whole saving: the world is not drawn while the screen is up
    pcall(function() RunService:Set3dRenderingEnabled(not on) end)
    frames, fpsAt, acc = 0, os.clock(), 1
    return true
  end
  S.addCommand({ "black", "fps" }, "[on | off]", "black stats screen on the stand's window, 3D off to save the PC", function(rest)
    rest = tostring(rest or ""):lower()
    Screen.set(rest == "on" or (rest ~= "off" and not Screen.on))
  end)
  L.hold(UIS.InputBegan:Connect(function(input, processed)
    if processed or UIS:GetFocusedTextBox() then return end
    if input.KeyCode == Enum.KeyCode.F6 then Screen.set(not Screen.on) end
  end))
  -- always hand the 3D view back, whatever unloads us
  L.cleanup(function()
    pcall(function() RunService:Set3dRenderingEnabled(true) end)
    if gui then pcall(function() gui:Destroy() end) end
  end, 60)
  local want = Core.config.BLACK_SCREEN
  if want == nil then want = S.ownerName ~= "" and S.owner ~= LP end
  if want then task.defer(function() if L.live() then Screen.set(true) end end) end
end

-- Anti-AFK: Roblox kicks a client idle for 20 minutes. An alt is never touched,
-- so answer the idle signal with a click nobody sees. _G.ANTI_AFK = false turns it off.
if Core.config.ANTI_AFK ~= false then
  local ok, VirtualUser = pcall(game.GetService, game, "VirtualUser")
  if ok and VirtualUser then
    L.hold(LP.Idled:Connect(function()
      if not L.live() then return end
      pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
      end)
    end))
  end
end

Core.ASSET_FILES = { "fonts/Figtree-500.ttf", "fonts/Figtree-700.ttf", "fonts/Syne-800.ttf", "glow.png", "icons/activity.png", "icons/anchor.png", "icons/arrow-down-to-line.png", "icons/arrow-down.png", "icons/check.png", "icons/chevron-down.png", "icons/circle-alert.png", "icons/circle-dot.png", "icons/clipboard-paste.png", "icons/command.png", "icons/copy.png", "icons/crosshair.png", "icons/crown.png", "icons/eye.png", "icons/flame.png", "icons/gauge.png", "icons/ghost.png", "icons/grab.png", "icons/hand.png", "icons/keyboard.png", "icons/layout-dashboard.png", "icons/link.png", "icons/lock.png", "icons/minus.png", "icons/move.png", "icons/octagon-x.png", "icons/play.png", "icons/plus.png", "icons/power.png", "icons/radar.png", "icons/rotate-ccw.png", "icons/scroll-text.png", "icons/search.png", "icons/settings.png", "icons/shield.png", "icons/skull.png", "icons/sparkles.png", "icons/square.png", "icons/sword.png", "icons/swords.png", "icons/target.png", "icons/timer.png", "icons/trash-2.png", "icons/undo-2.png", "icons/user.png", "icons/users.png", "icons/volume-2.png", "icons/wind.png", "icons/x.png", "icons/zap.png", "shadow.png", "slash.png", "tone.png" }
Core.startUI = function()
-- ============================================================================
--  STAND DOS CINTOE'S  ·  スタンド・ドス・シントエズ
--  The stand console. Rides on StandCore (above, in this same chunk): it reads
--  Core.status() and Core's events, and only ever acts through Core's API.
--
--  00 kernel   one render loop, springs, a store, error boundaries, factory
-- ============================================================================
local U = { version = "1.0.0" }
Core.UI = U
do
  local RS = game:GetService("RunService")
  local UIS = game:GetService("UserInputService")
  local HttpService = game:GetService("HttpService")
  local I = Core._internal
  U.RS, U.UIS, U.HttpService, U.I, U.LP = RS, UIS, HttpService, I, LP
  U.NAME, U.KANA = "STAND DOS CINTOE'S", "スタンド・ドス・シントエズ"
  U.ASSET = "StandDosCintoes"

  local function rgb(r, g, b) return Color3.fromRGB(r, g, b) end
  -- Stand-aura violet and menacing gold on violet-black ink.
  U.c = {
    ink = rgb(15, 11, 20), base = rgb(20, 15, 27), panel = rgb(28, 22, 37), panel2 = rgb(38, 30, 50),
    hover = rgb(47, 38, 62), line = rgb(60, 49, 75), lineSoft = rgb(43, 35, 55),
    paper = rgb(241, 233, 218), mute = rgb(172, 159, 187), faint = rgb(126, 113, 146),
    aura = rgb(183, 123, 255), auraDeep = rgb(96, 58, 150), gold = rgb(240, 192, 74), goldDeep = rgb(150, 110, 30),
    ok = rgb(98, 217, 165), warn = rgb(243, 165, 74), bad = rgb(255, 100, 119), black = rgb(0, 0, 0), white = rgb(255, 255, 255),
  }

  -- ------------------------------------------------------------ preferences
  function U.pref(key, default)
    local v = I.Cfg.feat("sdc." .. key, nil)
    if v == nil then return default end
    return v
  end
  function U.setPref(key, value) I.Cfg.setFeat("sdc." .. key, value) end

  -- ------------------------------------------------------------ assets
  local exists = {}
  function U.asset(path)
    if exists[path] ~= nil then return exists[path] or nil end
    local id = false
    if type(getcustomasset) == "function" and type(isfile) == "function" then
      local full = U.ASSET .. "/" .. path
      local ok, present = pcall(isfile, full)
      if ok and present then
        local okId, got = pcall(getcustomasset, full)
        if okId and type(got) == "string" then id = got end
      end
    end
    exists[path] = id
    return id or nil
  end
  function U.icon(name) return U.asset("icons/" .. name .. ".png") end

  -- Syne ExtraBold for display, Figtree for text; Roblox's own faces if the
  -- files are missing. A font family file is written next to each .ttf with the
  -- asset id this executor hands out, which is what Font.new reads.
  local function customFont(file)
    local ttf = U.asset("fonts/" .. file .. ".ttf")
    if not ttf then return nil end
    local ok = pcall(writefile, U.ASSET .. "/fonts/" .. file .. ".json", HttpService:JSONEncode({
      name = file, faces = { { name = "Regular", weight = 400, style = "normal", assetId = ttf } } }))
    if not ok then return nil end
    exists["fonts/" .. file .. ".json"] = nil
    local id = U.asset("fonts/" .. file .. ".json")
    if not id then return nil end
    local okFont, font = pcall(Font.new, id, Enum.FontWeight.Regular, Enum.FontStyle.Normal)
    return okFont and font or nil
  end
  U.f = {
    display = customFont("Syne-800") or Font.fromEnum(Enum.Font.GothamBlack),
    body = customFont("Figtree-500") or Font.fromEnum(Enum.Font.Gotham),
    bold = customFont("Figtree-700") or Font.fromEnum(Enum.Font.GothamBold),
    mono = Font.fromEnum(Enum.Font.RobotoMono),
    comic = Font.fromEnum(Enum.Font.Bangers),
  }

  -- ------------------------------------------------------------ factory
  function U.mk(class, props, children)
    local inst = Instance.new(class)
    local parent
    if props then
      for key, value in pairs(props) do
        if key == "Parent" then parent = value else inst[key] = value end
      end
    end
    if children then for _, child in ipairs(children) do child.Parent = inst end end
    if parent then inst.Parent = parent end
    return inst
  end
  local mk = U.mk
  function U.corner(inst, r)
    return mk("UICorner", { CornerRadius = typeof(r) == "UDim" and r or UDim.new(0, r or 8), Parent = inst })
  end
  function U.stroke(inst, color, thickness, transparency)
    return mk("UIStroke", { Color = color or U.c.line, Thickness = thickness or 1, Transparency = transparency or 0,
      ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = inst })
  end
  function U.pad(inst, t, r, b, l)
    return mk("UIPadding", { PaddingTop = UDim.new(0, t or 0), PaddingRight = UDim.new(0, r or t or 0),
      PaddingBottom = UDim.new(0, b or t or 0), PaddingLeft = UDim.new(0, l or r or t or 0), Parent = inst })
  end
  function U.list(inst, direction, gap, props)
    local layout = mk("UIListLayout", { FillDirection = direction == "x" and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical,
      Padding = UDim.new(0, gap or 0), SortOrder = Enum.SortOrder.LayoutOrder, Parent = inst })
    -- Newer layout properties (Wraps) are set softly: an older client just ignores them.
    if props then for k, v in pairs(props) do pcall(function() layout[k] = v end) end end
    return layout
  end
  function U.frame(parent, props)
    local f = mk("Frame", { BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 0),
      AutomaticSize = Enum.AutomaticSize.Y, Parent = parent })
    if props then for k, v in pairs(props) do f[k] = v end end
    return f
  end
  function U.text(parent, text, props)
    local label = mk("TextLabel", { BackgroundTransparency = 1, BorderSizePixel = 0, Text = text or "", FontFace = U.f.body,
      TextSize = 14, TextColor3 = U.c.paper, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Center,
      AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.new(), RichText = false, Parent = parent })
    if props then for k, v in pairs(props) do label[k] = v end end
    return label
  end
  function U.image(parent, name, props)
    local img = mk("ImageLabel", { BackgroundTransparency = 1, BorderSizePixel = 0, Image = U.icon(name) or "",
      Size = UDim2.fromOffset(18, 18), ImageColor3 = U.c.paper, ScaleType = Enum.ScaleType.Fit, Parent = parent })
    if props then for k, v in pairs(props) do img[k] = v end end
    -- Missing icon file: a small dot keeps the layout honest instead of a gap.
    if img.Image == "" then
      img.BackgroundTransparency = 0.6; img.BackgroundColor3 = img.ImageColor3
      U.corner(img, UDim.new(1, 0))
    end
    return img
  end
  -- A soft drop shadow. It is a SIBLING drawn one ZIndex below the element and
  -- follows its on-screen rectangle: with Sibling z-ordering a child always
  -- paints over its parent, so a shadow inside the panel would darken the panel
  -- itself. 9-slice with SliceScale sized to the spread, so a small element
  -- never collapses the slice into a solid dark box. parentScale is the UIScale
  -- in force on the element's parent (screen pixels per design unit).
  function U.shadow(inst, spread, transparency, parentScale)
    local id = U.asset("shadow.png")
    if not id or not inst.Parent then return nil end
    spread = spread or 18
    local sh = mk("ImageLabel", { Name = "Shadow", BackgroundTransparency = 1, Image = id, ImageColor3 = U.c.black,
      ImageTransparency = transparency or 0.35, ScaleType = Enum.ScaleType.Slice, SliceCenter = Rect.new(36, 36, 60, 60),
      SliceScale = math.clamp(spread / 36, 0.2, 1), ZIndex = math.max(inst.ZIndex - 1, 0), Parent = inst.Parent })
    local function sync()
      if not inst.Parent then sh:Destroy(); return end
      local ps = parentScale and parentScale() or 1
      local pa = inst.Parent.AbsolutePosition
      local p, sz = inst.AbsolutePosition, inst.AbsoluteSize
      sh.Position = UDim2.fromOffset((p.X - pa.X) / ps - spread, (p.Y - pa.Y) / ps - spread + 6)
      sh.Size = UDim2.fromOffset(sz.X / ps + spread * 2, sz.Y / ps + spread * 2)
      sh.Visible = inst.Visible
    end
    inst:GetPropertyChangedSignal("AbsolutePosition"):Connect(sync)
    inst:GetPropertyChangedSignal("AbsoluteSize"):Connect(sync)
    inst:GetPropertyChangedSignal("Visible"):Connect(sync)
    inst.Destroying:Connect(function() sh:Destroy() end)
    sync()
    return sh
  end
  function U.windowScale() return U.scale end

  function U.fmt(n, digits) return string.format("%." .. (digits or 0) .. "f", tonumber(n) or 0) end
  function U.clip(s, n) s = tostring(s or ""); return #s > n and (s:sub(1, n - 1) .. "…") or s end

  -- ------------------------------------------------------------ store
  -- One table of values. U.set marks a key dirty; watchers run once per frame,
  -- at the top of the render loop, however many times the key was written.
  U.S = {}
  local watchers, dirty = {}, {}
  local ctxStack = {}
  function U.set(key, value)
    if U.S[key] == value and type(value) ~= "table" then return end
    U.S[key] = value
    dirty[key] = true
  end
  function U.watch(key, fn, owner)
    local w = { fn = fn, owner = owner, ctx = ctxStack[#ctxStack] }
    local list = watchers[key]
    if not list then list = {}; watchers[key] = list end
    list[#list + 1] = w
    if w.ctx then w.ctx.items[#w.ctx.items + 1] = w end
    if U.S[key] ~= nil then
      local ok, err = pcall(fn, U.S[key])
      if not ok then if w.ctx then w.ctx.fail(err) else L.fault("sdc.watch." .. key, err) end end
    end
    return w
  end
  local function flush()
    for key in pairs(dirty) do
      dirty[key] = nil
      local list = watchers[key]
      if list then
        for i = #list, 1, -1 do
          local w = list[i]
          if w.dead or (w.owner and w.owner.Parent == nil) then table.remove(list, i)
          else
            local ok, err = pcall(w.fn, U.S[key])
            if not ok then
              w.dead = true
              if w.ctx then w.ctx.fail(err) else L.fault("sdc.watch." .. key, err) end
            end
          end
        end
      end
    end
  end

  -- ------------------------------------------------------------ springs
  -- Every movement is a spring: a response time and a damping ratio. A spring
  -- retargeted mid-flight keeps its velocity; one at rest costs nothing.
  U.TOKENS = { tap = { 0.16, 0.86 }, glide = { 0.30, 1.0 }, flourish = { 0.42, 0.72 }, menace = { 0.55, 0.58 } }
  U.reduced = U.pref("reducedMotion", false) == true
  local awake = {}
  local Spring = {}
  Spring.__index = Spring
  local function coeffs(token)
    local t = U.TOKENS[token] or U.TOKENS.glide
    local response, damping = t[1], t[2]
    if U.reduced then response, damping = response * 0.6, 1 end
    local w = 2 * math.pi / response
    return w * w, 2 * damping * w
  end
  function U.spring(n, token, onStep)
    return setmetatable({ n = n, x = table.create(n, 0), v = table.create(n, 0), t = table.create(n, 0),
      token = token or "glide", onStep = onStep }, Spring)
  end
  function Spring:set(values)
    for i = 1, self.n do self.x[i], self.t[i], self.v[i] = values[i], values[i], 0 end
    awake[self] = nil
    if self.onStep then self.onStep(self.x) end
  end
  function Spring:to(values, token)
    if token then self.token = token end
    for i = 1, self.n do self.t[i] = values[i] end
    awake[self] = true
  end
  function Spring:kick(i, velocity) self.v[i] += velocity; awake[self] = true end
  function Spring:step(dt)
    local k, c = coeffs(self.token)
    local steps = math.clamp(math.ceil(dt * 240), 1, 16)
    local h = dt / steps
    local x, v, t = self.x, self.v, self.t
    for _ = 1, steps do
      for i = 1, self.n do
        v[i] += (k * (t[i] - x[i]) - c * v[i]) * h
        x[i] += v[i] * h
      end
    end
    local rest = true
    for i = 1, self.n do
      if math.abs(t[i] - x[i]) > 1e-3 or math.abs(v[i]) > 1e-2 then rest = false; break end
    end
    if rest then
      for i = 1, self.n do x[i], v[i] = t[i], 0 end
      awake[self] = nil
    end
    if self.onStep then self.onStep(x) end
  end

  local packers = {
    number = { 1, function(v) return { v } end, function(x) return x[1] end },
    UDim2 = { 4, function(v) return { v.X.Scale, v.X.Offset, v.Y.Scale, v.Y.Offset } end,
      function(x) return UDim2.new(x[1], x[2], x[3], x[4]) end },
    UDim = { 2, function(v) return { v.Scale, v.Offset } end, function(x) return UDim.new(x[1], x[2]) end },
    Vector2 = { 2, function(v) return { v.X, v.Y } end, function(x) return Vector2.new(x[1], x[2]) end },
    Color3 = { 3, function(v) return { v.R, v.G, v.B } end,
      function(x) return Color3.new(math.clamp(x[1], 0, 1), math.clamp(x[2], 0, 1), math.clamp(x[3], 0, 1)) end },
  }
  local springsOf = setmetatable({}, { __mode = "k" })
  -- Spring an instance property toward a value. Color3, UDim2, UDim, Vector2
  -- and numbers; the spring is kept per (instance, property) and reused.
  function U.anim(inst, prop, target, token)
    local pack = packers[typeof(target)]
    if not pack then inst[prop] = target; return nil end
    local map = springsOf[inst]
    if not map then map = {}; springsOf[inst] = map end
    local s = map[prop]
    if not s then
      s = U.spring(pack[1], token, function(x) inst[prop] = pack[3](x) end)
      s:set(pack[2](inst[prop]))
      map[prop] = s
    end
    s:to(pack[2](target), token)
    return s
  end
  function U.snap(inst, prop, value)
    local map = springsOf[inst]
    local s = map and map[prop]
    local pack = packers[typeof(value)]
    if s and pack then s:set(pack[2](value)) else inst[prop] = value end
  end

  -- ------------------------------------------------------------ the one loop
  -- Springs, jobs and store flushes all run here. Jobs carry an optional rate
  -- (Hz) and a `visible` flag: with the console hidden those sleep entirely.
  -- A frame's jobs stop at the budget and resume where they left off.
  local jobs, cursor = {}, 1
  U.hidden = false
  U.budget = 0.0009
  function U.every(fn, opts)
    local job = { fn = fn, rate = opts and opts.rate, visible = opts and opts.visible, acc = 0, ctx = ctxStack[#ctxStack] }
    jobs[#jobs + 1] = job
    if job.ctx then job.ctx.items[#job.ctx.items + 1] = job end
    return job
  end
  function U.after(seconds, fn)
    local at = os.clock() + seconds
    local job
    job = U.every(function()
      if os.clock() >= at then job.dead = true; fn() end
    end)
    return job
  end
  U.stats = { frameMs = 0, jobs = 0, springs = 0 }
  local function loop(dt)
    if not L.live() then return end
    U.now = os.clock()
    flush()
    local springs = 0
    for s in pairs(awake) do springs += 1; s:step(dt) end
    local start = os.clock()
    local n = #jobs
    local ran = 0
    for step = 0, n - 1 do
      local index = (cursor + step - 1) % n + 1
      local job = jobs[index]
      if job and not job.dead and not (job.visible and U.hidden) then
        -- A throttled job is handed the time since IT last ran, not this frame's
        -- dt: at 200 fps a 30 Hz job handed dt ran its clock at 0.15x speed.
        local go, elapsed = true, dt
        if job.rate then
          job.acc += dt
          if job.acc < 1 / job.rate then go = false else elapsed = math.min(job.acc, 0.25); job.acc = 0 end
        end
        if go then
          ran += 1
          local ok, err = pcall(job.fn, elapsed)
          if not ok then
            job.dead = true
            if job.ctx then job.ctx.fail(err) else L.fault("sdc.job", err) end
          end
        end
      end
      if os.clock() - start > U.budget and step < n - 1 then cursor = index % n + 1; break end
    end
    for i = #jobs, 1, -1 do if jobs[i].dead then table.remove(jobs, i) end end
    U.stats.frameMs = (os.clock() - U.now) * 1000
    U.stats.jobs, U.stats.springs = ran, springs
  end
  L.hold(RS.RenderStepped:Connect(loop))

  -- ------------------------------------------------------------ boundaries
  -- A panel builds inside a boundary. Anything it registers (jobs, watchers)
  -- belongs to it; if the build or any of those throws, the panel is replaced
  -- by a card naming the error with a Retry, and the rest keeps running.
  function U.boundary(container, name, build)
    local ctx
    local function run()
      if ctx then for _, item in ipairs(ctx.items) do item.dead = true end end
      ctx = { items = {} }
      local failed = false
      function ctx.fail(err)
        if failed then return end
        failed = true
        for _, item in ipairs(ctx.items) do item.dead = true end
        L.fault("sdc." .. name, err)
        task.defer(function()
          container:ClearAllChildren()
          local card = mk("Frame", { BackgroundColor3 = U.c.panel, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = container })
          U.corner(card, 10); U.stroke(card, U.c.bad, 1, 0.4); U.pad(card, 14)
          U.list(card, "y", 8)
          U.text(card, "This panel stopped", { FontFace = U.f.bold, TextSize = 15, TextColor3 = U.c.bad })
          U.text(card, U.clip(tostring(err):gsub("^.-:%d+: ", ""), 160), { TextColor3 = U.c.mute, TextWrapped = true,
            AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0), TextSize = 13 })
          local retry = mk("TextButton", { Text = "Retry", FontFace = U.f.bold, TextSize = 13, TextColor3 = U.c.ink,
            BackgroundColor3 = U.c.gold, Size = UDim2.fromOffset(84, 28), AutoButtonColor = true, Parent = card })
          U.corner(retry, 7)
          retry.MouseButton1Click:Connect(run)
        end)
      end
      container:ClearAllChildren()
      ctxStack[#ctxStack + 1] = ctx
      local ok, err = pcall(build, container)
      table.remove(ctxStack)
      if not ok then ctx.fail(err) end
    end
    run()
  end

  -- ------------------------------------------------------------ input helpers
  function U.mouse() return UIS:GetMouseLocation() end
  function U.inside(gui, point)
    local p, s = gui.AbsolutePosition, gui.AbsoluteSize
    return point.X >= p.X and point.X <= p.X + s.X and point.Y >= p.Y and point.Y <= p.Y + s.Y
  end
  -- Drag with the mouse or a finger. onMove gets (position, delta since start).
  function U.drag(handle, onStart, onMove, onEnd)
    local dragging, startPos, conns = false, nil, {}
    handle.InputBegan:Connect(function(input)
      if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
      dragging = true
      startPos = Vector2.new(input.Position.X, input.Position.Y)
      if onStart then onStart(startPos) end
      conns[1] = UIS.InputChanged:Connect(function(change)
        if not dragging then return end
        if change.UserInputType == Enum.UserInputType.MouseMovement or change.UserInputType == Enum.UserInputType.Touch then
          local p = Vector2.new(change.Position.X, change.Position.Y)
          onMove(p, p - startPos)
        end
      end)
      conns[2] = UIS.InputEnded:Connect(function(ended)
        if ended.UserInputType == Enum.UserInputType.MouseButton1 or ended.UserInputType == Enum.UserInputType.Touch then
          dragging = false
          for _, c in ipairs(conns) do c:Disconnect() end
          table.clear(conns)
          if onEnd then onEnd() end
        end
      end)
    end)
  end

  -- ------------------------------------------------------------ sound
  -- Five sounds, off unless turned on, each played ±3% in pitch so a repeat
  -- never sounds mechanical.
  local SOUNDS = { click = "rbxasset://sounds/electronicpingshort.wav", tick = "rbxasset://sounds/clickfast.wav",
    open = "rbxasset://sounds/electronicpingshort.wav", warn = "rbxasset://sounds/electronicpingshort.wav",
    kill = "rbxasset://sounds/electronicpingshort.wav" }
  function U.sound(name, volume)
    if U.pref("sound", false) ~= true or not U.gui then return end
    local id = SOUNDS[name]
    if not id then return end
    local s = mk("Sound", { SoundId = id, Volume = (volume or 0.35) * (U.pref("volume", 0.6)),
      PlaybackSpeed = (name == "kill" and 0.8 or name == "warn" and 0.7 or 1) * (0.97 + math.random() * 0.06), Parent = U.gui })
    s:Play()
    task.delay(2, function() s:Destroy() end)
  end
end

-- 01 controls   buttons, toggles, sliders, segments, chips, inputs, dropdowns,
--               hold-to-confirm, tooltips and toasts. Every control returns an
--               api table with :set(value, silent) and .inst.
do
  local mk, c = U.mk, U.c
  local UIS = U.UIS
  local function mix(a, b, t) return a:Lerp(b, t) end
  U.mix = mix

  -- Wide-tracked caps for small labels (Roblox text has no letter-spacing).
  function U.track(s)
    local out = {}
    for _, code in utf8.codes(tostring(s):upper()) do out[#out + 1] = utf8.char(code) end
    return table.concat(out, "\u{200A}")
  end

  -- The layers every popover, tooltip and toast lives on. Built by the window
  -- part; controls only reach for them when they open something.
  U.scale = 1
  local function scaled(frame)
    local s = mk("UIScale", { Scale = U.scale, Parent = frame })
    U.scaled = U.scaled or setmetatable({}, { __mode = "k" })
    U.scaled[s] = true
    return s
  end
  U.scaledFrame = scaled

  -- ------------------------------------------------------------ tooltips
  -- The first waits 450 ms; while one was shown in the last 1.5 s the next
  -- appears at once, the way a toolbar should feel.
  local tip = { label = nil, owner = nil, warmUntil = 0, token = 0 }
  local function tipFrame()
    if tip.frame and tip.frame.Parent then return tip.frame end
    tip.frame = mk("Frame", { Name = "Tip", BackgroundColor3 = c.ink, AutomaticSize = Enum.AutomaticSize.XY,
      Size = UDim2.new(), Visible = false, ZIndex = 200, Parent = U.layers and U.layers.top or nil })
    U.corner(tip.frame, 6); U.stroke(tip.frame, c.line, 1, 0); U.pad(tip.frame, 5, 9, 5, 9)
    scaled(tip.frame)
    tip.label = U.text(tip.frame, "", { TextSize = 12.5, TextColor3 = c.paper, ZIndex = 201 })
    return tip.frame
  end
  function U.tip(gui, text)
    if not text or text == "" then return end
    gui.MouseEnter:Connect(function()
      tip.token += 1
      local token = tip.token
      local delay = os.clock() < tip.warmUntil and 0 or 0.45
      task.delay(delay, function()
        if token ~= tip.token or not gui.Parent then return end
        local f = tipFrame()
        tip.label.Text = type(text) == "function" and text() or text
        local m = U.mouse()
        f.Position = UDim2.fromOffset(m.X + 14, m.Y + 18)
        f.Visible = true
        tip.owner = gui
      end)
    end)
    gui.MouseLeave:Connect(function()
      tip.token += 1
      if tip.owner == gui and tip.frame then
        tip.frame.Visible = false
        tip.warmUntil = os.clock() + 1.5
        tip.owner = nil
      end
    end)
  end

  -- ------------------------------------------------------------ toasts
  -- A physics stack in the bottom-right: newest at the bottom pushes the rest
  -- up, hover pauses the timer, drag right to dismiss.
  local toasts = {}
  local function relayout()
    local y = 0
    for i = #toasts, 1, -1 do
      local t = toasts[i]
      local h = t.card.AbsoluteSize.Y / math.max(U.scale, 0.01)
      U.anim(t.card, "Position", UDim2.new(1, t.offsetX or 0, 1, -y - h), "flourish")
      y += h + 10
    end
  end
  function U.toast(title, body, kind)
    local host = U.layers and U.layers.toasts
    if not host then return end
    local tone = kind == "bad" and c.bad or kind == "ok" and c.ok or kind == "warn" and c.warn or c.aura
    local card = mk("Frame", { BackgroundColor3 = c.panel, Size = UDim2.fromOffset(330, 0), AutomaticSize = Enum.AutomaticSize.Y,
      AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 360, 1, -60), Parent = host })
    U.corner(card, 12); U.stroke(card, c.line, 1, 0); U.shadow(card, 16, 0.45, U.windowScale)
    local edge = mk("Frame", { BackgroundColor3 = tone, BorderSizePixel = 0, Size = UDim2.new(0, 3, 1, -20), Position = UDim2.fromOffset(0, 10), Parent = card })
    U.corner(edge, 2)
    local body_ = U.frame(card, { Size = UDim2.new(1, 0, 0, 0) })
    U.pad(body_, 11, 14, 12, 16); U.list(body_, "y", 3)
    U.text(body_, title or "", { FontFace = U.f.bold, TextSize = 14.5, TextColor3 = c.paper })
    if body and body ~= "" then
      U.text(body_, body, { TextSize = 13, TextColor3 = c.mute, TextWrapped = true, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0) })
    end
    local bar = mk("Frame", { BackgroundColor3 = tone, BackgroundTransparency = 0.4, BorderSizePixel = 0, Size = UDim2.new(1, -28, 0, 2),
      Position = UDim2.new(0, 14, 1, -5), Parent = card })
    local t = { card = card, left = 4.2, total = 4.2, hovered = false }
    table.insert(toasts, t)
    while #toasts > 5 do local old = table.remove(toasts, 1); old.card:Destroy() end
    card.MouseEnter:Connect(function() t.hovered = true end)
    card.MouseLeave:Connect(function() t.hovered = false end)
    local function dismiss()
      if t.gone then return end
      t.gone = true
      local at = table.find(toasts, t)
      if at then table.remove(toasts, at) end
      U.anim(card, "Position", UDim2.new(1, 380, card.Position.Y.Scale, card.Position.Y.Offset), "glide")
      task.delay(0.35, function() card:Destroy() end)
      relayout()
    end
    U.drag(card, nil, function(_, delta)
      t.offsetX = math.max(delta.X / math.max(U.scale, 0.01), 0)
      U.snap(card, "Position", UDim2.new(1, t.offsetX, card.Position.Y.Scale, card.Position.Y.Offset))
    end, function()
      if (t.offsetX or 0) > 90 then dismiss() else t.offsetX = 0; relayout() end
    end)
    U.every(function(dt)
      if t.gone or not card.Parent then return end
      if not t.hovered then t.left -= dt end
      bar.Size = UDim2.new(math.max(t.left / t.total, 0), -28 * math.max(t.left / t.total, 0), 0, 2)
      if t.left <= 0 then dismiss() end
    end)
    task.defer(relayout)
    U.sound(kind == "bad" and "warn" or "tick", 0.25)
    return t
  end
  Core.on("toast", function(title, message) U.toast(title, message, "warn") end)

  -- ------------------------------------------------------------ building blocks
  function U.card(parent, props)
    local f = mk("Frame", { BackgroundColor3 = c.panel, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 0),
      AutomaticSize = Enum.AutomaticSize.Y, Parent = parent })
    U.corner(f, 12); U.stroke(f, c.lineSoft, 1, 0)
    if props then for k, v in pairs(props) do f[k] = v end end
    U.pad(f, 14)
    U.list(f, "y", 10)
    return f
  end
  function U.section(parent, title, order)
    local row = U.frame(parent, { LayoutOrder = order or 0 })
    U.list(row, "x", 8, { VerticalAlignment = Enum.VerticalAlignment.Center })
    U.text(row, U.track(title), { FontFace = U.f.mono, TextSize = 11, TextColor3 = c.faint })
    return row
  end
  function U.hstack(parent, gap, props)
    local f = U.frame(parent, props)
    U.list(f, "x", gap or 8, { VerticalAlignment = Enum.VerticalAlignment.Center, Wraps = true })
    return f
  end

  -- ------------------------------------------------------------ button
  function U.button(parent, o)
    o = o or {}
    local style = o.style or "ghost"
    local base = style == "primary" and c.gold or style == "danger" and c.bad or style == "aura" and c.auraDeep or c.panel2
    local fg = (style == "primary" or style == "danger") and c.ink or c.paper
    local b = mk("TextButton", { AutoButtonColor = false, Text = "", BackgroundColor3 = base, BorderSizePixel = 0,
      Size = o.size or UDim2.fromOffset(0, o.height or 32), AutomaticSize = o.size and Enum.AutomaticSize.None or Enum.AutomaticSize.X,
      ClipsDescendants = true, LayoutOrder = o.order or 0, Parent = parent })
    U.corner(b, o.radius or 8)
    local stroke = U.stroke(b, style == "ghost" and c.line or base, 1, style == "ghost" and 0 or 1)
    local scale = mk("UIScale", { Parent = b })
    local inner = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), AutomaticSize = Enum.AutomaticSize.X, Parent = b })
    U.pad(inner, 0, o.padX or 12, 0, o.padX or 12)
    U.list(inner, "x", 7, { VerticalAlignment = Enum.VerticalAlignment.Center,
      HorizontalAlignment = o.size and Enum.HorizontalAlignment.Center or Enum.HorizontalAlignment.Left })
    local icon
    if o.icon then icon = U.image(inner, o.icon, { Size = UDim2.fromOffset(o.iconSize or 16, o.iconSize or 16), ImageColor3 = fg }) end
    local label
    if o.text then label = U.text(inner, o.text, { FontFace = U.f.bold, TextSize = o.textSize or 13.5, TextColor3 = fg }) end
    local api = { inst = b, label = label, icon = icon, enabled = true }
    local hover = mix(base, c.white, style == "ghost" and 0.06 or 0.12)
    b.MouseEnter:Connect(function() if api.enabled then U.anim(b, "BackgroundColor3", hover, "tap") end end)
    b.MouseLeave:Connect(function()
      U.anim(b, "BackgroundColor3", api.color or base, "tap")
      U.anim(scale, "Scale", 1, "tap")
      U.anim(inner, "Position", UDim2.new(), "glide")
    end)
    -- Lean 1.5 px toward the cursor: felt more than seen.
    b.MouseMoved:Connect(function(x, y)
      if not api.enabled then return end
      local p, s = b.AbsolutePosition, b.AbsoluteSize
      local dx = math.clamp((x - p.X - s.X / 2) / math.max(s.X / 2, 1), -1, 1)
      local dy = math.clamp((y - p.Y - s.Y / 2) / math.max(s.Y / 2, 1), -1, 1)
      U.anim(inner, "Position", UDim2.fromOffset(dx * 1.5, dy * 1.5), "glide")
    end)
    b.MouseButton1Down:Connect(function() if api.enabled then U.anim(scale, "Scale", 0.96, "tap") end end)
    b.MouseButton1Up:Connect(function() U.anim(scale, "Scale", 1, "tap") end)
    b.MouseButton1Click:Connect(function()
      if not api.enabled then return end
      -- ripple from where it was pressed
      local m = U.mouse()
      local p = b.AbsolutePosition
      local ring = mk("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = c.white, BackgroundTransparency = 0.8,
        Position = UDim2.fromOffset((m.X - p.X) / U.scale, (m.Y - p.Y) / U.scale), Size = UDim2.fromOffset(0, 0), ZIndex = b.ZIndex + 5, Parent = b })
      U.corner(ring, UDim.new(1, 0))
      local d = math.max(b.AbsoluteSize.X, b.AbsoluteSize.Y) * 2.2 / U.scale
      U.anim(ring, "Size", UDim2.fromOffset(d, d), "glide")
      U.anim(ring, "BackgroundTransparency", 1, "glide")
      task.delay(0.5, function() ring:Destroy() end)
      U.sound("click", 0.3)
      if o.onClick then
        local ok, err = pcall(o.onClick, api)
        if not ok then L.fault("sdc.button", err); U.toast("That did not work", tostring(err), "bad") end
      end
    end)
    function api:setText(t) if label then label.Text = t end end
    function api:setEnabled(on)
      api.enabled = on
      b.BackgroundTransparency = on and 0 or 0.5
      if label then label.TextTransparency = on and 0 or 0.45 end
      if icon then icon.ImageTransparency = on and 0 or 0.45 end
    end
    function api:setColor(col) api.color = col; U.anim(b, "BackgroundColor3", col, "glide") end
    if o.tip then U.tip(b, o.tip) end
    return api
  end

  -- An icon-only square button.
  function U.iconButton(parent, name, o)
    o = o or {}
    local size = o.size or 32
    local b = mk("TextButton", { AutoButtonColor = false, Text = "", BackgroundColor3 = c.panel2, BackgroundTransparency = o.solid and 0 or 1,
      Size = UDim2.fromOffset(size, size), LayoutOrder = o.order or 0, Parent = parent })
    U.corner(b, o.radius or 8)
    local img = U.image(b, name, { Size = UDim2.fromOffset(o.iconSize or 18, o.iconSize or 18), AnchorPoint = Vector2.new(0.5, 0.5),
      Position = UDim2.fromScale(0.5, 0.5), ImageColor3 = o.color or c.mute })
    local scale = mk("UIScale", { Parent = b })
    b.MouseEnter:Connect(function() U.anim(b, "BackgroundTransparency", 0, "tap"); U.anim(img, "ImageColor3", c.paper, "tap") end)
    b.MouseLeave:Connect(function()
      U.anim(b, "BackgroundTransparency", o.solid and 0 or 1, "tap"); U.anim(img, "ImageColor3", o.color or c.mute, "tap")
      U.anim(scale, "Scale", 1, "tap")
    end)
    b.MouseButton1Down:Connect(function() U.anim(scale, "Scale", 0.9, "tap") end)
    b.MouseButton1Up:Connect(function() U.anim(scale, "Scale", 1, "tap") end)
    b.MouseButton1Click:Connect(function() U.sound("click", 0.25); if o.onClick then o.onClick() end end)
    if o.tip then U.tip(b, o.tip) end
    return { inst = b, image = img }
  end

  -- ------------------------------------------------------------ hold to confirm
  -- Destructive actions fill over 600 ms while held; letting go early springs
  -- the fill back. No dialogs, no accidents.
  function U.holdButton(parent, o)
    local api = U.button(parent, { text = o.text, icon = o.icon, style = "ghost", order = o.order, tip = o.tip or "Hold to confirm" })
    local b = api.inst
    local fill = mk("Frame", { BackgroundColor3 = o.color or c.bad, BackgroundTransparency = 0.55, BorderSizePixel = 0,
      Size = UDim2.fromScale(0, 1), ZIndex = b.ZIndex, Parent = b })
    local holding, held = false, 0
    local job
    b.MouseButton1Down:Connect(function()
      holding, held = true, 0
      if job then job.dead = true end
      job = U.every(function(dt)
        if not holding then return end
        held += dt
        fill.Size = UDim2.fromScale(math.clamp(held / 0.6, 0, 1), 1)
        if held >= 0.6 then
          holding = false
          job.dead = true
          U.anim(fill, "Size", UDim2.fromScale(0, 1), "glide")
          U.sound("warn", 0.35)
          if o.onConfirm then o.onConfirm() end
        end
      end)
    end)
    local function cancel()
      if holding then holding = false; U.anim(fill, "Size", UDim2.fromScale(0, 1), "glide") end
    end
    b.MouseButton1Up:Connect(cancel)
    b.MouseLeave:Connect(cancel)
    return api
  end

  -- ------------------------------------------------------------ toggle
  function U.toggle(parent, o)
    local value = o.value == true
    local track = mk("TextButton", { AutoButtonColor = false, Text = "", Size = UDim2.fromOffset(42, 24),
      BackgroundColor3 = value and c.aura or c.panel2, LayoutOrder = o.order or 0, Parent = parent })
    U.corner(track, UDim.new(1, 0)); local stroke = U.stroke(track, value and c.aura or c.line, 1, 0)
    local knob = mk("Frame", { Size = UDim2.fromOffset(18, 18), AnchorPoint = Vector2.new(0, 0.5),
      Position = UDim2.new(0, value and 21 or 3, 0.5, 0), BackgroundColor3 = value and c.ink or c.mute, Parent = track })
    U.corner(knob, UDim.new(1, 0))
    local api = { inst = track }
    local function paint(animate)
      local f = animate and U.anim or U.snap
      f(track, "BackgroundColor3", value and c.aura or c.panel2, "glide")
      f(stroke, "Color", value and c.aura or c.line, "glide")
      f(knob, "Position", UDim2.new(0, value and 21 or 3, 0.5, 0), "flourish")
      f(knob, "BackgroundColor3", value and c.ink or c.mute, "glide")
      if animate then
        -- squash and stretch: the knob widens on the way, then settles round
        U.snap(knob, "Size", UDim2.fromOffset(24, 16))
        U.anim(knob, "Size", UDim2.fromOffset(18, 18), "flourish")
      end
    end
    function api:set(v, silent)
      v = v == true
      if v == value then return end
      value = v
      paint(true)
      if not silent and o.onChange then o.onChange(value) end
    end
    function api:get() return value end
    track.MouseButton1Click:Connect(function() U.sound("tick", 0.25); api:set(not value) end)
    if o.tip then U.tip(track, o.tip) end
    return api
  end

  -- ------------------------------------------------------------ slider
  -- Drag, Shift for tenth steps, double-click to reset, wheel to nudge, and the
  -- number itself can be typed into.
  function U.slider(parent, o)
    local min, max, step = o.min or 0, o.max or 1, o.step or 0.01
    local value = math.clamp(o.value or min, min, max)
    local fmt = o.format or function(v) return U.fmt(v, step < 0.1 and 2 or step < 1 and 1 or 0) end
    local root = mk("Frame", { BackgroundTransparency = 1, Size = o.size or UDim2.new(1, 0, 0, 28), LayoutOrder = o.order or 0, Parent = parent })
    local box = mk("TextBox", { Text = fmt(value), FontFace = U.f.mono, TextSize = 12.5, TextColor3 = c.paper, BackgroundColor3 = c.panel2,
      Size = UDim2.fromOffset(62, 24), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), ClearTextOnFocus = false, Parent = root })
    U.corner(box, 6)
    local track = mk("TextButton", { AutoButtonColor = false, Text = "", BackgroundColor3 = c.panel2, Size = UDim2.new(1, -74, 0, 6),
      AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Parent = root })
    U.corner(track, UDim.new(1, 0))
    local hit = mk("TextButton", { Text = "", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26), AnchorPoint = Vector2.new(0, 0.5),
      Position = UDim2.fromScale(0, 0.5), ZIndex = track.ZIndex + 3, Parent = track })
    local fill = mk("Frame", { BackgroundColor3 = o.color or c.aura, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), Parent = track })
    U.corner(fill, UDim.new(1, 0))
    local knob = mk("Frame", { Size = UDim2.fromOffset(14, 14), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5),
      BackgroundColor3 = c.paper, ZIndex = track.ZIndex + 2, Parent = track })
    U.corner(knob, UDim.new(1, 0)); U.stroke(knob, o.color or c.aura, 2, 0)
    local api = { inst = root }
    local function frac(v) return (v - min) / math.max(max - min, 1e-9) end
    local function paint(animate)
      local f = animate and U.anim or U.snap
      f(fill, "Size", UDim2.fromScale(frac(value), 1), "tap")
      f(knob, "Position", UDim2.fromScale(frac(value), 0.5), "tap")
      if not box:IsFocused() then box.Text = fmt(value) end
    end
    local function commit(v, silent)
      v = math.clamp(math.floor((v - min) / step + 0.5) * step + min, min, max)
      if math.abs(v - value) < 1e-9 then paint(true); return end
      value = v
      paint(true)
      if not silent and o.onChange then o.onChange(value) end
    end
    function api:set(v, silent)
      if type(v) ~= "number" then return end
      value = math.clamp(v, min, max)
      paint(true)
      if not silent and o.onChange then o.onChange(value) end
    end
    function api:get() return value end
    local lastClick, startValue, startX = 0, value, 0
    U.drag(hit, function(p)
      if os.clock() - lastClick < 0.3 and o.default ~= nil then commit(o.default); lastClick = 0; return end
      lastClick = os.clock()
      startValue, startX = value, p.X
      local fine = UIS:IsKeyDown(Enum.KeyCode.LeftShift) or UIS:IsKeyDown(Enum.KeyCode.RightShift)
      if not fine then
        local a, s = track.AbsolutePosition, track.AbsoluteSize
        commit(min + math.clamp((p.X - a.X) / math.max(s.X, 1), 0, 1) * (max - min))
        startValue = value
      end
      U.anim(knob, "Size", UDim2.fromOffset(18, 18), "tap")
    end, function(p)
      local s = track.AbsoluteSize
      local fine = UIS:IsKeyDown(Enum.KeyCode.LeftShift) or UIS:IsKeyDown(Enum.KeyCode.RightShift)
      local per = (max - min) / math.max(s.X, 1) * (fine and 0.1 or 1)
      commit(startValue + (p.X - startX) * per)
    end, function()
      U.anim(knob, "Size", UDim2.fromOffset(14, 14), "tap")
    end)
    hit.InputChanged:Connect(function(input)
      if input.UserInputType == Enum.UserInputType.MouseWheel then
        commit(value + (input.Position.Z > 0 and step or -step))
      end
    end)
    box.FocusLost:Connect(function()
      local n = tonumber((box.Text:gsub("[^%d%.%-]", "")))
      if n then commit(n) else paint(false) end
    end)
    paint(false)
    if o.tip then U.tip(track, o.tip) end
    return api
  end

  -- ------------------------------------------------------------ segmented
  function U.segmented(parent, o)
    local items = o.items
    local value = o.value or items[1]
    local root = mk("Frame", { BackgroundColor3 = c.panel2, Size = o.size or UDim2.fromOffset(#items * (o.itemWidth or 70), 30),
      LayoutOrder = o.order or 0, Parent = parent })
    U.corner(root, 8); U.stroke(root, c.line, 1, 0)
    local n = #items
    local pill = mk("Frame", { BackgroundColor3 = o.color or c.hover, Size = UDim2.new(1 / n, -4, 1, -4), Position = UDim2.new(0, 2, 0, 2), Parent = root })
    U.corner(pill, 6)
    local labels = {}
    local api = { inst = root }
    local function paint(animate)
      local index = table.find(items, value) or 1
      local f = animate and U.anim or U.snap
      f(pill, "Position", UDim2.new((index - 1) / n, 2, 0, 2), "flourish")
      for i, lab in ipairs(labels) do f(lab, "TextColor3", i == index and c.paper or c.faint, "glide") end
    end
    for i, item in ipairs(items) do
      local b = mk("TextButton", { AutoButtonColor = false, BackgroundTransparency = 1, Text = o.labels and o.labels[i] or item,
        FontFace = U.f.bold, TextSize = 12.5, TextColor3 = c.faint, Size = UDim2.new(1 / n, 0, 1, 0), Position = UDim2.fromScale((i - 1) / n, 0),
        ZIndex = pill.ZIndex + 1, Parent = root })
      labels[i] = b
      b.MouseButton1Click:Connect(function() U.sound("tick", 0.2); api:set(item) end)
    end
    function api:set(v, silent)
      if v == value or not table.find(items, v) then return end
      value = v
      paint(true)
      if not silent and o.onChange then o.onChange(value) end
    end
    function api:get() return value end
    paint(false)
    return api
  end

  -- ------------------------------------------------------------ chips
  function U.chips(parent, o)
    local wrap = U.hstack(parent, 6, { LayoutOrder = o.order or 0 })
    local api = { inst = wrap, buttons = {} }
    local value = o.value
    local function paint()
      for item, b in pairs(api.buttons) do
        local on = item == value
        U.anim(b, "BackgroundColor3", on and (o.color or c.gold) or c.panel2, "glide")
        U.anim(b, "TextColor3", on and c.ink or c.mute, "glide")
      end
    end
    for _, item in ipairs(o.items) do
      local b = mk("TextButton", { AutoButtonColor = false, Text = item, FontFace = U.f.mono, TextSize = 12, TextColor3 = c.mute,
        BackgroundColor3 = c.panel2, Size = UDim2.fromOffset(0, 26), AutomaticSize = Enum.AutomaticSize.X, Parent = wrap })
      U.corner(b, UDim.new(1, 0)); U.pad(b, 0, 11, 0, 11)
      api.buttons[item] = b
      b.MouseButton1Click:Connect(function()
        U.sound("tick", 0.2)
        value = item
        paint()
        if o.onChange then o.onChange(item) end
      end)
    end
    function api:set(v) value = v; paint() end
    paint()
    return api
  end

  -- ------------------------------------------------------------ text input
  function U.input(parent, o)
    local root = mk("Frame", { BackgroundColor3 = c.panel2, Size = o.size or UDim2.new(1, 0, 0, 32), LayoutOrder = o.order or 0, Parent = parent })
    U.corner(root, 8); local stroke = U.stroke(root, c.line, 1, 0)
    local x = 10
    if o.icon then U.image(root, o.icon, { Size = UDim2.fromOffset(15, 15), Position = UDim2.new(0, 10, 0.5, -7), ImageColor3 = c.faint }); x = 32 end
    local box = mk("TextBox", { BackgroundTransparency = 1, Text = o.value or "", PlaceholderText = o.placeholder or "",
      PlaceholderColor3 = c.faint, FontFace = o.mono and U.f.mono or U.f.body, TextSize = 13.5, TextColor3 = c.paper,
      TextXAlignment = Enum.TextXAlignment.Left, ClearTextOnFocus = false, Size = UDim2.new(1, -x - 8, 1, 0),
      Position = UDim2.fromOffset(x, 0), Parent = root })
    box.Focused:Connect(function() U.anim(stroke, "Color", c.aura, "glide") end)
    box.FocusLost:Connect(function(enter)
      U.anim(stroke, "Color", c.line, "glide")
      if o.onCommit then o.onCommit(box.Text, enter) end
    end)
    if o.onChange then box:GetPropertyChangedSignal("Text"):Connect(function() o.onChange(box.Text) end) end
    local api = { inst = root, box = box }
    function api:set(v) box.Text = tostring(v or "") end
    function api:get() return box.Text end
    return api
  end

  -- ------------------------------------------------------------ dropdown
  local openPop
  function U.closePopover()
    if openPop then
      local p = openPop
      openPop = nil
      U.anim(p.scale, "Scale", U.scale * 0.94, "tap")
      U.anim(p.frame, "BackgroundTransparency", 1, "tap")
      task.delay(0.12, function() p.frame:Destroy() end)
    end
  end
  function U.dropdown(parent, o)
    local value = o.value
    local b = mk("TextButton", { AutoButtonColor = false, Text = "", BackgroundColor3 = c.panel2, Size = o.size or UDim2.new(1, 0, 0, 32),
      LayoutOrder = o.order or 0, Parent = parent })
    U.corner(b, 8); U.stroke(b, c.line, 1, 0)
    local label = U.text(b, tostring(value or o.placeholder or "Choose"), { TextSize = 13.5, Position = UDim2.fromOffset(11, 0),
      Size = UDim2.new(1, -40, 1, 0), AutomaticSize = Enum.AutomaticSize.None, TextTruncate = Enum.TextTruncate.AtEnd })
    local chev = U.image(b, "chevron-down", { Size = UDim2.fromOffset(16, 16), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), ImageColor3 = c.faint })
    local api = { inst = b }
    function api:set(v, silent)
      value = v
      label.Text = tostring(v or o.placeholder or "Choose")
      if not silent and o.onChange then o.onChange(v) end
    end
    function api:get() return value end
    b.MouseButton1Click:Connect(function()
      if openPop and openPop.owner == b then U.closePopover(); return end
      U.closePopover()
      local items = type(o.items) == "function" and o.items() or o.items
      local top = U.layers.top
      local p, s = b.AbsolutePosition, b.AbsoluteSize
      local width = s.X / U.scale
      local frame = mk("Frame", { BackgroundColor3 = c.panel, Position = UDim2.fromOffset(p.X, p.Y + s.Y + 4), Size = UDim2.fromOffset(width, 0),
        AutomaticSize = Enum.AutomaticSize.Y, ZIndex = 150, Parent = top })
      local sc = scaled(frame)
      sc.Scale = U.scale * 0.94
      U.anim(sc, "Scale", U.scale, "flourish")
      U.corner(frame, 10); U.stroke(frame, c.line, 1, 0); U.shadow(frame, 16, 0.4); U.pad(frame, 6)
      U.list(frame, "y", 4)
      local search
      if #items > 8 then search = U.input(frame, { placeholder = "Search", icon = "search", size = UDim2.new(1, 0, 0, 30) }) end
      local scroll = mk("ScrollingFrame", { BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, math.min(#items, 8) * 30),
        CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 3, ScrollBarImageColor3 = c.line,
        LayoutOrder = 2, Parent = frame })
      U.list(scroll, "y", 2)
      local rows = {}
      for i, item in ipairs(items) do
        local text = type(item) == "table" and item.label or tostring(item)
        local key = type(item) == "table" and item.value or item
        local row = mk("TextButton", { AutoButtonColor = false, Text = "", BackgroundColor3 = key == value and c.hover or c.panel,
          Size = UDim2.new(1, -4, 0, 28), LayoutOrder = i, Parent = scroll })
        U.corner(row, 6)
        U.text(row, text, { TextSize = 13, Position = UDim2.fromOffset(9, 0), Size = UDim2.new(1, -18, 1, 0), AutomaticSize = Enum.AutomaticSize.None,
          TextTruncate = Enum.TextTruncate.AtEnd, TextColor3 = key == value and c.gold or c.paper })
        row.MouseEnter:Connect(function() U.anim(row, "BackgroundColor3", c.hover, "tap") end)
        row.MouseLeave:Connect(function() U.anim(row, "BackgroundColor3", key == value and c.hover or c.panel, "tap") end)
        row.MouseButton1Click:Connect(function() U.closePopover(); api:set(key) end)
        rows[#rows + 1] = { row = row, text = text:lower() }
      end
      if search then
        search.box:GetPropertyChangedSignal("Text"):Connect(function()
          local q = search.box.Text:lower()
          for _, r in ipairs(rows) do r.row.Visible = q == "" or r.text:find(q, 1, true) ~= nil end
        end)
        task.defer(function() search.box:CaptureFocus() end)
      end
      openPop = { frame = frame, scale = sc, owner = b }
    end)
    return api
  end
  -- A click anywhere outside an open popover closes it.
  L.hold(UIS.InputBegan:Connect(function(input)
    if not openPop then return end
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
    local m = U.mouse()
    if not U.inside(openPop.frame, m) and not U.inside(openPop.owner, m) then U.closePopover() end
  end))

  -- ------------------------------------------------------------ settings row
  -- Label and its footnote on the left, the control on the right. The footnote
  -- is where a measured default says why it is what it is.
  function U.row(parent, label, note, order)
    local row = U.frame(parent, { LayoutOrder = order or 0 })
    local left = U.frame(row, { Size = UDim2.new(1, -270, 0, 0) })
    U.list(left, "y", 2)
    U.text(left, label, { FontFace = U.f.bold, TextSize = 14 })
    if note and note ~= "" then
      U.text(left, note, { TextSize = 12.5, TextColor3 = c.faint, TextWrapped = true, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0) })
    end
    local right = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.new(0, 256, 0, 32), AnchorPoint = Vector2.new(1, 0),
      Position = UDim2.new(1, 0, 0, 0), Parent = row })
    U.list(right, "x", 6, { HorizontalAlignment = Enum.HorizontalAlignment.Right, VerticalAlignment = Enum.VerticalAlignment.Center })
    return row, right, left
  end

  -- A number that rolls to its new value instead of jumping.
  function U.roller(label, digits)
    local s = U.spring(1, "flourish", function(x) label.Text = U.fmt(x[1], digits or 0) end)
    s:set({ tonumber(label.Text) or 0 })
    return function(v) if type(v) == "number" then s:to({ v }) end end
  end
end

-- 02 window     the ScreenGui and its layers, the scale, the window chrome, the
--               surface rail, fade-through switches, throw-and-snap dragging,
--               resizing, the mini HUD, keybinds and undo.
do
  local mk, c = U.mk, U.c
  local UIS, RS = U.UIS, U.RS
  local camera = workspace.CurrentCamera
  local host = (type(gethui) == "function" and (function() local ok, h = pcall(gethui); return ok and h or nil end)())
    or game:GetService("CoreGui")
  -- A plain name: nothing branded in the tree.
  local gui = mk("ScreenGui", { Name = "ScreenGui", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 9000,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Parent = host })
  U.gui = gui
  L.own(gui)

  -- ------------------------------------------------------------ scale
  -- Design units are 1080p pixels; the whole console scales with the screen
  -- height, times the user's own UI scale.
  local function computeScale()
    local vp = camera.ViewportSize
    return math.clamp(vp.Y / 1080, 0.72, 1.6) * math.clamp(tonumber(U.pref("uiScale", 1)) or 1, 0.6, 1.6)
  end
  U.scale = computeScale()
  -- A container that fills the screen once scaled: its size is 1/scale.
  local fills = {}
  local function screenFill(name, z)
    local f = mk("Frame", { Name = name, BackgroundTransparency = 1, Size = UDim2.fromScale(1 / U.scale, 1 / U.scale), ZIndex = z, Parent = gui })
    local s = mk("UIScale", { Scale = U.scale, Parent = f })
    fills[#fills + 1] = { frame = f, scale = s }
    return f
  end
  U.layers = {
    window = screenFill("Main", 10),
    hud = screenFill("Hud", 20),
    toasts = screenFill("Notes", 60),
    top = mk("Frame", { Name = "Top", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 100, Parent = gui }),
  }
  U.pad(U.layers.toasts, 18)
  function U.rescale()
    U.scale = computeScale()
    for _, f in ipairs(fills) do f.scale.Scale = U.scale; f.frame.Size = UDim2.fromScale(1 / U.scale, 1 / U.scale) end
    for s in pairs(U.scaled or {}) do if s.Parent then s.Scale = U.scale end end
  end
  L.hold(camera:GetPropertyChangedSignal("ViewportSize"):Connect(U.rescale))
  local function screen() return camera.ViewportSize / U.scale end

  -- ------------------------------------------------------------ the window
  local W0, H0 = 1000, 640
  local geomKey = function() local v = camera.ViewportSize; return string.format("geom.%dx%d", v.X, v.Y) end
  local saved = U.pref(geomKey(), nil)
  local size = Vector2.new(W0, H0)
  local pos
  if type(saved) == "table" and tonumber(saved.w) then
    size = Vector2.new(math.max(saved.w, 760), math.max(saved.h, 500))
    pos = Vector2.new(saved.x, saved.y)
  end
  local scr = screen()
  pos = pos or Vector2.new((scr.X - size.X) / 2, (scr.Y - size.Y) / 2)

  local win = mk("Frame", { Name = "Window", BackgroundColor3 = c.base, Size = UDim2.fromOffset(size.X, size.Y),
    Position = UDim2.fromOffset(pos.X, pos.Y), Visible = false, Parent = U.layers.window })
  U.corner(win, 16)
  local winStroke = U.stroke(win, c.line, 1, 0)
  local winScale = mk("UIScale", { Scale = 1, Parent = win })
  U.win = win
  U.shadow(win, 34, 0.25, U.windowScale)
  -- Screentone in the top-right, fading out: the page this came from.
  local tone = U.asset("tone.png")
  if tone then
    local t = mk("ImageLabel", { BackgroundTransparency = 1, Image = tone, ImageColor3 = c.aura, ImageTransparency = 0.86,
      ScaleType = Enum.ScaleType.Tile, TileSize = UDim2.fromOffset(9, 9), Size = UDim2.new(0.55, 0, 0.6, 0), AnchorPoint = Vector2.new(1, 0),
      Position = UDim2.new(1, 0, 0, 0), Parent = win })
    U.corner(t, 16)
    mk("UIGradient", { Rotation = 145, Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.55, 0.85),
      NumberSequenceKeypoint.new(1, 1) }), Parent = t })
  end
  local glow = U.asset("glow.png")
  if glow then
    mk("ImageLabel", { BackgroundTransparency = 1, Image = glow, ImageColor3 = c.aura, ImageTransparency = 0.9,
      Size = UDim2.fromOffset(620, 620), Position = UDim2.new(1, -330, 0, -330), Parent = win })
  end

  -- ------------------------------------------------------------ title bar
  local bar = mk("Frame", { Name = "Bar", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 54), Parent = win })
  local mark = mk("Frame", { BackgroundColor3 = c.gold, Size = UDim2.fromOffset(22, 22), AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromOffset(30, 27), Rotation = 45, Parent = bar })
  U.corner(mark, 5)
  mk("UIGradient", { Color = ColorSequence.new(c.gold, c.goldDeep), Rotation = 90, Parent = mark })
  local markIn = mk("Frame", { BackgroundColor3 = c.base, Size = UDim2.fromOffset(10, 10), AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5), Parent = mark })
  U.corner(markIn, 2)
  local titleBox = U.frame(bar, { Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.XY, Position = UDim2.fromOffset(52, 9) })
  U.list(titleBox, "y", 0)
  local titleRow = U.frame(titleBox, { Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY })
  U.list(titleRow, "x", 12, { VerticalAlignment = Enum.VerticalAlignment.Center })
  local title = U.text(titleRow, "STAND DOS CINTOE'S", { FontFace = U.f.display, TextSize = 19, TextColor3 = c.white })
  local shine = mk("UIGradient", { Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, c.paper), ColorSequenceKeypoint.new(0.45, c.paper),
    ColorSequenceKeypoint.new(0.5, c.gold), ColorSequenceKeypoint.new(0.55, c.paper), ColorSequenceKeypoint.new(1, c.paper) }),
    Offset = Vector2.new(-1, 0), Parent = title })
  U.text(titleBox, U.KANA .. "  ·  v" .. U.version, { FontFace = U.f.mono, TextSize = 10.5, TextColor3 = c.faint })
  -- ゴゴゴ, trembling beside the name at a menacing 12 fps.
  -- It sits in the title row, so it follows the name's real rendered width.
  local gogoSlot = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(62, 24), LayoutOrder = 2, Parent = titleRow })
  local gogo = U.text(gogoSlot, "ゴゴゴ", { FontFace = U.f.comic, TextSize = 24, TextColor3 = c.aura, TextTransparency = 0.15,
    AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Rotation = -6 })
  mk("UIStroke", { Color = c.ink, Thickness = 1.5, Parent = gogo })
  U.gogo = gogo
  -- A gold shine crosses the name every seven seconds.
  local shineT = 0
  U.every(function(dt)
    shineT += dt
    local phase = shineT % 7
    shine.Offset = Vector2.new(phase < 1.1 and (-1 + phase / 1.1 * 2) or -1, 0)
    if not U.reduced then
      gogo.Position = UDim2.new(0.5, math.random(-1, 1), 0.5, math.random(-1, 1))
      gogo.Rotation = -6 + math.random(-10, 10) / 10
    end
  end, { rate = 12, visible = true })

  local right = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X,
    AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 0), Parent = bar })
  U.list(right, "x", 6, { VerticalAlignment = Enum.VerticalAlignment.Center, HorizontalAlignment = Enum.HorizontalAlignment.Right })

  -- mode pill: dot breathing at the stand's own bob, 2.2 rad/s
  local pill = mk("Frame", { BackgroundColor3 = c.panel2, Size = UDim2.fromOffset(0, 28), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 1, Parent = right })
  U.corner(pill, UDim.new(1, 0)); U.pad(pill, 0, 12, 0, 10)
  U.list(pill, "x", 7, { VerticalAlignment = Enum.VerticalAlignment.Center })
  local dotWrap = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(10, 10), Parent = pill })
  local halo = mk("Frame", { BackgroundColor3 = c.faint, BackgroundTransparency = 0.7, AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(10, 10), Parent = dotWrap })
  U.corner(halo, UDim.new(1, 0))
  local dot = mk("Frame", { BackgroundColor3 = c.faint, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(8, 8), Parent = dotWrap })
  U.corner(dot, UDim.new(1, 0))
  local pillText = U.text(pill, U.track("off"), { FontFace = U.f.mono, TextSize = 11.5, TextColor3 = c.mute })
  U.pill = { frame = pill, dot = dot, halo = halo, text = pillText }
  local breath = 0
  U.every(function(dt)
    breath += dt * 2.2
    local k = (math.sin(breath) + 1) / 2
    halo.Size = UDim2.fromOffset(10 + k * 8, 10 + k * 8)
    halo.BackgroundTransparency = 0.55 + k * 0.4
  end, { visible = true })

  local showChip = mk("TextButton", { AutoButtonColor = false, Text = U.track("showcase"), FontFace = U.f.mono, TextSize = 11,
    TextColor3 = c.ink, BackgroundColor3 = c.gold, Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X,
    Visible = false, LayoutOrder = 0, Parent = right })
  U.corner(showChip, UDim.new(1, 0)); U.pad(showChip, 0, 10, 0, 10)
  U.tip(showChip, "Showing simulated data. Nothing here moves your character or speaks in chat. Click to turn it off.")
  showChip.MouseButton1Click:Connect(function() if U.setShowcase then U.setShowcase(false) end end)
  U.showChip = showChip

  U.iconButton(right, "command", { order = 2, tip = "Command palette  ·  " .. tostring(U.pref("keyPalette", "F2")),
    onClick = function() if U.palette then U.palette() end end })
  U.iconButton(right, "minus", { order = 3, tip = "Shrink to the mini HUD", onClick = function() U.minimise() end })
  U.iconButton(right, "x", { order = 4, tip = "Hide  ·  " .. tostring(U.pref("keyToggle", "RightControl")) .. " brings it back",
    onClick = function() U.hide() end })

  -- ------------------------------------------------------------ rail
  local RAIL = 70
  local rail = mk("Frame", { Name = "Rail", BackgroundTransparency = 1, Size = UDim2.new(0, RAIL, 1, -62), Position = UDim2.fromOffset(0, 58), Parent = win })
  local railList = U.frame(rail, { Size = UDim2.new(1, 0, 0, 0) })
  U.list(railList, "y", 6, { HorizontalAlignment = Enum.HorizontalAlignment.Center })
  U.pad(railList, 6, 0, 0, 0)
  local indicator = mk("Frame", { BackgroundColor3 = c.gold, Size = UDim2.fromOffset(3, 22), Position = UDim2.fromOffset(0, 18), Parent = rail })
  U.corner(indicator, UDim.new(1, 0))
  local ver = U.text(rail, "v" .. U.version, { FontFace = U.f.mono, TextSize = 10, TextColor3 = c.faint, AnchorPoint = Vector2.new(0.5, 1),
    Position = UDim2.new(0.5, 0, 1, -8) })
  U.tip(ver, function() return string.format("UI frame %.2f ms · %d jobs · %d springs awake", U.stats.frameMs, U.stats.jobs, U.stats.springs) end)

  -- ------------------------------------------------------------ content
  local content = mk("Frame", { Name = "Content", BackgroundColor3 = c.ink, Size = UDim2.new(1, -RAIL - 10, 1, -64),
    Position = UDim2.fromOffset(RAIL, 56), ClipsDescendants = true, Parent = win })
  U.corner(content, 12); U.stroke(content, c.lineSoft, 1, 0)
  local veil = mk("Frame", { BackgroundColor3 = c.ink, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 50, Parent = content })
  U.corner(veil, 12)
  local winVeil = mk("Frame", { BackgroundColor3 = c.base, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 90, Parent = win })
  U.corner(winVeil, 16)

  U.surfaces, U.surfaceList = {}, {}
  local current
  function U.surface(def)
    U.surfaces[def.id] = def
    U.surfaceList[#U.surfaceList + 1] = def
    def.order = #U.surfaceList
  end

  local railButtons = {}
  local function buildRail()
    for i, def in ipairs(U.surfaceList) do
      local b = U.iconButton(railList, def.icon, { size = 44, iconSize = 21, order = i, tip = def.name .. (def.key and ("  ·  " .. def.key) or ""),
        onClick = function() U.go(def.id) end })
      railButtons[def.id] = b
    end
  end

  local function page(def)
    if def.page then return def.page end
    local scroll = mk("ScrollingFrame", { Name = def.id, BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1),
      CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 4, ScrollBarImageColor3 = c.line,
      ScrollingDirection = Enum.ScrollingDirection.Y, Visible = false, Parent = content })
    local inner = U.frame(scroll, { Size = UDim2.new(1, 0, 0, 0) })
    U.pad(inner, 18, 20, 22, 20)
    def.page, def.inner = scroll, inner
    U.boundary(inner, def.id, function(container)
      U.list(container, "y", 14)
      def.build(container, def)
    end)
    return scroll
  end

  -- Fade-through: the veil snaps over the content, the surfaces swap under it,
  -- and the new one slides the last 24 px as the veil lifts. Each surface keeps
  -- its own scroll position.
  function U.go(id)
    local def = U.surfaces[id]
    if not def or current == def then return end
    local old = current
    current = def
    U.set("surface", id)
    U.setPref("surface", id)
    local p = page(def)
    if old then
      U.snap(veil, "BackgroundTransparency", 0.15)
      old.page.Visible = false
    end
    p.Visible = true
    U.snap(p, "Position", UDim2.fromOffset(0, old and 24 or 0))
    U.anim(p, "Position", UDim2.fromOffset(0, 0), "glide")
    U.anim(veil, "BackgroundTransparency", 1, "glide")
    for sid, b in pairs(railButtons) do
      local on = sid == id
      U.anim(b.image, "ImageColor3", on and c.gold or c.mute, "glide")
      b.inst.BackgroundTransparency = on and 0 or 1
      b.inst.BackgroundColor3 = on and c.panel2 or c.panel2
    end
    local b = railButtons[id]
    if b then
      task.defer(function()
        local y = b.inst.AbsolutePosition.Y - rail.AbsolutePosition.Y
        U.anim(indicator, "Position", UDim2.fromOffset(0, y / U.scale + 11), "flourish")
      end)
    end
    if def.onShow then pcall(def.onShow) end
  end

  -- ------------------------------------------------------------ open / close
  U.visible = false
  local function saveGeometry()
    local p, s = win.Position, win.Size
    U.setPref(geomKey(), { x = p.X.Offset, y = p.Y.Offset, w = s.X.Offset, h = s.Y.Offset })
  end
  function U.show()
    if U.visible then return end
    U.visible, U.hidden = true, false
    if U.hud then U.hud.Visible = false end
    win.Visible = true
    U.snap(winScale, "Scale", 0.92)
    U.snap(winVeil, "BackgroundTransparency", 0)
    U.anim(winScale, "Scale", 1, "flourish")
    U.anim(winVeil, "BackgroundTransparency", 1, "glide")
    U.sound("open", 0.3)
  end
  function U.hide(toHud)
    if not U.visible then return end
    U.visible = false
    U.closePopover()
    U.anim(winScale, "Scale", 0.94, "glide")
    U.anim(winVeil, "BackgroundTransparency", 0, "tap")
    task.delay(0.2, function()
      if not U.visible then
        win.Visible = false
        U.hidden = not toHud
        if toHud and U.hud then U.hud.Visible = true end
      end
    end)
  end
  function U.minimise() U.hide(true) end
  function U.toggleWindow() if U.visible then U.hide() else U.show() end end

  -- ------------------------------------------------------------ drag, throw, snap
  -- Dragged by the title bar. Let go while moving and it keeps going, then
  -- settles; near an edge it snaps flush with a 16 px margin; it can never be
  -- lost off-screen.
  local SNAP, MARGIN = 28, 16
  local grabAt, startPos, samples = nil, nil, {}
  local function clampPos(p)
    local s = screen()
    local w, h = win.Size.X.Offset, win.Size.Y.Offset
    local x = math.clamp(p.X, -w + 120, s.X - 120)
    local y = math.clamp(p.Y, 0, s.Y - 60)
    if math.abs(x - MARGIN) < SNAP then x = MARGIN end
    if math.abs(x + w - (s.X - MARGIN)) < SNAP then x = s.X - MARGIN - w end
    if math.abs(y - MARGIN) < SNAP then y = MARGIN end
    if math.abs(y + h - (s.Y - MARGIN)) < SNAP then y = s.Y - MARGIN - h end
    return Vector2.new(x, y)
  end
  U.drag(bar, function(p)
    grabAt = p
    startPos = Vector2.new(win.Position.X.Offset, win.Position.Y.Offset)
    table.clear(samples)
  end, function(p, delta)
    local target = startPos + delta / U.scale
    U.snap(win, "Position", UDim2.fromOffset(target.X, target.Y))
    samples[#samples + 1] = { t = os.clock(), p = target }
    if #samples > 6 then table.remove(samples, 1) end
  end, function()
    local throw = Vector2.zero
    if #samples >= 2 then
      local a, b = samples[1], samples[#samples]
      local dt = math.max(b.t - a.t, 1 / 120)
      if os.clock() - b.t < 0.08 then throw = (b.p - a.p) / dt end
    end
    local here = Vector2.new(win.Position.X.Offset, win.Position.Y.Offset)
    local landing = clampPos(here + throw * 0.12)
    U.anim(win, "Position", UDim2.fromOffset(landing.X, landing.Y), "flourish")
    task.delay(0.6, saveGeometry)
  end)

  local grip = mk("TextButton", { Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.fromOffset(22, 22),
    AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, 0, 1, 0), ZIndex = 95, Parent = win })
  for i = 1, 3 do
    local d = mk("Frame", { BackgroundColor3 = c.faint, BackgroundTransparency = 0.3, Size = UDim2.fromOffset(2, 2),
      Position = UDim2.fromOffset(18 - i * 4, 14), ZIndex = 96, Parent = grip })
    U.corner(d, UDim.new(1, 0))
    local e = mk("Frame", { BackgroundColor3 = c.faint, BackgroundTransparency = 0.3, Size = UDim2.fromOffset(2, 2),
      Position = UDim2.fromOffset(14, 18 - i * 4), ZIndex = 96, Parent = grip })
    U.corner(e, UDim.new(1, 0))
  end
  U.tip(grip, "Drag to resize")
  local startSize
  U.drag(grip, function() startSize = Vector2.new(win.Size.X.Offset, win.Size.Y.Offset) end, function(_, delta)
    local s = startSize + delta / U.scale
    U.snap(win, "Size", UDim2.fromOffset(math.max(s.X, 760), math.max(s.Y, 500)))
  end, function() saveGeometry() end)

  -- ------------------------------------------------------------ mini HUD
  local hud = mk("TextButton", { Name = "Hud", AutoButtonColor = false, Text = "", BackgroundColor3 = c.base, Size = UDim2.fromOffset(0, 38),
    AutomaticSize = Enum.AutomaticSize.X, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 14), Visible = false, Parent = U.layers.hud })
  U.corner(hud, UDim.new(1, 0)); U.stroke(hud, c.line, 1, 0); U.shadow(hud, 14, 0.4, U.windowScale); U.pad(hud, 0, 16, 0, 12)
  U.list(hud, "x", 10, { VerticalAlignment = Enum.VerticalAlignment.Center })
  local hudDot = mk("Frame", { BackgroundColor3 = c.faint, Size = UDim2.fromOffset(9, 9), Parent = hud })
  U.corner(hudDot, UDim.new(1, 0))
  local hudText = U.text(hud, "off", { FontFace = U.f.bold, TextSize = 13 })
  local hudNext = U.text(hud, "", { FontFace = U.f.mono, TextSize = 12, TextColor3 = c.faint })
  U.hud, U.hudParts = hud, { dot = hudDot, text = hudText, extra = hudNext }
  local hudMoved = false
  local hudStart
  U.drag(hud, function() hudMoved = false; hudStart = hud.Position end, function(_, delta)
    if delta.Magnitude > 4 then hudMoved = true end
    U.snap(hud, "Position", UDim2.new(hudStart.X.Scale, hudStart.X.Offset + delta.X / U.scale, hudStart.Y.Scale, hudStart.Y.Offset + delta.Y / U.scale))
  end, nil)
  hud.MouseButton1Click:Connect(function() if not hudMoved then U.show() end end)
  U.tip(hud, "Click to open  ·  drag to move")

  -- ------------------------------------------------------------ undo
  U.history = {}
  function U.remember(label, undo)
    U.history[#U.history + 1] = { label = label, undo = undo }
    if #U.history > 20 then table.remove(U.history, 1) end
  end
  function U.undo()
    local last = table.remove(U.history)
    if not last then U.toast("Nothing to undo", nil, "warn"); return end
    local ok = pcall(last.undo)
    U.toast(ok and "Undone" or "Could not undo", last.label, ok and "ok" or "bad")
  end

  -- ------------------------------------------------------------ keys
  local function key(prefName, default)
    local name = U.pref(prefName, default)
    return Enum.KeyCode[name] or Enum.KeyCode[default]
  end
  U.key = key
  L.hold(UIS.InputBegan:Connect(function(input, processed)
    if UIS:GetFocusedTextBox() or U.capturing then return end
    if input.KeyCode == key("keyToggle", "RightControl") then U.toggleWindow(); return end
    if input.KeyCode == key("keyPalette", "F2") then if U.palette then U.palette() end; return end
    if input.KeyCode == key("keyWheel", "LeftAlt") and not processed then if U.wheelOpen then U.wheelOpen() end; return end
    if input.KeyCode == Enum.KeyCode.Z and U.visible and (UIS:IsKeyDown(Enum.KeyCode.LeftControl) or UIS:IsKeyDown(Enum.KeyCode.RightControl)) then
      U.undo()
    end
    if input.KeyCode == Enum.KeyCode.Escape and U.visible then U.closePopover() end
  end))
  L.hold(UIS.InputEnded:Connect(function(input)
    if input.KeyCode == key("keyWheel", "LeftAlt") and U.wheelClose then U.wheelClose() end
  end))

  U.buildRail = buildRail
  L.cleanup(function() pcall(function() gui:Destroy() end) end, 50)
end

-- 03 data       the store's one source: StandCore's status and events, or the
--               showcase simulator. Actions go through U.act, which in showcase
--               mode is simulated and NEVER reaches the stand -- no latch, no
--               chat, nothing another player can see.
do
  local LP = U.LP

  -- ------------------------------------------------------------ feed
  U.feed = {}
  local t0 = os.clock()
  local feedN = 0
  function U.push(kind, text, demo)
    feedN += 1
    table.insert(U.feed, { n = feedN, t = os.clock() - t0, kind = kind, text = tostring(text), demo = demo == true })
    while #U.feed > 200 do table.remove(U.feed, 1) end
    U.set("feedN", feedN)
  end
  local function real() return not U.S.showcase end
  Core.on("say", function(message) if real() then U.push("say", "“" .. message .. "”") end end)
  Core.on("command", function(word, rest) if real() then U.push("cmd", "." .. word .. (rest ~= "" and (" " .. rest) or "")) end end)
  Core.on("kill", function(player)
    if real() then U.push("kill", (player and player.Name or "target") .. " went down"); if U.onKill then U.onKill() end end
  end)
  Core.on("carry", function(phase, player, detail, died)
    if not real() then return end
    local who = player and player.Name or "?"
    if phase == "begin" then U.push("carry", "carry begins on " .. who .. " (" .. tostring(detail) .. ")")
    elseif phase == "hold" then U.push("carry", "hold with " .. tostring(detail) .. " — riding down")
    else U.push("carry", "carry ends: " .. tostring(detail) .. (died and " · they died in the hold" or "")) end
  end)
  Core.on("fault", function(label, err) U.push("fault", tostring(label) .. ": " .. U.clip(tostring(err), 120)) end)

  -- ------------------------------------------------------------ live status
  local function live()
    local st = Core.status()
    st.slots = Core.slots()
    st.squad = Core.squad()
    st.grabs = Core.grabs()
    return st
  end
  U.every(function()
    if U.S.showcase then return end
    local ok, st = pcall(live)
    if ok then U.set("st", st) else L.fault("sdc.status", st) end
  end, { rate = 12 })

  -- ------------------------------------------------------------ showcase
  -- A 26-second loop of a real fight, made of the measured numbers: the Hunter
  -- kit, Flowing Water's 1.5 s hold, a 1021-stud drop paced at 756 studs/s,
  -- the ~0.59 s from send to hold, the respawn and its spawn protection.
  local KIT = { { "Flowing Water", 9, 1.5 }, { "Lethal Whirlwind Stream", 12, 0.46 }, { "Hunter's Grasp", 14, "hint" }, { "Prey's Peril", 16, nil } }
  local sim = { t = 0, left = { 0, 0, 0, 0 }, next = 1, fireAcc = 0, kills = 3, carried = 5, ult = 20, phase = "" }
  local function say(line) U.push("say", "“" .. line .. "”", true) end
  local function cmd(line) U.push("cmd", line, true) end
  local function simStatus()
    local s = sim
    local ownerName = LP.Name
    local st = {
      mode = "summoned", active = true, pose = "Idle", owner = ownerName, ownerName = ownerName, ownerId = LP.UserId,
      target = nil, waiting = nil, anchor = ownerName, kills = s.kills, carried = s.carried, barrage = false, dashSpam = true,
      rotation = s.next, sending = nil, squadSlot = 1, squadCount = 2, voidReady = true, supported = true, prefix = ".",
      angle = { preset = Core.S.approachPreset, angle = Core.S.approach.angle, radius = Core.S.approach.radius,
        height = Core.S.approach.height, facing = Core.S.facing },
      fan = Core.S.fanMode, squadOn = true, squadAuto = true, comboOn = true, comboTries = 3, attempts = s.attempts or 0,
      ultimate = s.ult, lastCommand = s.lastCommand or "none",
      squad = { { name = LP.Name, id = LP.UserId, mine = true }, { name = "Partner", id = 0, mine = false } },
      grabs = { { name = "Flowing Water", hold = 1.5 }, { name = "Lethal Whirlwind Stream", hold = 0.46 } },
    }
    st.slots = {}
    for i, k in ipairs(KIT) do
      st.slots[i] = { name = k[1], cooling = s.left[i] > 0, remaining = s.left[i] / k[2], grab = k[3] }
    end
    local t = s.t
    if t >= 3 and t < 24 then
      st.mode, st.target, st.pose, st.anchor = "attacking", "Rival", "Strike", "Rival"
    end
    if t >= 9.0 and t < 12.2 then
      local since = t - 9.0
      local carry = { kind = "void", target = "Rival", need = 1021, rate = 756, hold = 1.5, ownerY = 441, tries = 1, depth = 0 }
      if since < 0.59 then carry.state = "casting Flowing Water"
      elseif since < 0.59 + 1.5 then
        carry.state = "carrying them down"; carry.depth = math.min((since - 0.59) * 756, 2042)
        st.pose, st.anchor = "Void", ownerName
      else carry.state = "letting go"; carry.depth = 1.5 * 756; st.pose, st.anchor = "Void", ownerName end
      st.carry = carry
    end
    if t >= 12.2 and t < 18.5 then st.waiting = t < 17.2 and "waiting for respawn" or "spawn protection"; st.pose, st.anchor = "Hidden", ownerName end
    return st
  end
  local events = {
    { 0.2, function() cmd(".s"); say("At your service.") end },
    { 3.0, function() cmd(".a flip"); say("Target acquired.") end },
    { 9.0, function() U.push("carry", "carry begins on Rival (void)", true) end },
    { 9.59, function() U.push("carry", "hold with Flowing Water — riding down", true); say("Going down.") end },
    { 10.9, function() sim.kills += 1; U.push("kill", "Rival went down at y −546", true); say("Target down."); if U.onKill then U.onKill() end end },
    { 12.2, function() sim.carried += 1; U.push("carry", "carry ends: released · they died in the hold · hold not learned", true) end },
    { 17.2, function() U.push("sys", "Rival respawned · waiting out the ForceField", true) end },
    { 18.5, function() U.push("sys", "back on them, from behind", true) end },
    { 24.0, function() cmd(".stop"); say("Understood.") end },
  }
  U.every(function(dt)
    if not U.S.showcase then return end
    local before = sim.t
    sim.t = (sim.t + dt) % 26
    local wrapped = sim.t < before
    for _, e in ipairs(events) do
      if (not wrapped and before < e[1] and sim.t >= e[1]) or (wrapped and (before < e[1] or sim.t >= e[1])) then e[2]() end
    end
    for i = 1, 4 do sim.left[i] = math.max(0, sim.left[i] - dt) end
    sim.ult = (sim.ult + dt * 3.2) % 101
    local attacking = sim.t >= 3 and sim.t < 24 and not (sim.t >= 9 and sim.t < 18.5)
    sim.fireAcc += dt
    if attacking and sim.fireAcc > 1.3 then
      sim.fireAcc = 0
      local i = sim.next
      -- grabs are held back for the carry, like the real rotation
      if KIT[i][3] ~= nil and KIT[i][3] ~= "hint" then sim.next = i % 4 + 1
      elseif sim.left[i] == 0 then
        sim.left[i] = KIT[i][2]
        U.push("cmd", "skill " .. i .. " taken · " .. KIT[i][1], true)
        sim.next = i % 4 + 1
      else sim.next = i % 4 + 1 end
    end
    if sim.t >= 9.0 and before < 9.0 then sim.left[1] = KIT[1][2] end
    U.set("st", simStatus())
  end, { rate = 30 })

  function U.setShowcase(on, quiet)
    on = on == true
    U.set("showcase", on)
    U.setPref("showcase", on)
    if U.showChip then U.showChip.Visible = on end
    if not quiet then
      U.toast(on and "Showcase on" or "Showcase off",
        on and "Simulated fight data. Buttons act on the simulation only; nothing reaches your character or chat."
          or "Live data from the stand.", on and "warn" or "ok")
    end
  end

  -- ------------------------------------------------------------ actions
  -- Every button and command goes through here. In showcase mode it is only
  -- written to the feed.
  local DEMO_LINES = { summon = "At your service.", dismiss = "Understood.", attack = "Target acquired.", stop = "Understood." }
  function U.act(name, ...)
    if U.S.showcase then
      local args = table.concat((function(...) local t = {} for i, v in ipairs({ ... }) do t[i] = tostring(v) end return t end)(...), " ")
      U.push("cmd", name .. (args ~= "" and (" " .. args) or "") .. "  (showcase: simulated)", true)
      if DEMO_LINES[name] then say(DEMO_LINES[name]) end
      return true
    end
    local fn = Core[name]
    if type(fn) ~= "function" then return false, "unknown action " .. tostring(name) end
    local ok, result, why = pcall(fn, ...)
    if not ok then U.toast("That failed", tostring(result), "bad"); return false end
    if result == false and why then U.toast(U.clip(name, 20), tostring(why), "warn") end
    return result, why
  end

  -- Stand settings: written live, saved under the stand's own config key, and
  -- undoable with Ctrl+Z.
  function U.setting(key, value, configKey, label)
    local old = Core.get(key)
    if old == value then return end
    Core.set(key, value, configKey)
    U.remember(label or key, function() Core.set(key, old, configKey) end)
  end
end

-- 10 deck       the at-a-glance home, plus the title-bar pill and the mini HUD
--               that every surface shares.
do
  local mk, c = U.mk, U.c
  local Players = game:GetService("Players")

  -- What the stand is doing, as a colour, an icon and a sentence.
  function U.describe(st)
    if not st then return c.faint, "power", "OFF", "Resting", "" end
    local carry = st.carry
    if carry then
      local line = string.format("Carrying @%s down", tostring(carry.target))
      if carry.need then line ..= string.format("  ·  %d / %d studs", math.floor(carry.depth or 0), math.floor(carry.need)) end
      return c.gold, "arrow-down-to-line", "CARRYING", line, tostring(carry.state or "")
    end
    if st.mode == "attacking" then
      if st.waiting then return c.warn, "timer", "WAITING", "Waiting on @" .. tostring(st.target), st.waiting end
      local preset = st.angle and st.angle.preset or "Behind"
      return c.bad, "swords", "ATTACKING", "On @" .. tostring(st.target) .. ", " .. preset:lower(), ""
    end
    if st.mode == "summoned" then return c.ok, "user", "SUMMONED", "Beside @" .. tostring(st.owner or st.ownerName or "?"), "" end
    if st.mode == "hidden" then return c.aura, "ghost", "HIDDEN", "In the void under @" .. tostring(st.owner or "?"), "" end
    return c.faint, "power", "OFF", "Resting", st.owner and "The owner can call it from chat." or "Choose an owner to begin."
  end

  local function subline(st)
    if not st then return "" end
    if st.blocked then return "■  paused: " .. st.blocked end
    local parts = {}
    if st.anchor then parts[#parts + 1] = "latch → " .. st.anchor end
    if st.pose then parts[#parts + 1] = "pose " .. st.pose end
    if (st.squadCount or 1) > 1 then parts[#parts + 1] = string.format("slot %d of %d", st.squadSlot or 1, st.squadCount) end
    if st.gate then parts[#parts + 1] = "▲ holding: " .. st.gate end
    if #parts == 0 then return "●  free" end
    return table.concat(parts, "  ·  ")
  end
  U.subline = subline

  -- ------------------------------------------------------------ shared chrome
  U.watch("st", function(st)
    local col, _, word, line = U.describe(st)
    local pill = U.pill
    U.anim(pill.dot, "BackgroundColor3", col, "glide")
    U.anim(pill.halo, "BackgroundColor3", col, "glide")
    pill.text.Text = U.track(word)
    U.anim(pill.text, "TextColor3", col, "glide")
    local hud = U.hudParts
    U.anim(hud.dot, "BackgroundColor3", col, "glide")
    hud.text.Text = line
    local extra = {}
    if st and st.rotation and st.mode == "attacking" then extra[#extra + 1] = "next " .. st.rotation end
    if st and st.carry and st.carry.depth then extra[#extra + 1] = string.format("%d studs down", st.carry.depth) end
    if st and st.kills and st.kills > 0 then extra[#extra + 1] = st.kills .. " kills" end
    hud.extra.Text = table.concat(extra, "  ·  ")
  end)

  -- ------------------------------------------------------------ avatars
  local thumbs = {}
  function U.avatar(parent, size)
    local frame = mk("Frame", { BackgroundColor3 = c.panel2, Size = UDim2.fromOffset(size, size), Parent = parent })
    U.corner(frame, UDim.new(1, 0)); U.stroke(frame, c.gold, 1.5, 0.3)
    local initials = U.text(frame, "?", { FontFace = U.f.display, TextSize = size * 0.38, TextColor3 = c.mute, AnchorPoint = Vector2.new(0.5, 0.5),
      Position = UDim2.fromScale(0.5, 0.5) })
    local img = mk("ImageLabel", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Image = "", Parent = frame })
    U.corner(img, UDim.new(1, 0))
    local shown
    local api = { frame = frame }
    function api:set(name, id)
      initials.Text = name and name:sub(1, 1):upper() or "?"
      if id == shown then return end
      shown = id
      img.Image = ""
      if not id or id <= 0 then return end
      if thumbs[id] then img.Image = thumbs[id]; return end
      task.spawn(function()
        local ok, url = pcall(Players.GetUserThumbnailAsync, Players, id, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
        if ok and url then thumbs[id] = url; if shown == id then img.Image = url end end
      end)
    end
    return api
  end

  -- ------------------------------------------------------------ deck
  U.surface({ id = "deck", name = "Deck", icon = "layout-dashboard", build = function(page)
    -- hero
    local hero = mk("Frame", { BackgroundColor3 = c.panel, Size = UDim2.new(1, 0, 0, 132), ClipsDescendants = true, LayoutOrder = 1, Parent = page })
    U.corner(hero, 14); local heroStroke = U.stroke(hero, c.lineSoft, 1, 0)
    local heroTone = U.asset("tone.png")
    if heroTone then
      local t = mk("ImageLabel", { BackgroundTransparency = 1, Image = heroTone, ImageColor3 = c.aura, ImageTransparency = 0.9, ScaleType = Enum.ScaleType.Tile,
        TileSize = UDim2.fromOffset(8, 8), Size = UDim2.new(0.5, 0, 1, 0), Position = UDim2.fromScale(0.5, 0), Parent = hero })
      mk("UIGradient", { Transparency = NumberSequence.new(1, 0), Parent = t })
    end
    local ring = mk("Frame", { BackgroundColor3 = c.ink, Size = UDim2.fromOffset(92, 92), AnchorPoint = Vector2.new(1, 0.5),
      Position = UDim2.new(1, -24, 0.5, 0), Parent = hero })
    U.corner(ring, UDim.new(1, 0))
    local ringStroke = mk("UIStroke", { Thickness = 3, Color = c.white, Parent = ring })
    local ringGrad = mk("UIGradient", { Color = ColorSequence.new(c.aura, c.gold), Transparency = NumberSequence.new({
      NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.5, 0.35), NumberSequenceKeypoint.new(1, 1) }), Parent = ringStroke })
    local ringIcon = U.image(ring, "power", { Size = UDim2.fromOffset(34, 34), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), ImageColor3 = c.faint })
    local text = U.frame(hero, { Size = UDim2.new(1, -150, 0, 0), Position = UDim2.fromOffset(22, 20) })
    U.list(text, "y", 6)
    local word = U.text(text, U.track("off"), { FontFace = U.f.mono, TextSize = 12, TextColor3 = c.faint })
    local main = U.text(text, "Resting", { FontFace = U.f.display, TextSize = 27, TextTruncate = Enum.TextTruncate.AtEnd,
      AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0) })
    local sub = U.text(text, "", { FontFace = U.f.mono, TextSize = 12.5, TextColor3 = c.mute, TextTruncate = Enum.TextTruncate.AtEnd,
      AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0) })
    local note = U.text(text, "", { TextSize = 13, TextColor3 = c.faint, TextTruncate = Enum.TextTruncate.AtEnd,
      AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0) })
    local spin = 0
    U.every(function(dt) spin = (spin + dt * 70) % 360; ringGrad.Rotation = spin end, { visible = true })
    -- A kill: one gold slash across the hero. No confetti.
    local slashId = U.asset("slash.png")
    local function slash()
      if not hero.Parent or not slashId then return end
      local s = mk("ImageLabel", { BackgroundTransparency = 1, Image = slashId, ImageColor3 = c.gold, Size = UDim2.new(1.4, 0, 0, 22),
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(-0.7, 0.55), Rotation = -7, ZIndex = 20, Parent = hero })
      U.anim(s, "Position", UDim2.fromScale(0.5, 0.5), "flourish")
      task.delay(0.45, function() U.anim(s, "ImageTransparency", 1, "glide") end)
      task.delay(1, function() s:Destroy() end)
      U.snap(heroStroke, "Color", c.gold); U.anim(heroStroke, "Color", c.lineSoft, "menace")
      U.sound("kill", 0.4)
    end
    U.onKill = slash

    -- stats
    local stats = U.frame(page, { LayoutOrder = 2 })
    mk("UIGridLayout", { CellSize = UDim2.new(0.25, -9, 0, 70), CellPadding = UDim2.fromOffset(12, 12), SortOrder = Enum.SortOrder.LayoutOrder, Parent = stats })
    local function stat(label, icon, order)
      local f = mk("Frame", { BackgroundColor3 = c.panel, LayoutOrder = order, Parent = stats })
      U.corner(f, 12); U.stroke(f, c.lineSoft, 1, 0); U.pad(f, 12, 14, 12, 14)
      U.image(f, icon, { Size = UDim2.fromOffset(16, 16), ImageColor3 = c.faint })
      U.text(f, U.track(label), { FontFace = U.f.mono, TextSize = 10.5, TextColor3 = c.faint, Position = UDim2.fromOffset(24, 1) })
      local v = U.text(f, "0", { FontFace = U.f.mono, TextSize = 24, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1) })
      return v
    end
    local killsV = stat("kills", "skull", 1)
    local carriedV = stat("carried", "arrow-down-to-line", 2)
    local slotV = stat("squad slot", "users", 3)
    local voidV = stat("void gate", "shield", 4)
    local rollKills, rollCarried = U.roller(killsV), U.roller(carriedV)

    -- owner and actions, side by side
    local cols = U.frame(page, { LayoutOrder = 3 })
    U.list(cols, "x", 12)
    local ownerCard = U.card(cols, { Size = UDim2.new(0.42, -6, 0, 0) })
    U.section(ownerCard, "owner")
    local who = U.frame(ownerCard)
    U.list(who, "x", 12, { VerticalAlignment = Enum.VerticalAlignment.Center })
    local avatar = U.avatar(who, 54)
    local whoText = U.frame(who, { Size = UDim2.new(1, -66, 0, 0) })
    U.list(whoText, "y", 2)
    local ownerName = U.text(whoText, "No owner", { FontFace = U.f.bold, TextSize = 17 })
    local ownerHint = U.text(whoText, "", { TextSize = 12.5, TextColor3 = c.faint, TextWrapped = true, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0) })
    local picker = U.dropdown(ownerCard, { placeholder = "Choose the owner", items = function()
      local out = { { label = "None", value = "None" } }
      for _, p in ipairs(Core.players()) do out[#out + 1] = { label = p.name .. (p.display ~= p.name and ("  (" .. p.display .. ")") or ""), value = p.name } end
      return out
    end, onChange = function(v) U.act("setOwner", v) end })
    U.text(ownerCard, "Only the owner's chat is read. Backspace frees the stand at any time.", { TextSize = 12.5, TextColor3 = c.faint,
      TextWrapped = true, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0) })

    local act = U.card(cols, { Size = UDim2.new(0.58, -6, 0, 0) })
    U.section(act, "command")
    local row1 = U.hstack(act, 8)
    U.button(row1, { text = "Summon", icon = "sparkles", style = "primary", onClick = function() U.act("summon") end, tip = ".s" })
    U.button(row1, { text = "Dismiss", icon = "ghost", onClick = function() U.act("dismiss") end, tip = ".d  ·  hide in the void" })
    U.button(row1, { text = "Stop", icon = "square", onClick = function() U.act("stop") end, tip = ".stop" })
    U.holdButton(row1, { text = "Free", icon = "power", onConfirm = function() U.act("free", "freed from the console") end,
      tip = "Hold to release the stand completely" })
    local target = U.input(act, { placeholder = "player name (blank = nearest)", icon = "crosshair", size = UDim2.new(1, 0, 0, 32) })
    local row2 = U.hstack(act, 8)
    U.button(row2, { text = "Attack", icon = "swords", style = "danger", onClick = function() U.act("attack", target:get()) end, tip = ".a name" })
    U.button(row2, { text = "Bring", icon = "hand", onClick = function() U.act("bring", target:get()) end, tip = ".b name  ·  a grab, delivered to the owner" })
    U.button(row2, { text = "Void", icon = "arrow-down", onClick = function() U.act("voidDrop", target:get()) end, tip = ".v name  ·  a grab, carried past the kill plane" })
    local row3 = U.hstack(act, 8)
    for i = 1, 4 do U.button(row3, { text = tostring(i), size = UDim2.fromOffset(40, 32), onClick = function() U.act("skill", i) end, tip = "." .. i }) end
    U.button(row3, { text = "Barrage", icon = "zap", onClick = function() U.act("toggleBarrage") end, tip = ".m1" })
    U.button(row3, { text = "Awaken", icon = "flame", style = "aura", onClick = function() U.act("ult") end, tip = ".ult" })

    -- the last few things that happened
    local recent = U.card(page, { LayoutOrder = 4 })
    U.section(recent, "just now")
    local lines = {}
    for i = 1, 4 do
      lines[i] = U.text(recent, "", { FontFace = U.f.mono, TextSize = 12.5, TextColor3 = c.mute, TextTruncate = Enum.TextTruncate.AtEnd,
        AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0), LayoutOrder = i + 1 })
    end
    U.watch("feedN", function()
      -- newest last, filled from the top so a short history leaves no gap
      local start = math.max(1, #U.feed - 3)
      for i = 1, 4 do
        local e = U.feed[start + i - 1]
        lines[i].Text = e and string.format("%6.1f  %s", e.t, e.text) or ""
        lines[i].TextColor3 = e and (U.kindColor and U.kindColor(e.kind) or c.mute) or c.mute
      end
    end, recent)

    local lastIcon
    U.watch("st", function(st)
      local col, icon, w, line, extra = U.describe(st)
      word.Text = U.track(w)
      U.anim(word, "TextColor3", col, "glide")
      main.Text = line
      sub.Text = subline(st)
      note.Text = extra or ""
      U.anim(ringGrad, "Offset", Vector2.new(0, 0), "glide")
      ringGrad.Color = ColorSequence.new(col, c.gold)
      if icon ~= lastIcon then
        lastIcon = icon
        ringIcon.Image = U.icon(icon) or ""
        U.snap(ringIcon, "Size", UDim2.fromOffset(20, 20)); U.anim(ringIcon, "Size", UDim2.fromOffset(34, 34), "menace")
      end
      U.anim(ringIcon, "ImageColor3", col, "glide")
      rollKills(st.kills or 0); rollCarried(st.carried or 0)
      slotV.Text = string.format("%d / %d", st.squadSlot or 1, st.squadCount or 1)
      voidV.Text = st.voidReady and "armed" or "open"
      voidV.TextColor3 = st.voidReady and c.ok or c.mute
      ownerName.Text = st.owner and ("@" .. st.owner) or (st.ownerName and st.ownerName ~= "" and (st.ownerName .. " (away)") or "No owner")
      ownerHint.Text = st.owner and string.format("Commands from chat, prefix “%s”", tostring(st.prefix or ".")) or "Pick who the stand obeys."
      avatar:set(st.owner or st.ownerName, st.ownerId)
      if picker:get() ~= st.owner and not U.S.showcase then picker:set(st.owner or "None", true) end
    end, hero)
  end })
end

-- 11 radar      top-down around the anchor, drawn from Core.layout -- the same
--               formation maths the latch uses, so the marks are where the
--               stands really stand. Drag to aim, wheel for distance.
do
  local mk, c = U.mk, U.c

  -- A body seen from above: a rounded block with a nose on its facing side.
  local function body(parent, color, label, z)
    local f = mk("Frame", { BackgroundColor3 = color, Size = UDim2.fromOffset(26, 16), AnchorPoint = Vector2.new(0.5, 0.5), ZIndex = z or 5, Parent = parent })
    U.corner(f, 5)
    local s = U.stroke(f, c.white, 1, 0.75)
    mk("Frame", { BackgroundColor3 = color, Size = UDim2.fromOffset(4, 12), AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 0, 2),
      BorderSizePixel = 0, ZIndex = z or 5, Parent = f })
    local tag = U.text(parent, label, { FontFace = U.f.mono, TextSize = 11, TextColor3 = c.mute, AnchorPoint = Vector2.new(0.5, 0), ZIndex = (z or 5) + 1 })
    return { frame = f, tag = tag, stroke = s }
  end
  local function line(parent, color, thickness, z)
    local f = mk("Frame", { BackgroundColor3 = color, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(0, thickness or 2),
      ZIndex = z or 3, Parent = parent })
    return f
  end
  -- place a line from a to b (pixels, radar-local)
  local function span(f, a, b)
    local d = b - a
    f.Position = UDim2.fromOffset((a.X + b.X) / 2, (a.Y + b.Y) / 2)
    f.Size = UDim2.fromOffset(d.Magnitude, f.Size.Y.Offset)
    f.Rotation = math.deg(math.atan2(d.Y, d.X))
  end
  local function circle(parent, r, color, transparency, thickness, z)
    local f = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(r * 2, r * 2), AnchorPoint = Vector2.new(0.5, 0.5),
      Position = UDim2.fromScale(0.5, 0.5), ZIndex = z or 2, Parent = parent })
    U.corner(f, UDim.new(1, 0))
    local s = U.stroke(f, color, thickness or 1, transparency or 0)
    return f, s
  end

  -- The radar itself, reusable: the Squad surface draws a small one too.
  function U.radar(parent, o)
    o = o or {}
    local SIZE = o.size or 400
    local R = SIZE * 0.44
    local box = mk("Frame", { BackgroundColor3 = c.ink, Size = UDim2.fromOffset(SIZE, SIZE), ClipsDescendants = true, LayoutOrder = o.order or 0, Parent = parent })
    U.corner(box, 14); U.stroke(box, c.lineSoft, 1, 0)
    mk("UIGradient", { Color = ColorSequence.new(c.panel, c.ink), Rotation = 90, Parent = box })
    local tone = U.asset("tone.png")
    if tone then
      mk("ImageLabel", { BackgroundTransparency = 1, Image = tone, ImageColor3 = c.aura, ImageTransparency = 0.93, ScaleType = Enum.ScaleType.Tile,
        TileSize = UDim2.fromOffset(8, 8), Size = UDim2.fromScale(1, 1), Parent = box })
    end
    for i = 1, 4 do circle(box, R * i / 4, c.line, 0.2) end
    local cx = line(box, c.line, 1, 1); span(cx, Vector2.new(10, SIZE / 2), Vector2.new(SIZE - 10, SIZE / 2)); cx.BackgroundTransparency = 0.5
    local cy = line(box, c.line, 1, 1); span(cy, Vector2.new(SIZE / 2, 10), Vector2.new(SIZE / 2, SIZE - 10)); cy.BackgroundTransparency = 0.5
    local north = U.text(box, U.track("their facing"), { FontFace = U.f.mono, TextSize = 10, TextColor3 = c.faint, AnchorPoint = Vector2.new(0.5, 0),
      Position = UDim2.new(0.5, 0, 0, 10) })
    -- the sweep: a beam with a fading trail, turning once every 5.7 s
    local trail = {}
    for i = 1, 9 do
      local l = line(box, c.aura, i == 1 and 2 or 3, 2)
      l.BackgroundTransparency = 0.55 + i * 0.05
      trail[i] = l
    end
    local ringFrame, ringStroke = circle(box, 30, c.gold, 0.35, 1.5, 3)
    local aim = line(box, c.gold, 1.5, 4)
    local center = body(box, c.bad, "TARGET", 6)
    local slots = {}
    local api = { box = box, view = o.view or "Strike" }
    local sweepAngle, last = 0, {}
    local mid = Vector2.new(SIZE / 2, SIZE / 2)
    local function toPx(x, z, span_) return mid + Vector2.new(x, z) * (R / span_) end

    function api:update(dt, st)
      if not box.Parent then return end
      sweepAngle = (sweepAngle + (dt or 0) * 63) % 360
      if not U.reduced then
        for i, l in ipairs(trail) do
          local a = math.rad(sweepAngle - (i - 1) * 3.2)
          span(l, mid, mid + Vector2.new(math.cos(a), math.sin(a)) * R)
        end
      end
      local view = api.view
      local count = math.max((st and st.squadCount) or 1, 1)
      local ok, layout = pcall(Core.layout, view, count)
      if not ok then layout = {} end
      local a = Core.S.approach
      local spanStuds = view == "Strike" and math.max(a.radius * 2.6, 7) or 13
      north.Text = U.track(view == "Strike" and "their facing" or "owner facing")
      center.frame.BackgroundColor3 = view == "Strike" and c.bad or c.ok
      center.tag.Text = view == "Strike" and (st and st.target and ("@" .. st.target) or "TARGET") or "OWNER"
      center.frame.Position = UDim2.fromOffset(mid.X, mid.Y)
      center.tag.Position = UDim2.fromOffset(mid.X, mid.Y + 19)
      ringFrame.Visible = view == "Strike"
      local ringR = a.radius * R / spanStuds
      if last.ring ~= ringR then last.ring = ringR; U.anim(ringFrame, "Size", UDim2.fromOffset(ringR * 2, ringR * 2), "flourish") end
      for slot = 1, 4 do
        local l = layout[slot]
        local s = slots[slot]
        if l and not s then
          s = body(box, slot == 1 and c.aura or c.panel2, "", 7)
          s.frame.Position = UDim2.fromOffset(mid.X, mid.Y)
          slots[slot] = s
        end
        if s then
          s.frame.Visible = l ~= nil
          s.tag.Visible = l ~= nil
          if l then
            local p = toPx(l.x, l.z, spanStuds)
            local key = string.format("%.1f,%.1f,%.0f", p.X, p.Y, l.yaw)
            if last[slot] ~= key then
              last[slot] = key
              U.anim(s.frame, "Position", UDim2.fromOffset(p.X, p.Y), "flourish")
              U.anim(s.tag, "Position", UDim2.fromOffset(p.X, p.Y + 13), "flourish")
              -- screen rotation: nose up at 0, clockwise; yaw is the look direction
              local look = Vector2.new(-math.sin(math.rad(l.yaw)), -math.cos(math.rad(l.yaw)))
              U.anim(s.frame, "Rotation", math.deg(math.atan2(look.X, -look.Y)), "flourish")
            end
            s.frame.BackgroundColor3 = l.mine and c.aura or c.panel2
            s.stroke.Transparency = l.mine and 0.3 or 0.6
            s.tag.Text = l.mine and "YOU" or ("S" .. slot)
            s.tag.TextColor3 = l.mine and c.paper or c.faint
            if l.mine then
              aim.Visible = view == "Strike"
              span(aim, mid, Vector2.new(s.frame.Position.X.Offset, s.frame.Position.Y.Offset))
            end
          end
        end
      end
    end

    -- drag to aim; the wheel changes the distance
    if o.interactive then
      local undoFrom
      U.drag(box, function(p)
        undoFrom = { angle = Core.S.approach.angle, radius = Core.S.approach.radius }
        api.view = "Strike"
        if api.onView then api.onView("Strike") end
        local rel = p - box.AbsolutePosition - box.AbsoluteSize / 2
        Core.setApproach({ angle = math.deg(math.atan2(rel.X, rel.Y)) })
      end, function(p)
        local rel = p - box.AbsolutePosition - box.AbsoluteSize / 2
        Core.setApproach({ angle = math.deg(math.atan2(rel.X, rel.Y)) })
      end, function()
        local from = undoFrom
        if from then U.remember("attack angle", function() Core.setApproach({ angle = from.angle, radius = from.radius }) end) end
        if api.onChange then api.onChange() end
      end)
      box.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseWheel then
          Core.setApproach({ radius = Core.S.approach.radius + (input.Position.Z > 0 and 0.25 or -0.25) })
          if api.onChange then api.onChange() end
        end
      end)
      U.tip(box, "Drag to set the attack angle  ·  wheel to change the distance")
    end
    return api
  end

  U.surface({ id = "radar", name = "Radar", icon = "radar", build = function(page)
    local cols = U.frame(page, { LayoutOrder = 1 })
    U.list(cols, "x", 16)
    local radar = U.radar(cols, { size = 410, interactive = true })
    local side = U.frame(cols, { Size = UDim2.new(1, -426, 0, 0) })
    U.list(side, "y", 12)

    U.section(side, "view", 1)
    local view = U.segmented(side, { items = { "Strike", "Idle", "Front" }, value = "Strike", size = UDim2.new(1, 0, 0, 32), order = 2,
      onChange = function(v) radar.view = v end })
    radar.onView = function(v) view:set(v, true) end

    U.section(side, "ready angles", 3)
    local names = { "Behind", "Behind left", "Behind right", "Left flank", "Right flank", "In front", "Above", "Below", "Point blank" }
    local chips = U.chips(side, { items = names, value = Core.S.approachPreset, order = 4, onChange = function(v)
      local before = { angle = Core.S.approach.angle, radius = Core.S.approach.radius, height = Core.S.approach.height }
      Core.angle(v)
      U.remember("angle preset", function() Core.setApproach(before) end)
    end })

    U.section(side, "fine tune", 5)
    local function tuneRow(label, key, min, max, step, order, unit)
      local row = U.frame(side, { LayoutOrder = order })
      U.list(row, "y", 4)
      U.text(row, label, { TextSize = 13, TextColor3 = c.mute })
      return U.slider(row, { min = min, max = max, step = step, value = Core.S.approach[key], default = key == "radius" and (Core.defaults.HUNT_DISTANCE or 6.1) or 0,
        format = function(v) return U.fmt(v, step < 1 and 1 or 0) .. unit end,
        onChange = function(v)
          -- the distance is the one hunt-distance knob (.dist, the loader, here)
          if key == "radius" then
            local old = Core.S.huntDistance
            Core.setHuntDistance(v)
            U.remember(label, function() Core.setHuntDistance(old) end)
            return
          end
          local old = Core.S.approach[key]; Core.setApproach({ [key] = v }); U.remember(label, function() Core.setApproach({ [key] = old }) end)
        end })
    end
    local angle = tuneRow("Angle around them", "angle", 0, 359, 1, 6, "°")
    local radius = tuneRow("Distance", "radius", 0.5, 30, 0.1, 7, "")
    local height = tuneRow("Height", "height", -20, 20, 0.1, 8, "")
    local facing = U.segmented(side, { items = { "Face them", "Face away" }, value = Core.S.facing, size = UDim2.new(1, 0, 0, 30), order = 9,
      onChange = function(v) Core.setFacing(v) end })
    local readout = U.text(side, "", { FontFace = U.f.mono, TextSize = 12, TextColor3 = c.faint, LayoutOrder = 10, TextWrapped = true,
      AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0) })

    local card = U.card(page, { LayoutOrder = 2 })
    U.section(card, "squad fan")
    local fanRow, fanRight = U.row(card, "Fan", "Ring spreads round the target: two stands take behind and in front. Arc keeps everyone near your angle.", 2)
    U.segmented(fanRight, { items = { "Ring", "Arc" }, value = Core.S.fanMode, size = UDim2.fromOffset(160, 30), onChange = function(v) Core.setFan(v) end })
    local _, prevRight = U.row(card, "Live angle preview in the world", "Draws every slot on the target's real body while you tune: yours solid, the rest as ghosts.", 3)
    U.toggle(prevRight, { value = Core.S.previewAngles, onChange = function(v) U.setting("previewAngles", v, "previewAngles", "angle preview") end })

    local function sync()
      local a = Core.S.approach
      angle:set(a.angle, true); radius:set(a.radius, true); height:set(a.height, true)
      chips:set(Core.S.approachPreset)
      facing:set(Core.S.facing, true)
      readout.Text = string.format("%s · %.0f° · %.1f studs · %+.1f up · %s", Core.S.approachPreset, a.angle, a.radius, a.height, Core.S.facing)
    end
    radar.onChange = sync
    local acc = 0
    U.every(function(dt)
      radar:update(dt, U.S.st)
      acc += dt
      if acc > 0.25 then acc = 0; sync() end
    end, { visible = true })
    sync()
  end })
end

-- 12 arsenal    the hotbar, mirrored: the real Cooldown frame as a falling
--               curtain, the rotation's next move, grabs held for the carry,
--               and what each grab has been watched to hold.
do
  local mk, c = U.mk, U.c

  U.surface({ id = "arsenal", name = "Arsenal", icon = "swords", build = function(page)
    local empty = U.card(page, { LayoutOrder = 0, Visible = false })
    U.text(empty, "The hotbar mirror reads The Strongest Battlegrounds' own hotbar.", { FontFace = U.f.bold, TextSize = 15 })
    U.text(empty, "Outside TSB there is nothing to mirror. Turn on Showcase to see it working with a simulated Hunter kit.",
      { TextSize = 13, TextColor3 = c.mute, TextWrapped = true, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0) })
    U.button(empty, { text = "Turn on Showcase", icon = "play", style = "primary", onClick = function() U.setShowcase(true) end })

    local grid = U.frame(page, { LayoutOrder = 1 })
    mk("UIGridLayout", { CellSize = UDim2.new(0.25, -9, 0, 156), CellPadding = UDim2.fromOffset(12, 12), SortOrder = Enum.SortOrder.LayoutOrder, Parent = grid })
    local tiles = {}
    for i = 1, 4 do
      local t = mk("TextButton", { AutoButtonColor = false, Text = "", BackgroundColor3 = c.panel, ClipsDescendants = true, LayoutOrder = i, Parent = grid })
      U.corner(t, 14)
      local stroke = U.stroke(t, c.lineSoft, 1.5, 0)
      local scale = mk("UIScale", { Parent = t })
      local curtain = mk("Frame", { BackgroundColor3 = c.black, BackgroundTransparency = 0.45, BorderSizePixel = 0, Size = UDim2.fromScale(1, 0), ZIndex = 4, Parent = t })
      local inner = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 5, Parent = t })
      U.pad(inner, 12, 14, 12, 14)
      local key = U.text(inner, tostring(i), { FontFace = U.f.display, TextSize = 36, TextColor3 = c.faint, ZIndex = 5 })
      local nextTag = mk("Frame", { BackgroundColor3 = c.aura, Size = UDim2.fromOffset(0, 20), AutomaticSize = Enum.AutomaticSize.X,
        AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Visible = false, ZIndex = 6, Parent = inner })
      U.corner(nextTag, UDim.new(1, 0)); U.pad(nextTag, 0, 8, 0, 8)
      U.text(nextTag, U.track("next"), { FontFace = U.f.mono, TextSize = 10, TextColor3 = c.ink, Size = UDim2.fromScale(0, 1), ZIndex = 7 })
      local lock = U.image(inner, "lock", { Size = UDim2.fromOffset(16, 16), AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 26),
        ImageColor3 = c.gold, Visible = false, ZIndex = 6 })
      local name = U.text(inner, "—", { FontFace = U.f.bold, TextSize = 15, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
        AutomaticSize = Enum.AutomaticSize.None, Size = UDim2.new(1, 0, 0, 38), Position = UDim2.fromOffset(0, 46), ZIndex = 5 })
      local status = U.text(inner, "", { FontFace = U.f.mono, TextSize = 11.5, TextColor3 = c.mute, AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.new(0, 0, 1, -22), ZIndex = 5 })
      local badge = U.text(inner, "", { FontFace = U.f.mono, TextSize = 11, TextColor3 = c.gold, AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.fromScale(0, 1), ZIndex = 5 })
      t.MouseEnter:Connect(function() U.anim(t, "BackgroundColor3", c.panel2, "tap") end)
      t.MouseLeave:Connect(function() U.anim(t, "BackgroundColor3", c.panel, "tap"); U.anim(scale, "Scale", 1, "tap") end)
      t.MouseButton1Down:Connect(function() U.anim(scale, "Scale", 0.96, "tap") end)
      t.MouseButton1Up:Connect(function() U.anim(scale, "Scale", 1, "tap") end)
      t.MouseButton1Click:Connect(function() U.sound("click", 0.3); U.act("skill", i) end)
      U.tip(t, "Fire it now, the way the owner would with ." .. i)
      tiles[i] = { t = t, stroke = stroke, curtain = curtain, key = key, nextTag = nextTag, lock = lock, name = name, status = status, badge = badge,
        scale = scale, wasCooling = false }
    end

    -- ultimate and the rotation
    local ultCard = U.card(page, { LayoutOrder = 2 })
    local ultHead = U.frame(ultCard)
    U.text(ultHead, U.track("awakening"), { FontFace = U.f.mono, TextSize = 11, TextColor3 = c.faint })
    local ultV = U.text(ultHead, "—", { FontFace = U.f.mono, TextSize = 12, TextColor3 = c.mute, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0) })
    local ultTrack = mk("Frame", { BackgroundColor3 = c.panel2, Size = UDim2.new(1, 0, 0, 10), Parent = ultCard })
    U.corner(ultTrack, UDim.new(1, 0))
    local ultFill = mk("Frame", { BackgroundColor3 = c.gold, Size = UDim2.fromScale(0, 1), Parent = ultTrack })
    U.corner(ultFill, UDim.new(1, 0))
    local ultGrad = mk("UIGradient", { Color = ColorSequence.new(c.aura, c.gold), Parent = ultFill })
    local rot = U.text(ultCard, "", { FontFace = U.f.mono, TextSize = 12.5, TextColor3 = c.mute })

    -- combat settings
    local set = U.card(page, { LayoutOrder = 3 })
    U.section(set, "combat")
    local S = Core.S
    local function flag(label, note, key, cfg)
      local _, r = U.row(set, label, note)
      U.toggle(r, { value = S[key], onChange = function(v) U.setting(key, v, cfg, label) end })
    end
    flag("Rotate skills", "1 → 2 → 3 → 4, each re-fired the moment its cooldown ends. Grabs are held back while a carry could open.", "useSkills", "useSkills")
    flag("M1 between skills", "At the game's own pace: measured ~4 per 3 s; faster sends are dropped by the server.", "useM1", "useM1")
    flag("Dash spam", "Forward only, straight at their back.", "dashSpam", "dashSpam")
    do
      local _, r = U.row(set, "Seconds between dashes", "About one dash a second is accepted.")
      U.slider(r, { min = 0.2, max = 3, step = 0.05, value = S.dashGap, default = 0.35, size = UDim2.fromOffset(250, 28),
        onChange = function(v) U.setting("dashGap", v, "dashGap", "dash gap") end })
    end
    flag("Awaken automatically", "Fires the awakening when the bar is full during an attack.", "autoUlt", "autoUlt")

    U.watch("st", function(st)
      local slots = st and st.slots
      empty.Visible = slots == nil
      grid.Visible = slots ~= nil
      ultCard.Visible = slots ~= nil
      if not slots then return end
      local attacking = st.mode == "attacking"
      for i, tile in ipairs(tiles) do
        local s = slots[i] or {}
        tile.name.Text = s.name or "empty"
        local rem = s.cooling and math.clamp(s.remaining or 0, 0, 1) or 0
        U.anim(tile.curtain, "Size", UDim2.fromScale(1, rem), "glide")
        local isNext = attacking and st.rotation == i and not s.cooling
        tile.nextTag.Visible = isNext
        local reserved = attacking and st.comboOn and st.voidReady and type(s.grab) == "number" and not s.cooling
        tile.lock.Visible = reserved
        local strokeColor = st.sending == i and c.gold or isNext and c.aura or (s.cooling and rem < 0.08 and rem > 0) and c.gold or c.lineSoft
        U.anim(tile.stroke, "Color", strokeColor, "glide")
        U.anim(tile.key, "TextColor3", s.cooling and c.faint or isNext and c.aura or c.paper, "glide")
        tile.status.Text = st.sending == i and "sending…" or s.cooling and string.format("cooling  %d%%", math.floor(rem * 100 + 0.5))
          or reserved and "held for the carry" or isNext and "up next" or "ready"
        tile.badge.Text = type(s.grab) == "number" and string.format("GRAB · %.2f s hold", s.grab) or s.grab == "hint" and "GRAB? · not yet seen"
          or s.grab == false and "watched · no hold" or ""
        -- the frame it comes off cooldown: a small pop
        if tile.wasCooling and not s.cooling then U.snap(tile.scale, "Scale", 1.04); U.anim(tile.scale, "Scale", 1, "flourish") end
        tile.wasCooling = s.cooling
      end
      local ult = st.ultimate
      ultV.Text = ult and (ult >= 100 and "READY" or string.format("%d%%", math.floor(ult))) or "—"
      ultV.TextColor3 = ult and ult >= 100 and c.gold or c.mute
      U.anim(ultFill, "Size", UDim2.fromScale(math.clamp((ult or 0) / 100, 0, 1), 1), "glide")
      local parts = {}
      for i = 1, 4 do parts[i] = (st.rotation == i and attacking) and ("[" .. i .. "]") or tostring(i) end
      rot.Text = "rotation  " .. table.concat(parts, " → ") .. (st.sending and ("   ·   sending " .. st.sending) or "")
    end, grid)
  end })
end

-- 13 carry lab  the void combo made visible. The gauge only draws what the
--               stand really knows: its own composed depth and the plan. The
--               victim is never drawn from our own client's read of them --
--               that read lies during a hold (measured: y≈0 while they were at 441).
do
  local mk, c = U.mk, U.c
  local TOP, BOTTOM, PLANE, CAP = 600, -1100, -500, 900

  U.surface({ id = "carry", name = "Carry lab", icon = "arrow-down-to-line", build = function(page)
    local S = Core.S
    local cols = U.frame(page, { LayoutOrder = 1 })
    U.list(cols, "x", 16)
    local H = 400
    -- White under the gradient: a UIGradient multiplies the background colour.
    local gauge = mk("Frame", { BackgroundColor3 = c.white, Size = UDim2.fromOffset(150, H), ClipsDescendants = true, Parent = cols })
    U.corner(gauge, 14); U.stroke(gauge, c.lineSoft, 1, 0)
    mk("UIGradient", { Rotation = 90, Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.fromRGB(26, 44, 46)),
      ColorSequenceKeypoint.new(0.55, c.panel), ColorSequenceKeypoint.new(0.7, Color3.fromRGB(58, 18, 34)), ColorSequenceKeypoint.new(1, Color3.fromRGB(34, 10, 20)) }), Parent = gauge })
    local function yPx(y) return (TOP - y) / (TOP - BOTTOM) * H end
    local function mark(y, color, label, dashed)
      local f = mk("Frame", { BackgroundColor3 = color, BackgroundTransparency = dashed and 0.35 or 0, BorderSizePixel = 0,
        Size = UDim2.new(1, -16, 0, dashed and 1 or 2), Position = UDim2.fromOffset(8, yPx(y)), Parent = gauge })
      local t = U.text(gauge, label, { FontFace = U.f.mono, TextSize = 10, TextColor3 = color, AnchorPoint = Vector2.new(1, 1),
        Position = UDim2.new(1, -10, 0, yPx(y) - 2) })
      return f, t
    end
    for y = 400, -1000, -200 do
      U.text(gauge, tostring(y), { FontFace = U.f.mono, TextSize = 9.5, TextColor3 = c.faint, Position = UDim2.fromOffset(8, yPx(y) - 6), TextTransparency = 0.3 })
    end
    local plane, planeLabel = mark(PLANE, c.bad, "KILL PLANE −500")
    local ownerLine, ownerLabel = mark(441, c.ok, "OWNER")
    local aimLine, aimLabel = mark(-580, c.gold, "AIM", true)
    local me = mk("Frame", { BackgroundColor3 = c.aura, Size = UDim2.fromOffset(16, 16), AnchorPoint = Vector2.new(0.5, 0.5),
      Position = UDim2.new(0.5, 0, 0, yPx(441)), ZIndex = 5, Parent = gauge })
    U.corner(me, UDim.new(1, 0)); U.stroke(me, c.white, 1.5, 0.3)
    local glowId = U.asset("glow.png")
    if glowId then
      mk("ImageLabel", { BackgroundTransparency = 1, Image = glowId, ImageColor3 = c.aura, ImageTransparency = 0.4, Size = UDim2.fromOffset(44, 44),
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), ZIndex = 4, Parent = me })
    end
    local meTag = U.text(gauge, "STAND", { FontFace = U.f.mono, TextSize = 10, TextColor3 = c.aura, AnchorPoint = Vector2.new(1, 0.5),
      Position = UDim2.new(0.5, -14, 0, yPx(441)), ZIndex = 5 })

    local side = U.frame(cols, { Size = UDim2.new(1, -166, 0, 0) })
    U.list(side, "y", 12)
    local now = U.card(side, { LayoutOrder = 1 })
    U.section(now, "now")
    local state = U.text(now, "idle", { FontFace = U.f.display, TextSize = 22 })
    local depthT = U.text(now, "", { FontFace = U.f.mono, TextSize = 12.5, TextColor3 = c.mute })
    -- pace against what the carry can track
    local paceRow = U.frame(now)
    U.list(paceRow, "y", 5)
    local paceT = U.text(paceRow, "pace", { FontFace = U.f.mono, TextSize = 11.5, TextColor3 = c.faint })
    local paceTrack = mk("Frame", { BackgroundColor3 = c.panel2, Size = UDim2.new(1, 0, 0, 8), Parent = paceRow })
    U.corner(paceTrack, UDim.new(1, 0))
    local paceFill = mk("Frame", { BackgroundColor3 = c.aura, Size = UDim2.fromScale(0, 1), Parent = paceTrack })
    U.corner(paceFill, UDim.new(1, 0))
    mk("Frame", { BackgroundColor3 = c.gold, BorderSizePixel = 0, Size = UDim2.new(0, 2, 1, 8), Position = UDim2.new(CAP / 1200, 0, 0, -4), Parent = paceTrack })
    U.tip(paceTrack, "The gold tick is 900 studs/s: the most the carry was watched to track. Faster and the victim is left behind.")
    local pipsRow = U.frame(now)
    U.list(pipsRow, "x", 6, { VerticalAlignment = Enum.VerticalAlignment.Center })
    U.text(pipsRow, "attempts", { FontFace = U.f.mono, TextSize = 11.5, TextColor3 = c.faint })
    local pips = {}
    for i = 1, 8 do
      local p = mk("Frame", { BackgroundColor3 = c.panel2, Size = UDim2.fromOffset(12, 12), Visible = false, LayoutOrder = i, Parent = pipsRow })
      U.corner(p, UDim.new(1, 0)); U.stroke(p, c.line, 1, 0)
      pips[i] = p
    end
    local gateT = U.text(now, "", { FontFace = U.f.mono, TextSize = 12, TextColor3 = c.mute })

    local learned = U.card(side, { LayoutOrder = 2 })
    local head = U.frame(learned)
    U.text(head, U.track("learned grabs"), { FontFace = U.f.mono, TextSize = 11, TextColor3 = c.faint })
    local list = U.frame(learned)
    U.list(list, "y", 4)
    local forgetAll = U.holdButton(learned, { text = "Forget all", icon = "trash-2", onConfirm = function()
      if U.S.showcase then U.toast("Showcase", "Nothing forgotten: this is simulated data.", "warn"); return end
      Core.forgetGrab(nil); U.toast("Grabs forgotten", "It will learn them again by watching.", "ok")
    end })
    local shownGrabs = ""

    -- settings
    local set = U.card(page, { LayoutOrder = 2 })
    U.section(set, "the carry")
    local function flag(label, note, key, cfg)
      local _, r = U.row(set, label, note)
      U.toggle(r, { value = S[key], onChange = function(v) U.setting(key, v, cfg, label) end })
    end
    local function num(label, note, key, cfg, min, max, step, default)
      local _, r = U.row(set, label, note)
      U.slider(r, { min = min, max = max, step = step, value = S[key], default = default, size = UDim2.fromOffset(250, 28),
        onChange = function(v) U.setting(key, v, cfg, label) end })
    end
    flag("Carry to the void while attacking", "Opens with a grab when one is ready, rides them under −500, takes them again if they live.", "comboOn", "combo")
    num("Attempts per target", "Per life of the target. Spent attempts now really count (they used to reset).", "comboTries", "comboTries", 1, 8, 1, 3)
    num("Seconds between carries", "Wait after one carry ends before the next may open.", "comboEvery", "comboEvery", 0, 60, 0.5, 4)
    num("Studs past the kill plane", "How far below −500 to aim. The rig killed at −546.", "voidMargin", "voidMargin", 20, 400, 5, 80)
    flag("Pace the drop to the move", "Spreads the descent across the hold this move was watched to have, capped at 900 studs/s.", "carryAdapt", "carryAdapt")
    num("Fixed descent rate", "Used when pacing is off. 700 worked on the rig; the lag was ~190 studs at 776.", "carryRate", "carryRate", 150, 2500, 10, 700)
    num("Seconds held down there", "After the grab lets go, so the release lands where the stand is.", "voidLinger", "voidLinger", 0, 3, 0.05, 0.35)
    do
      local _, r = U.row(set, "Delivery distance", "Studs in front of the owner a brought player is dropped. At 4 the owner was knocked down by their own delivery; 14 was clear.")
      U.slider(r, { min = 4, max = 40, step = 0.5, value = -S.poses.Bring.z, default = 14, size = UDim2.fromOffset(250, 28), onChange = function(v)
        local old = S.poses.Bring.z
        S.poses.Bring.z = -v
        U.I.Cfg.setFeat("stand.pose.Bring.z", -v)
        U.remember("delivery distance", function() S.poses.Bring.z = old; U.I.Cfg.setFeat("stand.pose.Bring.z", old) end)
      end })
    end
    U.section(set, "the deep hide")
    flag("Hide deep", "Dismissed or waiting out a respawn, it goes far under and away. Needs the void gate; without it, it stays above −450.", "hideDeep", "hideDeep")
    num("Depth below the owner", "Studs. Capped at 1500: a stand hidden at 4040 was measured to die there.", "hideDepth", "hideDepth", 60, 1500, 20, 900)
    num("Distance behind the owner", "Studs.", "hideAway", "hideAway", 0, 2000, 10, 250)

    local crossed = false
    U.watch("st", function(st)
      local carry = st and st.carry
      local ownerY = carry and carry.ownerY or 441
      U.anim(ownerLine, "Position", UDim2.fromOffset(8, yPx(ownerY)), "glide")
      ownerLabel.Position = UDim2.new(1, -10, 0, yPx(ownerY) - 2)
      local depth = carry and carry.depth or 0
      local y = ownerY - depth
      if st and st.pose == "Hidden" and not carry then y = ownerY - (S.hideDeep and S.hideDepth or 300) end
      y = math.max(y, BOTTOM + 20)
      U.anim(me, "Position", UDim2.new(0.5, 0, 0, yPx(y)), carry and "tap" or "flourish")
      U.anim(meTag, "Position", UDim2.new(0.5, -14, 0, yPx(y)), carry and "tap" or "flourish")
      local need = carry and carry.need
      aimLine.Visible, aimLabel.Visible = need ~= nil, need ~= nil
      if need then
        local aimY = ownerY - need
        aimLine.Position = UDim2.fromOffset(8, yPx(aimY)); aimLabel.Position = UDim2.new(1, -10, 0, yPx(aimY) - 2)
      end
      -- the plane pulses once when the stand goes through it
      if y < PLANE and not crossed then
        crossed = true
        U.snap(plane, "Size", UDim2.new(1, -16, 0, 6)); U.anim(plane, "Size", UDim2.new(1, -16, 0, 2), "menace")
        U.snap(planeLabel, "TextSize", 13); U.anim(planeLabel, "TextSize", 10, "menace")
      elseif y >= PLANE then crossed = false end
      state.Text = carry and tostring(carry.state or "carrying") or (st and st.pose == "Hidden" and "hidden in the void" or "idle")
      state.TextColor3 = carry and c.gold or c.paper
      depthT.Text = carry and need and string.format("%d / %d studs down  ·  hold %.2f s", math.floor(depth), math.floor(need), carry.hold or 0)
        or string.format("stand at y %d", math.floor(y))
      local rate = carry and carry.rate or (S.carryAdapt and 0 or S.carryRate)
      paceT.Text = rate > 0 and string.format("pace  %d studs/s  (cap %d)", math.floor(rate), CAP) or "pace  set by the move when a grab lands"
      U.anim(paceFill, "Size", UDim2.fromScale(math.clamp(rate / 1200, 0, 1), 1), "glide")
      paceFill.BackgroundColor3 = rate > CAP and c.bad or c.aura
      local tries = (st and st.comboTries) or S.comboTries
      local used = carry and carry.tries or (st and st.attempts) or 0
      for i, p in ipairs(pips) do
        p.Visible = i <= tries
        U.anim(p, "BackgroundColor3", i <= used and c.gold or c.panel2, "glide")
      end
      gateT.Text = (st and st.voidReady) and "● void gate armed: the stand may go below −500" or "▲ void gate open: the stand stays above −450"
      gateT.TextColor3 = (st and st.voidReady) and c.ok or c.warn
      -- learned grabs, rebuilt only when they change
      local grabs = st and st.grabs or {}
      local sig = {}
      for _, g in ipairs(grabs) do sig[#sig + 1] = g.name .. "=" .. tostring(g.hold) end
      local key = table.concat(sig, ";")
      if key ~= shownGrabs then
        shownGrabs = key
        list:ClearAllChildren()
        U.list(list, "y", 4)
        if #grabs == 0 then U.text(list, "None yet. It learns a move by watching it take hold.", { TextSize = 13, TextColor3 = c.faint }) end
        for i, g in ipairs(grabs) do
          local row = mk("Frame", { BackgroundColor3 = c.panel2, Size = UDim2.new(1, 0, 0, 34), LayoutOrder = i, Parent = list })
          U.corner(row, 8)
          U.text(row, g.name, { FontFace = U.f.bold, TextSize = 13.5, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(0, 0, 1, 0) })
          U.text(row, type(g.hold) == "number" and string.format("%.2f s hold", g.hold) or "no hold", { FontFace = U.f.mono, TextSize = 12,
            TextColor3 = type(g.hold) == "number" and c.gold or c.faint, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -44, 0, 0), Size = UDim2.new(0, 0, 1, 0) })
          local x = U.iconButton(row, "x", { size = 26, iconSize = 14, tip = "Forget this one", onClick = function()
            if U.S.showcase then U.toast("Showcase", "Nothing forgotten: this is simulated data.", "warn"); return end
            Core.forgetGrab(g.name)
          end })
          x.inst.AnchorPoint = Vector2.new(1, 0.5); x.inst.Position = UDim2.new(1, -6, 0.5, 0)
        end
      end
    end, gauge)
  end })
end

-- 14 squad      every stand on the owner, found by its PhysicsRepRootPart
--               latch (measured to replicate), and the formation they share.
do
  local mk, c = U.mk, U.c

  U.surface({ id = "squad", name = "Squad", icon = "users", build = function(page)
    local S = Core.S
    local cols = U.frame(page, { LayoutOrder = 1 })
    U.list(cols, "x", 16)
    local mini = U.radar(cols, { size = 300, view = "Idle" })
    local right = U.frame(cols, { Size = UDim2.new(1, -316, 0, 0) })
    U.list(right, "y", 12)
    U.section(right, "formation view", 1)
    U.segmented(right, { items = { "Idle", "Front", "Strike" }, value = "Idle", size = UDim2.new(1, 0, 0, 30), order = 2,
      onChange = function(v) mini.view = v end })
    U.text(right, "Idle is a wing: the shoulders first, then a row further back for each further pair. Front is a line abreast facing forward. Strike is the fan round the target.",
      { TextSize = 13, TextColor3 = c.faint, TextWrapped = true, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0), LayoutOrder = 3 })
    U.section(right, "roster", 4)
    local roster = U.frame(right, { LayoutOrder = 5 })
    U.list(roster, "y", 6)
    local shown = ""

    local set = U.card(page, { LayoutOrder = 2 })
    U.section(set, "fan out")
    local function flag(label, note, key, cfg)
      local _, r = U.row(set, label, note)
      U.toggle(r, { value = S[key], onChange = function(v) U.setting(key, v, cfg, label) end })
    end
    flag("Fan out", "Each stand takes its own slot so no two share a swing.", "squadOn", "squad.on")
    flag("Find the other stands", "Anyone latched to our owner or our target is a squadmate. Nothing is typed, nothing is sent between clients.", "squadAuto", "squad.auto")
    do
      local _, r = U.row(set, "Fan width", "Degrees the Arc spreads across, centred on your angle.")
      U.slider(r, { min = 20, max = 340, step = 5, value = S.squadArc, default = 140, size = UDim2.fromOffset(250, 28), format = function(v) return U.fmt(v) .. "°" end,
        onChange = function(v) U.setting("squadArc", v, "squad.arc", "fan width") end })
    end
    do
      local _, r = U.row(set, "Smallest gap", "The fan widens rather than let two stands share a swing.")
      U.slider(r, { min = 10, max = 180, step = 5, value = S.squadGap, default = 45, size = UDim2.fromOffset(250, 28), format = function(v) return U.fmt(v) .. "°" end,
        onChange = function(v) U.setting("squadGap", v, "squad.gap", "smallest gap") end })
    end
    do
      local _, r = U.row(set, "Other stands by name", "Only needed when finding is off, or for a stand it cannot see. Comma separated.")
      U.input(r, { value = S.squadNames, placeholder = "found automatically", size = UDim2.fromOffset(250, 32), onCommit = function(v) Core.setSquad(v) end })
    end

    U.every(function(dt) mini:update(dt, U.S.st) end, { visible = true })
    U.watch("st", function(st)
      local list = st and st.squad or {}
      local sig = {}
      for _, p in ipairs(list) do sig[#sig + 1] = p.name end
      local key = table.concat(sig, ",")
      if key == shown then return end
      shown = key
      roster:ClearAllChildren()
      U.list(roster, "y", 6)
      if #list <= 1 then
        U.text(roster, "Just this stand. Others appear here the moment they latch to the same owner.", { TextSize = 13, TextColor3 = c.faint,
          TextWrapped = true, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0) })
      end
      for i, p in ipairs(list) do
        local row = mk("Frame", { BackgroundColor3 = p.mine and c.panel2 or c.panel, Size = UDim2.new(1, 0, 0, 44), LayoutOrder = i, Parent = roster })
        U.corner(row, 10); U.stroke(row, p.mine and c.aura or c.lineSoft, 1, p.mine and 0.3 or 0)
        local av = U.avatar(row, 30)
        av:set(p.name, p.id)
        av.frame.Position = UDim2.fromOffset(8, 7)
        U.text(row, p.name, { FontFace = U.f.bold, TextSize = 14, Position = UDim2.fromOffset(48, 0), Size = UDim2.new(0, 0, 1, 0) })
        U.text(row, (p.mine and "YOU · " or "") .. "slot " .. i, { FontFace = U.f.mono, TextSize = 11.5, TextColor3 = p.mine and c.aura or c.faint,
          AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 0), Size = UDim2.new(0, 0, 1, 0) })
      end
    end, roster)
  end })
end

-- 15 feed       what happened, in order: voice lines, commands, kills, carries,
--               faults. Filters, copy for a bug report, clear.
do
  local mk, c = U.mk, U.c
  local COLORS = { say = c.paper, cmd = c.aura, kill = c.gold, carry = c.ok, sys = c.mute, fault = c.bad }
  local TAGS = { say = "SAY ", cmd = "CMD ", kill = "KILL", carry = "CARY", sys = "SYS ", fault = "ERR " }
  function U.kindColor(kind) return COLORS[kind] or c.mute end

  U.surface({ id = "feed", name = "Feed", icon = "scroll-text", build = function(page)
    local filter = "all"
    local top = U.frame(page, { LayoutOrder = 1 })
    U.list(top, "x", 10, { VerticalAlignment = Enum.VerticalAlignment.Center })
    local chips
    local box = mk("ScrollingFrame", { BackgroundColor3 = c.panel, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 470), CanvasSize = UDim2.new(),
      AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 4, ScrollBarImageColor3 = c.line, LayoutOrder = 2, Parent = page })
    U.corner(box, 12); U.stroke(box, c.lineSoft, 1, 0); U.pad(box, 10, 14, 10, 14)
    U.list(box, "y", 2)
    local rows, shownN = {}, 0
    local function line(e)
      local row = U.text(box, "", { FontFace = U.f.mono, TextSize = 12.5, RichText = true, TextColor3 = COLORS[e.kind] or c.mute,
        AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0), TextWrapped = true, LayoutOrder = e.n })
      local t = string.format('<font color="#7e7192">%7.1f</font>  <font color="#%s">%s</font>  %s', e.t,
        (COLORS[e.kind] or c.mute):ToHex(), TAGS[e.kind] or "    ",
        (e.text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")))
      if e.demo then t ..= '  <font color="#7e7192">· showcase</font>' end
      row.Text = t
      rows[#rows + 1] = row
      while #rows > 200 do table.remove(rows, 1):Destroy() end
    end
    local function atBottom()
      return box.CanvasPosition.Y >= box.AbsoluteCanvasSize.Y - box.AbsoluteSize.Y - 40
    end
    local function rebuild()
      for _, r in ipairs(rows) do r:Destroy() end
      table.clear(rows)
      shownN = 0
      for _, e in ipairs(U.feed) do
        if filter == "all" or e.kind == filter then line(e) end
        shownN = e.n
      end
      task.defer(function() box.CanvasPosition = Vector2.new(0, 1e6) end)
    end
    chips = U.chips(top, { items = { "all", "say", "cmd", "kill", "carry", "sys", "fault" }, value = "all", onChange = function(v) filter = v; rebuild() end })
    U.button(top, { text = "Copy", icon = "copy", tip = "Copy the last 50 lines as plain text", onClick = function()
      local out = {}
      for i = math.max(1, #U.feed - 49), #U.feed do
        local e = U.feed[i]
        out[#out + 1] = string.format("%7.1f %s %s", e.t, TAGS[e.kind] or "", e.text)
      end
      local ok = pcall(setclipboard, table.concat(out, "\n"))
      U.toast(ok and "Copied" or "No clipboard here", ok and (#out .. " lines") or nil, ok and "ok" or "warn")
    end })
    U.button(top, { text = "Clear", icon = "trash-2", onClick = function() table.clear(U.feed); rebuild() end })
    U.watch("feedN", function()
      local follow = atBottom()
      for _, e in ipairs(U.feed) do
        if e.n > shownN then
          if filter == "all" or e.kind == filter then line(e) end
          shownN = e.n
        end
      end
      if follow then task.defer(function() box.CanvasPosition = Vector2.new(0, 1e6) end) end
    end, box)
  end })
end

-- 16 settings   searchable; every row says why its default is what it is.
--               Profiles export to the clipboard and import from a paste.
do
  local mk, c = U.mk, U.c
  local UIS = U.UIS
  local STANCES = { "Perfect Concentration", "The Shadow", "Chosen", "Arms crossed", "Honored", "First Rule", "Behold", "Hunter pose",
    "Ready to strike", "Found you", "By my sword", "Shadow", "Into the void", "Fighting stance", "Calm float", "Off", "Custom" }

  U.surface({ id = "settings", name = "Settings", icon = "settings", build = function(page)
    local S = Core.S
    local index = {}
    local search = U.input(page, { placeholder = "Search settings", icon = "search", size = UDim2.new(1, 0, 0, 36), order = 0 })
    U.searchBox = search
    local order = 0
    local currentCard
    local function card(title)
      order += 1
      currentCard = U.card(page, { LayoutOrder = order })
      U.section(currentCard, title)
      index[#index + 1] = { card = currentCard, rows = {} }
      return currentCard
    end
    local function row(label, note)
      local r, right = U.row(currentCard, label, note)
      local entry = index[#index]
      entry.rows[#entry.rows + 1] = { frame = r, text = (label .. " " .. (note or "")):lower() }
      return right
    end
    local function flag(label, note, key, cfg)
      U.toggle(row(label, note), { value = S[key], onChange = function(v) U.setting(key, v, cfg, label) end })
    end
    local function num(label, note, key, cfg, min, max, step, default, fmt)
      U.slider(row(label, note), { min = min, max = max, step = step, value = S[key], default = default, size = UDim2.fromOffset(250, 28), format = fmt,
        onChange = function(v) U.setting(key, v, cfg, label) end })
    end

    card("the stand")
    U.input(row("Command prefix", "Typed before every command. Blank means bare words."), { value = S.prefix, mono = true, size = UDim2.fromOffset(120, 32),
      onCommit = function(v) local old = S.prefix; Core.setPrefix(v); U.remember("prefix", function() Core.setPrefix(old) end) end })
    flag("Take orders from the owner", "Only the owner's chat is ever read.", "listen", "listen")
    flag("Stand speaks", "Short replies in chat. One line a second at most; a newer line replaces a queued one.", "speak", "speak")

    card("pose and look")
    U.dropdown(row("Idle stance", "TSB's own emote idles, each load-tested. Aka Stance, Those Who Know, Take Me On and Superhero load with length 0 and are left out."),
      { items = STANCES, value = S.stance, size = UDim2.fromOffset(250, 32), onChange = function(v) U.setting("stance", v, "stance", "idle stance") end })
    U.input(row("Custom animation id", "Used when the stance is Custom."), { value = S.stanceCustom, mono = true, size = UDim2.fromOffset(180, 32),
      onCommit = function(v) U.setting("stanceCustom", tostring(v or ""), "stanceCustom", "custom animation") end })
    U.chips(row("Waiting side", "Where it waits beside the owner."), { items = { "right", "left", "behind", "above" }, onChange = function(v) Core.side(v) end })
    num("Float motion", "Studs of gentle bob; 0 holds still. The console's mode pill breathes at the same 2.2 rad/s.", "float", "float", 0, 2, 0.05, 0.35)
    flag("Keep upright", "Ignores the anchor's tilt and ragdolls, keeps its heading.", "upright", "upright")
    flag("PlatformStand", "Stiff hover. Off keeps the stance playing; on stops every animation.", "hover", "platformStand")
    flag("Camera on the owner", "Your own body sits far from the stand; this keeps the view on the owner.", "camera", "camera")
    flag("Show where others see it", "A local marker at the stand's real position.", "preview", "preview")

    card("safety")
    num("Hide below health", "The stand dismisses itself here and refuses to fight until healed. 0 turns it off.", "lowHP", "lowHP", 0, 90, 1, 25,
      function(v) return U.fmt(v) .. "%" end)
    flag("Wait out spawn protection", "After a respawn it stays in the void until the ForceField drops (a grab's own ForceField is ignored).", "waitShield", "waitShield")

    card("voice")
    for _, e in ipairs({ { "summon", "Summon line" }, { "dismiss", "Dismiss line" }, { "attack", "Attack line" }, { "done", "Kill line" },
      { "carry", "Carry line" }, { "bring", "Delivery line" } }) do
      U.input(row(e[2], nil), { value = S.lines[e[1]], size = UDim2.fromOffset(250, 32), onCommit = function(v)
        local old = S.lines[e[1]]
        S.lines[e[1]] = tostring(v or "")
        U.I.Cfg.setFeat("stand.line." .. e[1], S.lines[e[1]])
        U.remember(e[2], function() S.lines[e[1]] = old; U.I.Cfg.setFeat("stand.line." .. e[1], old) end)
      end })
    end

    card("interface")
    U.slider(row("Interface scale", "On top of the automatic scale from your screen height."), { min = 0.6, max = 1.6, step = 0.05, value = U.pref("uiScale", 1),
      default = 1, size = UDim2.fromOffset(250, 28), format = function(v) return U.fmt(v * 100) .. "%" end,
      onChange = function(v) U.setPref("uiScale", v); U.rescale() end })
    U.toggle(row("Reduced motion", "Every spring critically damped and quicker; decorative loops stop."), { value = U.reduced, onChange = function(v)
      U.reduced = v; U.setPref("reducedMotion", v) end })
    U.toggle(row("Interface sound", "Off by default. Five sounds, each a little different in pitch every time."), { value = U.pref("sound", false),
      onChange = function(v) U.setPref("sound", v); if v then U.sound("click", 0.4) end end })
    U.slider(row("Sound volume", nil), { min = 0, max = 1, step = 0.05, value = U.pref("volume", 0.6), default = 0.6, size = UDim2.fromOffset(250, 28),
      format = function(v) return U.fmt(v * 100) .. "%" end, onChange = function(v) U.setPref("volume", v) end })
    U.toggle(row("Intro on load", "The ゴゴゴ title card. Click it to skip."), { value = U.pref("intro", true), onChange = function(v) U.setPref("intro", v) end })
    U.toggle(row("Showcase", "Simulated fight data for looking at the console. Nothing reaches your character or chat."), { value = U.S.showcase == true,
      onChange = function(v) U.setShowcase(v) end })

    card("keys")
    local function keyRow(label, note, prefName, default)
      local b
      b = U.button(row(label, note), { text = tostring(U.pref(prefName, default)), icon = "keyboard", onClick = function()
        b:setText("press a key…")
        U.capturing = true
        local conn
        conn = UIS.InputBegan:Connect(function(input)
          if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
          conn:Disconnect()
          task.defer(function() U.capturing = false end)
          if input.KeyCode == Enum.KeyCode.Escape then b:setText(tostring(U.pref(prefName, default))); return end
          U.setPref(prefName, input.KeyCode.Name)
          b:setText(input.KeyCode.Name)
          U.toast("Key set", label .. ": " .. input.KeyCode.Name, "ok")
        end)
      end })
    end
    keyRow("Show or hide the console", "TSB already uses 1-4, Q, G and F, and Roblox gives Shift to shift-lock.", "keyToggle", "RightControl")
    keyRow("Command palette", "Search every command, surface and setting.", "keyPalette", "F2")
    keyRow("Command wheel (hold)", "Hold, flick toward a command, release. Release in the middle to cancel.", "keyWheel", "LeftAlt")
    do
      local r = row("Undo", "Ctrl+Z undoes the last setting change, 20 deep.")
      U.button(r, { text = "Undo last", icon = "undo-2", onClick = function() U.undo() end })
    end

    card("profiles")
    local function snapshot()
      local out = {}
      for k, v in pairs(U.I.Cfg.data) do
        if (k:sub(1, 6) == "stand." or k:sub(1, 4) == "sdc.") and not k:find("geom%.") then out[k] = v end
      end
      return out
    end
    U.button(row("Export", "Copies every stand and console setting as one line of text."), { text = "Copy profile", icon = "copy", onClick = function()
      local ok = pcall(setclipboard, "SDC1:" .. U.HttpService:JSONEncode(snapshot()))
      U.toast(ok and "Profile copied" or "No clipboard here", nil, ok and "ok" or "warn")
    end })
    local paste = U.input(row("Import", "Paste a profile, then Apply. The console reloads to take it."), { placeholder = "SDC1:{…}", mono = true, size = UDim2.fromOffset(250, 32) })
    U.button(row("", nil), { text = "Apply profile", icon = "clipboard-paste", style = "primary", onClick = function()
      local text = paste:get():gsub("^%s+", "")
      local ok, data = pcall(function() return U.HttpService:JSONDecode((text:gsub("^SDC1:", ""))) end)
      if not ok or type(data) ~= "table" then U.toast("That is not a profile", "It should start with SDC1:", "bad"); return end
      for k, v in pairs(data) do if type(k) == "string" and (k:sub(1, 6) == "stand." or k:sub(1, 4) == "sdc.") then U.I.Cfg.data[k] = v end end
      U.I.Cfg.save()
      U.toast("Profile applied", "Reloading…", "ok")
      task.delay(0.6, function()
        local okLoad, err = pcall(function() loadstring(readfile("Stand-dos-Cintoes.lua"))() end)
        if not okLoad then U.toast("Reload it yourself", tostring(err), "warn") end
      end)
    end })

    card("about")
    U.text(currentCard, U.NAME .. "  ·  " .. U.KANA .. "  ·  v" .. U.version, { FontFace = U.f.bold, TextSize = 14 })
    U.text(currentCard, "Every latch is a PhysicsRepRootPart binding; the others see the stand at anchor × local pose. Every default here was measured on the two-client rig; the footnotes say where.",
      { TextSize = 13, TextColor3 = c.faint, TextWrapped = true, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0) })
    local r = U.hstack(currentCard, 8)
    U.holdButton(r, { text = "Unload everything", icon = "power", tip = "Hold: frees the stand, hands the kill plane back, removes the console",
      onConfirm = function() task.defer(Core.unload) end })

    search.box:GetPropertyChangedSignal("Text"):Connect(function()
      local q = search.box.Text:lower()
      for _, entry in ipairs(index) do
        local any = false
        for _, rw in ipairs(entry.rows) do
          local hit = q == "" or rw.text:find(q, 1, true) ~= nil
          rw.frame.Visible = hit
          any = any or hit
        end
        entry.card.Visible = any or q == ""
      end
    end)
  end })
end

-- 20 overlays   the command palette (fuzzy search over every surface, action,
--               chat command and setting) and the hold-to-flick command wheel.
do
  local mk, c = U.mk, U.c
  local UIS = U.UIS

  -- Subsequence match: every query letter in order. Word starts and runs of
  -- adjacent letters score higher, so "vd" finds "Void drop" before "Dividend".
  local function fuzzy(query, text)
    if query == "" then return 1 end
    local q, t = query:lower(), text:lower()
    local score, ti, run, prev = 0, 1, 0, 0
    for qi = 1, #q do
      local ch = q:sub(qi, qi)
      local found = t:find(ch, ti, true)
      if not found then return nil end
      local start = found == 1 or t:sub(found - 1, found - 1):match("[%s%._%-]") ~= nil
      run = (found == prev + 1) and run + 1 or 0
      score += 1 + (start and 3 or 0) + run * 2
      prev, ti = found, found + 1
    end
    return score - #t * 0.01
  end
  U.fuzzy = fuzzy

  local function items()
    local list = {}
    local function add(label, hint, icon, run, keep) list[#list + 1] = { label = label, hint = hint, icon = icon, run = run, keep = keep } end
    for _, def in ipairs(U.surfaceList) do add("Go to " .. def.name, "surface", def.icon, function() U.show(); U.go(def.id) end) end
    add("Summon", ".s", "sparkles", function() U.act("summon") end)
    add("Dismiss to the void", ".d", "ghost", function() U.act("dismiss") end)
    add("Stop", ".stop", "square", function() U.act("stop") end)
    add("Attack the nearest", ".a", "swords", function() U.act("attack", "") end)
    add("Barrage in front", ".m1", "zap", function() U.act("toggleBarrage") end)
    add("Awaken", ".ult", "flame", function() U.act("ult") end)
    add("Dash spam on / off", ".dash", "wind", function() U.act("toggleDash") end)
    for i = 1, 4 do add("Skill " .. i, "." .. i, "sword", function() U.act("skill", i) end) end
    add(U.S.showcase and "Showcase off" or "Showcase on", "simulated data", "play", function() U.setShowcase(not U.S.showcase) end)
    add("Undo last change", "Ctrl+Z", "undo-2", function() U.undo() end)
    add("Hide the console", U.pref("keyToggle", "RightControl"), "x", function() U.hide() end)
    add("Mini HUD", "shrink", "minus", function() U.minimise() end)
    for _, cmd in ipairs(Core.commands()) do
      if cmd.args ~= "" then
        add("." .. cmd.names[1] .. " " .. cmd.args, cmd.desc, "command", nil, "." .. cmd.names[1] .. " ")
      end
    end
    -- settings: jump to the Settings surface with the search filled in
    for _, word in ipairs({ "prefix", "stance", "float", "camera", "health", "spawn protection", "voice", "scale", "motion", "sound", "keys", "profile" }) do
      add("Setting: " .. word, "settings", "settings", function()
        U.show(); U.go("settings")
        task.defer(function() if U.searchBox then U.searchBox:set(word) end end)
      end)
    end
    return list
  end

  local open
  function U.palette()
    if open then open.close(); return end
    U.show()
    local top = U.layers.top
    local dim = mk("TextButton", { AutoButtonColor = false, Text = "", BackgroundColor3 = c.black, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 170, Parent = top })
    U.anim(dim, "BackgroundTransparency", 0.45, "glide")
    local box = mk("Frame", { BackgroundColor3 = c.panel, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0.18, 0),
      Size = UDim2.fromOffset(580, 0), AutomaticSize = Enum.AutomaticSize.Y, ZIndex = 171, Parent = top })
    local sc = U.scaledFrame(box)
    sc.Scale = U.scale * 0.95
    U.anim(sc, "Scale", U.scale, "flourish")
    U.corner(box, 14); U.stroke(box, c.line, 1, 0); U.shadow(box, 24, 0.3); U.pad(box, 10)
    U.list(box, "y", 8)
    local input = U.input(box, { placeholder = "Type a command, a surface or a setting…", icon = "search", size = UDim2.new(1, 0, 0, 40) })
    input.box.TextSize = 16
    local results = U.frame(box)
    U.list(results, "y", 3)
    U.text(box, "↑ ↓ choose  ·  Enter run  ·  Esc close", { FontFace = U.f.mono, TextSize = 11, TextColor3 = c.faint, LayoutOrder = 9 })
    local all = items()
    local shown, sel = {}, 1
    local rows = {}
    local function paint()
      for i, r in ipairs(rows) do
        local on = i == sel
        U.anim(r.frame, "BackgroundColor3", on and c.hover or c.panel, "tap")
        r.bar.Visible = on
      end
    end
    local function render()
      for _, r in ipairs(rows) do r.frame:Destroy() end
      table.clear(rows)
      local q = input.box.Text
      local scored = {}
      for _, it in ipairs(all) do
        local s = fuzzy(q, it.label .. " " .. (it.hint or ""))
        if s then scored[#scored + 1] = { it = it, s = s } end
      end
      table.sort(scored, function(a, b) return a.s > b.s end)
      shown = {}
      for i = 1, math.min(#scored, 9) do
        local it = scored[i].it
        shown[i] = it
        local f = mk("TextButton", { AutoButtonColor = false, Text = "", BackgroundColor3 = c.panel, Size = UDim2.new(1, 0, 0, 38), LayoutOrder = i, ZIndex = 172, Parent = results })
        U.corner(f, 8)
        local bar = mk("Frame", { BackgroundColor3 = c.gold, Size = UDim2.new(0, 3, 0.6, 0), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5),
          Visible = false, ZIndex = 173, Parent = f })
        U.corner(bar, 2)
        U.image(f, it.icon or "command", { Size = UDim2.fromOffset(17, 17), Position = UDim2.new(0, 14, 0.5, -8), ImageColor3 = c.mute, ZIndex = 173 })
        U.text(f, it.label, { FontFace = U.f.bold, TextSize = 14, Position = UDim2.fromOffset(42, 0), Size = UDim2.new(0, 0, 1, 0), ZIndex = 173 })
        U.text(f, U.clip(it.hint or "", 46), { FontFace = U.f.mono, TextSize = 11.5, TextColor3 = c.faint, AnchorPoint = Vector2.new(1, 0),
          Position = UDim2.new(1, -12, 0, 0), Size = UDim2.new(0, 0, 1, 0), ZIndex = 173 })
        f.MouseEnter:Connect(function() sel = i; paint() end)
        f.MouseButton1Click:Connect(function() sel = i; open.run() end)
        rows[i] = { frame = f, bar = bar }
      end
      if #rows == 0 then
        local f = U.text(results, q:sub(1, 1) == "." and "Enter sends it as the owner's command." or "Nothing matches.", { TextSize = 13, TextColor3 = c.faint, ZIndex = 172 })
        rows[1] = { frame = f, bar = f }
      end
      sel = 1
      paint()
    end
    local conns = {}
    open = {}
    function open.close()
      for _, cn in ipairs(conns) do cn:Disconnect() end
      local b, d = box, dim
      open = nil
      U.anim(sc, "Scale", U.scale * 0.95, "tap")
      U.anim(d, "BackgroundTransparency", 1, "tap")
      task.delay(0.15, function() b:Destroy(); d:Destroy() end)
    end
    function open.run()
      local it = shown[sel]
      local q = input.box.Text
      if it and it.keep then
        input.box.Text = it.keep
        input.box:CaptureFocus()
        input.box.CursorPosition = #it.keep + 1
        return
      end
      open.close()
      if it and it.run then it.run()
      elseif q:sub(1, 1) == "." then U.act("command", q:sub(2)) end
    end
    conns[1] = input.box:GetPropertyChangedSignal("Text"):Connect(render)
    conns[2] = input.box.FocusLost:Connect(function(enter) if enter and open then open.run() end end)
    conns[3] = UIS.InputBegan:Connect(function(k)
      if not open then return end
      if k.KeyCode == Enum.KeyCode.Down then sel = math.min(sel + 1, #shown); paint()
      elseif k.KeyCode == Enum.KeyCode.Up then sel = math.max(sel - 1, 1); paint()
      elseif k.KeyCode == Enum.KeyCode.Escape then open.close() end
    end)
    dim.MouseButton1Click:Connect(function() if open then open.close() end end)
    render()
    task.defer(function() input.box:CaptureFocus() end)
  end

  -- ------------------------------------------------------------ the wheel
  -- Hold the key: eight commands spring out around the cursor. Flick toward
  -- one, release to send it. Releasing in the middle cancels.
  local WHEEL = {
    { ".s", "Summon", "sparkles", function() U.act("summon") end },
    { ".a", "Attack nearest", "swords", function() U.act("attack", "") end },
    { ".m1", "Barrage", "zap", function() U.act("toggleBarrage") end },
    { ".ult", "Awaken", "flame", function() U.act("ult") end },
    { ".stop", "Stop", "square", function() U.act("stop") end },
    { ".dash", "Dash spam", "wind", function() U.act("toggleDash") end },
    { ".d", "Dismiss", "ghost", function() U.act("dismiss") end },
    { "⌘", "Palette", "command", function() U.palette() end },
  }
  local wheel
  function U.wheelOpen()
    if wheel then return end
    local m = U.mouse()
    local root = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0), Position = UDim2.fromOffset(m.X, m.Y), ZIndex = 180, Parent = U.layers.top })
    local sc = U.scaledFrame(root)
    local hub = mk("Frame", { BackgroundColor3 = c.ink, Size = UDim2.fromOffset(92, 92), AnchorPoint = Vector2.new(0.5, 0.5), ZIndex = 181, Parent = root })
    U.corner(hub, UDim.new(1, 0)); U.stroke(hub, c.line, 1.5, 0)
    local hubText = U.text(hub, "cancel", { FontFace = U.f.bold, TextSize = 13, TextColor3 = c.faint, AnchorPoint = Vector2.new(0.5, 0.5),
      Position = UDim2.fromScale(0.5, 0.5), ZIndex = 182 })
    U.snap(hub, "Size", UDim2.fromOffset(40, 40)); U.anim(hub, "Size", UDim2.fromOffset(92, 92), "flourish")
    local pointer = mk("Frame", { BackgroundColor3 = c.gold, Size = UDim2.fromOffset(0, 2), AnchorPoint = Vector2.new(0.5, 0.5), ZIndex = 181, Parent = root })
    local nodes = {}
    for i, w in ipairs(WHEEL) do
      local a = math.rad((i - 1) * 45 - 90)
      local node = mk("Frame", { BackgroundColor3 = c.panel, Size = UDim2.fromOffset(60, 60), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(0, 0),
        ZIndex = 183, Parent = root })
      U.corner(node, UDim.new(1, 0)); local st = U.stroke(node, c.line, 1.5, 0)
      local nsc = mk("UIScale", { Scale = 0.6, Parent = node })
      U.image(node, w[3], { Size = UDim2.fromOffset(22, 22), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, -5), ZIndex = 184 })
      U.text(node, w[1], { FontFace = U.f.mono, TextSize = 10.5, TextColor3 = c.faint, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, 15), ZIndex = 184 })
      -- staggered 18 ms apart as they spring out
      task.delay((i - 1) * 0.018, function()
        U.anim(node, "Position", UDim2.fromOffset(math.cos(a) * 124, math.sin(a) * 124), "flourish")
        U.anim(nsc, "Scale", 1, "flourish")
      end)
      nodes[i] = { node = node, stroke = st, scale = nsc, a = a }
    end
    local chosen
    local job = U.every(function()
      local p = U.mouse()
      local d = (p - Vector2.new(m.X, m.Y)) / U.scale
      local pick
      if d.Magnitude > 30 then
        local ang = math.deg(math.atan2(d.Y, d.X)) + 90
        pick = math.floor(((ang + 22.5) % 360) / 45) + 1
        pointer.Visible = true
        pointer.Size = UDim2.fromOffset(math.min(d.Magnitude, 90), 2)
        pointer.Position = UDim2.fromOffset(d.Unit.X * math.min(d.Magnitude, 90) / 2, d.Unit.Y * math.min(d.Magnitude, 90) / 2)
        pointer.Rotation = math.deg(math.atan2(d.Y, d.X))
      else
        pointer.Visible = false
      end
      if pick ~= chosen then
        chosen = pick
        for i, n in ipairs(nodes) do
          local on = i == pick
          U.anim(n.scale, "Scale", on and 1.18 or 1, "tap")
          U.anim(n.node, "BackgroundColor3", on and c.auraDeep or c.panel, "tap")
          U.anim(n.stroke, "Color", on and c.aura or c.line, "tap")
        end
        hubText.Text = pick and WHEEL[pick][2] or "cancel"
        hubText.TextColor3 = pick and c.paper or c.faint
        if pick then U.sound("tick", 0.15) end
      end
    end)
    wheel = { root = root, job = job, pick = function() return chosen end }
  end
  function U.wheelClose()
    if not wheel then return end
    local w = wheel
    wheel = nil
    w.job.dead = true
    local pick = w.pick()
    w.root:Destroy()
    if pick then
      local ok, err = pcall(WHEEL[pick][4])
      if not ok then U.toast("That did not work", tostring(err), "bad") end
    end
  end
end

-- 90 boot       the title card, then the console. Click the card to skip it.
do
  local mk, c = U.mk, U.c
  U.buildRail()

  -- Showcase starts on by itself outside TSB with no owner chosen: there is
  -- nothing real to show there, and nothing in it can touch the game.
  local saved = U.pref("showcase", nil)
  local st = Core.status()
  local auto = not st.supported and not st.owner
  U.setShowcase(saved == nil and auto or saved == true, true)

  local function mount()
    U.show()
    U.go(U.surfaces[U.pref("surface", "deck")] and U.pref("surface", "deck") or "deck")
    task.delay(0.5, function()
      U.toast(U.NAME, (U.S.showcase and "Showcase is on: simulated data only. " or "")
        .. U.pref("keyToggle", "RightControl") .. " shows or hides it  ·  hold " .. U.pref("keyWheel", "LeftAlt") .. " for the wheel", "ok")
    end)
  end

  if U.pref("intro", true) == false then mount(); return end

  -- ゴゴゴ: three glyph clusters drift in and tremble, the name wipes in under
  -- a gold shine, a rule draws itself, and it all clears into the console.
  local top = U.layers.top
  local card = mk("TextButton", { AutoButtonColor = false, Text = "", BackgroundColor3 = c.ink, BackgroundTransparency = 1,
    Size = UDim2.fromScale(1, 1), ZIndex = 250, Parent = top })
  U.anim(card, "BackgroundTransparency", 0.08, "glide")
  local stage = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(900, 420), AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5), ZIndex = 251, Parent = card })
  local stageScale = U.scaledFrame(stage)
  local tone = U.asset("tone.png")
  if tone then
    local t = mk("ImageLabel", { BackgroundTransparency = 1, Image = tone, ImageColor3 = c.aura, ImageTransparency = 1, ScaleType = Enum.ScaleType.Tile,
      TileSize = UDim2.fromOffset(10, 10), Size = UDim2.fromScale(1, 1), ZIndex = 251, Parent = card })
    mk("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0.4), NumberSequenceKeypoint.new(1, 1) }),
      Rotation = 90, Parent = t })
    U.anim(t, "ImageTransparency", 0.8, "menace")
  end
  local glyphs = {}
  local spots = { { -330, -120, -12, 64 }, { 320, -150, 9, 52 }, { 290, 130, -5, 40 }, { -300, 140, 7, 36 } }
  for i, s in ipairs(spots) do
    local g = U.text(stage, "ゴゴゴ", { FontFace = U.f.comic, TextSize = s[4], TextColor3 = i % 2 == 1 and c.aura or c.gold, TextTransparency = 1,
      AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, s[1] * 0.6, 0.5, s[2] * 0.6), Rotation = s[3], ZIndex = 252 })
    mk("UIStroke", { Color = c.ink, Thickness = 2, Parent = g })
    task.delay(0.08 * i, function()
      U.anim(g, "TextTransparency", 0.05, "glide")
      U.anim(g, "Position", UDim2.new(0.5, s[1], 0.5, s[2]), "menace")
    end)
    glyphs[i] = { g = g, base = s }
  end
  local kana = U.text(stage, U.KANA, { FontFace = U.f.mono, TextSize = 15, TextColor3 = c.gold, TextTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.new(0.5, 0, 0.5, -58), ZIndex = 253 })
  local name = U.text(stage, U.NAME, { FontFace = U.f.display, TextSize = 64, TextColor3 = c.white, TextTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.new(0.5, 0, 0.5, 12), ZIndex = 253 })
  local shine = mk("UIGradient", { Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, c.paper), ColorSequenceKeypoint.new(0.42, c.paper),
    ColorSequenceKeypoint.new(0.5, c.gold), ColorSequenceKeypoint.new(0.58, c.paper), ColorSequenceKeypoint.new(1, c.paper) }), Offset = Vector2.new(-1, 0), Parent = name })
  local nameScale = mk("UIScale", { Scale = 1.25, Parent = name })
  local rule = mk("Frame", { BackgroundColor3 = c.gold, BorderSizePixel = 0, Size = UDim2.fromOffset(0, 2), AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.new(0.5, 0, 0.5, 62), ZIndex = 253, Parent = stage })
  local tag = U.text(stage, "the stand console", { FontFace = U.f.mono, TextSize = 13, TextColor3 = c.faint, TextTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.new(0.5, 0, 0.5, 84), ZIndex = 253 })
  task.delay(0.25, function()
    U.anim(name, "TextTransparency", 0, "glide")
    U.anim(nameScale, "Scale", 1, "menace")
    U.sound("open", 0.45)
  end)
  task.delay(0.45, function() U.anim(kana, "TextTransparency", 0.1, "glide"); U.anim(rule, "Size", UDim2.fromOffset(520, 2), "flourish") end)
  task.delay(0.65, function() U.anim(tag, "TextTransparency", 0.2, "glide") end)
  local t, done = 0, false
  local job = U.every(function(dt)
    t += dt
    shine.Offset = Vector2.new(math.clamp(-1 + (t - 0.5) * 1.6, -1, 1), 0)
    if not U.reduced then
      for _, gl in ipairs(glyphs) do
        if t > 0.6 then gl.g.Position = UDim2.new(0.5, gl.base[1] + math.random(-2, 2), 0.5, gl.base[2] + math.random(-2, 2)) end
      end
    end
  end, { rate = 30 })
  local function finish()
    if done then return end
    done = true
    job.dead = true
    U.anim(card, "BackgroundTransparency", 1, "glide")
    U.anim(stageScale, "Scale", U.scale * 1.06, "glide")
    for _, lab in ipairs({ name, kana, tag }) do U.anim(lab, "TextTransparency", 1, "tap") end
    for _, gl in ipairs(glyphs) do U.anim(gl.g, "TextTransparency", 1, "tap") end
    U.anim(rule, "BackgroundTransparency", 1, "tap")
    task.delay(0.12, mount)
    task.delay(0.6, function() card:Destroy() end)
  end
  card.MouseButton1Click:Connect(finish)
  task.delay(2.3, finish)
end

end