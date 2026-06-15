local IconWidget = require("ui/widget/iconwidget")
local Screen = require("device").screen

local BASE_DIR = (debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../"

local Icons = {
    size = {
        default = Screen:scaleBySize(22),
        list = Screen:scaleBySize(22),
        menu = Screen:scaleBySize(22),
        detail = Screen:scaleBySize(22),
    },
}

function Icons.path(name, state)
    local suffix = ""
    if state and state ~= "" and state ~= "default" then
        suffix = "-" .. state
    end
    return BASE_DIR .. "assets/icons/" .. name .. suffix .. ".svg"
end

function Icons.widget(name, opts)
    opts = opts or {}
    local size = opts.size or Icons.size.default
    return IconWidget:new{
        file = Icons.path(name, opts.state),
        width = opts.width or size,
        height = opts.height or size,
        alpha = opts.alpha ~= false,
        dim = opts.dim,
    }
end

return Icons
