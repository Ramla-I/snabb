-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(..., package.seeall)

local connectx = require("apps.mellanox.connectx")

function run (parameters)
   connectx.selftest()
end
