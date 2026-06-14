local _ = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "../../i18n/po.lua")

local function makeUnreadMap(data)
    local result = data and data.result or {}
    local unread_counts = result.unreadCounts or {}
    local unread_by_subscription_id = {}
    for i = 1, #unread_counts do
        local item = unread_counts[i]
        unread_by_subscription_id[item.subscriptionId] = item.count or 0
    end
    return unread_by_subscription_id
end

local function groupSubscriptions(data, unread_by_subscription_id)
    local result = data.result or {}
    local subscriptions = result.subscriptions or {}
    local categories = result.categories or {}
    local relations = result.subscriptionCategories or {}
    local subscriptions_by_id = {}
    local groups = {}
    local grouped_subscription_ids = {}

    for i = 1, #subscriptions do
        local subscription = subscriptions[i]
        subscription.unread_count = unread_by_subscription_id[subscription.id] or 0
        subscriptions_by_id[subscription.id] = subscription
    end
    for i = 1, #categories do
        local category = categories[i]
        local group = {
            id = category.id,
            label = category.label,
            is_all = category.label == "!all",
            subscriptions = {},
            unread_count = 0,
        }
        groups[category.id] = group
    end
    for i = 1, #relations do
        local relation = relations[i]
        local group = groups[relation.categoryId]
        local subscription = subscriptions_by_id[relation.subscriptionId]
        if group and subscription then
            table.insert(group.subscriptions, subscription)
            group.unread_count = group.unread_count + (subscription.unread_count or 0)
            if group.label ~= "!all" then
                grouped_subscription_ids[subscription.id] = true
            end
        end
    end

    local ordered = {}
    local all_group = nil
    for i = 1, #categories do
        local category = categories[i]
        local group = groups[category.id]
        table.sort(group.subscriptions, function(left, right)
            return (left.title or "") < (right.title or "")
        end)
        if group.is_all then
            all_group = group
        else
            table.insert(ordered, group)
        end
    end
    if all_group then
        table.insert(ordered, 1, all_group)
    end

    local ungrouped = {}
    for i = 1, #subscriptions do
        local subscription = subscriptions[i]
        if not grouped_subscription_ids[subscription.id] then
            table.insert(ungrouped, subscription)
        end
    end
    table.sort(ungrouped, function(left, right)
        return (left.title or "") < (right.title or "")
    end)

    return {
        groups = ordered,
        ungrouped = ungrouped,
        subscriptions = subscriptions,
    }
end

local function findSubscriptionByEntry(controller, entry)
    local target = entry and entry.target or nil
    if target and target.subscription then
        return target.subscription
    end
    local feed_id = entry and (entry.source_feed_id
        or (entry.raw and entry.raw.origin and entry.raw.origin.feedId))
    if feed_id == nil then
        return nil
    end
    local subscriptions = controller.subscriptions or {}
    for i = 1, #subscriptions do
        local subscription = subscriptions[i]
        if subscription.feedId == feed_id
            or subscription.id == feed_id
            or tostring(subscription.feedId) == tostring(feed_id)
            or tostring(subscription.id) == tostring(feed_id) then
            return subscription
        end
    end
end

local methods = {}

function methods:showGroups(data, unread_data, options)
    options = options or {}
    self.state = "groups"
    local grouped = groupSubscriptions(data, makeUnreadMap(unread_data))
    self.groups = grouped.groups
    self.ungrouped = grouped.ungrouped
    self.subscriptions = grouped.subscriptions
    self.subscriptions_dirty = false
    local valid_groups = {}
    for i = 1, #self.groups do
        valid_groups[self.groups[i].id] = true
    end
    for group_id in pairs(self.expanded_groups) do
        if not valid_groups[group_id] then
            self.expanded_groups[group_id] = nil
        end
    end
    self.save_settings()
    if options.refresh_existing and self.menu then
        self:refreshGroupsPage()
    else
        self:showGroupsPage()
    end
end

function methods:recomputeGroupUnreadCounts()
    local groups = self.groups or {}
    for i = 1, #groups do
        local group = groups[i]
        local count = 0
        local subscriptions = group.subscriptions or {}
        for j = 1, #subscriptions do
            count = count + (tonumber(subscriptions[j].unread_count) or 0)
        end
        group.unread_count = count
    end
end

function methods:adjustSubscriptionUnreadCounts(entries, delta)
    if not entries or #entries == 0 or not delta or delta == 0 then
        return false
    end
    local counts_by_subscription = {}
    for i = 1, #entries do
        local subscription = findSubscriptionByEntry(self, entries[i])
        if subscription then
            counts_by_subscription[subscription] = (counts_by_subscription[subscription] or 0) + 1
        end
    end
    local changed = false
    for subscription, count in pairs(counts_by_subscription) do
        local old_count = tonumber(subscription.unread_count) or 0
        local new_count = math.max(0, old_count + delta * count)
        if new_count ~= old_count then
            subscription.unread_count = new_count
            changed = true
        end
    end
    if changed then
        self:recomputeGroupUnreadCounts()
        self.subscriptions_dirty = true
    end
    return changed
end

function methods:showGroupsFromCache()
    if self.groups and self.ungrouped and self.subscriptions then
        self:showGroupsPage()
        return true
    end
    local data = self:readCache(
        self:cacheKey("subscriptions"),
        self:getCacheTtl("subscriptions"),
        true
    )
    if data then
        local unread_data = self:readCache(
            self:cacheKey("unread_counts"),
            self:getCacheTtl("unread_counts"),
            true
        )
        self:showGroups(data, unread_data)
        return true
    end
    self.groups = {}
    self.ungrouped = {}
    self.subscriptions = {}
    self:showGroupsPage()
    return false
end

function methods.buildArticleTarget(_self, row)
    if row.type == "group" and row.group then
        local group = row.group
        return {
            kind = "group",
            title = group.is_all and _("All") or (group.label or _("Untitled")),
            stream_id = "category-" .. tostring(group.id),
            group = group,
        }
    elseif row.type == "subscription" and row.subscription then
        local subscription = row.subscription
        return {
            kind = "subscription",
            title = subscription.title or subscription.feedUrl or tostring(subscription.id or ""),
            stream_id = "subscription-" .. tostring(subscription.id),
            subscription = subscription,
            group = row.group,
        }
    end
end

function methods:getSubscriptionTitleByFeedId(feed_id)
    local subscriptions = self.subscriptions or {}
    for i = 1, #subscriptions do
        local subscription = subscriptions[i]
        if subscription.feedId == feed_id or subscription.id == feed_id then
            return subscription.title or subscription.feedUrl or tostring(subscription.id or "")
        end
    end
    return tostring(feed_id or "")
end

function methods:normalizeArticlePage(target, result)
    local entries = result.entries or {}
    local normalized = {
        entries = {},
        has_more = result.hasMore == true,
        next_cursor = nil,
    }
    local readlater_tag_id = self.readlater_tag_id
    for i = 1, #entries do
        local entry = entries[i]
        local tag_ids = entry.tagIds or {}
        local is_read_later = false
        if readlater_tag_id then
            for j = 1, #tag_ids do
                if tag_ids[j] == readlater_tag_id then
                    is_read_later = true
                    break
                end
            end
        end
        table.insert(normalized.entries, {
            id = entry.id,
            title = entry.title or _("Untitled"),
            status = entry.status or 0,
            timestamp = entry.timestamp,
            published_at = entry.publishedAt,
            summary = entry.summary,
            url = entry.url,
            source_feed_id = entry.origin and entry.origin.feedId or nil,
            source_title = self:getSubscriptionTitleByFeedId(entry.origin and entry.origin.feedId or nil),
            date_text = self:formatArticleDate(entry.publishedAt),
            tag_ids = tag_ids,
            is_read_later = is_read_later,
            raw = entry,
            target = target,
        })
    end
    if #entries > 0 then
        normalized.next_cursor = entries[#entries].timestamp
    end
    return normalized
end

function methods:formatArticleDate(published_at)
    if not self or not published_at then
        return "--"
    end
    local timestamp = tonumber(published_at)
    local seconds = timestamp and math.floor(timestamp / 1000) or nil
    if not seconds then
        return "--"
    end
    local now = os.time()
    if seconds > now then
        seconds = now
    end

    local article_day = os.date("*t", seconds)
    local now_day = os.date("*t", now)
    local article_day_start = os.time{
        year = article_day.year,
        month = article_day.month,
        day = article_day.day,
        hour = 0,
        min = 0,
        sec = 0,
    }
    local today_start = os.time{
        year = now_day.year,
        month = now_day.month,
        day = now_day.day,
        hour = 0,
        min = 0,
        sec = 0,
    }
    local elapsed = now - seconds

    if article_day_start == today_start then
        if elapsed < 3600 then
            local minutes = math.max(1, math.floor(elapsed / 60))
            return string.format("%dm", minutes)
        end
        local hours = math.max(1, math.floor(elapsed / 3600))
        return string.format("%dh", hours)
    end

    if article_day_start == today_start - 86400 then
        return _("Yesterday")
    end

    return os.date("%m-%d", seconds)
end

return methods
