#!/usr/bin/env luajit

-- CLI wrapper for ljdb debugger module

local ljdb = require("ljdb")

-- If user asked for help explicitly
local arg0 = arg and arg[1]
if arg0 == "--help" or arg0 == "-h" or arg0 == "help" then
    print("Usage: luajit ljdb-cli.lua [--help|-h] <script.lua> [args...]")
    print("Starts the debugger for <script.lua>. Once inside the (ljdb) REPL, use 'help' to list commands.")
    ljdb.print_help()
    os.exit(0)
end

-- Must have at least one arg (script to debug)
if not arg0 then
    io.stderr:write("Error: no target script provided.\n")
    io.stderr:write("Run with --help for usage.\n")
    os.exit(1)
end

-- Extract target script and its arguments
local target_script = table.remove(arg, 1)
local target_args = arg -- whatever remains is script args

-- Attach debugger
ljdb.attach(target_script, target_args)
