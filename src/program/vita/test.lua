-- Use of this source code is governed by the GNU AGPL license; see COPYING.

module(...,package.seeall)

local vita = require("program.vita.vita")
local worker = require("core.worker")
local lib = require("core.lib")
local CPUSet = require("lib.cpuset")
local basic_apps = require("apps.basic.basic_apps")
local Synth = require("apps.test.synth").Synth
local Receiver = require("apps.interlink.receiver")
local Transmitter = require("apps.interlink.transmitter")
local PcapFilter = require("apps.packet_filter.pcap_filter").PcapFilter
local get_monotonic_time = require("ffi").C.get_monotonic_time
local ethernet= require("lib.protocol.ethernet")
local ipv4 = require("lib.protocol.ipv4")
local datagram = require("lib.protocol.datagram")
local yang = require("lib.yang.yang")


-- Testing apps for Vita

GenerateLoad = {}

function GenerateLoad:new (testconf)
   return Synth:new{packets=gen_packets(testconf), sizes={false}}
end

GaugeThroughput = {
   config = {
      name = {default="GaugeThroughput"},
      npackets = {default=1e6},
      exit_on_completion = {default=false}
   }
}

function GaugeThroughput:new (conf)
   local self = setmetatable(conf, { __index = GaugeThroughput })
   self.report = lib.logger_new({module=self.name})
   self.progress = lib.throttle(3)
   self:init{start=false}
   return self
end

function GaugeThroughput:push ()
   local input, output = self.input.input, self.output.output
   while not link.empty(input) do
      local p = link.receive(input)
      self:count(p)
      if output then
         link.transmit(output, p)
      else
         packet.free(p)
      end
   end
   if self.progress() then
      self:report_progress()
   end
   if self:gauge() then
      if self.exit_on_completion then
         main.exit()
      else
         self:init{start=true}
      end
   end
end

function GaugeThroughput:init (opt)
   self.packets, self.bytes, self.bits = 0, 0, 0
   self.start = opt.start and get_monotonic_time()
end

function GaugeThroughput:count (p)
   self.packets = self.packets + 1
   self.bytes = self.bytes + p.length
   self.bits = self.bits + packet.physical_bits(p)
end

function GaugeThroughput:report_progress ()
   local packets, npackets = self.packets, self.npackets
   if self.start then
      self.report:log(("Processed %s packets (%.0f%%)")
            :format(lib.comma_value(packets), packets / npackets * 100))
   else
      self.report:log(("Warming up... (%d packets)"):format(packets))
   end
end

function GaugeThroughput:gauge ()
   -- Exempt warmup packets from gauge.
   if not self.start and self.packets > engine.pull_npackets*2 then
      self:init{start=true}
   -- Report gauge stats.
   elseif self.start and self.packets >= self.npackets then
      local runtime = get_monotonic_time() - self.start
      local packets, bytes, bits = self.packets, self.bytes, self.bits
      self.report:log(("Processed %.1f million packets in %.2f seconds")
            :format(packets / 1e6, runtime))
      self.report:log(("%.3f Mpps"):format(packets / runtime / 1e6))
      self.report:log(("%d Bytes"):format(bytes))
      self.report:log(("%.3f Gbps (on GbE)"):format(bits / 1e9 / runtime))
      return true
   end
end


-- Testing setups for Vita

-- Run Vita in software benchmark mode.
function run_softbench (pktsize, npackets, nroutes, cpuspec, use_v6)
   local testconf = {
      private_interface4 = {
         nexthop_ip4 = private_interface4_defaults.ip4.default
      },
      packet_size = pktsize,
      nroutes = nroutes,
      negotiation_ttl = nroutes,
      sa_ttl = 16
   }
   if use_v6 then
      testconf.public_interface6 = {
         [public_interface6_defaults.nexthop_ip6.default] = {}
      }
   end

   local function configure_vita_softbench (conf)
      local c, private, public = vita.configure_vita_queue(conf, 1, 'free')

      config.app(c, "bridge", basic_apps.Join)
      config.link(c, "bridge.output -> "..private.input)

      config.app(c, "synth", GenerateLoad, testconf)
      config.link(c, "synth.output -> bridge.synth")

      config.app(c, "gauge", GaugeThroughput, {
                    name = "SoftBench",
                    npackets = npackets,
                    exit_on_completion = true
      })
      config.link(c, private.output.." -> gauge.input")

      config.app(c, "sieve", PcapFilter, {filter="arp"})
      config.link(c, "gauge.output -> sieve.input")
      config.link(c, "sieve.output -> bridge.arp")

      config.link(c, public.output.." -> "..public.input)

      return c
   end

   local function softbench_worker (conf)
      return { softbench = configure_vita_softbench(conf) }
   end

   local function wait_gauge ()
      if not worker.status().softbench.alive then
         main.exit()
      end
   end
   timer.activate(timer.new('wait_gauge', wait_gauge, 1e9/10, 'repeating'))

   local cpuset = CPUSet:new()
   if cpuspec then
      CPUSet.global_cpuset():add_from_string(cpuspec)
   end

   vita.run_vita{
      setup_fn = softbench_worker,
      initial_configuration = gen_configuration(testconf),
      cpuset = cpuspec and CPUSet:new():add_from_string(cpuspec)
   }
end


-- Test case generation for Vita via synthetic traffic and configurations.
-- Exposes configuration knobs like “number of routes” and “packet size”.
--
-- Produces a set of test packets and a matching vita-esp-gateway configuration
-- in loopback mode by default. I.e., potentially many routes to a single
-- destination.

defaults = {
   private_interface4 = {},
   public_interface4 = {default={["172.16.0.10"]={queue=1}}},
   public_interface6 = {default={}},
   route_prefix = {default="172.16"},
   nroutes = {default=1},
   packet_size = {default="IMIX"},
   sa_ttl = {},
   negotiation_ttl = {default=1}
}
private_interface4_defaults = {
   pci = {default="00:00.0"},
   mac = {default="02:00:00:00:00:01"}, -- needed because used in sim. packets
   ip4 = {default="172.16.0.10"},
   nexthop_ip4 = {default="172.16.1.1"},
   nexthop_mac = {}
}
public_interface4_defaults = {
   pci = {default="00:00.0"},
   mac = {},
   nexthop_ip4 = {default="172.16.0.10"},
   nexthop_mac = {},
   queue = {default=1}
}
public_interface6_defaults = {
   pci = {default="00:00.0"},
   mac = {},
   nexthop_ip6 = {default="172:16:0::10"},
   nexthop_mac = {},
   queue = {default=1}
}

traffic_templates = {
   -- Internet Mix, see https://en.wikipedia.org/wiki/Internet_Mix
   IMIX = { 54, 54, 54, 54, 54, 54, 54, 590, 590, 590, 590, 1514 }
}

local function parse_gentestconf (conf)
   -- default to v4
   conf.private_interface4 = (not conf.private_interface6) and
                             (conf.private_interface4 or {})
   conf.public_interface4 = (conf.public_interface6 and {}) or
                            conf.public_interface4
   -- populate defaults
   conf = lib.parse(conf, defaults)
   conf.private_interface4 = conf.private_interface4 and
      lib.parse(conf.private_interface4, private_interface4_defaults)
   for ip4, interface in pairs(conf.public_interface4) do
      conf.public_interface4[ip4] =
         lib.parse(interface, public_interface4_defaults)
   end
   for ip6, interface in pairs(conf.public_interface6) do
      conf.public_interface6[ip6] =
         lib.parse(interface, public_interface6_defaults)
   end
   assert(conf.nroutes >= 0 and conf.nroutes <= 255,
          "Invalid number of routes: "..conf.nroutes)
   return conf
end

function gen_packet (conf, route, size)
   local payload_size = size - ethernet:sizeof() - ipv4:sizeof()
   assert(payload_size >= 0, "Negative payload_size :-(")
   local d = datagram:new(packet.resize(packet.allocate(), payload_size))
   d:push(ipv4:new{ src = ipv4:pton(conf.private_interface4.nexthop_ip4),
                    dst = ipv4:pton(conf.route_prefix.."."..route.."."..math.random(254)),
                    total_length = ipv4:sizeof() + payload_size,
                    ttl = 64 })
   d:push(ethernet:new{ dst = ethernet:pton(conf.private_interface4.mac),
                        type = 0x0800 })
   local p = d:packet()
   -- Pad to minimum Ethernet frame size (excluding four octet CRC)
   return packet.resize(p, math.max(60, p.length))
end

-- Return simulation packets for test conf.
function gen_packets (conf)
   conf = parse_gentestconf(conf)
   local sim_packets = {}
   local sizes = traffic_templates[conf.packet_size]
              or {tonumber(conf.packet_size)}
   for _, size in ipairs(sizes) do
      for i = 1, math.floor(1000 / #sizes / conf.nroutes) do
         for route = 1, conf.nroutes do
            table.insert(sim_packets, gen_packet(conf, route, size))
         end
      end
   end
   return sim_packets
end

-- Return Vita config for test conf.
function gen_configuration (conf)
   conf = parse_gentestconf(conf)
   local cfg = {
      private_interface4 = conf.private_interface4,
      public_interface4 = conf.public_interface4,
      public_interface6 = conf.public_interface6,
      route4 = {},
      route46 = {},
      negotiation_ttl = conf.negotiation_ttl,
      sa_ttl = conf.sa_ttl
   }
   local function has (map) for k,v in pairs(map) do return true end end
   local routes =
      (cfg.private_interface4 and has(cfg.public_interface4) and cfg.route4) or
      (cfg.private_interface4 and has(cfg.public_interface6) and cfg.route46)
   for route = 1, conf.nroutes do
      local r = {
         net_cidr4 = conf.route_prefix.."."..route..".0/24",
         gateway = {},
         preshared_key = ("%064x"):format(route),
         spi = 1000+route
      }
      for _, interface in pairs(conf.public_interface4) do
         r.gateway[interface.nexthop_ip4] = {queue=interface.queue}
      end
      for _, interface in pairs(conf.public_interface6) do
         r.gateway[interface.nexthop_ip6] = {queue=interface.queue}
      end
      routes["test"..route] = r
   end
   return cfg
end

-- Include vita-gentest YANG schema.
yang.add_schema(require("program.vita.vita_gentest_yang",
                        "program/vita/vita-gentest.yang"))
schemata = {
   ['gentest'] = yang.load_schema_by_name('vita-gentest')
}
