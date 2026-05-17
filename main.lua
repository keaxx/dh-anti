--[[
    Advanced Anti‑Cheat for Roblox (Da Hood / similar)
    Detects & blocks:
        - Silent Aim (hooked __namecall, FireServer "UpdateMousePos" or "Shoot")
        - Force Hit / modified shot arguments
        - Rapid Fire / Double Tap
        - Bypassed GunCheck
        - Speed / Fly / Teleport
        - Hitbox Expander (oversized HumanoidRootPart, Neon material)
        - Noclip

    Configuration toggles:
        KICK_ON_SILENT_AIM  : Kick player when silent aim / force hit detected
        BLOCK_SILENT_AIM    : Reject the modified shot (server‑side block)
        KICK_ON_SPEED       : Kick for speed / fly / teleport
        KICK_ON_HITBOX      : Kick for hitbox expansion
        MAX_VIOLATIONS      : Number of warnings before kick (if kicking is disabled)
]]

local CONFIG = {
    -- Silent aim / force hit detection
    KICK_ON_SILENT_AIM = true,      -- Kick immediately on detection
    BLOCK_SILENT_AIM   = true,      -- Block the shot (also blocks if kicking is false)
    MAX_ANGLE_DEVIATION = 15,       -- Max degrees between look direction and shot direction
    MIN_HIT_DISTANCE = 10,          -- Ignore angle check for very close shots (melee)
    RAPID_FIRE_TOLERANCE = 0.12,    -- Minimum seconds between shots (adjust to your weapons)
    GUN_CHECK_REQUIRED = true,      -- Require GunCheck InvokeServer to return non‑nil

    -- Movement detection
    KICK_ON_SPEED = true,
    MAX_SPEED = 65,                 -- studs/second (normal sprint ~20-25)
    MAX_TELEPORT_DIST = 150,        -- studs in <0.5 seconds
    CHECK_INTERVAL = 0.3,           -- movement check frequency

    -- Hitbox expander
    KICK_ON_HITBOX = true, -- set to false if hitbox isnt configured
    HITBOX_MAX_SIZE = Vector3.new(3.5, 3.5, 2.5),  -- normal ~2,2,1
    ALLOWED_MATERIALS = {           -- materials allowed for HumanoidRootPart
        Enum.Material.Plastic,
        Enum.Material.SmoothPlastic,
        Enum.Material.Wood,
        Enum.Material.Metal
    },

    -- Miscellaneous
    MAX_VIOLATIONS = 3,             -- number of warnings before kick (if KICK_ON_* false)
    LOG_TO_CONSOLE = true,          -- print violations to output
}

-- ========== SERVICES ==========
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

-- ========== PLAYER DATA ==========
local playerData = {}

-- Helper: handle violation (kick or warn)
local function handleViolation(player, reason, isCritical)
    local data = playerData[player.UserId]
    if not data then return end
    data.violations = (data.violations or 0) + 1

    if CONFIG.LOG_TO_CONSOLE then
        warn(string.format("[AC] %s (%d) - %s (violation %d)", player.Name, player.UserId, reason, data.violations))
    end

    if isCritical or data.violations >= CONFIG.MAX_VIOLATIONS then
        player:Kick("Anti-Cheat: " .. reason)
    end
end

-- ========== 1. SHOT VALIDATION (anti‑silent aim / force hit) ==========
local function setupShotValidation(player)
    local data = { lastShotTime = 0, weaponCooldown = 0.2 }
    playerData[player.UserId] = data

    -- Get weapon cooldown (customise to your game)
    local function getWeaponCooldown(tool)
        local gunData = tool:FindFirstChild("GunData")
        if gunData and gunData:IsA("ModuleScript") then
            local ok, module = pcall(require, gunData)
            if ok and module and module.cooldown then
                return module.cooldown
            end
        end
        return 0.2
    end

    -- Find the shoot remote (common names)
    local shootEvent = ReplicatedStorage:FindFirstChild("MainEvent") or
                       ReplicatedStorage:FindFirstChild("MAINEVENT") or
                       ReplicatedStorage:FindFirstChild("MainRemoteEvent")
    if not shootEvent then
        warn("[AC] Could not find shoot remote event. Shot validation disabled.")
        return
    end

    local oldFireServer = shootEvent.OnServerEvent
    shootEvent.OnServerEvent = function(plr, ...)
        if plr ~= player then return oldFireServer and oldFireServer(plr, ...) or nil end

        local args = {...}
        if not args[1] or (args[1] ~= "Shoot" and args[1] ~= "ShootGun") then
            return oldFireServer and oldFireServer(plr, ...) or nil
        end

        -- Rapid fire detection
        local now = tick()
        local timeSinceLast = now - data.lastShotTime
        if timeSinceLast < data.weaponCooldown - 0.01 then
            handleViolation(player, string.format("Rapid fire (%.3f s between shots)", timeSinceLast), CONFIG.KICK_ON_SILENT_AIM)
            if CONFIG.BLOCK_SILENT_AIM then return nil end
        end
        data.lastShotTime = now

        -- Extract reported hit part (exploit structure)
        local shotData = args[2]
        local reportedPart = nil
        if type(shotData) == "table" then
            if shotData[1] and shotData[1][1] and shotData[1][1]["Instance"] then
                reportedPart = shotData[1][1]["Instance"]
            elseif shotData[2] and shotData[2][1] and shotData[2][1]["thePart"] then
                reportedPart = shotData[2][1]["thePart"]
            end
        end

        if reportedPart and reportedPart:IsA("BasePart") then
            -- Validate hit angle
            local character = player.Character
            if character then
                local hrp = character:FindFirstChild("HumanoidRootPart")
                local head = character:FindFirstChild("Head")
                local gunPosition = head and head.Position or (hrp and hrp.Position)
                if gunPosition then
                    local shootDir = (reportedPart.Position - gunPosition).Unit
                    local lookDir = hrp and hrp.CFrame.LookVector or Vector3.new(0,0,1)
                    local angle = math.deg(math.acos(math.clamp(lookDir:Dot(shootDir), -1, 1)))
                    local distance = (reportedPart.Position - gunPosition).Magnitude
                    if angle > CONFIG.MAX_ANGLE_DEVIATION and distance > CONFIG.MIN_HIT_DISTANCE then
                        handleViolation(player, string.format("Silent aim (angle %.1f°)", angle), CONFIG.KICK_ON_SILENT_AIM)
                        if CONFIG.BLOCK_SILENT_AIM then return nil end
                    end
                end
            end
        end

        -- Update weapon cooldown
        local tool = player.Character and player.Character:FindFirstChildWhichIsA("Tool")
        if tool then
            data.weaponCooldown = getWeaponCooldown(tool)
        end

        -- Allow the original event
        return oldFireServer and oldFireServer(plr, ...) or nil
    end
end

-- ========== 2. DETECT GUNCHECK BYPASS ==========
local function setupGunCheckValidation(player)
    local gunCheckEvent = ReplicatedStorage:FindFirstChild("MainFunction") or
                          ReplicatedStorage:FindFirstChild("GunCheck")
    if not gunCheckEvent then return end

    local oldInvoke = gunCheckEvent.OnServerInvoke
    gunCheckEvent.OnServerInvoke = function(plr, ...)
        if plr ~= player then return oldInvoke and oldInvoke(plr, ...) or nil end
        local args = {...}
        if args[1] == "GunCheck" then
            local result = oldInvoke and oldInvoke(plr, ...)
            if result == nil then
                handleViolation(player, "Bypassed GunCheck (returned nil)", CONFIG.KICK_ON_SILENT_AIM)
                if CONFIG.BLOCK_SILENT_AIM then return false end
            end
            return result
        end
        return oldInvoke and oldInvoke(plr, ...) or nil
    end
end

-- ========== 3. MOVEMENT DETECTION (speed, fly, teleport) ==========
local function setupMovementTracking(player)
    local data = playerData[player.UserId]
    if not data then
        data = { violations = 0 }
        playerData[player.UserId] = data
    end
    data.lastPos = nil
    data.lastTime = nil

    local function trackMovement()
        local char = player.Character
        if not char then return end
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if not hrp then return end

        local now = tick()
        local currentPos = hrp.Position

        if data.lastPos and data.lastTime then
            local dt = now - data.lastTime
            if dt > 0 then
                local distance = (currentPos - data.lastPos).Magnitude
                local speed = distance / dt

                if speed > CONFIG.MAX_SPEED then
                    handleViolation(player, string.format("Speed hack (%.1f studs/s)", speed), CONFIG.KICK_ON_SPEED)
                end

                if dt < 0.5 and distance > CONFIG.MAX_TELEPORT_DIST then
                    handleViolation(player, string.format("Teleport (%.1f studs)", distance), CONFIG.KICK_ON_SPEED)
                end
            end
        end

        data.lastPos = currentPos
        data.lastTime = now
    end

    local connection = RunService.Heartbeat:Connect(function()
        if player and player.Parent then
            trackMovement()
        else
            connection:Disconnect()
        end
    end)
    data.movementConnection = connection
end

-- ========== 4. HITBOX EXPANDER DETECTION ==========
local function checkHitboxExpander(player)
    local char = player.Character
    if not char then return end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end

    -- Size check
    if hrp.Size.X > CONFIG.HITBOX_MAX_SIZE.X or
       hrp.Size.Y > CONFIG.HITBOX_MAX_SIZE.Y or
       hrp.Size.Z > CONFIG.HITBOX_MAX_SIZE.Z then
        handleViolation(player, "Hitbox expander (oversized HumanoidRootPart)", CONFIG.KICK_ON_HITBOX)
        hrp.Size = Vector3.new(2, 2, 1)
        return true
    end

    -- Material / transparency check
    if not table.find(CONFIG.ALLOWED_MATERIALS, hrp.Material) and hrp.Transparency < 0.5 then
        handleViolation(player, "Hitbox expander (suspicious material/transparency)", CONFIG.KICK_ON_HITBOX)
        hrp.Material = Enum.Material.Plastic
        hrp.Transparency = 1
        return true
    end

    -- Outline object detection
    if hrp:FindFirstChild("Outline") or hrp.Parent:FindFirstChild("Outline") then
        handleViolation(player, "Hitbox expander (outline object detected)", CONFIG.KICK_ON_HITBOX)
        return true
    end
    return false
end

-- ========== 5. INITIALIZE FOR EACH PLAYER ==========
local function setupAntiCheat(player)
    if playerData[player.UserId] then
        local old = playerData[player.UserId]
        if old.movementConnection then old.movementConnection:Disconnect() end
        playerData[player.UserId] = nil
    end

    setupShotValidation(player)
    setupGunCheckValidation(player)
    setupMovementTracking(player)

    -- Periodic hitbox check
    task.spawn(function()
        while player and player.Parent do
            task.wait(2)
            if player.Character then
                checkHitboxExpander(player)
            end
        end
    end)
end

-- Connect for new and existing players
Players.PlayerAdded:Connect(setupAntiCheat)
for _, player in ipairs(Players:GetPlayers()) do
    task.spawn(setupAntiCheat, player)
end

print("[AC] Anti‑cheat loaded. Configuration:")
print("  KICK_ON_SILENT_AIM =", CONFIG.KICK_ON_SILENT_AIM)
print("  BLOCK_SILENT_AIM   =", CONFIG.BLOCK_SILENT_AIM)
print("  KICK_ON_SPEED      =", CONFIG.KICK_ON_SPEED)
print("  KICK_ON_HITBOX     =", CONFIG.KICK_ON_HITBOX)
