-- State variables
local Octree = loadstring(game:HttpGet("https://raw.githubusercontent.com/Sleitnick/rbxts-octo-tree/main/src/init.lua", true))()

local rt = {} -- Removable table
rt.__index = rt
rt.octree = Octree.new()

rt.RoundInProgress = false
rt.IsCurrentlyMurderer = false

rt.Players = game.Players
rt.player = game.Players.LocalPlayer

rt.coinContainer = nil
rt.radius = 500 :: number -- Radius to search for coins
rt.walkspeed = 30 :: number -- speed at which you will go to a coin measured in walkspeed
rt.touchedCoins = {} -- Table to track touched coins
rt.positionChangeConnections = setmetatable({}, { __mode = "v" }) -- Weak table for connections
rt.Added = nil :: RBXScriptConnection
rt.Removing = nil :: RBXScriptConnection

rt.UserDiedConnection = nil :: RBXScriptConnection
rt.RoundEndSoundConnection = nil :: RBXScriptConnection

local State = {
    Action = "Action",                -- Actively collecting coins (for any role)
    WaitingForRound = "WaitingForRound",-- Waiting for a new round to start
    RespawnState = "RespawnState",    -- Handling player respawn and teleport
    Idle = "Idle"                     -- Fallback for unexpected states
}

local CurrentState = State.WaitingForRound
local LastPosition = nil :: CFrame?
local RoundInProgress = function()
    return rt.RoundInProgress
end
local BagIsFull = false

-- *** CRITICAL NEW FLAG ***
local IsHandlingRespawnCycle = false -- Global lock to prevent re-entry into respawn logic

-- Constants
rt.RoleTracker1 = nil :: RBXScriptConnection
rt.RoleTracker2 = nil :: RBXScriptConnection
rt.InvalidPos = nil :: RBXScriptConnection
local Working = false
local ROUND_TIMER = workspace:WaitForChild("RoundTimerPart").SurfaceGui.Timer
local PLAYER_GUI = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")

----------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------
function rt:Message(_Title, _Text, Time)
    game:GetService("StarterGui"):SetCore("SendNotification", { Title = _Title, Text = _Text, Duration = Time })
end

function rt:Character(): (Model?)
    return self.player.Character
end

function rt:GetCharacterLoaded(): (Model)
    local char = self.player.Character
    if not char then
        rt:Message("Info", "Waiting for character to load...", 1)
        char = self.player.CharacterAdded:Wait()
    end

    local humanoid, hrp = nil, nil
    local max_wait_time = 10 -- Max seconds to wait for character to be fully ready
    local start_time = tick()

    repeat
        task.wait(0.2) -- Increased wait time for more stability
        humanoid = char:FindFirstChildOfClass("Humanoid")
        hrp = char:FindFirstChild("HumanoidRootPart")

        -- Re-fetch character if it changed, indicating another death/respawn
        if char ~= self.player.Character then
            char = self.player.Character
            if not char then -- If character is now nil, wait for a new one to be added
                rt:Message("Warning", "Character changed unexpectedly during load, waiting for new character...", 1)
                char = self.player.CharacterAdded:Wait()
            end
        end

        -- Exit if character becomes invalid during the wait
        if not char or not char.Parent then
            rt:Message("Error", "Character became invalid during loading, retrying wait.", 2)
            char = self.player.CharacterAdded:Wait() -- Wait for a new character again
            start_time = tick() -- Reset timer for the new character
        end

    until (char and humanoid and hrp and humanoid.Health > 0 and hrp.CFrame ~= CFrame.new(0,0,0)) or (tick() - start_time > max_wait_time)

    if not (char and humanoid and hrp and humanoid.Health > 0 and hrp.CFrame ~= CFrame.new(0,0,0)) then
        rt:Message("Error", "Failed to load ready character after max wait time. This may lead to issues.", 3)
        -- Fallback: return current character even if not fully ready, to prevent infinite loop here
        return self.player.Character or self.player.CharacterAdded:Wait()
    end

    rt:Message("Info", "Character loaded and ready.", 1)
    return char
end


function rt:CheckIfPlayerIsInARound(): (boolean)
    local mainGUI = PLAYER_GUI:FindFirstChild("MainGUI")
    if not mainGUI then return false end

    local gameUI = mainGUI:FindFirstChild("Game")
    if gameUI then
        local timer = gameUI:FindFirstChild("Timer")
        if timer and timer.Visible and tonumber(timer.Text) and tonumber(timer.Text) > 0 then
            return true
        end
        local earnedXP = gameUI:FindFirstChild("EarnedXP")
        if earnedXP and earnedXP.Visible then
            return true
        end
    end
    return false
end

function rt:MainGUI(): (ScreenGui?)
    return self.player.PlayerGui.MainGUI or self.player.PlayerGui:WaitForChild("MainGUI")
end

function rt.Disconnect(connection: RBXScriptConnection?)
    if connection and connection.Connected then
        connection:Disconnect()
    end
end

function rt:Map(): (Model | nil)
    for _, v in workspace:GetDescendants() do
        if v.Name == "Spawns" and v.Parent.Name ~= "Lobby" then
            return v.Parent
        end
    end
    return nil
end

function rt:CheckIfGameInProgress(): (boolean)
    return rt:Map() ~= nil
end

function rt:GetAlivePlayers(): (table)
    local aliveplrs = {}
    local char = self:Character()

    if not char or not char.PrimaryPart then
        return aliveplrs
    end

    local OldPos = char:GetPivot()
    local lobbySpawnPos = CFrame.new(-121.995956, 134.462997, 46.4180717)

    local isAliveInRound = rt:CheckIfPlayerIsInARound()

    if not isAliveInRound then
        char:PivotTo(lobbySpawnPos)
        task.wait(0.1)
    end

    for _, v in pairs(rt.Players:GetPlayers()) do
        if v.Character and v.Character.PrimaryPart and v ~= rt.player then
            local distance = (char.PrimaryPart.Position - v.Character.PrimaryPart.Position).Magnitude
            if isAliveInRound then
                if distance <= 500 then
                    table.insert(aliveplrs, v)
                end
            else
                if distance > 500 then
                    table.insert(aliveplrs, v)
                end
            end
        end
    end

    if not isAliveInRound and char and char.PrimaryPart then
        char:PivotTo(OldPos)
    end

    return aliveplrs
end

function rt:CheckIfPlayerWasInARound(): (boolean)
    return self.player:GetAttribute("Alive") == true
end

function rt:IsElite(): (boolean)
    return self.player:GetAttribute("Elite") == true
end

local function AutoFarmCleanUp()
    for coin, connection in pairs(rt.positionChangeConnections) do
        rt.Disconnect(connection)
        rt.positionChangeConnections[coin] = nil
    end
    rt.Disconnect(rt.Added)
    rt.Disconnect(rt.Removing)
    
    -- Keep RoundEndSoundConnection connected, it's for global game events
    -- Keep UserDiedConnection connected, it's for global player death events

    rt:Message("Info", "Autofarm CleanUp Success", 2)
    table.clear(rt.touchedCoins)
    rt.octree:ClearAllNodes()
end

local function isCoinTouched(coin)
    return rt.touchedCoins[coin] == true
end

local function markCoinAsTouched(coin)
    if not rt then return end
    if not coin or not coin:IsA("BasePart") then return end

    rt.touchedCoins[coin] = true
    local node = rt.octree:FindFirstNode(coin)
    if node then
        rt.octree:RemoveNode(node)
    end
    rt.Disconnect(rt.positionChangeConnections[coin])
    rt.positionChangeConnections[coin] = nil
end

local function setupTouchTracking(coin)
    if rt.positionChangeConnections[coin] or isCoinTouched(coin) then return end

    local touchInterest = coin:FindFirstChildWhichIsA("TouchTransmitter")
    if touchInterest then
        local connection = touchInterest.AncestryChanged:Connect(function(_, parent)
            if not rt then rt.Disconnect(connection); return end
            if parent == nil then
                markCoinAsTouched(coin)
            end
        end)
        rt.positionChangeConnections[coin] = connection
    end
end

local function setupPositionTracking(coin: MeshPart, LastPositonY: number)
    if rt.positionChangeConnections[coin] or isCoinTouched(coin) then return end

    local connection = coin:GetPropertyChangedSignal("Position"):Connect(function()
        if not rt or not coin.Parent then
            markCoinAsTouched(coin)
            return
        end

        local currentY = coin.Position.Y
        if LastPositonY and math.abs(LastPositonY - currentY) > 0.1 then
            markCoinAsTouched(coin)
        end
    end)
    rt.positionChangeConnections[coin] = connection
end

local function moveToPositionSlowly(targetPosition: Vector3, duration: number)
    local char = rt:Character()
    if not char or not char.PrimaryPart then
        rt:Message("Error", "Character not available for movement.", 1)
        return false
    end

    local startPosition = char.PrimaryPart.Position
    local startTime = tick()

    local success = false
    local timeout = tick() + duration + 5

    while tick() < timeout do
        local char_current = rt:Character()
        if not char_current or not char_current.PrimaryPart then
            rt:Message("Warning", "Character lost during movement, stopping.", 1)
            break
        end

        local elapsedTime = tick() - startTime
        local alpha = math.min(elapsedTime / duration, 1)

        char_current:PivotTo(CFrame.new(startPosition:Lerp(targetPosition, alpha)))

        if (char_current.PrimaryPart.Position - targetPosition).Magnitude < 1.5 then
            success = true
            break
        end

        task.wait()
    end

    if success and char and char.PrimaryPart then
        char:PivotTo(CFrame.new(targetPosition))
        task.wait(0.05)
    end

    task.wait(0.1)
    return success
end

local function populateOctree()
    rt.octree:ClearAllNodes()
    rt.touchedCoins = {}

    local coinContainer = rt.coinContainer
    if not coinContainer then
        rt:Message("Warning", "Coin container not found during octree population.", 2)
        return
    end

    for _, descendant in pairs(coinContainer:GetDescendants()) do
        if descendant:IsA("TouchTransmitter") then
            local parentCoin = descendant.Parent
            if parentCoin and parentCoin:IsA("BasePart") and not isCoinTouched(parentCoin) then
                rt.octree:CreateNode(parentCoin.Position, parentCoin)
                setupTouchTracking(parentCoin)
                setupPositionTracking(parentCoin, parentCoin.Position.Y)
            end
        end
    end

    rt.Disconnect(rt.Added)
    rt.Added = coinContainer.DescendantAdded:Connect(function(descendant)
        if descendant:IsA("TouchTransmitter") then
            local parentCoin = descendant.Parent
            if parentCoin and parentCoin:IsA("BasePart") and not isCoinTouched(parentCoin) then
                rt.octree:CreateNode(parentCoin.Position, parentCoin)
                setupTouchTracking(parentCoin)
                setupPositionTracking(parentCoin, parentCoin.Position.Y)
            end
        end
    end)

    rt.Disconnect(rt.Removing)
    rt.Removing = coinContainer.DescendantRemoving:Connect(function(descendant)
        if descendant:IsA("TouchTransmitter") and descendant.Parent and descendant.Parent:IsA("BasePart") then
            local parentCoin = descendant.Parent
            markCoinAsTouched(parentCoin)
        end
    end)
end

local function ChangeState(StateName)
    if CurrentState ~= StateName then
        CurrentState = StateName
        -- print("STATE CHANGED TO: " .. StateName)
    end
end
----------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------

local function IsBagFull()
    local playerGui = PLAYER_GUI:FindFirstChild("MainGUI")
    if not playerGui then return false end
    local gameUI = playerGui:FindFirstChild("Game")
    if not gameUI then return false end
    local coinBags = gameUI:FindFirstChild("CoinBags")
    if not coinBags then return false end
    local container = coinBags:FindFirstChild("Container")
    if not container then return false end
    local snowToken = container:FindFirstChild("SnowToken")
    if not snowToken then return false end
    local currencyFrame = snowToken:FindFirstChild("CurrencyFrame")
    if not currencyFrame then return false end
    local icon = currencyFrame:FindFirstChild("Icon")
    if not icon then return false end
    local coinsText = icon:FindFirstChild("Coins")
    if not coinsText or not coinsText:IsA("TextLabel") then return false end

    local currentCoins = tonumber(coinsText.Text) or 0
    return currentCoins >= (rt:IsElite() and 50 or 40)
end

local function ForcePlayerDeath()
    local char = rt:Character()
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")
    if humanoid and humanoid.Health > 0 then
        rt:Message("Alert", "Forcing character death to reset bag.", 2)
        humanoid.Health = 0 -- Set health to 0 to trigger death
        -- IMPORTANT: Do not add a task.wait() here. Let the CharacterRemoving listener handle the subsequent state change.
        return true
    end
    return false
end

local function RespawnAndTeleportBack()
    if IsHandlingRespawnCycle then
        rt:Message("Info", "Respawn already being handled by another cycle, skipping this call.", 1)
        return true
    end

    IsHandlingRespawnCycle = true -- Set the global lock

    rt:Message("Info", "Initiating Respawn and Teleport Back...", 2)

    local newChar = nil
    local success = pcall(function()
        newChar = rt:GetCharacterLoaded() -- This waits until char is ready and alive
    end)

    if not success or not newChar then
        rt:Message("Error", "Failed to load new character after respawn attempt. Retrying later.", 3)
        IsHandlingRespawnCycle = false -- Release lock on failure to load char
        return false
    end
    rt:Message("Info", "New character loaded after respawn.", 1)

    -- Determine a good position to teleport to
    if not LastPosition then
        local alivePlayers = rt:GetAlivePlayers()
        if alivePlayers and #alivePlayers > 0 then
            local targetPlayer = nil
            for _, v in pairs(alivePlayers) do
                if v.Character and v.Character.PrimaryPart and rt:CheckIfPlayerIsInARound() then
                    targetPlayer = v
                    break
                end
            end
            if targetPlayer then
                LastPosition = targetPlayer.Character.PrimaryPart.CFrame
                rt:Message("Info", "Set LastPosition from alive player.", 2)
            else
                LastPosition = CFrame.new(0, 100, 0)
                rt:Message("Warning", "No in-round alive players found, using default LastPosition.", 2)
            end
        else
            LastPosition = CFrame.new(0, 100, 0)
            rt:Message("Warning", "No alive players found for LastPosition, using default.", 2)
        end
    end

    if newChar and LastPosition and newChar:FindFirstChild("HumanoidRootPart") then
        local humanoid = newChar:FindFirstChildOfClass("Humanoid")
        if humanoid then
            humanoid.WalkSpeed = rt.walkspeed -- Ensure walkspeed is restored for teleport
            humanoid.JumpPower = 50
            humanoid.Sit = false
        end

        rt:Message("Info", "Pivoting to LastPosition.", 1)
        newChar:PivotTo(LastPosition)
        task.wait(0.5) -- Small wait after pivot to stabilize
    else
        rt:Message("Error", "Failed to pivot character after respawn. Character or LastPosition invalid.", 3)
        IsHandlingRespawnCycle = false -- Release lock on pivot failure
        return false
    end

    rt:Message("Info", "Respawn and Teleport Back complete.", 1)
    IsHandlingRespawnCycle = false -- Release the global lock on success
    return true
end

local function CollectCoins()
    Working = true
    local mapmodel = rt:Map()
    if not mapmodel then
        rt:Message("Warning", "No map found, waiting for map to load.", 2)
        Working = false
        ChangeState(State.WaitingForRound)
        return
    end

    rt.coinContainer = mapmodel:FindFirstChild("CoinContainer")
    if not rt.coinContainer then
        rt:Message("Warning", "CoinContainer not found, cannot collect coins.", 2)
        Working = false
        ChangeState(State.WaitingForRound)
        return
    end

    populateOctree()
    rt:Message("Info", "Octree populated with coins.", 1)

    local char = rt:Character()
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")

    -- Ensure character properties are correct for grinding
    if humanoid then
        humanoid.WalkSpeed = rt.walkspeed
        humanoid.JumpPower = 50
        humanoid.Sit = false
    end

    -- If Murderer, adjust behavior
    if rt.IsCurrentlyMurderer then
        rt:Message("Info", "You are the Murderer. Attempting to survive and collect if possible.", 2)
        if humanoid then
            humanoid.WalkSpeed = 0 -- Keep walkspeed at 0 for AFK murderer
            humanoid.JumpPower = 0 -- Prevent jumping
            humanoid.Sit = true -- Sit down for full AFK (if game allows)
        end
    end

    while CurrentState == State.Action and not IsHandlingRespawnCycle do -- Added IsHandlingRespawnCycle check
        if IsBagFull() then
            BagIsFull = true
            ForcePlayerDeath() -- Trigger death
            -- The UserDiedConnection will now pick this up and transition to RespawnState
            break -- Exit coin collection loop immediately
        end

        if not char or not char.PrimaryPart or not humanoid or humanoid.Health <= 0 then
            rt:Message("Warning", "Character not ready or died during coin collection. Aborting CollectCoins.", 2)
            break -- Break if character is not valid, will lead to RespawnState via UserDiedConnection
        end

        local nearestNode = rt.octree:GetNearest(char.PrimaryPart.Position, rt.radius, 1)[1]

        if nearestNode then
            local closestCoin = nearestNode.Object
            if closestCoin and not isCoinTouched(closestCoin) then
                local targetPosition = closestCoin.Position
                local distance = (char.PrimaryPart.Position - targetPosition).Magnitude
                local duration = distance / rt.walkspeed
                if duration < 0.1 then duration = 0.1 end

                if not rt.IsCurrentlyMurderer or (rt.IsCurrentlyMurderer and distance < 50) then
                    if moveToPositionSlowly(targetPosition, duration) then
                        markCoinAsTouched(closestCoin)
                        task.wait(0.1)
                    else
                        rt:Message("Warning", "Failed to reach coin, retrying or moving on.", 1)
                        markCoinAsTouched(closestCoin)
                        task.wait(0.3)
                    end
                else
                    rt:Message("Info", "Murderer idling, waiting for closer coins or round end.", 1)
                    task.wait(1)
                end
            else
                markCoinAsTouched(closestCoin)
                task.wait(0.1)
            end
        else
            rt:Message("Info", "No nearby coins found, waiting for new coins or round end.", 2)
            task.wait(2)
            rt.coinContainer = rt:Map() and rt:Map():FindFirstChild("CoinContainer")
            if rt.coinContainer then populateOctree() end
        end

        if not RoundInProgress() then
            rt:Message("Info", "Round ended during coin collection.", 2)
            break
        end
    end

    -- Restore character stats if they were changed (e.g., for Murderer)
    if humanoid then
        humanoid.WalkSpeed = rt.walkspeed
        humanoid.JumpPower = 50
        humanoid.Sit = false
    end

    AutoFarmCleanUp()
    Working = false
end

local function RespawnState()
    rt:Message("Info", "Entering RespawnState...", 2)
    Working = false
    BagIsFull = false
    
    -- Crucial: Ensure IsHandlingRespawnCycle is set to allow RespawnAndTeleportBack to proceed
    IsHandlingRespawnCycle = true

    -- This will try to respawn and teleport.
    if not RespawnAndTeleportBack() then
        rt:Message("Error", "Respawn and teleport failed. Transitioning to WaitingForRound.", 3)
        ChangeState(State.WaitingForRound)
        IsHandlingRespawnCycle = false -- Release lock if this state fails to complete respawn
        return
    end

    rt:Message("Info", "Respawned!", 2)

    -- After successful respawn, check round status and transition
    if not RoundInProgress() then
        rt:Message("Info", "Round ended during respawn, transitioning to WaitingForRound.", 2)
        ChangeState(State.WaitingForRound)
    else
        ChangeState(State.Action) -- Continue grinding in the current round
    end
    IsHandlingRespawnCycle = false -- Release lock once RespawnState successfully completes its cycle
end

local function WaitingForRound()
    rt:Message("Info", "Waiting for round to start...", 2)
    Working = false
    AutoFarmCleanUp()

    local char = rt:Character()
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")
    if humanoid then
        humanoid.WalkSpeed = rt.walkspeed
        humanoid.JumpPower = 50
        humanoid.Sit = false
        humanoid:ChangeState(Enum.HumanoidStateType.Running)
    end

    rt.RoundInProgress = false
    rt.IsCurrentlyMurderer = false
    BagIsFull = false
    LastPosition = nil
    IsHandlingRespawnCycle = false -- Ensure lock is off for a new round

    repeat
        task.wait(0.5)
        if not rt:Character() or not rt:Character():FindFirstChild("HumanoidRootPart") then
            rt:GetCharacterLoaded() -- Ensure character is loaded while waiting
        end
        if rt:CheckIfPlayerIsInARound() then
            rt.RoundInProgress = true
            break
        end
    until RoundInProgress()

    rt:Message("Alert", "Round started!", 2)
    ChangeState(State.Action)
end

local function ActionState()
    rt:Message("Info", "Entering ActionState (Grinding for all roles).", 2)
    LastPosition = nil -- Reset LastPosition for a new grinding phase if it wasn't already

    CollectCoins()

    -- If CollectCoins broke due to bag full or character death,
    -- the UserDiedConnection would have already pushed to RespawnState.
    -- If it broke because the round ended, push to WaitingForRound.
    if not RoundInProgress() then
        rt:Message("Info", "Round ended during ActionState, transitioning to WaitingForRound.", 2)
        ChangeState(State.WaitingForRound)
    elseif not IsHandlingRespawnCycle then -- Only transition to RespawnState if not already in a respawn cycle
        rt:Message("Info", "CollectCoins finished. Re-evaluating state, potentially Respawning.", 2)
        ChangeState(State.RespawnState)
    end
end

----------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------
rt.RoleTracker1 = rt.player.DescendantAdded:Connect(function(descendant)
    if descendant:IsA("Tool") and descendant.Name == "Knife" then
        rt.IsCurrentlyMurderer = true
        rt:Message("Role", "You are the Murderer!", 3)
    end
end)

rt.RoleTracker2 = rt.player.Backpack.ChildRemoved:Connect(function(child)
    if child:IsA("Tool") and child.Name == "Knife" then
        rt.IsCurrentlyMurderer = false
        rt:Message("Role", "You are no longer the Murderer.", 3)
    end
end)


rt.InvalidPos = workspace.DescendantAdded:Connect(function(descendant)
    if descendant:IsA("Model") then
        if string.match(descendant.Name, "Glitch") and descendant.Parent and descendant.Parent.Name ~= "Lobby" then
            descendant:Destroy()
        end

        if string.match(descendant.Name, "Invis") and descendant.Parent and descendant.Parent.Name ~= "Lobby" then
            descendant:Destroy()
        end
    end
end)

ROUND_TIMER:GetPropertyChangedSignal("Text"):Connect(function()
    local timerText = ROUND_TIMER.Text
    if tonumber(timerText) and tonumber(timerText) > 0 then
        if not rt.RoundInProgress then
            rt.RoundInProgress = true
            rt:Message("Event", "Round timer active, likely round start.", 2)
            if not IsHandlingRespawnCycle then -- Only change state if not busy respawning
                ChangeState(State.Action)
            end
        end
    elseif timerText == "WAITING" or timerText == "0" or timerText == "" then
        if rt.RoundInProgress then
            rt.RoundInProgress = false
            rt:Message("Event", "Round timer stopped/waiting, likely round end.", 2)
            if not IsHandlingRespawnCycle then -- Only change state if not busy respawning
                ChangeState(State.WaitingForRound)
            end
        end
    end
end)

rt.RoundEndSoundConnection = game:GetService("SoundService").DescendantAdded:Connect(function(descendant)
    -- REPLACE "rbxassetid://YOUR_ROUND_END_SOUND_ID_HERE" with the actual SoundId for round end.
    -- Or, if the game uses a specific sound name, use string.find(descendant.Name:lower(), "roundend")
    if descendant:IsA("Sound") and (descendant.SoundId == "rbxassetid://123456789" or string.find(descendant.Name:lower(), "roundend")) then
        if rt.RoundInProgress then
            rt:Message("Event", "Round end sound/cue detected. Resetting for new round.", 2)
            rt.RoundInProgress = false
            Working = false
            BagIsFull = false
            LastPosition = nil
            rt.IsCurrentlyMurderer = false
            IsHandlingRespawnCycle = false -- Release lock for a clean start
            ChangeState(State.WaitingForRound)
        end
    end
end)

-- This connection is for handling player death/reset reliably
rt.UserDiedConnection = rt.player.CharacterRemoving:Connect(function(character)
    -- Crucial: Defer the action to allow Roblox engine to process the CharacterRemoving fully
    -- and check our global lock.
    task.defer(function()
        if IsHandlingRespawnCycle then
            rt:Message("Info", "CharacterRemoving fired, but respawn already handled. Ignoring.", 1)
            return
        end

        rt:Message("Event", "Character removed (player died or reset). Triggering RespawnState.", 2)
        AutoFarmCleanUp() -- Clean up active farm connections
        rt.IsCurrentlyMurderer = false -- Assume role is reset on death
        Working = false
        BagIsFull = false
        LastPosition = nil
        
        ChangeState(State.RespawnState) -- Immediately transition to RespawnState
    end)
end)

----------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------

-- Initial checks and state setting
rt.IsCurrentlyMurderer = rt.player.Backpack:FindFirstChild("Knife") and true or false

if rt:CheckIfPlayerIsInARound() then
    rt.RoundInProgress = true
    ChangeState(State.Action)
else
    ChangeState(State.WaitingForRound)
end

-- Main Loop
while task.wait() do
    if IsHandlingRespawnCycle and CurrentState ~= State.RespawnState then
        -- If we're currently handling a respawn, and not already in RespawnState,
        -- force the state to RespawnState to ensure it's processed correctly.
        ChangeState(State.RespawnState)
    end

    if CurrentState == State.WaitingForRound then
        WaitingForRound()
    elseif CurrentState == State.Action then
        ActionState()
    elseif CurrentState == State.RespawnState then
        RespawnState()
    elseif CurrentState == State.Idle then
        rt:Message("Info", "Script is in Idle state, waiting...", 1)
        task.wait(5)
        ChangeState(State.WaitingForRound)
    end
end
