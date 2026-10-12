lib.versionCheck('Qbox-project/qbx_taxijob')

local config = require 'config.server'
local sharedConfig = require 'config.shared'
local ITEMS = exports.ox_inventory:Items()

local function getPlayerWithTaxiJob(src)
    local player = exports.qbx_core:GetPlayer(src)
    if not player then return nil end
    if player.PlayerData.job.name ~= 'taxi' then
        return nil
    end
    return player
end

local function nearDeliverLocation(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local coords = GetEntityCoords(ped)
    for _, v in pairs(sharedConfig.npcLocations.deliverLocations) do
        local dist = #(coords - v.xyz)
        if dist < config.deliverLocationMaxDistance then
            return true
        end
    end
    return false
end

local function isAllowedVehicleModel(model)
    if type(model) ~= 'string' then return false end
    local lower = model:lower()
    for _, allowed in ipairs(config.allowedVehicleModels) do
        if type(allowed) == 'string' and allowed:lower() == lower then
            return true
        end
    end
    return false
end

local function getCoordsXYZW(coords)
    if type(coords) == 'table' then
        local x = coords.x or coords[1]
        local y = coords.y or coords[2]
        local z = coords.z or coords[3]
        local w = coords.w or coords[4]
        if x and y and z then
            x, y, z = tonumber(x), tonumber(y), tonumber(z)
            w = w and tonumber(w) or 0
            if x and y and z then return x, y, z, w end
        end
    elseif type(coords) == 'vector3' or type(coords) == 'vector4' or (type(coords) == 'userdata' and coords.x) then
        return coords.x, coords.y, coords.z, coords.w or 0
    end
    return nil, nil, nil, 0
end

local function isNearAllowedSpawnPoint(coords)
    local x, y, z = getCoordsXYZW(coords)
    if not x or not y or not z then return false end
    local pos = vec3(x, y, z)
    for _, spawn in ipairs(config.cabSpawns) do
        local dist = #(pos - spawn.xyz)
        if dist <= config.spawnPointMaxDistance then
            return true
        end
    end
    return false
end

lib.callback.register('qb-taxi:server:spawnTaxi', function(source, model, coords)
    local player = getPlayerWithTaxiJob(source)
    if not player then
        lib.print.warn(('qb_taxijob: spawnTaxi from source %s without taxi job'):format(source))
        return nil
    end

    if not isAllowedVehicleModel(model) then
        lib.print.warn(('qb_taxijob: spawnTaxi from source %s invalid model %s'):format(source, tostring(model)))
        return nil
    end

    if not isNearAllowedSpawnPoint(coords) then
        lib.print.warn(('qb_taxijob: spawnTaxi from source %s coords not near cab spawn'):format(source))
        return nil
    end

    local x, y, z, heading = getCoordsXYZW(coords)
    if not x or not y or not z then return nil end
    local spawnCoords = vec4(x, y, z, heading)
    local netId, veh = qbx.spawnVehicle({
        model = model,
        spawnSource = spawnCoords,
        warp = GetPlayerPed(source --[[@as number]]),
    })

    if not veh or veh == 0 then return nil end

    local plate = 'TAXI' .. math.random(1000, 9999)
    SetVehicleNumberPlateText(veh, plate)
    TriggerClientEvent('vehiclekeys:client:SetOwner', source, plate)
    return netId
end)

-- Atlas fork: the server owns an NPC ride from start to payment. It picks the pick-up and the drop-off,
-- computes the fare from the distance between them, and pays only when the driver was at both points
-- with enough time in between. Nothing the client sends decides the amount.

---@class TaxiRide
---@field take integer index in sharedConfig.npcLocations.takeLocations
---@field deliver integer index in sharedConfig.npcLocations.deliverLocations
---@field fare integer
---@field distance number metres, straight line
---@field pickedUpAt? integer GetGameTimer() at pick-up

---@type table<integer, TaxiRide>
local rides = {}
local lastTake, lastDeliver = {}, {}
local lastRideStart = {}

local METRES_PER_MILE = 1609.34

---@param count integer
---@param previous? integer
---@return integer
local function pickIndex(count, previous)
    local index = math.random(1, count)
    if count > 1 and index == previous then
        index = index % count + 1
    end
    return index
end

---@param src integer
---@param target vector4
---@param maxDistance number
---@return boolean
local function isPedNear(src, target, maxDistance)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    return #(GetEntityCoords(ped) - target.xyz) < maxDistance
end

---@param src integer
---@return boolean
local function isInAllowedVehicle(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local vehicle = GetVehiclePedIsIn(ped, false)
    if not vehicle or vehicle == 0 then return false end
    local model = GetEntityModel(vehicle)
    for _, allowed in ipairs(config.allowedVehicleModels) do
        if type(allowed) == 'string' and joaat(allowed) == model then
            return true
        end
    end
    return false
end

lib.callback.register('qb-taxi:server:startRide', function(source)
    if not getPlayerWithTaxiJob(source) then
        lib.print.warn(('qb_taxijob: startRide from source %s without taxi job'):format(source))
        return nil
    end

    if not isInAllowedVehicle(source) then return nil end

    local now = os.time()
    if lastRideStart[source] and (now - lastRideStart[source]) < config.rideStartCooldownSeconds then
        return nil
    end
    lastRideStart[source] = now

    local locations = sharedConfig.npcLocations
    local take = pickIndex(#locations.takeLocations, lastTake[source])
    local deliver = pickIndex(#locations.deliverLocations, lastDeliver[source])
    lastTake[source], lastDeliver[source] = take, deliver

    local distance = #(locations.takeLocations[take].xyz - locations.deliverLocations[deliver].xyz)
    local fare = math.floor(config.startingPrice + distance / METRES_PER_MILE * config.pricePerMile)

    -- A ride that was started and not finished is replaced and never paid.
    rides[source] = {
        take = take,
        deliver = deliver,
        distance = distance,
        fare = math.min(fare, config.maxFare),
    }

    return { take = take, deliver = deliver, fare = rides[source].fare }
end)

lib.callback.register('qb-taxi:server:pickUp', function(source)
    local ride = rides[source]
    if not ride or ride.pickedUpAt or not getPlayerWithTaxiJob(source) then return false end

    local take = sharedConfig.npcLocations.takeLocations[ride.take]
    if not isPedNear(source, take, config.takeLocationMaxDistance) or not isInAllowedVehicle(source) then
        lib.print.warn(('qb_taxijob: pickUp from source %s away from the pick-up point or not in a cab'):format(source))
        return false
    end

    ride.pickedUpAt = GetGameTimer()
    return true
end)

RegisterNetEvent('qb-taxi:server:NpcPay', function()
    local src = source
    local player = getPlayerWithTaxiJob(src)
    if not player then
        lib.print.warn(('qb_taxijob: NpcPay from source %s without taxi job'):format(src))
        return
    end

    local ride = rides[src]
    if not ride or not ride.pickedUpAt then
        lib.print.warn(('qb_taxijob: NpcPay from source %s without a ride in progress'):format(src))
        return
    end

    local deliver = sharedConfig.npcLocations.deliverLocations[ride.deliver]
    if not isPedNear(src, deliver, config.deliverLocationMaxDistance) then
        lib.print.warn(('qb_taxijob: NpcPay from source %s not near its deliver location'):format(src))
        return
    end

    -- The ride cannot have been faster than the best average speed a cab can hold.
    local elapsed = (GetGameTimer() - ride.pickedUpAt) / 1000
    if elapsed < ride.distance / config.maxAverageSpeed then
        lib.print.warn(('qb_taxijob: NpcPay from source %s after %.0f s for %.0f m'):format(src, elapsed, ride.distance))
        rides[src] = nil
        return
    end

    -- Cleared before paying: a second request for the same ride finds nothing.
    rides[src] = nil

    local paymentAmount = ride.fare
    local randomAmount = math.random(1, 5)
    local r1, r2 = math.random(1, 5), math.random(1, 5)
    if randomAmount == r1 or randomAmount == r2 then
        paymentAmount = paymentAmount + math.random(10, 20)
    end

    player.Functions.AddMoney('cash', paymentAmount, 'taxi-fare')
    if config.chanceItemEnabled and config.chanceItem and config.chancePercent and config.chancePercent > 0 then
        local chance = math.random(1, 100)
        if chance <= config.chancePercent then
            player.Functions.AddItem(config.chanceItem, 1, false)
            local itemData = ITEMS[config.chanceItem]
            if itemData then
                TriggerClientEvent('inventory:client:ItemBox', src, itemData, 'add')
            end
        end
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    rides[src] = nil
    lastTake[src], lastDeliver[src] = nil, nil
    lastRideStart[src] = nil
end)
