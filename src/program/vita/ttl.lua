-- Use of this source code is governed by the GNU AGPL license; see COPYING.

module(...,package.seeall)

local counter = require("core.counter")
local ipv4 = require("lib.protocol.ipv4")
local ipv6 = require("lib.protocol.ipv6")

DecrementTTL = {
   name = "DecrementTTL",
   shm = {
      protocol_errors = {counter}
   }
}

function DecrementTTL:new ()
   return setmetatable({ip4 = ipv4:new({})}, {__index=DecrementTTL})
end

function DecrementTTL:push ()
   local output = self.output.output
   local time_exceeded = self.output.time_exceeded
   for _, input in ipairs(self.input) do
      while not link.empty(input) do
         local p = link.receive(input)
         local ip4 = self.ip4:new_from_mem(p.data, p.length)
         if ip4 and ip4:ttl() > 0 then
            ip4:ttl_decrement()
            link.transmit(output, p)
         elseif ip4 then
            link.transmit(time_exceeded, p)
         else
            packet.free(p)
            counter.add(self.shm.protocol_errors)
         end
      end
   end
end

DecrementHopLimit = {
   name = "DecrementHopLimit",
   shm = {
      protocol_errors = {counter}
   }
}

function DecrementHopLimit:new ()
   return setmetatable({ip6 = ipv6:new({})}, {__index=DecrementHopLimit})
end

function DecrementHopLimit:push ()
   local output = self.output.output
   local hop_limit_exceeded = self.output.hop_limit_exceeded
   for _, input in ipairs(self.input) do
      while not link.empty(input) do
         local p = link.receive(input)
         local ip6 = self.ip6:new_from_mem(p.data, p.length)
         if ip6 and ip6:hop_limit() > 0 then
            ip6:hop_limit(ip6:hop_limit() - 1)
            link.transmit(output, p)
         elseif ip6 then
            link.transmit(hop_limit_exceeded, p)
         else
            packet.free(p)
            counter.add(self.shm.protocol_errors)
         end
      end
   end
end
