--- Netatmo-to-Homie bridge.
--
-- This module instantiates a homie device acting as a bridge between the Netatmo
-- API and Homie. For now it only supports weather data.
--
-- The module returns a single function that takes an options table. When called
-- it will construct a Homie device and add it to the Copas scheduler (without
-- running the scheduler).
-- @copyright Copyright (c) 2022-2023 Thijs Schreijer
-- @author Thijs Schreijer
-- @license MIT, see `LICENSE`.
-- @usage
-- local copas = require "copas"
-- local hna = require "homie-netatmo"
--
-- hna {
--   netatmo_client_id = "xxxxxxxx",
--   netatmo_client_secret = "xxxxxxxx",
--   netatmo_listen_ip = "*",                -- default: "127.0.0.1"
--   netatmo_listen_port = "8080"            -- default: "54321"
--   netatmo_redirect_host = "localhost",    -- default: netatmo_listen_host
--   netatmo_redirect_port = "8080",         -- default: netatmo_listen_port
--   netatmo_data_dir = "./data",            -- default: "./"
--   netatmo_poll_interval = 5*60,           -- default: 5 minutes
--   homie_mqtt_uri = "http://mqtthost:123", -- format: "mqtt(s)://user:pass@hostname:port"
--   homie_domain = "homie",                 -- default: "homie"
--   homie_device_id = "netatmo",            -- default: "netatmo"
--   homie_device_name = "NA2H bridge",      -- default: "Netatmo-to-Homie bridge"
-- }
--
-- copas.loop()

local REDIRECT_PATH = "/netatmo/auth"

local copas = require "copas"
local copas_timer = require "copas.timer"
local Device = require "homie.device"
local log = require("logging").defaultLogger()
local socket = require "socket"
local pl_utils = require "pl.utils"
local pl_path = require "pl.path"
local pl_file = require "pl.file"

local Netatmo = require("netatmo")
Netatmo.https = require("copas.http")  -- make sure we use non-blocking Copas http


local function start_server(session, host, port)
  local server_sock = assert(socket.bind(host, port))
  local server_ip, server_port = assert(server_sock:getsockname())

  local socket_handler = function(sock)
    -- we assume no http body, so read lines until the line is empty
    local request = {}
    while true do
      local line, err = sock:receive("*l")
      --print(line, err)
      if not line then
        session.log:error("[homie-netatmo] Failed reading OAuth2 callback request: %s", err)
        sock:close()
        return
      end
      if line == "" then break end
      request[#request+1] = line
    end

    -- validate the first line
    local expect = "GET " .. REDIRECT_PATH .. "?"
    if request[1]:sub(1, #expect) ~= expect then
      session.log:error("[homie-netatmo] Bad request: '%s'", request[1])
      sock:send("HTTP/1.1 404 Not Found\r\n\r\nNot found.\r\n")
      sock:close()
      return
    end

    local ok, err = session:authorize(request[1])
    if not ok then
      session.log:error("[homie-netatmo] Authentication failed: %s", err)
      sock:send("HTTP/1.1 401 Unauthorized\r\n\r\nAuthorization failed.\r\n")
    else
      session.log:info("[homie-netatmo] Authenticated successfully")
      sock:send("HTTP/1.1 200 OK\r\n\r\nOAuth2 access approved, please close this browser window.\r\n")
    end
    sock:close()
  end

  -- start the server
  copas.addserver(
    server_sock,
    copas.handler(socket_handler),
    30, -- timeout
    "OAuth2_callback_handler"
  )
  session.log:info("[homie-netatmo] listening for OAuth2 callbacks on %s:%s", server_ip, server_port)
end


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
    if err == self.netatmo.ERR_MUST_AUTHORIZE then
      log:info("[homie-netatmo] please login: %s", self.netatmo:get_authorization_url())
    elseif err == self.netatmo.ERR_REFRESH_IN_PROGRESS then
      copas.sleep(3) -- wait a bit and try again
      return timer_callback(timer, self) -- TODO: possibility of loop!
    else
      log:error("[homie-netatmo] failed to update modules: %s", err)
    end
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
  local datafile = pl_path.join(self.netatmo_data_dir, "netatmo.pat")
  local cached_token, err
  if pl_path.exists(datafile) then
    cached_token, err = pl_utils.readfile(datafile)
    if not cached_token then
      log:error("[homie-netatmo] failed to read cached token (%s): %s", datafile, err)
    else
      log:info("[homie-netatmo] using cached token (%s)", datafile)
    end
  else
    log:info("[homie-netatmo] no cached token found (%s)", datafile)
  end

  -- Netatmo API session object
  self.netatmo = Netatmo.new {
    client_id = self.netatmo_client_id,
    client_secret = self.netatmo_client_secret,
    refresh_token = cached_token,
    persist = function(session, token)
      if token then
        local ok, err = pl_utils.writefile(datafile, token)
        if not ok then
          log:error("[homie-netatmo] failed to write cached token (%s): %s", datafile, err)
        else
          log:debug("[homie-netatmo] cached token written (%s)", datafile)
        end
      else
        -- token is nil, so remove cached file
        pl_file.delete(datafile)
      end
    end,
    callback_url = "http://" .. self.netatmo_redirect_host .. ":" .. self.netatmo_redirect_port .. REDIRECT_PATH,
  }

  self.module_list = {}  -- last list retrieved

  -- keep-alive timer
  copas.addthread(function()
    while true do
      copas.sleep(self.netatmo:keepalive(60))
    end
  end)

  -- start auth-server
  start_server(self.netatmo, self.netatmo_listen_ip, self.netatmo_listen_port)

  -- recurring timer to fetch data and update homie device
  self.timer = copas_timer.new {
    name = "homie-netatmo updater",
    recurring = true,
    delay = self.netatmo_poll_interval,
    initial_delay = 0,
    callback = timer_callback,
    params = self,
  }
end
