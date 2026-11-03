-- PANICORE Host Controller v0.11.6 radar performance / stable 0.11.5 gameplay controls
-- Tested in simulation only. School freeze visually confirmed in v0.2.0 Lua.
-- HOST ONLY: checks authoritative GameMode world for ANY control change.
-- F6: freeze / unfreeze all recognized host-controlled enemy pawns (multi-entity supported).
-- F7: toggle local host pawn noclip: MOVE_Flying + collision OFF; restores previous state.
-- F8: emergency RETURN TO SPAWN (no map/progress reset).
-- During noclip: hold Space to ascend, either Ctrl to descend, release to hover.
--      Flying suspends gravity but does NOT preserve physical floor collision.
--      You may disable noclip outside map bounds; F8 can rescue you afterwards.
-- NO remote-player teleport, anti-cheat bypass, remote-client control,
-- auto file/network sending, or external network traffic in this Lua mod.

local PREFIX = "[PHC v0.11.6] "
local SETTINGS = {
    -- Observed class and AI controller names from the October 23 multi-level test.
    -- Class/controller identity is independent of map so Random Entity mode can use it.
    KnownEnemyPairs = {
        { pawn = "BP_Puppet_C", controller = "BP_AIPuppet_C" },
        { pawn = "BP_AIMonsterCharacter_C", controller = "BP_AIMonster_C" },
        { pawn = "BP_BansheeAI_C", controller = "BP_AIBanshee_C" },
        { pawn = "BP_Submarine_Monster_New_C", controller = "BP_AISubmarine_C" },
        { pawn = "BP_SlenderLike_C", controller = "AI_SlenderLike_C" },
        { pawn = "BP_SantaClown_C", controller = "BP_AISantaClown_C" },
    },
    MaxTargets = 8,  -- avoid inadvertently affecting many unrelated NPCs
    AltitudePollMs = 50, -- serviced by the shared loop; only active during noclip
    AltitudeSpeedCmPerSec = 170, -- 1.7 m/s, adjustable in source code
}

local EXCLUDE_WORDS = {
    "player", "spectator", "lobby", "preview", "dummy", "controller", "randomscary", "jump_scare", "jumpscare", "launchcharacterscare", "bp_slave_c"
}

local frozenRecords = {}
local noclip = nil
local spawnAnchor = nil -- cached per authoritative UWorld, first grounded F7 only as fallback
local rescueCooldown = false
local hasUEHelpers, UEHelpers = pcall(require, "UEHelpers")
local freezeReason = "PanicoreHostControl"

local WORK = {now=0, inside=false, jobs={}, handlers={}, queue={}, frame=nil,
              world=nil, worldSettledAt=0, sequence=0, lastKey={}, errors={}}
local function set_job(name, period, fn)
    WORK.jobs[name] = {period=period, due=WORK.now+period, fn=fn}
end
local function clear_job(name) WORK.jobs[name]=nil end
local function enqueue(label)
    -- No native object operations in an input-thread callback.
    if #WORK.queue < 24 then WORK.queue[#WORK.queue+1]=label end
end
local function dense_list(class)
    local ok, items=pcall(FindAllOf,class)
    if not ok or type(items)~="table" then return {} end
    -- Do not use a generic iterator across native UObject calls.
    local result={}
    for i=1,rawlen(items) do
        local value=rawget(items,i)
        if value~=nil then result[#result+1]=value end
    end
    return result
end
local function log(message)
    print(PREFIX .. tostring(message) .. "\n")
end

local reportFolder=nil
local function operation_note(phase)
    if not reportFolder then return end
    pcall(function()
        local f=io.open(reportFolder.."\\PHC_LastOperation.txt","wb")
        if f then f:write(os.date("!%Y-%m-%dT%H:%M:%SZ"),"\n",tostring(phase),"\n"); f:close() end
    end)
end
local function is_valid(obj)
    if obj == nil then return false end
    local ok, val = pcall(function() return obj:IsValid() end)
    return ok and val == true
end

local function call(obj, method, ...)
    if not is_valid(obj) then return false, nil end
    local args = {...}
    local ok, result = pcall(function()
        return obj[method](obj, table.unpack(args))
    end)
    return ok, result
end

local function property(obj, member)
    if not is_valid(obj) then return nil end
    local ok, result = pcall(function() return obj[member] end)
    if ok then return result end
    return nil
end

local function full_name(obj)
    local ok, name = call(obj, "GetFullName")
    if ok and type(name) == "string" then return name end
    return "<unknown>"
end

local function class_name(obj)
    local ok, cls = call(obj, "GetClass")
    if not ok or not is_valid(cls) then return "<unknown-class>" end
    local okName, fname = call(cls, "GetFName")
    if not okName or fname == nil then return "<unknown-class>" end
    local okStr, name = pcall(function() return fname:ToString() end)
    if okStr and type(name) == "string" then return name end
    return "<unknown-class>"
end

local function contains_any(name, words)
    local value = string.lower(name)
    for _, word in ipairs(words) do
        if string.find(value, word, 1, true) then return true end
    end
    return false
end

local function get_position(actor)
    local ok, loc = call(actor, "K2_GetActorLocation")
    if not ok or loc == nil then return nil end
    local okV, x, y, z = pcall(function() return tonumber(loc.X), tonumber(loc.Y), tonumber(loc.Z) end)
    if not okV or x == nil or y == nil or z == nil then return nil end
    return {x=x, y=y, z=z}
end

local function posstr(pos)
    if not pos then return "unavailable" end
    return string.format("(%.1f, %.1f, %.1f)", pos.x, pos.y, pos.z)
end

local function distance3(a, b)
    if not a or not b then return nil end
    local x, y, z = a.x-b.x, a.y-b.y, a.z-b.z
    return math.sqrt(x*x + y*y + z*z)
end

-- Periodic work is serialized by WORK; no asynchronous delayed closures.

local function world_address(actor)
    local ok, world = call(actor, "GetWorld")
    if not ok or not is_valid(world) then return nil end
    local okAddr, address = call(world, "GetAddress")
    if okAddr and address ~= nil then return tostring(address).."|"..full_name(world) end
    -- Fallback is only for UE4SS builds that don't expose GetAddress.
    local fallback = full_name(world)
    if fallback ~= "<unknown>" then return fallback end
    return nil
end

local function authoritative_gamemodes()
    local f=WORK.frame
    if not f or not f.authority then return {} end
    return {[f.world]=f.gm}
end

local function is_host_world(actor, hostWorlds)
    local world = world_address(actor)
    return world ~= nil and hostWorlds[world] ~= nil
end

local function pawn_player_flag(pawn)
    local ok, isPlayer = call(pawn, "IsPlayerControlled")
    if ok and type(isPlayer) == "boolean" then return isPlayer end
    return nil  -- Unknown is NOT considered safe for changing NPC behavior.
end

local function host_npc_pawns(hostWorlds)
    local results = {}
    local pawns = dense_list("Pawn")
    for pawnIndex=1,#pawns do
        local pawn=rawget(pawns,pawnIndex)
        if is_valid(pawn) and is_host_world(pawn, hostWorlds) then
            local okAuth, hasAuth = call(pawn, "HasAuthority")
            local player = pawn_player_flag(pawn)
            local cls = class_name(pawn)
            if okAuth and hasAuth == true and player == false
                and not contains_any(cls, EXCLUDE_WORDS) then
                results[#results+1] = pawn
            end
        end
    end
    return results, #pawns
end

local STRONG_ENEMY_WORDS = {"monster", "enemy", "entity", "banshee", "ghost", "creature", "witch", "stalker", "boss", "horror", "puppet"}

local function is_ai_controller(controller)
    if not is_valid(controller) then return false end
    local name = string.lower(class_name(controller))
    if name == "aicontroller" or name:find("aicontroller", 1, true)
        or name:find("^bp_ai") or name:find("_ai_", 1, true)
        or name:find("_ai_c", 1, true) then return true end
    local ok, yes = call(controller, "IsA", "/Script/AIModule.AIController")
    return ok and yes == true
end

local function select_targets(worlds)
    local candidates, total = host_npc_pawns(worlds)
    log("F6 target search: loaded pawns=" .. total .. ", safe non-player host pawns=" .. #candidates)
    local known, inferred, strong = {}, {}, {}
    for pawnIndex=1,#candidates do
        local pawn=rawget(candidates,pawnIndex)
        local pname = class_name(pawn)
        local _, ctrl = call(pawn, "GetController")
        local cname = class_name(ctrl)
        local verified = false
        for _, pair in ipairs(SETTINGS.KnownEnemyPairs) do
            if pname == pair.pawn and cname == pair.controller and is_ai_controller(ctrl) then
                known[#known+1] = pawn
                verified = true
                log("Recognized hostile actor: " .. pname .. " / " .. cname .. " " .. full_name(pawn))
                break
            end
        end
        if is_ai_controller(ctrl) and not verified then
            inferred[#inferred+1] = pawn
            log("Unrecognized AI candidate (not yet trusted): " .. pname .. " / " .. cname .. " " .. full_name(pawn))
            if contains_any(pname, STRONG_ENEMY_WORDS) then strong[#strong+1] = pawn end
        end
    end

    -- Known types can spawn together on PANICORE+ and on random-entity maps.
    -- Unknown NPCs and scripted jump-scares are never added automatically to a known group.
    if #known > 0 then
        if #known > SETTINGS.MaxTargets then
            return nil, "Too many recognized monsters (" .. #known .. "); refused to freeze over limit."
        end
        if #inferred > 0 then
            log("SAFETY: leaving " .. #inferred .. " unrecognized AI NPC(s) untouched.")
        end
        return known, "recognized hostile class/controller pairs"
    end
    -- One unknown enemy is a provisional fallback, preserving previous behavior.
    if #inferred == 1 then
        return {inferred[1]}, "unique AI-controlled NPC (unverified fallback)"
    end
    if #strong == 1 then
        return {strong[1]}, "single strongly enemy-named AI NPC (unverified fallback)"
    end
    if #inferred == 0 then
        return nil, "No recognized monster or credible AI pawn; see log after exit."
    end
    return nil, "Ambiguous unrecognized AI enemies (" .. #inferred .. "); see log after exit."
end

local function get_movement(pawn)
    local _, move = call(pawn, "GetCharacterMovement")
    if not is_valid(move) then move = property(pawn, "CharacterMovement") end
    if not is_valid(move) then return nil end
    return move
end

local function get_brain(pawn)
    local _, ctrl = call(pawn, "GetController")
    if not is_valid(ctrl) then return nil, nil end
    local brain = property(ctrl, "BrainComponent")
    if not is_valid(brain) then
        local _, result = call(ctrl, "GetBrainComponent")
        brain = result
    end
    return ctrl, (is_valid(brain) and brain or nil)
end


-- No speculative timer or Blueprint spawn hooks in this build.

local function freeze_target(pawn)
    local record = {
        world = world_address(pawn),
        name = full_name(pawn),
        moveName = nil,
        oldMode = nil,
        oldCustomMode = 0,
        brainName = nil,
        brainAction = nil,
        active = true,
    }
    local ctrl, brain = get_brain(pawn)
    if brain then
        local okPause = call(brain, "PauseLogic", freezeReason)
        if okPause then
            record.brainName, record.brainAction = full_name(brain), "pause"
            log("Brain logic paused.")
        else
            local okStop = call(brain, "StopLogic", freezeReason)
            if okStop then
                record.brainName, record.brainAction = full_name(brain), "stop"
                log("Brain logic stopped (restart required on unfreeze).")
            else
                log("AI Brain pause/stop methods unavailable; continuing to movement method.")
            end
        end
    else
        log("No accessible AI BrainComponent on pawn controller.")
    end

    local move = get_movement(pawn)
    if move then
        local original = property(move, "MovementMode")
        local custom = property(move, "CustomMovementMode")
        -- Never call DisableMovement if the old movement mode is not readable:
        -- we must be able to restore it, including flying or custom monsters.
        if type(original) == "number" then
            local okDisable = call(move, "DisableMovement")
            if okDisable then
                record.moveName = full_name(move)
                record.oldMode = original
                record.oldCustomMode = type(custom) == "number" and custom or 0
                log("Character movement disabled; prior movement mode=" .. tostring(original))
            else
                log("DisableMovement unavailable on this pawn.")
            end
        else
            log("MovementMode not numeric/readable; leaving movement component unchanged.")
        end
    else
        log("No CharacterMovement component (monster may use custom movement).")
    end

    if ctrl and (record.brainAction ~= nil or record.moveName ~= nil) then
        local okStop = call(ctrl, "StopMovement")
        if okStop then log("Existing AI path movement cancelled.") end
    end

    if record.brainAction == nil and record.moveName == nil then
        return nil, "Freeze unsupported on this actor so far; diagnostics needed."
    end
    record.startPos = get_position(pawn)
    log("FREEZE start position=" .. posstr(record.startPos) .. ", initial mode=" .. tostring(property(move, "MovementMode")))
    -- No delayed actor telemetry. Keeping a raw UE4SS UObject in a scheduled
    -- callback after despawn/map-change can cause a native access violation.
    -- F6 now logs only the synchronous result; visual confirmation is still required.
    return record, nil
end

local function unfreeze_target(record, pawn)
    if not is_valid(pawn) or full_name(pawn)~=record.name or world_address(pawn)~=record.world then return false end
    local success=true
    if record.moveName then
        local move=get_movement(pawn)
        if is_valid(move) and full_name(move)==record.moveName then
            local ok=call(move,"SetMovementMode",record.oldMode,record.oldCustomMode)
            success=ok and property(move,"MovementMode")==record.oldMode and success
        else success=false end
    end
    if record.brainAction then
        local _,brain=get_brain(pawn)
        if is_valid(brain) and full_name(brain)==record.brainName then
            local ok
            if record.brainAction=="pause" then ok=call(brain,"ResumeLogic",freezeReason)
            else ok=call(brain,"RestartLogic") end
            success=ok and success
        else success=false end
    end
    log("UNFREEZE "..record.name.." restored="..tostring(success))
    return success
end

local function remove_stale_records(worlds)
    local current={}
    local pawns=host_npc_pawns(worlds)
    for i=1,#pawns do
        local pawn=pawns[i]
        current[full_name(pawn)]=pawn
    end
    local live={}
    for _,record in ipairs(frozenRecords) do
        if current[record.name] and record.world==world_address(current[record.name]) then
            live[#live+1]=record
        else
            record.active=false
            log("STALE FREEZE metadata discarded: "..tostring(record.name))
        end
    end
    frozenRecords=live
    return current
end

local function toggle_freeze()
    local worlds = authoritative_gamemodes()
    if next(worlds) == nil then
        log("F6 BLOCKED: no authoritative GameMode. Only host inside a loaded map may control monsters.")
        return
    end
    local current=remove_stale_records(worlds)

    if #frozenRecords > 0 then
        local remaining, restoredCount = {}, 0
        log("F6 -> UNFREEZE ALL recognized monsters (" .. #frozenRecords .. ").")
        for _, record in ipairs(frozenRecords) do
            local pawn=current[record.name]
            local okAuth, authority = call(pawn, "HasAuthority")
            if is_valid(pawn) and is_host_world(pawn,worlds) and okAuth and authority == true then
                log("UNFREEZE requested: " .. record.name)
                if unfreeze_target(record,pawn) then
                    record.active = false
                    restoredCount = restoredCount + 1
                else
                    remaining[#remaining+1] = record
                    log("UNFREEZE INCOMPLETE: " .. record.name .. "; F6 can retry or restart the map.")
                end
            else
                record.active = false
                log("STALE FREEZE skipped during unfreeze; actor changed state: " .. record.name)
            end
        end
        frozenRecords = remaining
        log("UNFREEZE BATCH: restored=" .. restoredCount .. " remaining=" .. #remaining)
        return
    end

    local targets, reason = select_targets(worlds)
    if not targets then
        log("F6 BLOCKED: " .. tostring(reason))
        return
    end
    local applied = 0
    for _, target in ipairs(targets) do
        local okAuth, authority = call(target, "HasAuthority")
        if not is_valid(target) or not is_host_world(target, worlds)
            or not okAuth or authority ~= true or pawn_player_flag(target) ~= false then
            log("FREEZE SKIPPED: actor is no longer safely controlled by host: " .. full_name(target))
        else
            log("F6 -> FREEZE attempt: " .. full_name(target) .. ", selection=" .. tostring(reason))
            local record, why = freeze_target(target)
            if record then
                frozenRecords[#frozenRecords+1] = record
                applied = applied + 1
                -- Asset-guided intervention runs only on F6 after the basic freeze is applied.
                -- Timer manipulation retired after v0.10.6 failed to stop respawns.
                log("FREEZE COMMAND APPLIED: " .. record.name)
            else
                log("FREEZE FAILED: " .. tostring(why))
            end
        end
    end
    log("FREEZE BATCH: " .. applied .. "/" .. #targets .. " recognized monsters commanded to stop.")
    if applied > 0 then
        log("Verify monsters actually stop; multiplayer replication to clients remains untested.")
    end
end

-- Read LOCAL host player pawn only. Never select a random player character or Chris.
local function local_host_pawn(worlds)
    local f=WORK.frame
    if not f or not f.authority or not worlds[f.world] then return nil,"no authoritative local world" end
    local pawn=f.pawn
    if not is_valid(pawn) or pawn_player_flag(pawn)~=true then return nil,"local player not ready" end
    local ok,auth=call(pawn,"HasAuthority")
    if not ok or auth~=true then return nil,"local pawn has no authority" end
    return pawn,nil
end

local function get_collision(pawn)
    local ok, value = call(pawn, "GetActorEnableCollision")
    if ok and type(value) == "boolean" then return value end
    return nil
end

local function restore_noclip(record)
    local f=WORK.frame
    local pawn=f and f.pawn or nil
    if not is_valid(pawn) or full_name(pawn)~=record.name or f.world~=record.world then return false end
    local move=get_movement(pawn)
    if not is_valid(move) then return false end
    local okC=call(pawn,"SetActorEnableCollision",record.oldCollision)
    local okM=call(move,"SetMovementMode",record.oldMode,record.oldCustomMode)
    log("NOCLIP OFF: collision="..tostring(get_collision(pawn)).." mode="..tostring(property(move,"MovementMode")))
    return okC and okM and get_collision(pawn)==record.oldCollision and property(move,"MovementMode")==record.oldMode
end

-- Key-down polling is necessary: UE4SS RegisterKeyBind only fires on key press,
-- and cannot detect the key being held or released. Unreal PlayerController's
-- IsInputKeyDown accepts an FKey table with KeyName = FName (from UEHelpers).
-- The poll loop is started ONLY for the locally authoritative player during
-- noclip; it ends on toggle OFF, actor replacement, or mod unload.
local function make_unreal_key(keyName)
    local ok, key = pcall(function()
        if hasUEHelpers and type(UEHelpers.FindOrAddFName) == "function" then
            return UEHelpers.FindOrAddFName(keyName)
        end
        return FName(keyName, EFindName and EFindName.FNAME_Add or nil)
    end)
    if ok and key ~= nil then return { KeyName = key } end
    return nil
end

local function read_input_key(pc, unrealKey)
    if unrealKey == nil then return nil end
    local ok, pressed = call(pc, "IsInputKeyDown", unrealKey)
    if ok and type(pressed) == "boolean" then return pressed end
    -- Some older UE4SS bindings prefer the FName directly.
    if unrealKey.KeyName ~= nil then
        ok, pressed = call(pc, "IsInputKeyDown", unrealKey.KeyName)
        if ok and type(pressed) == "boolean" then return pressed end
    end
    return nil
end

local function stop_altitude(record, reason)
    clear_job("altitude")
    if record and record.verticalDirection and record.verticalDirection ~= 0 then
        log("ALTITUDE HOVER (" .. tostring(reason) .. ")")
    end
    if record then record.verticalDirection = 0 end
end

local function start_altitude_poll(record)
    local spaceKey=make_unreal_key("SpaceBar")
    local leftKey=make_unreal_key("LeftControl")
    local rightKey=make_unreal_key("RightControl")
    set_job("altitude",50,function()
        if noclip~=record then clear_job("altitude"); return end
        local f=WORK.frame
        if not f or not f.authority then return end
        local pawn=f.pawn
        if not is_valid(pawn) then return end
        if full_name(pawn)~=record.name or f.world~=record.world then
            stop_altitude(record,"player replaced"); noclip=nil; return
        end
        local move=get_movement(pawn)
        if not is_valid(move) then return end
        if property(move,"MovementMode")~=5 or get_collision(pawn)~=false then
            stop_altitude(record,"game changed movement state"); return
        end
        local up=read_input_key(f.pc,spaceKey)
        local left=read_input_key(f.pc,leftKey)
        local right=read_input_key(f.pc,rightKey)
        if up==nil or (left==nil and right==nil) then
            stop_altitude(record,"key query unavailable"); return
        end
        local down=left==true or right==true
        local direction=(up and not down) and 1 or ((down and not up) and -1 or 0)
        if direction~=record.verticalDirection then
            record.verticalDirection=direction
            log("ALTITUDE "..(direction==1 and "ASCEND" or direction==-1 and "DESCEND" or "HOVER"))
        end
        if direction~=0 then
            local pos=get_position(pawn)
            if not pos then return end
            local target={X=pos.x,Y=pos.y,Z=pos.z+direction*SETTINGS.AltitudeSpeedCmPerSec*0.05}
            local ok,result=call(pawn,"K2_SetActorLocation",target,false,{},true)
            if not ok or result==false then stop_altitude(record,"position update failed") end
        end
    end)
    log("ALTITUDE enabled in shared game-thread loop: Space up / Ctrl down / release hover.")
end

-- Emergency return target: prefer the host controller's actual StartSpot, then
-- a level PlayerStart nearest to the first grounded noclip activation, then a
-- GameMode-chosen PlayerStart. The first grounded F7 position is retained as a
-- fallback (not guaranteed to be the original spawn). Never teleport to (0,0,0)
-- solely because the spawn point cannot be found.
local function finite_position(pos)
    return pos and pos.x == pos.x and pos.y == pos.y and pos.z == pos.z
        and math.abs(pos.x) < 10000000 and math.abs(pos.y) < 10000000
        and math.abs(pos.z) < 10000000
end

local function get_rotation(actor)
    local ok, rot = call(actor, "K2_GetActorRotation")
    if ok and rot ~= nil then
        local yes,result=pcall(function() return {Pitch=tonumber(rot.Pitch) or 0,Yaw=tonumber(rot.Yaw) or 0,Roll=tonumber(rot.Roll) or 0} end)
        if yes then return result end
    end
    return { Pitch=0, Yaw=0, Roll=0 }
end

local function candidate_spawn(actor, worlds, label)
    if not is_valid(actor) or not is_host_world(actor, worlds) then return nil end
    local pos = get_position(actor)
    if not finite_position(pos) then return nil end
    return { pos=pos, rot=get_rotation(actor), source=label }
end

local function capture_spawn_anchor(pawn, worlds, allowFirstSafePosition)
    local world = world_address(pawn)
    if not world or not worlds[world] then return nil end
    if spawnAnchor and spawnAnchor.world == world then return spawnAnchor end
    spawnAnchor = nil  -- never reuse a spawn from the previous loaded map

    local current = get_position(pawn)
    local move = get_movement(pawn)
    local walking = (move and property(move, "MovementMode") == 1)
    local colliding = (get_collision(pawn) == true)
    local fallback = nil
    if allowFirstSafePosition and walking and colliding and finite_position(current) then
        fallback = {pos=current, rot=get_rotation(pawn), source="first grounded F7 position"}
    end

    local pc = WORK.frame and WORK.frame.pc or nil
    local primary = nil
    if pc then
        primary = candidate_spawn(property(pc, "StartSpot"), worlds, "PlayerController.StartSpot")
    end
    if not primary then
        -- A small one-time global lookup on the FIRST F7 for each loaded map,
        -- never a continuous scan. The list is confined to this authoritative UWorld.
        local starts = dense_list("PlayerStart")
        local bestDistance = math.huge
        for startIndex=1,#starts do
            local start=rawget(starts,startIndex)
            local result = candidate_spawn(start, worlds, "nearest PlayerStart")
            if result then
                local d = finite_position(current) and distance3(current, result.pos) or 0
                if d < bestDistance then primary, bestDistance = result, d end
            end
        end
    end
    if not primary and pc then
        local gameMode = worlds[world]
        local ok, start = call(gameMode, "K2_FindPlayerStart", pc, "")
        if ok then primary = candidate_spawn(start, worlds, "GameMode.FindPlayerStart") end
    end
    if not primary and not fallback then
        log("SPAWN ANCHOR unavailable: no valid PlayerStart and no grounded first-F7 position. Refusing unsafe coordinates.")
        return nil
    end
    spawnAnchor = {
        world=world, primary=primary or fallback, fallback=fallback,
    }
    log("SPAWN ANCHOR saved: " .. spawnAnchor.primary.source .. " at " .. posstr(spawnAnchor.primary.pos) ..
        (fallback and ("; safe fallback=" .. posstr(fallback.pos)) or "; no grounded fallback"))
    return spawnAnchor
end

-- One press sends the locally controlled host Pawn to its spawn anchor, without
-- calling RestartPlayer, touching saves, or respawning teammates. This is a
-- teleport and movement-state recovery, not a level restart.
local function rescue_player()
    if type(rescueCooldown)=="number" and WORK.now<rescueCooldown then return end
    rescueCooldown=WORK.now+700
    local worlds = authoritative_gamemodes()
    if next(worlds) == nil then
        log("F8 RESCUE BLOCKED: no host-authoritative world. Enter a hosted level.")
        return
    end
    local pawn, err = local_host_pawn(worlds)
    if not pawn then
        log("F8 RESCUE BLOCKED: " .. tostring(err))
        return
    end
    local anchor = capture_spawn_anchor(pawn, worlds, false)
    if not anchor then
        log("F8 RESCUE BLOCKED: no safe spawn recorded for this map. Never using arbitrary 0,0,0.")
        return
    end
    local move = get_movement(pawn)
    if not move then
        log("F8 RESCUE BLOCKED: local player movement component unavailable.")
        return
    end
    local clipRecord = noclip and noclip.name == full_name(pawn) and noclip.world == world_address(pawn) and noclip or nil
    local before = get_position(pawn)
    local function try_destination(dest)
        if not dest or not finite_position(dest.pos) then return false end
        local location = {X=dest.pos.x, Y=dest.pos.y, Z=dest.pos.z}
        local ok, applied = call(pawn, "K2_TeleportTo", location, dest.rot or get_rotation(pawn))
        local arrived = get_position(pawn)
        local distance = distance3(arrived, dest.pos)
        if ok and applied ~= false and distance and distance < 300 then
            log("F8 TELEPORT confirmed: " .. dest.source .. " at " .. posstr(arrived) ..
                ", distance_cm=" .. string.format("%.1f", distance))
            return true
        end
        log("F8 TELEPORT failed: " .. dest.source .. "; API_ok=" .. tostring(ok) ..
            " result=" .. tostring(applied) .. " actual=" .. posstr(arrived))
        return false
    end
    local reached = try_destination(anchor.primary)
    if not reached and anchor.fallback
        and distance3(anchor.primary.pos, anchor.fallback.pos) > 5 then
        reached = try_destination(anchor.fallback)
    end
    if not reached then
        log("F8 RESCUE FAILED: no successful safe teleport; original noclip/physics state preserved.")
        return
    end

    -- Restore floor collision BEFORE restarting gravity. If restoration fails,
    -- stay airborne (don't force MOVE_Walking with collision disabled).
    local collisionOK = call(pawn, "SetActorEnableCollision", true)
    if not collisionOK or get_collision(pawn) ~= true then
        log("F8 RESCUE PARTIAL: returned to start but collision could not be restored; retry F7 or relaunch map.")
        return
    end
    call(move, "StopMovementImmediately")
    local modeOK = call(move, "SetMovementMode", 1, 0) -- MOVE_Walking
    if not modeOK or property(move, "MovementMode") ~= 1 then
        log("F8 RESCUE PARTIAL: arrived with collision enabled, but Walking mode was not confirmed.")
        return
    end
    call(move, "StopMovementImmediately")
    if clipRecord then
        stop_altitude(clipRecord, "F8 returned to spawn")
        noclip = nil
    elseif noclip and (noclip.name ~= full_name(pawn) or noclip.world~=world_address(pawn)) then
        stop_altitude(noclip, "stale pawn at F8 rescue")
        noclip = nil
    end
    log("F8 RESCUE COMPLETE: from " .. posstr(before) .. " to " .. posstr(get_position(pawn)) ..
        "; collision ON; WALKING; noclip OFF; map and progress preserved.")
end

local function toggle_noclip()
    -- Restore the previous pawn when possible, even if its position is outside map bounds.
    if noclip then
        -- Check the current game-controlled player before dereferencing the old
        -- noclip pawn: the game may have replaced the actor during a map load.
        local worldsNow = authoritative_gamemodes()
        local livePawn = local_host_pawn(worldsNow)
        if not livePawn or full_name(livePawn)~=noclip.name or world_address(livePawn)~=noclip.world then
            log("NOCLIP previous pawn replaced; forgetting stale record safely.")
            stop_altitude(noclip, "local pawn changed")
            noclip = nil
            return
        end
        if restore_noclip(noclip) then
            stop_altitude(noclip, "noclip disabled")
            noclip = nil
            log("F7 noclip OFF. Outside the map? Normal gravity may make you fall or respawn.")
        else
            log("F7 noclip restore INCOMPLETE. Press F7 to retry, or exit the map.")
        end
        return
    end
    local worlds = authoritative_gamemodes()
    if next(worlds) == nil then log("F7 BLOCKED: host GameMode world missing."); return end
    local pawn, err = local_host_pawn(worlds)
    if not pawn then log("F7 BLOCKED: " .. err); return end
    local move = get_movement(pawn)
    if not move then log("F7 BLOCKED: host player CharacterMovement missing."); return end
    local priorMode = property(move, "MovementMode")
    local customMode = property(move, "CustomMovementMode")
    local priorCollision = get_collision(pawn)
    if type(priorMode) ~= "number" or type(priorCollision) ~= "boolean" then
        log("F7 BLOCKED: cannot read original movement or collision state for safe restoration.")
        return
    end
    local record = {
        name=full_name(pawn), world=world_address(pawn), oldMode=priorMode, oldCustomMode=(type(customMode)=="number" and customMode or 0),
        oldCollision=priorCollision, startPos=get_position(pawn)
    }
    capture_spawn_anchor(pawn, worlds, true)
    -- UE EMovementMode: 5 = MOVE_Flying, ignores gravity (prevents falling when
    -- floor collision is off). We do not try to claim floor collision remains.
    local flying = 5
    local okFlight = call(move, "SetMovementMode", flying, 0)
    if not okFlight or property(move, "MovementMode") ~= flying then
        log("F7 BLOCKED: SetMovementMode(Flying) failed; restoring original mode.")
        call(move, "SetMovementMode", record.oldMode, record.oldCustomMode)
        return
    end
    local okOff = call(pawn, "SetActorEnableCollision", false)
    if not okOff or get_collision(pawn) ~= false then
        log("F7 BLOCKED: collision-off failed, restoring original player movement/collision.")
        call(pawn, "SetActorEnableCollision", priorCollision)
        call(move, "SetMovementMode", record.oldMode, record.oldCustomMode)
        return
    end
    call(move,"StopMovementImmediately")
    noclip = record
    record.verticalDirection = 0
    log("F7 NOCLIP ON: host pawn=" .. class_name(pawn) .. " position=" .. posstr(record.startPos) ..
        " prior_mode=" .. tostring(priorMode) .. " prior_collision=" .. tostring(priorCollision) ..
        "; Flying=5, collision=false. Altitude is gravity-free, not physical floor support.")
    start_altitude_poll(record)
    -- No delayed noclip actor telemetry: a map transition may destroy the
    -- underlying object before the callback fires. Current input poll is enough.
end

local function register_control(key,label,fn)
    WORK.handlers[label]=fn
    RegisterKeyBind(key,function() enqueue(label) end)
end

-- v0.11.4: Military Base lockdown (no native event hook or repeated timer reflection). Retains F6 intent across replacement actors.
-- Uses GS_Main.SlenderLikes instead of periodic FindAllOf(Pawn) object scans.
-- Only string/number/boolean state is retained between ticks; no cached monster UObjects.
-- Pure game-state watchdog; no native BeginPlay or Blueprint event hooks.
local PHC_LOCK = {
    enabled = false,
    generation = 0,
    worldKey = nil,
    records = {},
    ticks = 0,
    sawArray = false,
    logNoArray = false,
}
local LOCK_TAG = "[PHC LOCK v0.11.4] "
local function lock_log(s) print(LOCK_TAG .. tostring(s) .. "\n") end

local function current_lock_context()
    local f=WORK.frame
    if not f or not f.authority or not is_valid(f.gs) then return nil,"host world not ready" end
    return {gs=f.gs,gm=f.gm,me=f.pawn,world=f.world,map=f.map},nil
end

local function unwrap_array_obj(raw)
    if is_valid(raw) then return raw end
    if raw == nil then return nil end
    local ok, obj = pcall(function() return raw:get() end)
    if ok and is_valid(obj) then return obj end
    return nil
end

local function game_state_stalkers(ctx)
    local array = property(ctx.gs, "SlenderLikes")
    if array == nil then return nil, "GS_Main.SlenderLikes unavailable" end
    local okN, count = pcall(function() return #array end)
    if not okN or type(count) ~= "number" or count < 0 or count > 32 then
        return nil, "SlenderLikes array count invalid/unreadable"
    end
    local result = {}
    for i = 1, count do
        local ok, raw = pcall(function() return array[i] end)
        if ok then
            local actor = unwrap_array_obj(raw)
            if actor then result[#result+1] = actor end
        end
    end
    return result, nil
end

local function verified_stalker(actor, ctx)
    if not is_valid(actor) or class_name(actor) ~= "BP_SlenderLike_C" then return false end
    if not is_host_world(actor, {[ctx.world] = ctx.gm}) then return false end
    local okAuth, auth = call(actor, "HasAuthority")
    if not okAuth or auth ~= true or pawn_player_flag(actor) ~= false then return false end
    -- Once positively identified by class/controller pair, keep the record even if
    -- a scripted AI state transition temporarily drops its controller.
    local actorKey = full_name(actor)
    if PHC_LOCK.records[actorKey] ~= nil then return true end
    local _, c = call(actor, "GetController")
    return is_valid(c) and class_name(c) == "AI_SlenderLike_C"
end

local function lock_change_property(obj, name, oldValue, newValue)
    if not is_valid(obj) or oldValue == nil then return false end
    local ok = pcall(function() obj[name] = newValue end)
    return ok
end

local LOCK_HITBOXES = {"KillBox", "CharacterTriggerCollision", "HitBoxAI"}
-- Stalker protection only uses the established movement/collision/range fields.

local function lockdown_apply(actor, ctx)
    if not verified_stalker(actor, ctx) then return false end
    local key = full_name(actor)
    if key == "<unknown>" then return false end
    local record = PHC_LOCK.records[key]
    local isNew = record == nil
    if isNew then
        record = {key=key, origMode=nil, origCustom=0, origCollision=nil,
                  origKillRange=nil, origAIActive=nil, comps={}}
        local movement = get_movement(actor)
        if is_valid(movement) then
            local mode=property(movement,"MovementMode")
            local custom=property(movement,"CustomMovementMode")
            if type(mode)=="number" then
                record.origMode=mode
                record.origCustom=type(custom)=="number" and custom or 0
            end
        end
        local okCol,col=call(actor,"GetActorEnableCollision")
        if okCol and type(col)=="boolean" then record.origCollision=col end
        local kr=property(actor,"KillRange")
        if type(kr)=="number" and kr >= 0 and kr <= 100000 then record.origKillRange=kr end
        local ai=property(actor,"AIActive")
        if type(ai)=="boolean" then record.origAIActive=ai end
        for _,field in ipairs(LOCK_HITBOXES) do
            local component=property(actor,field)
            if is_valid(component) then
                local okMode,old=call(component,"GetCollisionEnabled")
                if okMode and type(old)=="number" then
                    record.comps[field]=old
                end
            end
        end
        PHC_LOCK.records[key] = record
        lock_log("LOCKED NEW STALKER: "..key)
    end
    local move=get_movement(actor)
    if is_valid(move) and record.origMode ~= nil then
        local current=property(move,"MovementMode")
        if type(current)=="number" and current ~= 0 then
            local ok = call(move,"DisableMovement")
            if ok then lock_log((isNew and "Movement frozen: " or "Re-froze movement: ")..key) end
        end
    end
    local _,ctrl=call(actor,"GetController")
    if isNew and is_valid(ctrl) then call(ctrl,"StopMovement") end
    if record.origCollision ~= nil then
        local ok,coll=call(actor,"GetActorEnableCollision")
        if ok and coll ~= false then
            local disabled = call(actor,"SetActorEnableCollision",false)
            if isNew then lock_log("Attack collision OFF command="..tostring(disabled).." for "..key) end
        end
    end
    for field,_ in pairs(record.comps) do
        local component=property(actor,field)
        if is_valid(component) then
            local ok,mode=call(component,"GetCollisionEnabled")
            if ok and type(mode)=="number" and mode ~= 0 then call(component,"SetCollisionEnabled",0) end
        end
    end
    if record.origKillRange ~= nil and record.origKillRange ~= 0 then
        local cur=property(actor,"KillRange")
        if type(cur)=="number" and cur ~= 0 then
            local changed=lock_change_property(actor,"KillRange",cur,0)
            if isNew then lock_log("KillRange zeroing="..tostring(changed).." for "..key) end
        end
    end
    if record.origAIActive ~= nil then
        local cur=property(actor,"AIActive")
        if cur == true then lock_change_property(actor,"AIActive",true,false) end
    end
    return true
end

local function lockdown_restore(actor, ctx)
    if not verified_stalker(actor,ctx) then return false end
    local key=full_name(actor)
    local record=PHC_LOCK.records[key]
    if record==nil then return false end
    -- Re-enable hit detectors and attack range before restoring normal movement.
    for field,prior in pairs(record.comps) do
        local component=property(actor,field)
        if is_valid(component) then call(component,"SetCollisionEnabled",prior) end
    end
    if record.origCollision ~= nil then call(actor,"SetActorEnableCollision",record.origCollision) end
    if record.origKillRange ~= nil then
        lock_change_property(actor,"KillRange",0,record.origKillRange)
    end
    if record.origAIActive ~= nil then
        lock_change_property(actor,"AIActive",false,record.origAIActive)
    end
    local move=get_movement(actor)
    if record.origMode ~= nil and is_valid(move) then
        call(move,"SetMovementMode",record.origMode,record.origCustom)
    end
    PHC_LOCK.records[key] = nil
    lock_log("RESTORED STALKER: "..key)
    return true
end

local function lockdown_tick()
    if not PHC_LOCK.enabled then return end
    local ctx,why=current_lock_context()
    if not ctx then return end -- brief load/death gap is not proof of a new world
    if ctx.world ~= PHC_LOCK.worldKey or ctx.map ~= "MilitaryBase" then
        lock_log("Level/authority changed; dropping stale freeze intent and references: "..tostring(why or (ctx and ctx.map)))
        PHC_LOCK.enabled=false
        PHC_LOCK.generation=PHC_LOCK.generation+1
        PHC_LOCK.records={}
        return
    end
    local stalkers,err=game_state_stalkers(ctx)
    if stalkers==nil then
        if not PHC_LOCK.logNoArray then lock_log("NO GAME-STATE LIST: "..tostring(err).."; refusing unsafe periodic global scans") end
        PHC_LOCK.logNoArray=true
        return
    end
    PHC_LOCK.sawArray=true
    local seen={}
    local affected=0
    for stalkerIndex=1,#stalkers do
        local stalker=rawget(stalkers,stalkerIndex)
        if affected>=8 then break end
        if verified_stalker(stalker,ctx) then
            local key=full_name(stalker)
            seen[key]=true
            if lockdown_apply(stalker,ctx) then affected=affected+1 end
        end
    end
    -- Forget metadata for actors the game removed. No IsValid() calls on stale UObjects.
    for key,_ in pairs(PHC_LOCK.records) do
        if not seen[key] then
            PHC_LOCK.records[key]=nil
            lock_log("Despawned while locked; F6 stays ON for replacements: "..key)
        end
    end
    PHC_LOCK.ticks=PHC_LOCK.ticks+1
    if PHC_LOCK.ticks%50==1 then
        lock_log(string.format("LOCKDOWN heartbeat: game-state list=%d, verified=%d, F6=ON",#stalkers,affected))
    end
end

local function lockdown_queue_next(gen)
    set_job("lockdown",300,function()
        if not PHC_LOCK.enabled or PHC_LOCK.generation~=gen then clear_job("lockdown"); return end
        lockdown_tick()
    end)
end

local function lockdown_unhook() clear_job("lockdown") end
local function lockdown_install_hook()
    lock_log("Native spawn hooks OFF; stalker work runs in the single recurring game-thread dispatcher.")
end

local function lockdown_toggle()
    if PHC_LOCK.enabled then
        PHC_LOCK.enabled=false
        PHC_LOCK.generation=PHC_LOCK.generation+1
        lockdown_unhook()
        local ctx=current_lock_context()
        local count=0
        if ctx and ctx.map=="MilitaryBase" and ctx.world==PHC_LOCK.worldKey then
            local live=game_state_stalkers(ctx)
            if live then
                for stalkerIndex=1,#live do
                    local stalker=rawget(live,stalkerIndex)
                    if lockdown_restore(stalker,ctx) then count=count+1 end
                end
            end
        end
        lock_log("F6 LOCKDOWN OFF: restored="..count.." active monster(s). Level respawn may be needed if the game removed earlier instances")
        PHC_LOCK.records={}
        PHC_LOCK.worldKey=nil
        return
    end
    local ctx,why=current_lock_context()
    if not ctx or ctx.map~="MilitaryBase" then
        lock_log("F6 MilitaryBase lockdown not available here: "..tostring(why or (ctx and ctx.map)))
        return
    end
    PHC_LOCK.enabled=true
    PHC_LOCK.generation=PHC_LOCK.generation+1
    PHC_LOCK.records={}
    PHC_LOCK.worldKey=ctx.world
    PHC_LOCK.ticks=0
    PHC_LOCK.sawArray=false
    PHC_LOCK.logNoArray=false
    lock_log("F6 LOCKDOWN ON: will remain enabled through despawns and new spawns until F6 OFF")
    lockdown_install_hook()
    local ok,whyTick=xpcall(lockdown_tick,debug.traceback)
    if not ok then lock_log("Initial lockdown error: "..tostring(whyTick)) end
    lockdown_queue_next(PHC_LOCK.generation)
end

local function phc_f6_dispatch()
    if PHC_LOCK.enabled then lockdown_toggle(); return end
    local ctx=current_lock_context()
    if ctx and ctx.map=="MilitaryBase" then
        lockdown_toggle()
        return
    end
    toggle_freeze()
end


register_control(Key.F6, "F6", phc_f6_dispatch)
register_control(Key.F7, "F7", toggle_noclip)
register_control(Key.F8, "F8", rescue_player)
log("Core controls: F6 freeze-all / MilitaryBase persistent lockdown | F7 NOCLIP (Space UP / Ctrl DOWN; release HOVER) | F8 RETURN TO START. F5 top-down radar toggles a local Windows viewer.")
log("Known enemies: Puppet, Hospital, Banshee, Submarine, SlenderLike, SantaClown. Supports multiple verified monsters in any map.")
log("F8 recovers only the host player; records the true PlayerStart when available and the first grounded F7 position as fallback.")






-- Immutable identifiers only; never dereference stale enemy UObjects for the radar.
local function frozen_actor_keys()
    local keys = {}
    for _, r in ipairs(frozenRecords) do
        if r.active == true and type(r.name) == "string" then keys[r.name] = true end
    end
    if PHC_LOCK.enabled then
        for name,_ in pairs(PHC_LOCK.records) do
            if type(name) == "string" then keys[name] = true end
        end
    end
    return keys
end

-- PHC heading-up radar 0.11.6. Lower-overhead updates, unchanged world-object semantics.
-- Progression inspection is READ-ONLY: do not fake achievement/counter results.
local function init_phc_radar()
    local TAG = '[PHC-RADAR v0.11.6] '
    local function note(s) print(TAG .. tostring(s) .. '\n') end
    local function list_of(unrealClass) return dense_list(unrealClass) end
    local function invoke(o, methodName, ...)
        if not o then return nil end
        local args = {...}
        local ok, result = pcall(function() return o[methodName](o, table.unpack(args)) end)
        if ok then return result end
        return nil
    end
    local function get(o, fieldName)
        local ok, result = pcall(function() return o[fieldName] end)
        if ok then return result end
        return nil
    end
    local function clean_label(s)
        return tostring(s or '?'):gsub('[\r\n\t|]',' '):sub(1,36)
    end
    local function printable(v)
        if v == nil then return 'nil' end
        if type(v)=='string' or type(v)=='number' or type(v)=='boolean' then return clean_label(v) end
        if type(v)=='table' then return '<table>' end
        local tostringMethod = invoke(v,'ToString')
        if type(tostringMethod)=='string' then return clean_label(tostringMethod) end
        return '<'..type(v)..'>'
    end

    -- UE4SS normally records the loaded source path as @.../Scripts/main.lua.
    -- We write only into our own mod directory, NOT PANICORE assets or saves.
    local source = (debug.getinfo(1,'S') or {}).source or ''
    source = source:gsub('^@',''):gsub('/','\\')
    local moddir = source:match('^(.*)\\[Ss]cripts\\main%.lua$')
    local snapshot = moddir and (moddir .. '\\RadarSnapshot.tsv') or 'PHC_RadarSnapshot.tsv'
    if moddir then
        pcall(function()
            local f=io.open(moddir..'\\ReportDirectory.txt','rb')
            if f then reportFolder=f:read('*l'); f:close() end
        end)
    end
    local allow_file = type(io)=='table' and type(io.open)=='function'
    local hadWriteError = false
    local function write_state(lines)
        if not allow_file then
            if not hadWriteError then note('Lua file I/O unavailable. Radar viewer cannot receive locations.'); hadWriteError=true end
            return
        end
        WORK.sequence=WORK.sequence+1
        local committed={}
        for i=1,#lines do committed[i]=lines[i] end
        committed[#committed+1]='END\t'..tostring(#lines)
        local ok, err = pcall(function()
            local f, openErr = io.open(snapshot,'wb')
            if not f then error(openErr or 'open failed') end
            f:write(table.concat(committed, '\n'),'\n')
            f:close()
        end)
        if not ok and not hadWriteError then
            note('Radar snapshot write failed: '..tostring(err))
            hadWriteError = true
        end
    end
    local radarOn = false
    write_state({'PHC2\t0\t-\tNA'})
    note('F5 radar: local snapshot bridge initialized; viewer launched separately by portable controller.')

    -- Category is a conservative type-based aid, NOT a claim that a route or
    -- puzzle still needs the item. Never hide a pickup just because it is yellow.
    local tokenToItem = {
        {'elevatorasylumkey','ELEVATOR KEY','IMPORTANT'}, {'elevatorkey','ELEVATOR KEY','IMPORTANT'},
        {'keycard','KEYCARD','IMPORTANT'}, {'codepaper','CODE','IMPORTANT'},
        {'doorhandle','HANDLE','IMPORTANT'}, {'generatorpart','GENERATOR','IMPORTANT'},
        {'circuitboard','CIRCUIT','IMPORTANT'}, {'screwdriver','SCREWDRIVER','IMPORTANT'},
        {'fuse','FUSE','IMPORTANT'}, {'cutter','CUTTER','IMPORTANT'}, {'key','KEY','IMPORTANT'},
        {'plank','PLANK','IMPORTANT'}, {'hammer','HAMMER','IMPORTANT'}, {'wrench','WRENCH','IMPORTANT'},
        {'rope','ROPE','IMPORTANT'}, {'crowbar','CROWBAR','IMPORTANT'},
        {'battery','BATTERY','OTHER'}, {'gasoline','GASOLINE','IMPORTANT'},
        {'canister','CANISTER','IMPORTANT'}, {'gear','GEAR','IMPORTANT'}, {'oxygen','OXYGEN','OTHER'},
        {'saw','SAW','IMPORTANT'}, {'wheel','WHEEL','IMPORTANT'}, {'pipe','PIPE','IMPORTANT'},
        {'valve','VALVE','IMPORTANT'}, {'lockpick','LOCKPICK','IMPORTANT'},
        {'fuel','FUEL','IMPORTANT'}, {'card','CARD','IMPORTANT'},
        {'flashlight','FLASHLIGHT','OTHER'}, {'medkit','MEDKIT','OTHER'},
        {'firstaid','FIRST AID','OTHER'}, {'bandage','BANDAGE','OTHER'},
        {'energydrink','ENERGY DRINK','OTHER'},
    }
    local function item_name(actor)
        local n = class_name(actor):lower()
        if n:find('character',1,true) or n:find('monster',1,true) or n:find('controller',1,true)
            or n:find('door_',1,true) or n:find('scare',1,true) or n:find('widget',1,true)
            or n:find('player',1,true) or n:find('keypad',1,true) or n:find('keyhole',1,true)
            or n:find('scenery',1,true) then return nil end
        -- A socket/holder/spawn marker is not the physical pickup. Do not use a
        -- broad "same label == same actor" filter: two batteries may be real.
        for _,word in ipairs({'socket','itemslot','batteryholder','batterycharger','spawnpoint','spawner','preview'}) do
            if n:find(word,1,true) then return nil end
        end
        for _,p in ipairs(tokenToItem) do
            if n:find(p[1],1,true) then
                local category=p[3]
                if p[1]=='battery' and (n:find('carbattery',1,true) or n:find('vehiclebattery',1,true)
                    or n:find('generatorbattery',1,true)) then category='IMPORTANT' end
                return p[2],category
            end
        end
        return nil
    end
    local function enemy_name(actor)
        local n=class_name(actor)
        for _,p in ipairs(SETTINGS.KnownEnemyPairs) do
            if n==p.pawn then
                local control=invoke(actor, 'GetController')
                if is_valid(control) and class_name(control)==p.controller then
                    return ({BP_Puppet_C='PUPPET',BP_AIMonsterCharacter_C='HOSPITAL',
                        BP_BansheeAI_C='BANSHEE',BP_Submarine_Monster_New_C='SUBMARINE',
                        BP_SlenderLike_C='STALKER',BP_SantaClown_C='SANTA'})[n] or n
                end
            end
        end
        return nil
    end
    -- Lifetime-safe radar: only NUMBERS and STRINGS survive between snapshots.
    -- In particular, itemCache must never hold live UE4SS actor references.
    local itemCache = {}
    local knownItems = {} -- identities only, never native actor/component handles
    local currentMap = ''
    local counter = 0
    local itemScanErrors = 0
    local scans = 0
    local pawnCoordinates={}
    local lastPawnRefresh=-1000
    local lastItemRefresh=-45000
    local lastPickupRefresh=-1000
    local lastCensus=''
    local function safe_position(actor)
        local pos = get_position(actor)
        if not pos or pos.x ~= pos.x or pos.y ~= pos.y or pos.z ~= pos.z then return nil end
        if math.abs(pos.x)>1e7 or math.abs(pos.y)>1e7 or math.abs(pos.z)>1e7 then return nil end
        return pos
    end
    local function clean_id(id)
        return tostring(id or ''):gsub('[\r\n\t]',' ')
    end
    local function append_coords(lines, kind, label, pos, frozen, category, identity)
        if not pos then return end
        lines[#lines+1] = string.format('%s\t%s\t%.1f\t%.1f\t%.1f\t%s\t%s\t%s',
            kind,clean_label(label),pos.x,pos.y,pos.z,frozen and 'FROZEN' or 'ACTIVE',
            category or '-',clean_id(identity))
    end
    local function radar_worlds() return authoritative_gamemodes() end
    local function actor_is_player(a)
        if not is_valid(a) then return false end
        local c=class_name(a)
        return c=='BP_Character_C' or c=='PC_Main_C' or pawn_player_flag(a)==true
    end
    local function pickup_state(a,record)
        if get(a,'bHidden')==true then return nil,'hidden' end
        -- A carried actor is no longer a world pickup, even if its hand mesh is
        -- still visible. Only follow attachment ancestry; ownership by itself
        -- is a networking concept and must NOT hide a dropped/world item.
        local canonical=record.key
        local parent=invoke(a,'GetAttachParentActor')
        local visited={}
        for depth=1,6 do
            if not is_valid(parent) then break end
            if actor_is_player(parent) then return nil,'attached-to-player' end
            local key=full_name(parent)
            if visited[key] then break end
            visited[key]=true
            local label=item_name(parent)
            if label==record.label and key~='<unknown>' then canonical=key end
            parent=invoke(parent,'GetAttachParentActor')
        end
        -- Check an actual root mesh, not an invisible collision root. Hidden
        -- collision/scene roots are normal in otherwise visible pickups.
        local root=invoke(a,'GetRootComponent')
        if is_valid(root) then
            local rc=class_name(root)
            if rc=='StaticMeshComponent' or rc=='SkeletalMeshComponent' then
                if get(root,'bVisible')==false or get(root,'bHiddenInGame')==true then return nil,'mesh-hidden' end
            end
        end
        local pos=safe_position(a)
        if not pos then return nil,'no-position' end
        return {key=canonical,source=record.key,label=record.label,category=record.category,
                x=pos.x,y=pos.y,z=pos.z},'world-pickup'
    end
    local function write_census(rows)
        if not reportFolder then return end
        local text=table.concat(rows,'\n')..'\n'
        if text==lastCensus then return end
        lastCensus=text
        pcall(function()
            local f=io.open(reportFolder..'\\RadarItems_Last.tsv','wb')
            if f then f:write(text); f:close() end
        end)
    end
    local function refresh_pickups(worlds)
        local found,byKey={},{}
        local census={'Category\tLabel\tStatus\tActorIdentity\tX\tY\tZ'}
        local alive={}
        for i=1,#knownItems do
            local record=rawget(knownItems,i)
            -- Resolve the current object by its full path each time. A name
            -- lookup does not resurrect destroyed objects or hold them alive.
            local ok,a=pcall(StaticFindObject,record.path)
            local row,reason=nil,'missing'
            if not ok then
                alive[#alive+1]=record -- retry a transient lookup error next refresh
                reason='lookup-error'
            elseif is_valid(a) and full_name(a)==record.key and is_host_world(a,worlds) then
                alive[#alive+1]=record
                local good,r,why=pcall(pickup_state,a,record)
                if good then row,reason=r,why else reason='read-error' end
            end
            if record.lastState~=reason then
                if record.lastState~=nil then note('PICKUP STATE '..reason..': '..record.key) end
                record.lastState=reason
            end
            census[#census+1]=table.concat({record.category,record.label,reason,clean_id(record.key),
                row and tostring(row.x) or '',row and tostring(row.y) or '',row and tostring(row.z) or ''},'\t')
            if row then
                local prior=byKey[row.key]
                if not prior then
                    found[#found+1]=row
                    byKey[row.key]=#found
                elseif row.source==row.key then
                    -- Prefer the pickup root to a child representation of it.
                    found[prior]=row
                end
            end
        end
        knownItems=alive
        itemCache=found
        write_census(census)
    end
    local function item_snapshot(worlds, map)
        -- Discovery stays at the v0.11.3 interval. Frequent refresh is a narrow
        -- full-path lookup of known pickups, NOT a repeated Actor world scan.
        local previous={}
        for i=1,#knownItems do previous[knownItems[i].key]=knownItems[i] end
        local found,seen={},{}
        operation_note('RADAR: collectible enumeration begin')
        local actors=list_of('Actor')
        local possible=0
        for actorIndex=1,#actors do
            local a=rawget(actors,actorIndex)
            local ok,label,category=pcall(item_name,a)
            if not ok then
                itemScanErrors=itemScanErrors+1
                if itemScanErrors<=3 then note('Skipped unsupported item class lookup: '..tostring(label)) end
            elseif label and is_valid(a) and is_host_world(a,worlds) then
                possible=possible+1
                local key=full_name(a)
                local path=key:match('^[^ ]+ (.+)$')
                if path and key~='<unknown>' and not seen[key] then
                    seen[key]=true
                    found[#found+1]={key=key,path=path,label=label,category=category or 'OTHER',
                        lastState=previous[key] and previous[key].lastState or nil}
                end
            end
        end
        table.sort(found,function(a,b) return a.key<b.key end)
        knownItems=found
        refresh_pickups(worlds)
        operation_note('RADAR: collectible enumeration complete')
        scans=scans+1
        if scans<=5 or (scans%10)==0 then
            note(string.format('RADAR ITEM SCAN %s: totalActors=%d examined=%d candidates=%d items=%d; known pickup refresh=1000ms',
                map,#actors,#actors,possible,#itemCache))
        end
    end
    local function build_snapshot()
        if not radarOn then return end
        local worlds = radar_worlds()
        if not next(worlds) then write_state({'PHC2\t1\tNO HOST WORLD\tNA'}); return end
        local me = local_host_pawn(worlds)
        if not is_valid(me) then write_state({'PHC2\t1\tWAITING FOR PLAYER\tNA'}); return end
        local map = full_name(me):match('/Game/Maps/([%w_]+)') or 'UNKNOWN MAP'
        local mapKey=map.."@"..tostring(WORK.world)
        if mapKey ~= currentMap then
            currentMap = mapKey
            itemCache = {}
            knownItems = {}
            lastCensus = ''
            lastPickupRefresh=-1000
            counter = 0
            pawnCoordinates={}
            lastPawnRefresh=-1000
            lastItemRefresh=-45000
        end
        counter = counter + 1
        local yaw=nil
        local yawSource='VIEW'
        local okRot,rot=call(WORK.frame.pc,'GetControlRotation')
        if okRot and rot then local ok,value=pcall(function() return tonumber(rot.Yaw) end); if ok then yaw=value end end
        if not yaw or yaw~=yaw or math.abs(yaw)>1e9 then
            yaw=nil
            local okBody,body=call(me,'K2_GetActorRotation')
            if okBody and body then
                local ok,value=pcall(function() return tonumber(body.Yaw) end)
                if ok and value and value==value and math.abs(value)<=1e9 then yaw=value; yawSource='BODY' end
            end
        end
        local output = {'PHC2\t1\t'..clean_label(map)..'\t'..(yaw and string.format('%.3f',yaw%360) or 'NA')..'\t'..yawSource}
        append_coords(output,'Y','YOU',safe_position(me),false)
        -- A single *current-tick* Pawn query supplies both enemies and players;
        -- NO references are retained for the next radar tick.
        local frozen = frozen_actor_keys()
        if WORK.now-lastPawnRefresh>=500 then
        local pawnLines={}
        local numEnemies, numPlayers = 0,0
        local livePawns=list_of('Pawn')
        for pawnIndex=1,#livePawns do
            local p=rawget(livePawns,pawnIndex)
            if is_valid(p) and is_host_world(p,worlds) then
                local class = class_name(p)
                local enemy = enemy_name(p)
                if enemy and numEnemies < 16 then
                    local name = full_name(p)
                    append_coords(pawnLines,'E',enemy,safe_position(p),frozen[name] == true,'-',name)
                    numEnemies = numEnemies + 1
                elseif class == 'BP_Character_C' and p ~= me and numPlayers < 12 then
                    append_coords(pawnLines,'P','PLAYER',safe_position(p),false,'-',full_name(p))
                    numPlayers = numPlayers + 1
                end
            end
        end
        pawnCoordinates=pawnLines
        lastPawnRefresh=WORK.now
        end
        for i=1,#pawnCoordinates do output[#output+1]=pawnCoordinates[i] end
        -- Items are mostly stationary: discover once per ~45 seconds, not every
        -- snapshot. This reduces broad global object enumeration dramatically.
        if WORK.now-lastItemRefresh>=45000 and WORK.now>=WORK.worldSettledAt then
            item_snapshot(worlds,map); lastItemRefresh=WORK.now; lastPickupRefresh=WORK.now
        elseif WORK.now-lastPickupRefresh>=1000 then
            refresh_pickups(worlds); lastPickupRefresh=WORK.now
        end
        for _, item in ipairs(itemCache) do
            append_coords(output,'I',item.label,{x=item.x,y=item.y,z=item.z},false,item.category,item.key)
        end
        write_state(output)
    end
    register_control(Key.F5,"F5",function()
        local host=radar_worlds()
        if not next(host) then note("F5 requires a hosted world."); return end
        radarOn=not radarOn
        counter=0
        if radarOn then
            currentMap=""
            note("F5 RADAR ON: player-facing; mouse-transparent; blue snowflake=frozen; vector altitude arrows.")
            set_job("radar",200,build_snapshot)
        else
            clear_job("radar")
            write_state({'PHC2\t0\t-\tNA'})
            note("F5 RADAR OFF.")
        end
    end)


    -- All unused progression reflection functions omitted in audited release.
    note('Progression reflection scans disabled for stability. No changes to progression data.')
    -- Background progression scan intentionally removed.
end
local radarOk, radarErr = xpcall(init_phc_radar,debug.traceback)
if not radarOk then print('[PHC-RADAR v0.11.6] INITIALIZATION FAILED '..tostring(radarErr)..'\n') end

-- One fresh native context per dispatch, never stored past the callback.
local function resolve_frame()
    local pcs=dense_list("PlayerController")
    for i=1,#pcs do
        local pc=pcs[i]
        if is_valid(pc) then
            local localOK,yes=call(pc,"IsLocalController")
            if localOK and yes==true then
                local worldOK,world=call(pc,"GetWorld")
                if worldOK and is_valid(world) then
                    local gm=property(world,"AuthorityGameMode")
                    local gs=property(world,"GameState")
                    local authOK,auth=call(gm,"HasAuthority")
                    local id=world_address(pc)
                    if authOK and auth==true and id then
                        local pawn=property(pc,"Pawn")
                        local worldName=full_name(world)
                        local map=worldName:match("/Game/Maps/([%w_]+)")
                        if not map and is_valid(pawn) then map=full_name(pawn):match("/Game/Maps/([%w_]+)") end
                        return {pc=pc,world=id,gm=gm,gs=gs,pawn=pawn,authority=true,map=map or "UNKNOWN"}
                    end
                end
            end
        end
    end
    return nil
end
local function run_dispatch()
    if WORK.inside then return end
    WORK.now=WORK.now+50
    local wanted=#WORK.queue>0
    if not wanted then
        for _,job in pairs(WORK.jobs) do
            if WORK.now>=job.due then wanted=true; break end
        end
    end
    if not wanted then return end -- no UObject queries when all features are idle
    WORK.inside=true
    local ok,why=xpcall(function()
        WORK.frame=resolve_frame()
        local f=WORK.frame
        if f and WORK.world~=f.world then
            -- Same map reloaded is a different world identity too.
            WORK.world=f.world
            WORK.worldSettledAt=WORK.now+1000
            frozenRecords={}; spawnAnchor=nil; noclip=nil
            clear_job("altitude"); clear_job("lockdown")
            PHC_LOCK.enabled=false; PHC_LOCK.records={}; PHC_LOCK.worldKey=nil
            PHC_LOCK.generation=PHC_LOCK.generation+1
            log("WORLD CHANGED: cleared prior-world metadata; initial item scan settles for 1 second.")
        end
        -- Process queued keys once, with a short per-key debounce for keyboard repeats.
        local pending=WORK.queue; WORK.queue={}
        for i=1,#pending do
            local label=pending[i]
            local fn=WORK.handlers[label]
            if fn and (not WORK.lastKey[label] or WORK.now-WORK.lastKey[label]>=200) then
                WORK.lastKey[label]=WORK.now
                WORK.errors={}
                operation_note("CONTROL "..label.." begin")
                local yes,err=xpcall(fn,debug.traceback)
                operation_note("CONTROL "..label.." complete="..tostring(yes))
                if not yes then log("CONTROL ERROR "..label..": "..tostring(err)) end
            end
        end
        -- Fixed job ordering. Never schedule another native callback inside this callback.
        for _,name in ipairs({"lockdown","altitude","radar"}) do
            local job=WORK.jobs[name]
            if job and WORK.now>=job.due then
                job.due=WORK.now+job.period
                local yes,err=xpcall(job.fn,debug.traceback)
                if not yes then
                    WORK.errors[name]=(WORK.errors[name] or 0)+1
                    log("SUBSYSTEM ERROR "..name..": "..tostring(err))
                    -- Repeated Lua failures do not justify repeatedly poking the same native path.
                    if WORK.errors[name]>=3 then clear_job(name); log("SUBSYSTEM PAUSED after repeated errors: "..name.."; toggle to retry.") end
                else WORK.errors[name]=0 end
            end
        end
    end,debug.traceback)
    WORK.frame=nil
    WORK.inside=false
    if not ok then log("DISPATCH ERROR: "..tostring(why)) end
end
if type(LoopInGameThreadWithDelay)=="function" then
    local ok,handle=pcall(LoopInGameThreadWithDelay,50,run_dispatch)
    if ok then
        log("SCHEDULER: single persistent game-thread loop, 50 ms; no chained ExecuteWithDelay callbacks.")
    else log("SCHEDULER FAILED: "..tostring(handle)) end
else
    log("SCHEDULER UNAVAILABLE: runtime must provide LoopInGameThreadWithDelay; no unsafe fallback enabled.")
end
