--- Netatmo-to-Homie bridge.
--
-- This module instantiates a homie device acting as a bridge between the Netatmo
-- API and Homie. For now it only supports weather data.
--
-- The module returns a single function that takes an options table. When called
-- it will construct a Homie device and add it to the Copas scheduler (without
-- running the scheduler).
-- @copyright Copyright (c) 2022-2022 Thijs Schreijer
-- @author Thijs Schreijer
-- @license MIT, see `LICENSE`.
-- @usage
-- local copas = require "copas"
-- local hna = require "homie-netatmo"
--
-- hna {
--   netatmo_client_id = "xxxxxxxx",
--   netatmo_client_secret = "xxxxxxxx",
--   netatmo_username = "xxxxxxxx",
--   netatmo_password = "xxxxxxxx",
--   netatmo_poll_interval = 5*60,           -- default: 5 minutes
--   homie_mqtt_uri = "http://mqtthost:123", -- format: "mqtt(s)://user:pass@hostname:port"
--   homie_domain = "homie",                 -- default: "homie"
--   homie_device_id = "netatmo",            -- default: "netatmo"
--   homie_device_name = "NA2H bridge",      -- default: "Netatmo-to-Homie bridge"
-- }
--
-- copas.loop()

local copas_timer = require "copas.timer"
local Device = require "homie.device"
local log = require("logging").defaultLogger()

local Netatmo = require("netatmo")
Netatmo.https = require("copas.http")  -- make sure we use non-blocking Copas http

local function create_device(self_bridge)
  local newdevice = {
    uri = self_bridge.homie_mqtt_uri,
    domain = self_bridge.homie_domain,
    broker_state = false,  -- not restoring, since it is sensor data (read-only) only
    id = self_bridge.homie_device_id,
    homie = "4.0.0",
    extensions = "",
    name = self_bridge.homie_device_name,
    nodes = {}
  }

  for i, module in ipairs(self_bridge.module_list) do
    local node = {}
    newdevice.nodes[module.deviceName] = node

    node.name = module.deviceName
    node.type = self_bridge.netatmo.DEVICE_TYPES[module.type]
    local props = {}
    node.properties = props

    if module.rf_status then
      props.radiosignal = {
        name = "radiosignal",
        datatype = "string",
        settable = false,
        retained = true,
        validate = function(self, value)
          return type(value) == "number"
        end,
        pack = function(self, value)
          -- 90=low, 60=highest
          if value >= 90 then return "bad ("..tostring(value)..")" end
          if value > 60 then return "ok ("..tostring(value)..")" end
          return "good ("..tostring(value)..")"
        end,
      }
    end
    if module.wifi_status then
      props.wifisignal = {
        name = "wifisignal",
        datatype = "string",
        settable = false,
        retained = true,
        validate = function(self, value)
          return type(value) == "number"
        end,
        pack = function(self, value)
          -- 86=bad, 56=good
          if value >= 86 then return "bad ("..tostring(value)..")" end
          if value > 56 then return "ok ("..tostring(value)..")" end
          return "good ("..tostring(value)..")"
        end,
      }
    end
    if module.reachable ~= nil then
      props.reachable = {
        name = "reachable",
        datatype = "boolean",
        settable = false,
        retained = true,
      }
    end
    if module.battery_percent then
      props.battery = {
        name = "battery",
        datatype = "integer",
        settable = false,
        retained = true,
        unit = "%",
        format = "0:100",
      }
    end
    if module.last_seen or module.last_status_store then
      props["last-seen"] = {
        name = "last-seen",
        datatype = "string",
        settable = false,
        retained = true,
        validate = function(self, value)
          return type(value) == "number"
        end,
        pack = function(self, value)
          return os.date("%y-%m-%d %H:%M:%S", value)
        end,
      }
    end
    -- check data-elements exposed; dynamic in case of future additions
    do
      local units = {
        Temperature = "°C",
        Humidity = "%",
        CO2 = "ppm",
        Pressure = "mbar",
        Noise = "dB",
      }
      for _, data_name in ipairs(module.data_type) do
        props[data_name:lower()] = {
          name = data_name:lower(),
          datatype = "float",
          settable = false,
          retained = true,
          unit = units[data_name],
        }
      end
    end
  end

  return Device.new(newdevice)
end

--local homie_device


local function timer_callback(timer, self)
  log:debug("[homie-netatmo] starting update")

  local modules, err = self.netatmo:get_modules_data()
  if not modules then
    log:error("[homie-netatmo] failed to update modules: %s", err)
    return
  end

  -- set names
  for i, module in ipairs(modules) do
    local name = self.netatmo.DEVICE_TYPES[module.type] .. " " .. module.module_name
    module.deviceName = name:lower():gsub("[^a-z0-9]", "-")  -- slugify to allowed characters
  end

  -- check if device-list has changed
  local changed = #modules ~= #self.module_list
  if not changed then -- equal length, check contents: check against names, not ID's, because that's how they are published
    for i, new_module in ipairs(modules) do
      local found = false
      for j, old_module in ipairs(self.module_list) do
        if new_module.deviceName == old_module.deviceName then
          found = true
          break
        end
      end
      if not found then
        changed = true
      end
    end
  end

  -- set new device values
  self.module_list = modules

  if changed then
    log:info("[homie-netatmo] module list changed, updating device")
    if self.homie_device then
      self.homie_device:stop()
    end

    self.homie_device = create_device(self)
    self.homie_device:start()
  else
    log:debug("[homie-netatmo] module list is unchanged")
  end

  -- update retrieved values
  for i, module in ipairs(self.module_list) do
    local node = self.homie_device.nodes[module.deviceName]

    if module.rf_status then
      node.properties.radiosignal:set(module.rf_status)
    end
    if module.wifi_status then
      node.properties.wifisignal:set(module.wifi_status)
    end
    if module.reachable ~= nil then
      node.properties.reachable:set(module.reachable)
    end
    if module.battery_percent then
      node.properties.battery:set(module.battery_percent)
    end
    if module.last_seen or module.last_status_store then
      node.properties["last-seen"]:set(module.last_seen or module.last_status_store)
    end
    -- check data-elements exposed; dynamic in case of future additions
    if module.dashboard_data then
      for _, data_name in ipairs(module.data_type) do
        local data_value = module.dashboard_data[data_name]
        node.properties[data_name:lower()]:set(data_value)
      end
    else
      log:warn("[homie-netatmo] no dashboard data received for module '%s'", module.deviceName)
    end
  end
end



return function(self)
  -- Netatmo API session object
  self.netatmo = Netatmo.new(
    self.netatmo_client_id, self.netatmo_client_secret,
    self.netatmo_username, self.netatmo_password)

  self.module_list = {}  -- last list retrieved

  self.timer = copas_timer.new {
    name = "homie-netatmo updater",
    recurring = true,
    delay = self.netatmo_poll_interval,
    initial_delay = 0,
    callback = timer_callback,
    params = self,
  }
end
