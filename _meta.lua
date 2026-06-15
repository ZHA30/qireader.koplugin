local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "i18n/po.lua")

return {
    fullname = _("QiReader"),
    description = _("A modern web RSS reader, beautiful, fast, and synced on all your devices."),
}
