local config = require 'config.server'
local sharedConfig = require 'config.shared'
local VEHICLES = exports.qbx_core:GetVehiclesByName()

local function findPlateOnServer(plate)
    local vehicles = GetAllVehicles()
    for i = 1, #vehicles do
        if plate == GetVehicleNumberPlateText(vehicles[i]) then
            return true
        end
    end
end

---@alias VehicleEntity table

---@param source number
---@param garage string
---@param garageType GarageType
---@param category VehicleType
---@return VehicleEntity[]?
lib.callback.register('qbx_garages:server:getGarageVehicles', function(source, garage, garageType, category)
    local player = exports.qbx_core:GetPlayer(source)
    if garageType == GarageType.PUBLIC then -- Public garages give player cars in the garage only
        local result = MySQL.query.await('SELECT * FROM player_vehicles WHERE citizenid = ? AND garage = ? AND state = ?', {player.PlayerData.citizenid, garage, VehicleState.GARAGED})
        return result[1] and result
    elseif garageType == GarageType.DEPOT then -- Depot give player cars that are not in garage only
        local result = MySQL.query.await('SELECT * FROM player_vehicles WHERE citizenid = ? AND state = ?', {player.PlayerData.citizenid, VehicleState.OUT})
        local toSend = {}
        if not result[1] then return end
        for _, vehicle in pairs(result) do -- Check vehicle type against depot type
            if not findPlateOnServer(vehicle.plate) then
                if (category == VehicleType.AIR and (VEHICLES[vehicle.vehicle].category == 'helicopters' or VEHICLES[vehicle.vehicle].category == 'planes')) or
                   (category == VehicleType.SEA and VEHICLES[vehicle.vehicle].category == 'boats') or
                   (category == VehicleType.CAR and VEHICLES[vehicle.vehicle].category ~= 'helicopters' and VEHICLES[vehicle.vehicle].category ~= 'planes' and VEHICLES[vehicle.vehicle].category ~= 'boats') then
                    toSend[#toSend + 1] = vehicle
                end
            end
        end
        return toSend
    elseif garageType == GarageType.HOUSE or not config.sharedGarages then -- House/Personal Job/Gang garages give all cars in the garage
        local result = MySQL.query.await('SELECT * FROM player_vehicles WHERE garage = ? AND state = ? AND citizenid = ?', {garage, VehicleState.GARAGED, player.PlayerData.citizenid})
        return result[1] and result
    else -- Job/Gang shared garages
        local result = MySQL.query.await('SELECT * FROM player_vehicles WHERE garage = ? AND state = ?', {garage, VehicleState.GARAGED})
        return result[1] and result
    end
end)

---@param source number
---@param garage string
---@param garageType GarageType
---@param vehicleId string
---@return VehicleEntity
local function validateGarageVehicle(source, garage, garageType, vehicleId)
    local player = exports.qbx_core:GetPlayer(source)
    if garageType == GarageType.PUBLIC then -- Public garages give player cars in the garage only
        local result = MySQL.query.await('SELECT * FROM player_vehicles WHERE citizenid = ? AND garage = ? AND state = ? AND id = ?', {player.PlayerData.citizenid, garage, VehicleState.GARAGED, vehicleId})
        return result[1]
    elseif garageType == GarageType.DEPOT then -- Depot give player cars that are not in garage only
        local result = MySQL.query.await('SELECT * FROM player_vehicles WHERE citizenid = ? AND (state = ? OR state = ?) AND id = ?', {player.PlayerData.citizenid, VehicleState.OUT, VehicleState.IMPOUNDED, vehicleId})
        return result[1]
    elseif garageType == GarageType.HOUSE or not config.sharedGarages then -- House/Personal Job/Gang garages give all cars in the garage
        local result = MySQL.query.await('SELECT * FROM player_vehicles WHERE garage = ? AND state = ? AND citizenid = ? AND id = ?', {garage, VehicleState.OUT, player.PlayerData.citizenid, vehicleId})
        return result[1] and result
    else -- Job/Gang shared garages
        local result = MySQL.query.await('SELECT * FROM player_vehicles WHERE garage = ? AND state = ?', {garage, VehicleState.OUT})
        return result[1] and result
    end
end

---@param source number
---@param garageType GarageType
---@param garage string
---@param gang string
---@param veh number entity
---@return boolean
local function isParkable(source, garageType, garage, gang, veh)
    local vehicleId = Entity(veh).state.vehicleid
    assert(vehicleId ~= nil, 'owned vehicles must have vehicle ids')
    local player = exports.qbx_core:GetPlayer(source)
    if garageType == GarageType.PUBLIC then -- Public garages only for player cars
         local result = MySQL.scalar.await('SELECT 1 FROM player_vehicles WHERE id = ? AND citizenid = ?', {vehicleId, player.PlayerData.citizenid})
         return not not result
    elseif garageType == GarageType.HOUSE then -- House garages only for player cars that have keys of the house
        local result = MySQL.single.await('SELECT license, citizenid FROM player_vehicles WHERE id = ?', {vehicleId})
        return result and exports['qb-houses']:hasKey(result.license, result.citizenid, garage)
    elseif garageType == GarageType.GANG then -- Gang garages only for gang members cars (for sharing)
        local citizenId = MySQL.scalar.await('SELECT citizenid FROM player_vehicles WHERE id = ?', {vehicleId})
        if not citizenId then return false end
        -- Check if found owner is part of the gang
        return player.PlayerData.gang?.name == gang
    elseif garageType == GarageType.HOUSE or not config.sharedGarages then -- House/Personal Job/Gang garages give all cars in the garage
        local result = MySQL.scalar.await('SELECT 1 FROM player_vehicles WHERE citizenid = ? AND id = ?', {player.PlayerData.citizenid, vehicleId})
        return not not result
    else -- Job/Gang shared garages
        local result = MySQL.scalar.await('SELECT 1 FROM player_vehicles WHERE id = ?', {vehicleId})
        return not not result
    end
end

lib.callback.register('qbx_garages:server:isParkable', function(source, type, garage, gang, netId)
    return isParkable(source, type, garage, gang, NetworkGetEntityFromNetworkId(netId))
end)

---@param source number
---@param vehicleEntity VehicleEntity
---@param coords vector4
---@param garageType GarageType
---@return number? netId
lib.callback.register('qbx_garages:server:spawnVehicle', function (source, vehicleEntity, coords, garageType)
    local props = {}

    local result = MySQL.query.await('SELECT id, mods FROM player_vehicles WHERE id = ? LIMIT 1', {vehicleEntity.id})

    if result[1] then
        if garageType == GarageType.DEPOT then
            if findPlateOnServer(result[1].plate) then -- If depot, check if vehicle is not already spawned on the map
                return exports.qbx_core:Notify(source, Lang:t('error.not_impound'), 'error', 5000)
            end
        end
        props = json.decode(result[1].mods)
    end

    local warpPed = sharedConfig.takeOut.warpInVehicle and GetPlayerPed(source)
    local netId, veh = qbx.spawnVehicle({ spawnSource = coords, model = vehicleEntity.vehicle, props = props, warp = warpPed})

    if sharedConfig.takeOut.doorsLocked then
        SetVehicleDoorsLocked(veh, 2)
    end

    TriggerClientEvent('vehiclekeys:client:SetOwner', source, vehicleEntity.plate)

    Entity(veh).state:set('vehicleid', result[1].id, false)

    return netId
end)

---@param source number
---@param netId number
---@param props table ox_lib vehicle props https://github.com/overextended/ox_lib/blob/master/resource/vehicleProperties/client.lua#L3
---@param garage string
---@param garageType GarageType
---@param gang string
lib.callback.register('qbx_garages:server:parkVehicle', function(source, netId, props, garage, garageType, gang)
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    local owned = isParkable(source, garageType, garage, gang, vehicle) --Check ownership
    if not owned then
        exports.qbx_core:Notify(source, Lang:t('error.not_owned'), 'error')
        return
    end

    local vehicleId = Entity(vehicle).state.vehicleid
    if garageType ~= GarageType.HOUSE and not sharedConfig.garages[garage] then return end
    MySQL.update('UPDATE player_vehicles SET state = ?, garage = ?, fuel = ?, engine = ?, body = ?, mods = ? WHERE id = ?', {VehicleState.GARAGED, garage, props.fuelLevel, props.engineHealth, props.bodyHealth, json.encode(props), vehicleId})
    DeleteEntity(vehicle)
end)

---@param state VehicleState
---@param vehicleId string
---@param garage string
RegisterNetEvent('qbx_garages:server:updateVehicleState', function(state, vehicleId, garage)
    local type
    if sharedConfig.garages[garage] then
        type = sharedConfig.garages[garage].type
    else
        type = GarageType.HOUSE
    end

    local owned = validateGarageVehicle(source, garage, type, vehicleId) -- Check ownership
    if not owned then
        exports.qbx_core:Notify(source, Lang:t('error.not_owned'), 'error')
        return
    end

    if state ~= VehicleState.OUT then return end -- Check state value

    local carInfo = MySQL.single.await('SELECT vehicle, depotprice FROM player_vehicles WHERE id = ?', {vehicleId})
    if not carInfo then return end

    local vehCost = VEHICLES[carInfo.vehicle].price
    local newPrice = qbx.math.round(vehCost * (config.impoundFee.percentage / 100))
    if config.impoundFee.enable then
        if carInfo.depotprice ~= newPrice then
            MySQL.update('UPDATE player_vehicles SET state = ?, depotprice = ? WHERE id = ?', {state, newPrice, vehicleId})
        else
            MySQL.update('UPDATE player_vehicles SET state = ? WHERE id = ?', {state, vehicleId})
        end
    else
        MySQL.update('UPDATE player_vehicles SET state = ?, depotprice = 0 WHERE id = ?', {state, vehicleId})
    end
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= cache.resource then return end
    Wait(100)
    if not config.autoRespawn then return end

    MySQL.update('UPDATE player_vehicles SET state = ? WHERE state = ?', {VehicleState.GARAGED, VehicleState.OUT})
end)

---@param data {vehicle: VehicleEntity, garageInfo: GarageConfig, garageName: string}
RegisterNetEvent('qbx_garages:server:PayDepotPrice', function(data)
    local src = source
    local player = exports.qbx_core:GetPlayer(src)
    local cashBalance = player.PlayerData.money.cash
    local bankBalance = player.PlayerData.money.bank
    local vehicle = data.vehicle

    local depotPrice = MySQL.scalar.await('SELECT depotprice FROM player_vehicles WHERE id = ?', {vehicle.id})
    if not depotPrice then return end
    if cashBalance >= depotPrice then
        player.Functions.RemoveMoney('cash', depotPrice, 'paid-depot')
        TriggerClientEvent('qbx_garages:client:takeOutGarage', src, data)
    elseif bankBalance >= depotPrice then
        player.Functions.RemoveMoney('bank', depotPrice, 'paid-depot')
        TriggerClientEvent('qbx_garages:client:takeOutGarage', src, data)
    else
        exports.qbx_core:Notify(src, Lang:t('error.not_enough'), 'error')
    end
end)
