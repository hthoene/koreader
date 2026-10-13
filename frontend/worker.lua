--[[--
Run tasks in a sub-process (so they don't block the UI, and can be interrupted).

Unlike @{ffi.util.runInSubProcess}, tasks are not functions, but descriptions of a function
call (made with @{Worker.task}), so they can also be run where `fork()` is not available
(i.e. on Windows): in a new LuaJIT process (a "worker"), which is set up like KOReader
(with the same settings and language), but with a dummy (headless) device.

So a task:

- must not rely on any other state of the main process (only on its own arguments);
- must not use the UI, nor change the settings (they're not saved);
- can only take and return serializable values (with `string.buffer`: no functions,
  coroutines, userdata…).

@usage
    local Worker = require("worker")
    local task = Worker.task("ui/translator", ":loadPage", text, target_lang, source_lang)
    local completed, result = Trapper:dismissableRunInSubprocess(task, trap_widget)

@module worker
]]

local ffiutil = require("ffi/util")
local logger = require("logger")

local Worker = {}

-- Whether we're running in a sub-process started by `Worker.runInSubProcess`.
local in_subprocess = false

--[[--
Describe a task: a call to `module.func(...)` (or `module:method(...)`, when `func` is `":method"`).

The task's `path` field can be set to a directory to add to the modules search path
(e.g. a plugin's own directory).

@string module name of the module to require
@string func name of the function (or `":"` followed by the name of the method) to call
@param ... arguments
@treturn table the task
]]
function Worker.task(module, func, ...)
    return { module = module, func = func, n = select("#", ...), ... }
end

--- Run a task (in the current process), returning its results.
function Worker.runTask(task)
    local module = require(task.module)
    local method = task.func:match("^:(.+)$")
    if method then
        return module[method](module, unpack(task, 1, task.n))
    end
    return module[task.func](unpack(task, 1, task.n))
end

--- Whether we're running in a sub-process (started by @{Worker.runInSubProcess}).
function Worker.isInSubProcess()
    return in_subprocess
end

--[[--
Run a task in a sub-process.

The returned values can be used with @{ffi.util.isSubProcessDone}, @{ffi.util.terminateSubProcess},
@{ffi.util.getNonBlockingReadSize} & @{ffi.util.readAllFromFD}, like those of @{ffi.util.runInSubProcess}.

With `with_pipe`, the task's results are sent back serialized (as a `table.pack`ed table, with
`string.buffer`); nothing is sent if the task failed (errors are logged).

@table task the task
@bool with_pipe whether to get the task's results
@return the sub-process pid (or nil, and an error message)
@return the file descriptor to read the results from (with `with_pipe`)
]]
function Worker.runInSubProcess(task, with_pipe)
    if ffiutil.canFork() then
        return ffiutil.runInSubProcess(function(_pid, child_write_fd)
            in_subprocess = true
            if task.path then
                Worker.addPath(task.path)
            end
            local results = table.pack(Worker.runTask(task))
            if child_write_fd then
                ffiutil.writeToFD(child_write_fd, require("string.buffer").encode(results), true)
            end
        end, with_pipe)
    end
    if jit.os ~= "Windows" then
        return nil, "sub-processes are not supported"
    end
    local lfs = require("libs/libkoreader-lfs")
    local win32 = require("ffi/win32")
    local request = require("string.buffer").encode{
        task = task,
        settings = G_reader_settings.data,
    }
    -- NOTE: the standard output is taken over before anything else (by `setupkoenv`,
    --       when loading libraries) gets a chance to write to it.
    local proc, err = win32.spawn({
        lfs.currentdir() .. "/luajit.exe", "-e",
        "local write = require('ffi/win32').takeStdout() require('setupkoenv') require('worker').main(write)",
    }, {
        capture_stdout = with_pipe,
        input = request,
        background = true,
    })
    if not proc then
        return nil, err
    end
    logger.dbg("Worker: started process", proc.pid, "for", task.module, task.func)
    return proc, with_pipe and proc or nil
end

--- Add a directory to the modules search path (if not already there).
-- NOTE: only in a sub-process (like `PluginLoader`, which restores the search path
--       after loading a plugin, so its modules can't shadow others).
function Worker.addPath(path)
    local entry = path .. "/?.lua;"
    if package.path:sub(1, #entry) ~= entry and not package.path:find(";" .. entry, 1, true) then
        package.path = entry .. package.path
    end
end

--[[--
Entry point of a worker process (c.f. @{Worker.runInSubProcess}).

The request is read from the standard input, and the results written with `write`.
]]
function Worker.main(write)
    in_subprocess = true
    local buffer = require("string.buffer")
    local ok, err = xpcall(function()
        local request = buffer.decode(require("ffi/win32").readStdin())
        -- Set up like `reader.lua`, but with the main process' settings.
        G_defaults = require("luadefaults"):open()
        G_reader_settings = require("luasettings"):wrap(request.settings)
        local lang_locale = G_reader_settings:readSetting("language")
        if lang_locale then
            require("gettext").changeLang(lang_locale)
        end
        -- A dummy device (no window, no input).
        local Device = require("device/dummy/device")
        Device:init()
        package.loaded["device"] = Device
        require("document/canvascontext"):init(Device)

        local task = request.task
        if task.path then
            Worker.addPath(task.path)
        end
        local results = table.pack(Worker.runTask(task))
        if write and not write(buffer.encode(results)) then
            error("cannot send the results")
        end
    end, debug.traceback)
    if not ok then
        logger.err("Worker: task failed:", err)
    end
    os.exit(ok and 0 or 1)
end

return Worker
