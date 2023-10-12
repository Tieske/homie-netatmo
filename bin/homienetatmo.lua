#!/usr/bin/env lua

--- Main CLI application.
-- Reads configuration from environment variables and starts the Netatmo-to-Homie bridge.
-- Does not support any CLI parameters.
--
-- For configuring the log, use
-- [LuaLogging environment variable](https://lunarmodules.github.io/lualogging/manual.html#environment)
-- prefix `"HOMIE_LOG_"`, see "logLevel" in the example below.
-- @script homienetatmo
-- @usage
-- # configure parameters as environment variables
-- export NETATMO_CLIENT_ID="xxxxxxxx"
-- export NETATMO_CLIENT_SECRET="xxxxxxxx"
-- export NETATMO_POLL_INTERVAL=300           # default: 300 seconds (5 mins)
-- export NETATMO_LISTEN_IP="127.0.0.1"       # where the daeomn will listen, default: "127.0.0.1"
-- export NETATMO_LISTEN_PORT="8080"          # where the daemon will listen, default: "8080"
-- export NETATMO_REDIRECT_HOST="localhost"   # use for network indirection, eg. docker. default: to 'listen_host'
-- export NETATMO_REDIRECT_PORT="54321"       # use for network indirection, eg. docker. default: to 'listen_port'
-- export NETATMO_DATA_DIR="./data/"          # where to store refresh-token, default: "./"
-- export HOMIE_MQTT_URI="mqtt://synology"    # format: "mqtt(s)://user:pass@hostname:port"
-- export HOMIE_DOMAIN="homie"                # default: "homie"
-- export HOMIE_DEVICE_ID="netatmo"           # default: "netatmo"
-- export HOMIE_DEVICE_NAME="NA2H bridge"     # default: "Netatmo-to-Homie bridge"
-- export HOMIE_LOG_LOGLEVEL="info"           # default: "INFO"
--
-- # start the application
-- homienetatmo


-- do -- Add corowatch for debugging purposes
--   local corowatch = require "corowatch"
--   if jit then jit.off() end -- no hooks will be called for jitted code, so disable jit
--   corowatch.export(_G)
--   corowatch.watch(nil, 30) -- watch the main-coroutine, kill coroutine after 30 seconds
-- end

local ll = require "logging"
local copas = require "copas"
require("logging.rsyslog").copas() -- ensure copas, if rsyslog is used
local logger = assert(require("logging.envconfig").set_default_logger("HOMIE_LOG"))


do -- set Copas errorhandler
  local lines = require("pl.stringx").lines

  copas.setErrorHandler(function(msg, co, skt)
    msg = copas.gettraceback(msg, co, skt)
    for line in lines(msg) do
      ll.defaultLogger():error(line)
    end
  end , true)
end


print("starting Netatmo-to-Homie bridge")
logger:info("starting Netatmo-to-Homie bridge")


local opts = {
  netatmo_client_id = assert(os.getenv("NETATMO_CLIENT_ID"), "environment variable NETATMO_CLIENT_ID not set"),
  netatmo_client_secret = assert(os.getenv("NETATMO_CLIENT_SECRET"), "environment variable NETATMO_CLIENT_SECRET not set"),
  netatmo_poll_interval = tonumber(os.getenv("NETATMO_POLL_INTERVAL")) or 5*60,
  netatmo_listen_ip = os.getenv("NETATMO_LISTEN_IP") or "127.0.0.1",
  netatmo_listen_port = os.getenv("NETATMO_LISTEN_PORT") or "8080",
  netatmo_redirect_host = os.getenv("NETATMO_REDIRECT_HOST"),
  netatmo_redirect_port = os.getenv("NETATMO_REDIRECT_PORT"),
  netatmo_data_dir = os.getenv("NETATMO_DATA_DIR") or "./",
  homie_domain = os.getenv("HOMIE_DOMAIN") or "homie",
  homie_mqtt_uri = assert(os.getenv("HOMIE_MQTT_URI"), "environment variable HOMIE_MQTT_URI not set"),
  homie_device_id = os.getenv("HOMIE_DEVICE_ID") or "netatmo",
  homie_device_name = os.getenv("HOMIE_DEVICE_NAME") or "Netatmo-to-Homie bridge",
}
opts.netatmo_redirect_host = opts.netatmo_redirect_host or opts.netatmo_listen_host
opts.netatmo_redirect_port = opts.netatmo_redirect_port or opts.netatmo_listen_port

logger:info("Bridge configuration:")
logger:info("NETATMO_CLIENT_ID: ********")
logger:info("NETATMO_CLIENT_SECRET: ********")
logger:info("NETATMO_POLL_INTERVAL: %d seconds", opts.netatmo_poll_interval)
logger:info("NETATMO_LISTEN_IP: %s", opts.netatmo_listen_ip)
logger:info("NETATMO_LISTEN_PORT: %s", opts.netatmo_listen_port)
logger:info("NETATMO_REDIRECT_HOST: %s", opts.netatmo_redirect_host)
logger:info("NETATMO_REDIRECT_PORT: %s", opts.netatmo_redirect_port)
logger:info("NETATMO_DATA_DIR: %s", opts.netatmo_data_dir)
logger:info("HOMIE_DOMAIN: %s", opts.homie_domain)
logger:info("HOMIE_MQTT_URI: %s", opts.homie_mqtt_uri)
logger:info("HOMIE_DEVICE_ID: %s", opts.homie_device_id)
logger:info("HOMIE_DEVICE_NAME: %s", opts.homie_device_name)


copas.loop(function()
  require("homie-netatmo")(opts)
end)

-- never happens, since loop won't exit
ll.defaultLogger():info("Netatmo-to-Homie bridge exited")
