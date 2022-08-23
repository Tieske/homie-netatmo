#!/usr/bin/env lua

--- Main CLI application.
-- Reads configuration from environment variables and starts the Millheat-to-Homie bridge.
-- Does not support any CLI parameters.
-- @module homienetatmo
-- @usage
-- # configure parameters as environment variables
-- export NETATMO_CLIENT_ID="xxxxxxxx"
-- export NETATMO_CLIENT_SECRET="xxxxxxxx"
-- export NETATMO_USERNAME="xxxxxxxx"
-- export NETATMO_PASSWORD="xxxxxxxx"
-- export NETATMO_POLL_INTERVAL=300           # default: 300 seconds (5 mins)
-- export HOMIE_MQTT_URI="mqtt://synology"    # format: "mqtt(s)://user:pass@hostname:port"
-- export HOMIE_LOG_LEVEL="info"              # default: "INFO"
-- export HOMIE_DOMAIN="homie"                # default: "homie"
-- export HOMIE_DEVICE_ID="netatmo"           # default: "netatmo"
-- export HOMIE_DEVICE_NAME="NA2H bridge"     # default: "Netatmo-to-Homie bridge"
--
-- # start the application
-- homienetatmo

local ansicolors = require "ansicolors" -- https://github.com/kikito/ansicolors.lua
local ll = require "logging"

local log_level = tostring(os.getenv("HOMIE_LOG_LEVEL") or "INFO"):upper()
assert(type(ll[log_level]) == "string", "environment variable HOMIE_LOG_LEVEL invalid; '"..log_level.."' is not a valid log-level")

local logger do -- configure the default logger
  require "logging.console"

  logger = ll.defaultLogger(ll.console {
    logLevel = ll[log_level],
    destination = "stderr",
    timestampPattern = "%y-%m-%d %H:%M:%S",
    logPatterns = {
      [ll.DEBUG] = ansicolors("%date%{cyan} %level %message %{reset}(%source)\n"),
      [ll.INFO] = ansicolors("%date %level %message\n"),
      [ll.WARN] = ansicolors("%date%{yellow} %level %message\n"),
      [ll.ERROR] = ansicolors("%date%{red bright} %level %message %{reset}(%source)\n"),
      [ll.FATAL] = ansicolors("%date%{magenta bright} %level %message %{reset}(%source)\n"),
    }
  })
end


local copas = require "copas"

do -- set Copas errorhandler
  local lines = require("pl.stringx").lines
  copas.setErrorHandler(function(msg, co, skt)
    -- TODO: remove this code once Copas 4.1.0 is released
    local co_str = co == nil and "nil" or copas.getthreadname(co)
    local skt_str = skt == nil and "nil" or copas.getsocketname(skt)

    msg = ("%s (coroutine: %s, socket: %s)"):format(tostring(msg), co_str, skt_str)

    if type(co) == "thread" then
      -- regular Copas coroutine
      msg = debug.traceback(co, msg)
    else
      -- not a coroutine, but the main thread, this happens if a timeout callback
      -- (see `copas.timeout` causes an error (those callbacks run on the main thread).
      msg = debug.traceback(msg, 2)
    end

    for line in lines(msg) do
      ll.defaultLogger():error(line)
    end
  end , true)
end


logger:info("starting Netatmo-to-Homie bridge")


local opts = {
  netatmo_client_id = assert(os.getenv("NETATMO_CLIENT_ID"), "environment variable NETATMO_CLIENT_ID not set"),
  netatmo_client_secret = assert(os.getenv("NETATMO_CLIENT_SECRET"), "environment variable NETATMO_CLIENT_SECRET not set"),
  netatmo_username = assert(os.getenv("NETATMO_USERNAME"), "environment variable NETATMO_USERNAME not set"),
  netatmo_password = assert(os.getenv("NETATMO_PASSWORD"), "environment variable NETATMO_PASSWORD not set"),
  netatmo_poll_interval = tonumber(os.getenv("NETATMO_POLL_INTERVAL")) or 15,
  homie_domain = os.getenv("HOMIE_DOMAIN") or "homie",
  homie_mqtt_uri = assert(os.getenv("HOMIE_MQTT_URI"), "environment variable HOMIE_MQTT_URI not set"),
  homie_device_id = os.getenv("HOMIE_DEVICE_ID") or "netatmo",
  homie_device_name = os.getenv("HOMIE_DEVICE_NAME") or "Netatmo-to-Homie bridge",
}

logger:info("Bridge configuration:")
logger:info("NETATMO_CLIENT_ID: ********")
logger:info("NETATMO_CLIENT_SECRET: ********")
logger:info("NETATMO_USERNAME: %s", opts.netatmo_username)
logger:info("NETATMO_PASSWORD: ********")
logger:info("NETATMO_POLL_INTERVAL: %d seconds", opts.netatmo_poll_interval)
logger:info("HOMIE_LOG_LEVEL: %s", log_level)
logger:info("HOMIE_DOMAIN: %s", opts.homie_domain)
logger:info("HOMIE_MQTT_URI: %s", opts.homie_mqtt_uri)
logger:info("HOMIE_DEVICE_ID: %s", opts.homie_device_id)
logger:info("HOMIE_DEVICE_NAME: %s", opts.homie_device_name)


copas.loop(function()
  require("homie-netatmo")(opts)
end)

ll.defaultLogger():info("Netatmo-to-Homie bridge exited")
