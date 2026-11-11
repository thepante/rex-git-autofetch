-- rex-git-autofetch fetches the git repositories open in Rex terminals, each at
-- most once every `frequency` minutes.
--
-- The file has two roles. Loaded from init.lua with require(), setup() defines
-- the actions and starts the watcher. Run with `rex do --all`, the same file is
-- the watcher: a timer scans the panes and terminal.pwd_changed triggers a scan
-- earlier for shells that report their directory.

local VERSION = "1.2.0"
local MODULE = "rex-git-autofetch"
local TERMINAL = "com.superlogical.terminal"
local LOG_LIMIT = 1024 * 1024

local DEFAULTS = {
  enabled = true,
  frequency = 3,
  scan_interval = 60,
  timeout = 10,
  git = "git",
  ssh_command = nil,
  scan_paths = nil,
  skip_paths = nil,
  log = false,
  state_dir = nil,
}

local KNOWN = {
  enabled = true,
  frequency = true,
  scan_interval = true,
  timeout = true,
  git = true,
  ssh_command = true,
  scan_paths = true,
  skip_paths = true,
  log = true,
  state_dir = true,
}

local function trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function expand_home(path)
  if path:sub(1, 1) == "~" then
    return (os.getenv("HOME") or "") .. path:sub(2)
  end
  return path
end

local function default_state_dir()
  local base = os.getenv("XDG_STATE_HOME")
  if base == nil or base == "" then
    base = (os.getenv("HOME") or ".") .. "/.local/state"
  end
  return base .. "/" .. MODULE
end

local function normalize_patterns(value, name)
  if value == nil then
    return nil
  end
  local list
  if type(value) == "string" then
    list = { value }
  elseif type(value) == "table" then
    list = value
  else
    error(name .. " must be a string or a list of strings", 0)
  end
  local patterns = {}
  for index, pattern in ipairs(list) do
    if type(pattern) ~= "string" then
      error(name .. " must contain only strings", 0)
    end
    local anchor, rest = pattern:match("^(%^?)(.*)$")
    patterns[index] = anchor .. expand_home(rest)
  end
  return patterns
end

local function validate(input)
  local opts = {}
  for key, value in pairs(DEFAULTS) do
    opts[key] = value
  end
  if input ~= nil then
    if type(input) ~= "table" then
      error(MODULE .. ".setup expects a table", 0)
    end
    for key, value in pairs(input) do
      if not KNOWN[key] then
        error(MODULE .. ".setup: unknown option " .. tostring(key), 0)
      end
      opts[key] = value
    end
  end

  if type(opts.enabled) ~= "boolean" then
    error("enabled must be a boolean", 0)
  end
  if type(opts.frequency) ~= "number" or opts.frequency < 0 then
    error("frequency must be a number of minutes, 0 or more", 0)
  end
  if type(opts.scan_interval) ~= "number" or opts.scan_interval < 5 then
    error("scan_interval must be a number of seconds, 5 or more", 0)
  end
  if type(opts.timeout) ~= "number" or opts.timeout < 1 then
    error("timeout must be a number of seconds, 1 or more", 0)
  end
  if type(opts.git) ~= "string" or opts.git == "" then
    error("git must be the name or path of the git program", 0)
  end
  if opts.ssh_command ~= nil and type(opts.ssh_command) ~= "string" then
    error("ssh_command must be a string", 0)
  end
  if type(opts.log) ~= "boolean" then
    error("log must be a boolean", 0)
  end
  if opts.state_dir ~= nil and type(opts.state_dir) ~= "string" then
    error("state_dir must be a string", 0)
  end

  opts.scan_paths = normalize_patterns(opts.scan_paths, "scan_paths")
  opts.skip_paths = normalize_patterns(opts.skip_paths, "skip_paths")
  opts.state_dir = expand_home(opts.state_dir or default_state_dir())
  return opts
end

local function pattern_match(pattern, path)
  local anchored_start = pattern:sub(1, 1) == "^"
  local anchored_end = pattern:sub(-1) == "$"
  local text = pattern
  if anchored_start then
    text = text:sub(2)
  end
  if anchored_end then
    text = text:sub(1, -2)
  end
  -- "/work/" also matches a pane in /work itself, not only below it.
  if text:sub(-1) == "/" and path:sub(-1) ~= "/" then
    path = path .. "/"
  end
  if anchored_start and anchored_end then
    return path == text
  end
  if anchored_start then
    return path:sub(1, #text) == text
  end
  if anchored_end then
    return path:sub(-#text) == text
  end
  return path:find(text, 1, true) ~= nil
end

local function any_match(patterns, path)
  for _, pattern in ipairs(patterns) do
    if pattern_match(pattern, path) then
      return true
    end
  end
  return false
end

local function allowed(opts, path)
  if opts.skip_paths and any_match(opts.skip_paths, path) then
    return false
  end
  if opts.scan_paths and not any_match(opts.scan_paths, path) then
    return false
  end
  return true
end

local function read_file(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  return text
end

local function write_file(path, text)
  local file = io.open(path, "w")
  if not file then
    return false
  end
  file:write(text)
  file:close()
  return true
end

local function read_json(path)
  local text = read_file(path)
  if not text or text == "" then
    return nil
  end
  local value = rex.json.decode(text)
  return value
end

local function write_json(path, value)
  local text = rex.json.encode(value, { indent = true })
  if not text then
    return false
  end
  local temporary = path .. ".tmp"
  if not write_file(temporary, text .. "\n") then
    return false
  end
  return os.rename(temporary, path) ~= nil
end

local function deep_equal(left, right)
  if type(left) ~= type(right) then
    return false
  end
  if type(left) ~= "table" then
    return left == right
  end
  for key, value in pairs(left) do
    if not deep_equal(value, right[key]) then
      return false
    end
  end
  for key in pairs(right) do
    if left[key] == nil then
      return false
    end
  end
  return true
end

local function process_alive(pid)
  local result = rex.exec({ "kill", "-0", tostring(pid) }, { stdout = false, stderr = false })
  return result ~= nil and result.ok
end

local function process_command(pid)
  local result = rex.exec({ "ps", "-p", tostring(pid), "-o", "args=" }, { stderr = false })
  if result and result.ok then
    return trim(result.stdout)
  end
  return ""
end

local function executable(path)
  if not path or path == "" then
    return false
  end
  local result = rex.exec({ "test", "-x", path }, { stdout = false, stderr = false })
  return result ~= nil and result.ok
end

local function rex_binary()
  local bin_dir = os.getenv("REX_BIN_DIR")
  if bin_dir then
    local path = bin_dir .. "/rex"
    if executable(path) then
      return path
    end
  end
  local found = rex.exec({ "sh", "-c", "command -v rex 2>/dev/null" }, { stderr = false })
  if found and found.ok then
    local path = trim(found.stdout)
    if executable(path) then
      return path
    end
  end
  local candidates = {
    (os.getenv("HOME") or "") .. "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex",
    "/Applications/Rex.app/Contents/MacOS/rex",
    "/usr/local/bin/rex",
    "/opt/homebrew/bin/rex",
  }
  for _, path in ipairs(candidates) do
    if executable(path) then
      return path
    end
  end
  return nil
end

local function config_dir()
  local xdg = os.getenv("XDG_CONFIG_HOME")
  if xdg and xdg ~= "" then
    return xdg .. "/rex"
  end
  return (os.getenv("HOME") or ".") .. "/.config/rex"
end

local function module_path()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  if source:sub(1, 1) ~= "/" then
    source = config_dir() .. "/" .. source
  end
  return source
end

local function run_git(opts, arguments, extra)
  local argv = { opts.git }
  for _, argument in ipairs(arguments) do
    argv[#argv + 1] = argument
  end
  local call_opts = { stderr = false }
  if extra then
    for key, value in pairs(extra) do
      call_opts[key] = value
    end
  end
  return rex.exec(argv, call_opts)
end

local function common_dir(opts, path)
  local result = run_git(opts, { "-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir" })
  if not result or not result.ok then
    result = run_git(opts, { "-C", path, "rev-parse", "--git-common-dir" })
  end
  if not result or not result.ok then
    return nil
  end
  local dir = trim(result.stdout)
  if dir == "" then
    return nil
  end
  if dir:sub(1, 1) ~= "/" then
    dir = path:gsub("/+$", "") .. "/" .. dir
  end
  return dir
end

local function error_text(opts, result)
  if not result then
    return "git did not run"
  end
  if result.timed_out then
    return "timed out after " .. opts.timeout .. " seconds"
  end
  local text = trim(result.stderr or "")
  if text == "" then
    text = trim(result.stdout or "")
  end
  if text == "" then
    text = "exit status " .. tostring(result.code)
  end
  if #text > 500 then
    text = text:sub(1, 500)
  end
  return text
end

local function fetch(opts, dir)
  local env = { GIT_TERMINAL_PROMPT = "0" }
  if opts.ssh_command then
    env.GIT_SSH_COMMAND = opts.ssh_command
  end
  return rex.exec({ opts.git, "-C", dir, "fetch", "--quiet", "--all" }, {
    env = env,
    timeout = opts.timeout,
  })
end

local function log_line(opts, line)
  if not opts.log then
    return
  end
  local path = opts.state_dir .. "/git-autofetch.log"
  local file = io.open(path, "a")
  if not file then
    return
  end
  file:write(os.date("%Y-%m-%d %H:%M:%S "), line, "\n")
  local size = file:seek("end")
  file:close()
  if size and size > LOG_LIMIT then
    os.rename(path, path .. ".1")
  end
end

local function daemon_args(opts)
  return {
    daemon = true,
    version = VERSION,
    enabled = true,
    frequency = opts.frequency,
    scan_interval = opts.scan_interval,
    timeout = opts.timeout,
    git = opts.git,
    ssh_command = opts.ssh_command,
    scan_paths = opts.scan_paths,
    skip_paths = opts.skip_paths,
    log = opts.log,
    state_dir = opts.state_dir,
  }
end

local function read_pid(state_dir)
  local text = read_file(state_dir .. "/daemon.pid")
  if not text then
    return nil
  end
  return tonumber(trim(text))
end

local function daemon_running(state_dir)
  local pid = read_pid(state_dir)
  if not pid or not process_alive(pid) then
    return nil
  end
  local current = read_json(state_dir .. "/daemon.json")
  -- A watcher started before 1.1.0 has no token: its command names the module.
  local marker = current and current.token or MODULE
  if not process_command(pid):find(marker, 1, true) then
    return nil
  end
  return pid
end

local function format_time(value)
  return value and os.date("%Y-%m-%d %H:%M:%S", value)
end

local function stop(opts)
  local pid = daemon_running(opts.state_dir)
  if pid then
    rex.exec({ "kill", "-TERM", tostring(pid) }, { stdout = false, stderr = false })
  end
  -- Without daemon.json, a watcher the PID file does not name stops too.
  os.remove(opts.state_dir .. "/daemon.json")
  return { running = false }
end

local setup
local start

local function define_actions(opts)
  rex.action({
    name = "git_autofetch_status",
    title = "Git Autofetch: Status",
    description = "Report the git-autofetch watcher and the repositories it fetched.",
    keywords = "git autofetch fetch status",
    run = function()
      local pid = daemon_running(opts.state_dir)
      local state = read_json(opts.state_dir .. "/state.json")
      local stale = false
      if state then
        stale = pid ~= nil and state.last_scan ~= nil and
          os.time() - state.last_scan > opts.scan_interval * 3
        state.started_at = format_time(state.started_at)
        state.last_scan = format_time(state.last_scan)
        for _, repo in ipairs(state.repos or {}) do
          repo.last_fetch = format_time(repo.last_fetch)
        end
      end
      return {
        running = pid ~= nil,
        pid = pid,
        stale = stale,
        state = state,
      }
    end,
  })
  rex.action({
    name = "git_autofetch_start",
    title = "Git Autofetch: Start",
    description = "Start the git-autofetch watcher if it is not running.",
    keywords = "git autofetch fetch start",
    run = function()
      return start(opts)
    end,
  })
  rex.action({
    name = "git_autofetch_stop",
    title = "Git Autofetch: Stop",
    description = "Stop the git-autofetch watcher until the next start or reload.",
    keywords = "git autofetch fetch stop",
    run = function()
      return stop(opts)
    end,
  })
  rex.action({
    name = "git_autofetch_fetch",
    title = "Git Autofetch: Fetch Now",
    description = "Fetch the repository of the active pane now.",
    keywords = "git autofetch fetch now",
    run = function(ctx)
      local process = rex.call("block.method", {
        session_id = ctx.session_id,
        block_id = ctx.block_id,
        method = "process",
      })
      local cwd = process and process.foreground and process.foreground.cwd
      local dir = cwd and common_dir(opts, cwd)
      if not dir then
        return { fetched = false, error = "the active pane is not in a git repository" }
      end
      local result = fetch(opts, dir)
      if result and result.ok then
        return { fetched = true, dir = dir }
      end
      return { fetched = false, dir = dir, error = error_text(opts, result) }
    end,
  })
end

start = function(opts)
  if not opts.enabled then
    return stop(opts)
  end
  rex.exec({ "mkdir", "-p", opts.state_dir }, { stdout = false, stderr = false })

  local args = daemon_args(opts)
  local pid = daemon_running(opts.state_dir)
  if pid then
    local current = read_json(opts.state_dir .. "/daemon.json")
    args.token = current and current.token
    if deep_equal(current, args) then
      return { running = true, pid = pid }
    end
    rex.exec({ "kill", "-TERM", tostring(pid) }, { stdout = false, stderr = false })
  end

  -- os.clock tells apart two starts within the same second.
  args.token = "watcher-" .. os.time() .. "-" .. os.clock()
  local encoded = rex.json.encode(args)
  if not encoded then
    rex.log("warn", MODULE .. ": cannot encode the configuration")
    return { running = false }
  end
  local binary = rex_binary()
  if not binary then
    rex.log("warn", MODULE .. ": rex not found, the watcher did not start")
    return { running = false }
  end
  -- daemon.json goes first: the watcher checks its token in it on its first scan.
  if not write_json(opts.state_dir .. "/daemon.json", args) then
    rex.log("warn", MODULE .. ": cannot write to " .. opts.state_dir)
    return { running = false }
  end
  local handle, err = rex.exec.start({ binary, "do", "--all", module_path(), "--args", encoded }, {
    detach = true,
    stdout = false,
    stderr = false,
  })
  if not handle then
    rex.log("warn", MODULE .. ": " .. tostring(err))
    return { running = false }
  end
  write_file(opts.state_dir .. "/daemon.pid", tostring(handle.pid))
  return { running = true, pid = handle.pid }
end

setup = function(input)
  local opts = validate(input)
  if opts.enabled then
    define_actions(opts)
  end
  return start(opts)
end

-- Each failure in a row doubles the wait, up to eight times `frequency`, so an
-- unreachable remote is not tried again every few minutes.
local function fetch_due(opts, repo, now)
  local wait = opts.frequency * 60 * 2 ^ math.min(repo.failures or 0, 3)
  return now - (repo.last_fetch or 0) >= wait
end

local function scan_once(opts, state)
  local now = os.time()
  local paths = {}
  local scanned_sessions = 0
  local scanned_blocks = 0
  local scanned_paths = 0
  local sessions = rex.call("session.list")
  if sessions and sessions.sessions then
    for _, session in ipairs(sessions.sessions) do
      scanned_sessions = scanned_sessions + 1
      local blocks, blocks_error = rex.call("session.list_blocks", { session_id = session.session_id })
      if not blocks then
        log_line(opts, "blocks " .. session.session_id .. ": " .. tostring(blocks_error))
      end
      if blocks and blocks.blocks then
        for _, block in ipairs(blocks.blocks) do
          scanned_blocks = scanned_blocks + 1
          if block.creator_name == TERMINAL and block.block_id and
            (state.host_id == nil or block.host_id == state.host_id) then
            local process = rex.call("block.method", {
              session_id = session.session_id,
              block_id = block.block_id,
              method = "process",
            })
            local cwd = process and process.foreground and process.foreground.cwd
            if cwd and cwd ~= "" and allowed(opts, cwd) then
              if not paths[cwd] then
                scanned_paths = scanned_paths + 1
              end
              paths[cwd] = true
            end
          end
        end
      end
    end
  end

  local seen = {}
  local fetched = 0
  local failed = 0
  for path in pairs(paths) do
    local dir = common_dir(opts, path)
    if dir then
      seen[dir] = true
      local repo = state.repos[dir] or { last_fetch = 0 }
      repo.path = path
      state.repos[dir] = repo
      if fetch_due(opts, repo, now) then
        repo.last_fetch = now
        local result = fetch(opts, dir)
        if result and result.ok then
          repo.error = nil
          repo.failures = nil
          fetched = fetched + 1
          log_line(opts, "fetched " .. dir)
        else
          repo.error = error_text(opts, result)
          repo.failures = (repo.failures or 0) + 1
          failed = failed + 1
          log_line(opts, "failed " .. dir .. ": " .. repo.error)
        end
      end
    end
  end
  -- A repository out of sight keeps its entry until its window passes:
  -- dropping it at once made leaving and re-entering fetch again.
  for dir, repo in pairs(state.repos) do
    if not seen[dir] and fetch_due(opts, repo, now) then
      state.repos[dir] = nil
    end
  end
  state.last_scan = now
  state.last_scan_reason = state.reason
  state.fetched = fetched
  state.failed = failed
  local summary = string.format("sessions=%d blocks=%d paths=%d fetched=%d failed=%d",
    scanned_sessions, scanned_blocks, scanned_paths, fetched, failed)
  if summary ~= state.logged_summary then
    state.logged_summary = summary
    log_line(opts, "scan (" .. state.reason .. "): " .. summary)
  end
  return fetched, failed
end

local function run_daemon(args)
  local input = {}
  for key, value in pairs(args) do
    if key ~= "daemon" and key ~= "version" and key ~= "token" then
      input[key] = value
    end
  end
  local opts = validate(input)
  rex.exec({ "mkdir", "-p", opts.state_dir }, { stdout = false, stderr = false })

  local status = rex.call("server.status")
  local state = {
    repos = {},
    host_id = status and status.host_id,
    started_at = os.time(),
    reason = "start",
  }
  local previous = read_json(opts.state_dir .. "/state.json")
  if previous and type(previous.repos) == "table" then
    for _, repo in ipairs(previous.repos) do
      if repo.dir then
        state.repos[repo.dir] = {
          path = repo.path,
          last_fetch = repo.last_fetch or 0,
          error = repo.error,
          failures = repo.failures,
        }
      end
    end
  end

  local function save_state()
    local repos = {}
    for dir, repo in pairs(state.repos) do
      repos[#repos + 1] = {
        dir = dir,
        path = repo.path,
        last_fetch = repo.last_fetch,
        error = repo.error,
        failures = repo.failures,
      }
    end
    table.sort(repos, function(left, right)
      return (left.path or "") < (right.path or "")
    end)
    write_json(opts.state_dir .. "/state.json", {
      version = VERSION,
      pid = read_pid(opts.state_dir),
      host_id = state.host_id,
      started_at = state.started_at,
      last_scan = state.last_scan,
      last_scan_reason = state.last_scan_reason,
      fetched = state.fetched,
      failed = state.failed,
      repos = repos,
    })
  end

  local function scan(reason)
    -- start() names the watcher in charge in daemon.json. One that was
    -- replaced, or whose state directory is gone, stops here.
    local current = read_json(opts.state_dir .. "/daemon.json")
    if not current or current.token ~= args.token then
      rex.stop()
      return
    end
    state.reason = reason
    scan_once(opts, state)
    save_state()
  end

  local pending
  local function schedule(reason)
    if pending then
      pending:cancel()
    end
    pending = rex.after(2, function()
      pending = nil
      scan(reason)
    end)
  end

  rex.every(opts.scan_interval, function()
    scan("timer")
  end)
  rex.on("terminal.pwd_changed", function()
    schedule("pwd")
  end)
  rex.log("info", MODULE .. ": started")
  -- The first scan runs from a timer: session.list_blocks answers only once
  -- the script hears the sessions, after its top level returns. Attaching by
  -- hand needs a detach, and a detached session stops sending its events.
  rex.after(0, function()
    scan("start")
  end)
end

if type(rex.args) == "table" and rex.args.daemon then
  run_daemon(rex.args)
  return {}
end

return {
  version = VERSION,
  setup = setup,
  _test = {
    validate = validate,
    pattern_match = pattern_match,
  },
}
