-- Set search path for `require()`.
package.path =
    "common/?.lua;frontend/?.lua;plugins/exporter.koplugin/?.lua;" ..
    package.path
package.cpath =
    "common/?.so;common/?.dll;/usr/lib/lua/?.so;" ..
    package.cpath
-- Setup `ffi.load` override and 'loadlib' helper.
require("ffi/loadlib")
if jit.os == "Windows" then
    local win32 = require("ffi/win32")
    win32.setDllDirectory("libs")
    -- POSIX-like behavior for some standard library functions.
    win32.setupStdlib()
end
