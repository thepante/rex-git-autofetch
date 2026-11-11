local dir = debug.getinfo(1, "S").source:match("^@?(.*)/[^/]+$") or "."
local internals = dofile(dir .. "/../init.lua")._test
local validate = internals.validate
local pattern_match = internals.pattern_match
local home = os.getenv("HOME")

-- The counts live in tables: once pcall catches an error, Rex's Lua stops
-- sharing a number local between this chunk and check().
local passed = {}
local failed = {}

local function check(name, ok)
  local list = ok and passed or failed
  list[#list + 1] = name
end

local function rejects(input, message)
  local ok, err = pcall(validate, input)
  return not ok and tostring(err):find(message, 1, true) ~= nil
end

local matches = {
  { "/vendor/", "/a/vendor/b", true },
  { "/vendor/", "/a/vendors/b", false },
  { "/a.b-c/", "/x/a.b-c/y", true },
  { "^/Users/x/", "/Users/x/Projects", true },
  { "^/Users/x/", "/a/Users/x/", false },
  { "/foo$", "/Users/x/Projects/foo", true },
  { "/foo$", "/Users/x/Projects/foo/foo", true },
  { "/foo$", "/Users/x/foo/bar", false },
  { "/Users/x/Projects/foo$", "/foo", false },
  { "^/Users/x$", "/Users/x", true },
  { "^/Users/x$", "/Users/x/y", false },
  { "/work/", "/a/work", true },
  { "/work/", "/a/work/sub", true },
  { "/work/", "/a/worker", false },
  { "^/Users/x/Projects/", "/Users/x/Projects", true },
  { "^/Users/x/Projects/", "/Users/x/Projects2", false },
  { "/foo/$", "/x/foo", true },
  { "/foo/$", "/x/foo/bar", false },
}
for _, case in ipairs(matches) do
  check(case[1] .. " against " .. case[2], pattern_match(case[1], case[2]) == case[3])
end

local defaults = validate(nil)
check("defaults", defaults.enabled == true and defaults.frequency == 3 and
  defaults.scan_interval == 60 and defaults.timeout == 10 and defaults.git == "git" and
  defaults.log == false and defaults.scan_paths == nil and defaults.skip_paths == nil)
check("default state_dir", defaults.state_dir:match("/rex%-git%-autofetch$") ~= nil)
check("state_dir expands ~", validate({ state_dir = "~/x" }).state_dir == home .. "/x")
check("a string pattern becomes a list", validate({ skip_paths = "/vendor/" }).skip_paths[1] == "/vendor/")
check("a pattern expands ~", validate({ scan_paths = { "~/a" } }).scan_paths[1] == home .. "/a")
check("a pattern expands ~ after ^", validate({ scan_paths = { "^~/a/" } }).scan_paths[1] == "^" .. home .. "/a/")
check("frequency 0 is valid", validate({ frequency = 0 }).frequency == 0)

check("rejects a non-table", rejects("x", "expects a table"))
check("rejects an unknown option", rejects({ nope = 1 }, "unknown option nope"))
check("rejects enabled", rejects({ enabled = "yes" }, "enabled must be"))
check("rejects frequency", rejects({ frequency = -1 }, "frequency must be"))
check("rejects scan_interval", rejects({ scan_interval = 4 }, "scan_interval must be"))
check("rejects timeout", rejects({ timeout = 0 }, "timeout must be"))
check("rejects git", rejects({ git = "" }, "git must be"))
check("rejects ssh_command", rejects({ ssh_command = 1 }, "ssh_command must be"))
check("rejects log", rejects({ log = 1 }, "log must be"))
check("rejects state_dir", rejects({ state_dir = 1 }, "state_dir must be"))
check("rejects a pattern type", rejects({ scan_paths = 1 }, "scan_paths must be"))
check("rejects a pattern entry", rejects({ skip_paths = { 1 } }, "skip_paths must contain only strings"))

if #failed > 0 then
  error(#failed .. " failed:\n" .. table.concat(failed, "\n"), 0)
end
return { passed = #passed }
