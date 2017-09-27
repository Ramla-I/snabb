-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

local shm = require("core.shm")
local lib = require("core.lib")
local worker = require("core.worker")
local counter = require("core.counter")
local vita = require("program.vita.vita")
local basic_apps = require("apps.basic.basic_apps")
local Synth = require("apps.test.synth").Synth
local PcapFilter = require("apps.packet_filter.pcap_filter").PcapFilter
local ethernet= require("lib.protocol.ethernet")
local ipv4 = require("lib.protocol.ipv4")
local datagram = require("lib.protocol.datagram")

-- sudo ./snabb snsh program/vita/test.lua [<pktsize>|IMIX] [<npackets>]
-- default is 10 million packets at IMIX                (-:

local IMIX = { 54, 54, 54, 54, 54, 54, 54, 590, 590, 590, 590, 1514 }

function test_packets (pktsize)
   pktsize = pktsize ~= "IMIX" and tonumber(pktsize)
   local sizes = (pktsize and {pktsize}) or IMIX
   local packets = {}
   for _, size in ipairs(sizes) do
      local payload_size = size - ethernet:sizeof() - ipv4:sizeof()
      assert(payload_size >= 0, "Negative payload_size :-(")
      local d = datagram:new(packet.resize(packet.allocate(), payload_size))
      d:push(ipv4:new{ src = ipv4:pton("192.168.10.100"),
                       dst = ipv4:pton("192.168.10.200"),
                       ttl = 64 })
      d:push(ethernet:new{ src = ethernet:pton("52:54:00:00:00:00"),
                           dst = ethernet:pton("52:54:00:00:00:00"),
                           type = 0x0800 })
      packets[#packets+1] = d:packet()
   end
   return packets
end


local conf = {
  node_mac = "52:54:00:00:00:00",
   node_ip4 = "192.168.10.1",
   private_nexthop_ip4 = "192.168.10.1",
   public_nexthop_ip4 = "192.168.10.1",
   routes = {
      {
         net_cidr4 = "192.168.10.0/24",
         gw_ip4 = "192.168.10.1",
         preshared_key = string.rep("00", 512)
      }
   },
   negotiation_ttl = 1
}

local c, private = vita.configure_private_router(conf, config.new())

config.app(c, "bridge", basic_apps.Join)
config.link(c, "bridge.output -> "..private.input)

config.app(c, "synth", Synth, {packets=test_packets(main.parameters[1])})
config.link(c, "synth.output -> bridge.synth")

config.app(c, "sieve", PcapFilter, {filter="arp"})
config.link(c, private.output.." -> sieve.input")
config.link(c, "sieve.output -> bridge.arp")

engine.log = true
engine.configure(c)

local confpath = shm.root.."/"..shm.resolve("group/testconf")
worker.start(
   "PublicRouter",
   ([[require("program.vita.vita").public_router_loopback_worker(%q)]])
      :format(confpath)
)
lib.store_conf(confpath, conf)

worker.start("ESP", [[require("program.vita.vita").esp_worker()]])
worker.start("DSP", [[require("program.vita.vita").dsp_worker()]])


-- adapted from snabbnfv traffic

local npackets = tonumber(main.parameters[2]) or 10e6
local get_monotonic_time = require("ffi").C.get_monotonic_time
local start, packets, bytes = 0, 0, 0
local dest_link = engine.app_table.sieve.input.input
local function done ()
   local txpackets = counter.read(dest_link.stats.txpackets)
   local txbytes = counter.read(dest_link.stats.txbytes)
   if start == 0 and txpackets > 100 then
      -- started receiving, record time and packet count
      print("TEST START")
      packets = txpackets
      bytes = txbytes
      start = get_monotonic_time()
   end
   return txpackets - packets >= npackets
end

engine.main({done=done, report={showlinks=true}})
local finish = get_monotonic_time()

local runtime = finish - start
local breaths = tonumber(counter.read(engine.breaths))
packets = tonumber(counter.read(dest_link.stats.txpackets) - packets)
bytes = tonumber(counter.read(dest_link.stats.txbytes) - bytes)

for w, s in pairs(worker.status()) do
   print(("worker %s: pid=%s alive=%s status=%s"):format(
         w, s.pid, s.alive, s.status))
end

print(("Processed %.1f million packets in %.2f seconds (%d bytes; %.2f Gbps)"):format(packets / 1e6, runtime, bytes, bytes * 8.0 / 1e9 / runtime))
print(("Made %s breaths: %.2f packets per breath; %.2fus per breath"):format(lib.comma_value(breaths), packets / breaths, runtime / breaths * 1e6))
print(("Rate(Mpps):\t%.3f"):format(packets / runtime / 1e6))
