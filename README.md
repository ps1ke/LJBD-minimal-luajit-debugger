<!-- Prevent Markdown from rendering the title -->

# ljdb-cli.lua - LuaJIT Debugger CLI

## Description
`ljdb-cli.lua` is a command-line interface wrapper for the `ljdb` debugger module.  
It allows you to debug Lua or LuaJIT scripts interactively with breakpoints, step controls, 
stack inspection, and expression evaluation.

## Requirements
- LuaJIT or Lua 5.1
- `ljdb.lua` (included in the same folder)

## Installation
1. Place `ljdb-cli.lua` and `ljdb.lua` in the same directory.  
2. Ensure `luajit` or `lua` is in your PATH.  
3. Make `ljdb-cli.lua` executable (optional):
   ```bash
   chmod +x ljdb-cli.lua
   ```

## Usage
Basic usage:
```bash
luajit ljdb-cli.lua [--help|-h] <script.lua> [args...]
```

- `<script.lua>` : the Lua script you want to debug  
- `[args...]` : optional arguments passed to your script  
- `--help` or `-h` : show usage and exit  

Once the debugger starts, you enter an interactive REPL (read-eval-print loop) where you can use commands:

## Commands
- `b [file:]line`       : set breakpoint (file optional = current file)  
- `bl`                  : list breakpoints  
- `bc N|file:line`      : clear breakpoint  
- `s`                   : step into  
- `n`                   : step over  
- `f`                   : finish (step out)  
- `c`                   : continue execution  
- `bt`                  : backtrace  
- `frame N`             : select frame (0 = current)  
- `stack`               : inspect locals and upvalues of current frame  
- `info locals`         : show locals of current frame  
- `info upvalues`       : show upvalues of current frame  
- `p <expr>`            : evaluate expression in current frame  
- `list [N]`            : show source around current line  
- `where`               : show current location  
- `help`                : display help  
- `q`                   : quit debugger

You can also just press RETURN (enter key) and it will step over 

## Features
- Breakpoints with robust path handling  
- Step into, step over, step out  
- Stack inspection with locals and upvalues  
- Expression evaluation in frame context  
- Source listing  
- Modular API for programmatic control  

## License
MIT License

