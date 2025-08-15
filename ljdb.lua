-- ljdb.lua - LuaJIT / Lua 5.1 debugger module
-- MIT License
-- Features: breakpoints (robust path handling), step over/in/out, stack inspection,
-- backtrace, locals/upvalues, expression eval, source listing, REPL, modular API.

local M = {}

-- ---------------- Utilities & I/O ----------------
local fmt = string.format

local function default_write(s) io.write(s or "") end
local function default_println(...)
  local t = {}
  for i = 1, select("#", ...) do
    t[#t+1] = tostring(select(i, ...))
  end
  io.write(table.concat(t, "\t") .. "\n")
end
local function default_readline(prompt)
  if prompt and prompt ~= "" then io.write(prompt) end
  io.flush()
  return io.read("*l")
end

local IO = { write = default_write, println = default_println, readline = default_readline }
function M.set_io(opts)
  if type(opts) ~= "table" then return end
  if type(opts.write) == "function" then IO.write = opts.write end
  if type(opts.println) == "function" then IO.println = opts.println end
  if type(opts.readline) == "function" then IO.readline = opts.readline end
end

local function trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end
local function saferepr(v, depth)
  depth = depth or 0
  local tv = type(v)
  if tv == "string" then return fmt("%q", v)
  elseif tv == "number" or tv == "boolean" or tv == "nil" then return tostring(v)
  elseif tv == "table" then
    if depth > 1 then return "{...}" end
    local parts, n = {}, 0
    for k, val in pairs(v) do
      n = n + 1
      if n > 8 then parts[#parts + 1] = "…"; break end
      parts[#parts + 1] = "[" .. saferepr(k, depth + 1) .. "]=" .. saferepr(val, depth + 1)
    end
    return "{" .. table.concat(parts, ", ") .. "}"
  else
    local ok, s = pcall(tostring, v)
    return ok and s or ("<" .. tv .. ">")
  end
end

-- Normalizes LuaJIT/Lua source paths for breakpoint matching
local function normalize_source(source)
  if type(source) ~= "string" then return nil end
  if source:sub(1,1) == "@" then source = source:sub(2) end
  source = source:gsub("\\", "/") -- unify slashes
  local f = io.open(source, "r")
  if f then f:close(); return source end
  -- fallback: match basename only
  local basename = source:match("([^/]+)$")
  return basename
end

-- ---------------- Debugger State ----------------
local breakpoints = {}           -- breakpoints[file][line] = true
local bp_list = {}               -- { {file=..., line=...}, ... }
local state = {
  mode = "stop",                -- step, next, finish, run, stop
  stop_depth = 0,
  current_frame = 0,
  current = { file = nil, line = nil },
  pending_cmds = {},
  attached = false,
}
local opts = { repl = true, on_pause = nil }
local QUIT_TOKEN = "__LJDB_QUIT__"

-- ---------------- Helpers ----------------
local function callstack_depth()
  local depth, d = 0, 2
  while debug.getinfo(d, "f") do depth = depth + 1; d = d + 1 end
  return depth
end

local function set_breakpoint(file, line)
  local f = normalize_source(file)
  if not f then
    IO.println("Cannot set breakpoint — invalid file:", file)
    return false
  end
  breakpoints[f] = breakpoints[f] or {}
  breakpoints[f][line] = true
  bp_list[#bp_list + 1] = { file = f, line = line }
  IO.println("Breakpoint set at " .. f .. ":" .. line)
  return true
end

local function clear_breakpoint(ident)
  if tonumber(ident) then
    local idx = tonumber(ident)
    local bp = bp_list[idx]
    if not bp then return false end
    breakpoints[bp.file][bp.line] = nil
    table.remove(bp_list, idx)
    return true
  else
    for i, bp in ipairs(bp_list) do
      if fmt("%s:%s", bp.file, bp.line) == ident then
        breakpoints[bp.file][bp.line] = nil
        table.remove(bp_list, i)
        return true
      end
    end
    return false
  end
end

local function is_breakpoint_hit(file, line)
  local f = normalize_source(file)
  return f and breakpoints[f] and breakpoints[f][line]
end

local function backtrace()
  local i, out = 2, {}
  while true do
    local ar = debug.getinfo(i, "nSlu")
    if not ar then break end
    local f = normalize_source(ar.source) or ar.short_src or "[C]"
    out[#out + 1] = { level = i, file = f, line = ar.currentline, name = ar.name or "<anon>", what = ar.what }
    i = i + 1
  end
  return out
end

local function show_backtrace()
  for idx, fr in ipairs(backtrace()) do
    local mark = (idx - 1 == state.current_frame) and "->" or "  "
    IO.println(fmt("%s #%d  %s:%s in %s [%s]", mark, idx - 1, fr.file, fr.line, fr.name, fr.what))
  end
end

local function show_locals(level)
  local i = 1
  while true do
    local name, val = debug.getlocal(level, i)
    if not name then break end
    if name ~= "(*temporary)" then
      IO.println(fmt("local %s = %s", name, saferepr(val)))
    end
    i = i + 1
  end
end

local function show_upvalues(func)
  if not func then return end
  local i = 1
  while true do
    local name, val = debug.getupvalue(func, i)
    if not name then break end
    IO.println(fmt("upvalue %s = %s", name, saferepr(val)))
    i = i + 1
  end
end

local function show_stack()
  local level = 2 + state.current_frame
  local info = debug.getinfo(level, "nSluf")
  if not info then IO.println("Could not inspect stack frame."); return end
  IO.println(fmt("Stack frame #%d: %s:%s", state.current_frame, info.short_src, info.currentline))
  local i = 1
  while true do
    local name, val = debug.getlocal(level, i)
    if not name then break end
    IO.println(fmt("[%d] local %s = %s", i, name, saferepr(val)))
    i = i + 1
  end
  if info.func then
    local ui = 1
    while true do
      local name, val = debug.getupvalue(info.func, ui)
      if not name then break end
      IO.println(fmt("[u%d] upvalue %s = %s", ui, name, saferepr(val)))
      ui = ui + 1
    end
  end
end

local function list_source(file, lineno, radius)
  radius = radius or 5
  if not file then IO.println("(no file)"); return end
  local f, err = io.open(file, "r")
  if not f then IO.println("(cannot open " .. file .. "): " .. tostring(err)); return end
  local lines = {}
  for l in f:lines() do lines[#lines + 1] = l end
  f:close()
  local startl = math.max(1, lineno - radius)
  local endl = math.min(#lines, lineno + radius)
  for i = startl, endl do
    local mark = (i == lineno) and "=>" or "  "
    IO.println(fmt("%s %4d  %s", mark, i, lines[i]))
  end
end

local function make_frame_env(level)
  local env = {}
  local i = 1
  while true do
    local name, val = debug.getlocal(level, i)
    if not name then break end
    if name ~= "(*temporary)" then env[name] = val end
    i = i + 1
  end
  local fr = debug.getinfo(level, "f")
  if fr and fr.func then
    i = 1
    while true do
      local name, val = debug.getupvalue(fr.func, i)
      if not name then break end
      env[name] = val
      i = i + 1
    end
  end
  setmetatable(env, { __index = _G })
  return env
end

local function eval_expr(expr, level)
  expr = trim(expr)
  if expr == "" then return nil, "empty expression" end
  local chunk, err = loadstring("return " .. expr)
  if not chunk then chunk, err = loadstring(expr); if not chunk then return nil, err end end
  setfenv(chunk, make_frame_env(level))
  local ok, a, b, c = pcall(chunk)
  if not ok then return nil, a end
  return {a, b, c}
end

-- ---------------- Commands & REPL ----------------
local HELP_TEXT = [[
Commands:
  b [file:]line        set breakpoint (file optional = current file)
  bl                   list breakpoints
  bc N|file:line       clear breakpoint
  s                    step into
  n                    step over
  f                    finish (step out)
  c                    continue
  bt                   backtrace
  frame N              select frame (0 = current)
  stack                inspect all locals and upvalues of current frame
  info locals          show locals of current frame
  info upvalues        show upvalues of current frame
  p <expr>             evaluate expression in current frame
  list [N]             show source around current line
  where                show current location
  help                 this help
  q                    quit debugger
]]

function M.print_help()
  IO.println(HELP_TEXT)
end

local function show_where()
  IO.println(fmt("Stopped at %s:%s", tostring(state.current.file or "?"), tostring(state.current.line or "?")))
  list_source(state.current.file, state.current.line, 3)
end

local function read_line(prompt)
  if #state.pending_cmds > 0 then
    return table.remove(state.pending_cmds, 1)
  end
  return IO.readline(prompt)
end

local function repl()
  while true do
    local line = read_line("(ljdb) ")
    if not line then state.mode = "run"; return end
    line = trim(line)
    if line == "" then state.mode = "next"; state.stop_depth = 0; return end

    local cmd, rest = line:match("^(%S+)%s*(.*)$")
    if cmd == "help" or cmd == "h" or cmd == "?" then
      M.print_help()
    elseif cmd == "q" or cmd == "quit" then
      debug.sethook()
      state.attached = false
      error(QUIT_TOKEN, 0)
    elseif cmd == "bt" then show_backtrace()
    elseif cmd == "frame" then
      local n = tonumber(rest)
      if not n then IO.println("Usage: frame N") else state.current_frame = n end
    elseif cmd == "stack" then show_stack()
    elseif cmd == "info" then
      if rest == "locals" then show_locals(2 + state.current_frame)
      elseif rest == "upvalues" then
        local fr = debug.getinfo(2 + state.current_frame, "f")
        show_upvalues(fr and fr.func)
      else IO.println("Usage: info locals | info upvalues") end
    elseif cmd == "p" then
      local ok, res = eval_expr(rest, 2 + state.current_frame)
      if not ok then IO.println("Eval error: "..tostring(res))
      else
        local out = {}
        for _, v in ipairs(res) do out[#out + 1] = saferepr(v) end
        IO.println(table.concat(out, "\t"))
      end
    elseif cmd == "b" then
      local f, l = rest:match("^(.-):(%d+)$")
      if f and l then set_breakpoint(f, tonumber(l))
      else
        if not state.current.file or not rest:match("^%d+$") then
          IO.println("Usage: b [file:]line")
        else
          set_breakpoint(state.current.file, tonumber(rest))
        end
      end
    elseif cmd == "bl" then
      if #bp_list == 0 then IO.println("(no breakpoints)")
      else for i, bp in ipairs(bp_list) do IO.println(fmt("%d: %s:%d", i, bp.file, bp.line)) end end
    elseif cmd == "bc" then
      if rest == "" then IO.println("Usage: bc N | bc file:line")
      else
        if not clear_breakpoint(rest) then IO.println("Breakpoint not found: " .. rest) end
      end
    elseif cmd == "s" then state.mode = "step"; return
    elseif cmd == "n" then state.mode = "next"; state.stop_depth = 0; return
    elseif cmd == "f" then state.mode = "finish"; state.stop_depth = 0; return
    elseif cmd == "c" then state.mode = "run"; return
    elseif cmd == "list" then
      local r = tonumber(rest) or 5
      list_source(state.current.file, state.current.line, r)
    elseif cmd == "where" or cmd == "w" then show_where()
	elseif cmd == "" then state.mode = "next"; state.stop_depth = 0; return
    else IO.println("Unknown command. Type 'help'.") end

    ::cont::
  end
end

-- ---------------- Hook & Execution ----------------
local function should_break(ar)
  state.current.file = normalize_source(ar.source) or ar.short_src
  state.current.line = ar.currentline

  if is_breakpoint_hit(ar.source, ar.currentline) then return true end
  if state.mode == "step" then return true end
  if state.mode == "next" then
    if state.stop_depth == 0 then state.stop_depth = callstack_depth() end
    if callstack_depth() <= state.stop_depth then return true end
  end
  if state.mode == "finish" then
    if state.stop_depth == 0 then state.stop_depth = callstack_depth() end
    if callstack_depth() < state.stop_depth then return true end
  end
  return false
end

local function hook(event, line)
  local ar = debug.getinfo(2, "nSlu")
  if not ar or event ~= "line" then return end
  if should_break(ar) then
    state.mode = "stop"; state.current_frame = 0
    IO.println(fmt("\n[ljdb] Paused at %s:%s", state.current.file, state.current.line))
    list_source(state.current.file, state.current.line, 2)
    if type(opts.on_pause) == "function" then pcall(opts.on_pause, M.get_state()) end
    if opts.repl then repl() else
      while state.mode == "stop" do
        local l = read_line("")
        if not l then state.mode = "run"; break end
        table.insert(state.pending_cmds, 1, l); repl()
      end
    end
  end
end

-- ---------------- Public Interface ----------------
function M.feed(line)
  if type(line) == "string" then table.insert(state.pending_cmds, line) end
end

function M.get_state()
  local bps = {}
  for i, bp in ipairs(bp_list) do bps[#bps + 1] = { index = i, file = bp.file, line = bp.line } end
  return {
    attached = state.attached,
    mode = state.mode,
    current = { file = state.current.file, line = state.current.line },
    current_frame = state.current_frame,
    breakpoints = bps,
  }
end

function M.detach()
  debug.sethook()
  state.attached = false
end

-- Attach and run target script
local function run_target(script, args)
  local chunk, err = loadfile(script)
  if not chunk then return false, "Cannot load: " .. tostring(err) end
  _G.arg = { [0] = script }
  for i, v in ipairs(args or {}) do _G.arg[i] = v end

  debug.sethook(hook, "lcr")
  state.mode = "step"; state.attached = true

  local ok, perr = pcall(chunk)
  debug.sethook(); state.attached = false

  if not ok then
    if tostring(perr) == QUIT_TOKEN then return true end
    IO.write("[ljdb] Runtime error: " .. tostring(perr) .. "\n")
    local i = 2
    while true do
      local ar = debug.getinfo(i, "nSlu")
      if not ar then break end
      IO.write(fmt("  at %s:%s in %s\n", ar.short_src, ar.currentline, ar.name or "<anon>"))
      i = i + 1
    end
    return false, perr
  end
  return true
end

function M.attach(script, args, options)
  if type(options) == "table" then opts.repl = options.repl ~= false; opts.on_pause = options.on_pause end
  breakpoints, bp_list = {}, {}
  state.mode, state.stop_depth, state.current_frame = "stop", 0, 0
  state.current = { file = nil, line = nil }
  state.pending_cmds = {}
  return run_target(script, args)
end

M.version = "0.3.0"
return M


