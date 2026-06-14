# QiReader Plugin Logic

本文记录 `qireader.koplugin` 当前已经落地的实现逻辑，用于后续交接与维护。

只保留仍然有效的现状，不保留已失效的排查结论和历史方案。

## 入口与页面结构

插件入口仍在 KOReader FileManager 主菜单。

当前 UI 分为两层：

- 订阅页：基于 KOReader 原生 `Menu`
- 文章页：基于自定义全屏 widget

订阅页负责：

- 登录 / 登出
- 拉取订阅与分组
- 展示未读数
- “只显示未读”过滤
- 进入订阅或分组对应的文章页

文章页负责：

- 拉取文章流
- 分页浏览
- 未读过滤
- 排序切换
- 翻页标记已读
- 稍后阅读切换
- 打开文章正文

## 核心文件

- `main.lua`：插件入口
- `qireader/controller.lua`：主控制器、菜单、状态切换、文章归一化
- `qireader/client.lua`：QiReader Web API 调用
- `qireader/articlelist.lua`：文章列表全屏 widget
- `qireader/settings.lua`：设置默认值与持久化

## 登录与状态

当前登录态依赖 Cookie。

本地设置保存：

- `api_base`
- `cookie`
- `user`
- `subscriptions_version`
- `show_unread_only`
- `article_settings.global`
- `article_settings.custom`

其中 `article_settings` 的固定字段为：

- `show_unread_only`
- `order_oldest_first`
- `mark_read_on_page_turn`
- `items_per_page`
- `title_font_size`

`article_settings.custom` 以文章目标 `stream_id` 的字符串形式为 key。

历史扁平键 `article_show_unread_only`、`article_order_oldest_first`、`article_mark_read_on_page_turn`、`article_items_per_page`、`article_title_font_size` 会在加载时迁移到 `article_settings.global`，后续保存不再继续写回这些旧键。

本地不保存密码。

`401` 的处理约定是清空会话并回到未登录状态，不继续保留失效页面状态。

订阅页顶部设置菜单当前固定为：

- `Account`
- `Unread only: On/Off`

其中 `Account` 直接打开统一账号弹窗：

- 标题：`QiReader account`
- 输入项：`Email`、`Password`
- 底部按钮：`Cancel`、`Log out`、`Log in`
- 已登录时 `Log out` 可用、`Log in` 灰显
- 未登录时 `Log in` 可用、`Log out` 灰显

当前登录和登出都在这个弹窗内完成，不再经过额外的账号详情页或登出确认框。
未登录且当前没有可显示订阅时，订阅页保持空列表，不再显示 `Not logged in` 占位行。

## 文章列表数据流

文章页支持两类目标：

- 分组：`category-<id>`
- 订阅：`subscription-<id>`

文章 API 拉取与显示已解耦：

- 列表本地每页显示条数由当前生效设置 `items_per_page` 控制
- 远端拉取批次固定为 `50` 条

当前实现会先按远端批次拉取，再在本地拆成多个 UI 页。

相关约定：

- `remote_batch_size = 50`
- `article_settings.global.items_per_page` 默认值为 `5`
- 切换“每页列表项”或“列表项字号”时，只重排本地布局，不重新请求远端
- 切换“只显示未读”或“排序”时，会重新从远端加载文章流

## 文章列表设置作用域

文章页设置支持两种作用域：

- 全局：所有仍使用全局的列表共用一套规则
- 自定义：只对当前订阅或分组生效

当前切换入口只有一个菜单项：

- `Config: Global`
- `Config: Custom`

规则是：

- 每个列表默认使用全局
- 从全局切到自定义时，会复制当前生效设置作为该列表的自定义起点
- 从自定义切回全局时，会删除该列表的自定义条目
- 列表处于全局时，修改设置会同步影响所有仍使用全局的列表
- 列表处于自定义时，修改设置只影响当前列表

## 预加载策略

当前文章页有下一批预加载。

规则是：

- 当用户翻到当前远端批次的末尾附近时
- 若下一批尚未加载且当前批次仍有更多数据
- 则后台预拉取下一批

当前触发阈值为：

- `preload_pages_before_end = 1`

也就是在当前批次最后 1 页附近触发下一批预加载。

## 翻页与已读逻辑

“翻页标记为已读”当前语义已经固定：

- 标记翻走的页
- 不是标记翻到的页

具体行为：

- 首次打开第一页，不会立刻标记已读
- 从第 1 页翻到第 2 页，会标记第 1 页
- 前翻、后翻、跳页都遵循“标记离开的页”

标记请求方式是：

- 每次翻走一页，最多发 1 个请求
- 该请求包含这一页中所有未读文章的 `id`

当前不是逐条请求。

同一批已加载数据在本地标记成功后，会把条目状态改为已读，因此同一次会话里不会重复发送同一页的已读请求。

## 文章时间显示

文章列表第二行格式为：

- `时间 | 订阅源标题`

时间显示基于 `publishedAt`，当前规则是：

- 今天且 1 小时内：`xm`
- 今天但超过 1 小时：`xh`
- 昨天：`昨天`
- 更早：`%m-%d`

这里的 `m` / `h` 是固定字符，不做翻译。

时间判断按本地日历日处理，因此跨天后优先显示“昨天”。

## 列表项显示约定

当前列表项约定如下：

- 标题显示在左侧主体区域
- 第二行显示 `时间 | 来源`
- 右侧按钮文案固定为 `Later`
- 未读条目的标题与第二行文字都使用黑色
- 已读条目通过灰显表达
- 已读条目的标题与第二行文字共用同一套灰色
- 已读/未读不再显示左侧圆点
- 相邻列表项之间使用深灰色分隔线
- `Later` 按钮有边框
- `Later` 按钮文字和边框始终同色
- 未加入稍后阅读时 `Later` 为黑色
- 已加入稍后阅读时 `Later` 为深灰色

“稍后阅读”不是独立布尔字段，而是通过 `!readlater` 标签映射。

## 文章页设置菜单

当前文章页菜单包含：

- `Config: Global` / `Config: Custom`
- `Unread only`
- `Oldest first`
- `Mark on page turn`
- `Items per page`
- `Title font size`

语义已经固定：

- `Config`：切换当前列表使用全局配置还是自定义配置
- `Items per page`：控制一屏目标显示多少条
- `Title font size`：控制标题字号
- `Items per page` 和 `Title font size` 使用原生数字选单，不使用输入框

## 当前依赖的接口面

当前代码已经接入的接口包括：

- `/subscriptions`
- `/markers/unread/counts`
- `/streams/{streamId}`
- `/entry-contents`
- `/markers/reads`
- `/tags`
- `/entries/.../tags/...`

其中：

- 文章列表依赖 `/streams/{streamId}`
- 文章正文依赖 `/entry-contents`
- 翻页标记已读依赖 `/markers/reads`
- 稍后阅读依赖标签接口

## 当前文档边界

本文只描述当前逻辑与约定。

若要补接口取证，更新 `docs/api/`。
若要补界面草图或交互讨论，更新 `docs/tui/`。
