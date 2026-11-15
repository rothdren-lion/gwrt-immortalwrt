package.preload['luci.sys'] = function() return {} end
function translate(s) return s end
NamedSection, ListValue, DynamicList, DummyValue, Value = {}, {}, {}, {}, {}
local options = {}
function Map()
 local map = {}
 function map:section()
  return {option = function(_, _, name)
   local o = {value = function() end}
   options[name] = o
   return o
  end}
 end
 return map
end
local model = arg[1] or '/usr/lib/lua/luci/model/cbi/tvadblock.lua'
assert(loadfile(model))()
local fixtures={
 {'ads.example.com','ads.example.com'},
 {' .Ads.Example.COM ','ads.example.com'},
 {'360.cn','360.cn'},
 {'xn--fiqs8s.example','xn--fiqs8s.example'},
 {'foo..example.com',false},
 {'example.com.',false},
 {'http://ads.example.com',false},
 {'a;reboot.com',false},
 {'-bad.example.com',false},
 {'bad-.example.com',false},
 {string.rep('a',64)..'.example.com',false},
 {'singlelabel',false},
 {'192.168.9.9',false}
}
for _, name in ipairs({'custom_block','custom_allow'}) do
 for _, case in ipairs(fixtures) do
  local result=options[name].validate(options[name], {case[1]})
  local got=result and result[1] or false
  assert(got==case[2], name..': '..case[1]..' got '..tostring(got))
 end
end
print('PASS 26 validation cases on actual Lua 5.1 CBI model')
