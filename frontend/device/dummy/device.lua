local Generic = require("device/generic/device")
local logger = require("logger")

local function yes() return true end
local function no() return false end

local Device = Generic:extend{
    model = "dummy",
    hasKeyboard = no,
    hasKeys = no,
    isTouchDevice = no,
    needsScreenRefreshAfterResume = no,
    hasColorScreen = yes,
    hasEinkScreen = no,
}

function Device:init()
    self.screen = require("ffi/framebuffer_SDL3"):new{
        dummy = true,
        device = self,
        debug = logger.dbg,
    }
    -- No input either.
    self.input = require("device/input"):new{
        device = self,
        input = {},
    }
    Generic.init(self)
end

return Device
