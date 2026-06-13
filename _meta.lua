local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "i18n/po.lua")

return {
    fullname = _("QiReader"),
    description = _("Browse QiReader subscriptions and groups."),
}
