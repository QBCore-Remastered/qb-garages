assert(lib.checkDependency('qbx_core', '1.15.0', true))

---@class PlayerVehicle
---@field id number
---@field citizenid? string
---@field modelName string
---@field garage string
---@field state VehicleState
---@field depotPrice integer
---@field props table ox_lib properties table

Config = require 'config.server'
SharedConfig = require 'config.shared'
VEHICLES = exports.qbx_core:GetVehiclesByName()
Storage = require 'server.storage'

function FindPlateOnServer(plate)
    local vehicles = GetAllVehicles()
    for i = 1, #vehicles do
        if plate == GetVehicleNumberPlateText(vehicles[i]) then
            return true
        end
    end
end

---@param garage string
---@return GarageType
function GetGarageType(garage)
    if SharedConfig.garages[garage] then
        return SharedConfig.garages[garage].type
    else
        return GarageType.HOUSE
    end
end

---@class PlayerVehiclesFilters
---@field citizenid? string
---@field states? VehicleState|VehicleState[]
---@field garage? string

---@param source number
---@param garageName string
---@param garageType GarageType
---@return PlayerVehiclesFilters
function GetPlayerVehicleFilter(source, garageName, garageType)
    local player = exports.qbx_core:GetPlayer(source)
    local filter = {}
    filter.citizenid = SharedConfig.garages[garageName].shared and player.PlayerData.citizenid or nil
    if garageType == GarageType.DEPOT then -- Depot give player cars that are not in garage only
        filter.states = VehicleState.OUT
    else
        filter.garage = garageName
        filter.states = VehicleState.GARAGED
    end
    return filter
end

local function getCanAccessGarage(player, garage)
    if garage.groups and not exports.qbx_core:HasPrimaryGroup(garage.groups, QBX.PlayerData) then
        return false
    end
    if garage.canAccess ~= nil and not garage.canAccess(player.PlayerData.source) then
        return false
    end
    return true
end

---@param source number
---@param garageName string
---@return PlayerVehicle[]?
lib.callback.register('qbx_garages:server:getGarageVehicles', function(source, garageName)
    local player = exports.qbx_core:GetPlayer(source)
    local garage = SharedConfig.garages[garageName]
    if not getCanAccessGarage(player, garage) then return end
    local garageType = GetGarageType(garageName)
    local filter = GetPlayerVehicleFilter(source, garageName, garageType)
    local playerVehicles = exports.qbx_vehicles:GetPlayerVehicles(filter)
    if garageType == GarageType.DEPOT then -- Depot give player cars that are not in garage only
        local toSend = {}
        if not playerVehicles[1] then return end
        for _, vehicle in pairs(playerVehicles) do -- Check vehicle type against depot type
            if not FindPlateOnServer(vehicle.props.plate) then
                local vehicleType = SharedConfig.garages[garageName].vehicleType
                if (vehicleType == VehicleType.AIR and (VEHICLES[vehicle.modelName].category == 'helicopters' or VEHICLES[vehicle.modelName].category == 'planes')) or
                   (vehicleType == VehicleType.SEA and VEHICLES[vehicle.modelName].category == 'boats') or
                   (vehicleType == VehicleType.CAR and VEHICLES[vehicle.modelName].category ~= 'helicopters' and VEHICLES[vehicle.modelName].category ~= 'planes' and VEHICLES[vehicle.modelName].category ~= 'boats') then
                    toSend[#toSend + 1] = vehicle
                end
            end
        end
        return toSend
    else
        return playerVehicles[1] and playerVehicles
    end
end)

---@param source number
---@param vehicleId string
---@param garageName string
---@return boolean
local function isParkable(source, vehicleId, garageName)
    local garageType = GetGarageType(garageName)
    --- DEPOTS are only for retrieving, not storing
    if garageType == GarageType.DEPOT then return false end
    assert(vehicleId ~= nil, 'owned vehicles must have vehicleid statebag set')
    local player = exports.qbx_core:GetPlayer(source)
    local garage = SharedConfig.garages[garageName]
    if not getCanAccessGarage(player, garage) then
        return false
    end
    if not garage.shared then
        local playerVehicle = exports.qbx_vehicles:GetPlayerVehicle(vehicleId)
        if playerVehicle.citizenid ~= player.PlayerData.citizenid then
            return false
        end
    end
    return true
end

lib.callback.register('qbx_garages:server:isParkable', function(source, garage, netId)
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    local vehicleId = Entity(vehicle).state.vehicleid
    return isParkable(source, vehicleId, garage)
end)

---@param source number
---@param netId number
---@param props table ox_lib vehicle props https://github.com/overextended/ox_lib/blob/master/resource/vehicleProperties/client.lua#L3
---@param garage string
lib.callback.register('qbx_garages:server:parkVehicle', function(source, netId, props, garage)
    local garageType = GetGarageType(garage)
    assert(garageType == GarageType.HOUSE or SharedConfig.garages[garage] ~= nil, string.format('Garage %s not found in config', garage))
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    local owned = isParkable(source, Entity(vehicle).state.vehicleid, garage) --Check ownership
    if not owned then
        exports.qbx_core:Notify(source, Lang:t('error.not_owned'), 'error')
        return
    end

    local vehicleId = Entity(vehicle).state.vehicleid
    Storage.saveVehicle(vehicleId, props, garage)
    DeleteEntity(vehicle)
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= cache.resource then return end
    Wait(100)
    if Config.autoRespawn then
        Storage.moveOutVehiclesIntoGarages()
    end
end)

---@param vehicleId string
---@return boolean? success true if successfully paid
lib.callback.register('qbx_garages:server:payDepotPrice', function(source, vehicleId)
    local player = exports.qbx_core:GetPlayer(source)
    local cashBalance = player.PlayerData.money.cash
    local bankBalance = player.PlayerData.money.bank

    local vehicle = exports.qbx_vehicles:GetPlayerVehicle(vehicleId)
    local depotPrice = vehicle.depotPrice
    if not depotPrice or depotPrice == 0 then return true end
    if cashBalance >= depotPrice then
        player.Functions.RemoveMoney('cash', depotPrice, 'paid-depot')
        return true
    elseif bankBalance >= depotPrice then
        player.Functions.RemoveMoney('bank', depotPrice, 'paid-depot')
        return true
    end
end)