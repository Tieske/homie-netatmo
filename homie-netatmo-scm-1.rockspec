local package_name = "homie-netatmo"
local package_version = "scm"
local rockspec_revision = "1"
local github_account_name = "Tieske"
local github_repo_name = "homie-netatmo"


package = package_name
version = package_version.."-"..rockspec_revision

source = {
  url = "git+https://github.com/"..github_account_name.."/"..github_repo_name..".git",
  branch = (package_version == "scm") and "main" or nil,
  tag = (package_version ~= "scm") and package_version or nil,
}

description = {
  summary = "A bridge that exposes Netatmo devices as Homie mqtt devices ",
  detailed = [[
    A bridge that exposes Netatmo devices as Homie mqtt devices
  ]],
  license = "MIT",
  homepage = "https://github.com/"..github_account_name.."/"..github_repo_name,
}

dependencies = {
  "lua >= 5.1, < 5.5",
  "homie",
  "lualogging >= 1.6.0, < 2",
  "ansicolors",
  "netatmo",
}

build = {
  type = "builtin",

  modules = {
    ["homie-netatmo.init"] = "src/homie-netatmo/init.lua",
  },

  install = {
    bin = {
      homienetatmo = "bin/homienetatmo.lua",
    }
  },

  copy_directories = {
    "docs",
  },
}
