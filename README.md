# Wrist AI · 腕上助手

**简体中文** · [English](README.en.md)

> 英语阅读做到一半，碰到一句「We need to address this problem.」几个词都认识，连起来却拿不准意思。手机不能带进学校，手边也没有词典笔。这时候，能不能抬起手腕就查一下？

腕上助手从国内初高中生的这个场景出发。如果你已经有 Apple Watch，又不想额外买一支词典笔，可以先在表上离线查 `address`，再翻译整句话。手表有网时，还能问 DeepSeek「为什么这里的 `address` 是『处理』的意思？」做题卡住了，也可以对它说「先给我一点提示，我想自己做。」

它也面向平时想在 Apple Watch 上用 AI 的人。通勤时想到一个问题，或是手机不在手边，可以直接在表上问，想细聊就沿着同一段对话追问。

## 0.9.27（66）

- AI 对话使用 DeepSeek 官方会话标题。没有返回标题时，手表保留本地生成的标题。
- 网页直读分段提取，最多读取 5 MB。达到预算时保留已读正文和链接，并提供 Safari 或可选的云端读取入口。
- AI 回答支持常见数学和化学公式，可按需展开思考过程与搜索来源。
- 表盘和智能叠放小组件可进入腕上助手，也可展示最近收藏、查词或 AI 提问。

## 手表上能做什么

- **离线查词**支持英查中，也支持用中文反查英文。
- **离线翻译**用 Core ML 在手表上完成中英双向翻译。
- **DeepSeek 对话**支持提问、连续追问和查看历史对话。发问时需要联网并配置自己的 API Key。

## 项目结构

- `WatchBrowser/` 是合并版手表 App，含配套的 iPhone 工程和可选阅读网关源码。
- `LexiWatch/` 提供共享的查词界面、索引、翻译模型和独立词典 App。
- 公开版随附 ECDICT 词库、ESDB 的扩展词头和 OPUS-MT 模型。数据与模型的来源见 [第三方说明](THIRD_PARTY_NOTICES.md)。

## 构建

需要 macOS、Xcode 及 watchOS SDK。打开 `WatchBrowser/WatchBrowser.xcodeproj`，选择 WatchBrowser scheme。可先在 watchOS Simulator 上运行；在实体设备上运行时请用自己的开发团队和唯一 Bundle ID 签名。修改项目级 `IOS_COMPANION_BUNDLE_ID` 可同步更新 iPhone、Watch 和小组件的标识。

```sh
xcodebuild -project WatchBrowser/WatchBrowser.xcodeproj -scheme WatchBrowser \
  -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
swift test --package-path WatchBrowser
swift test --package-path LexiWatch
```

实体手表上的 Debug 版可在 Mac 终端运行下述命令。命令会隐藏输入并把 Key 存进目标手表的钥匙串。设备 ID 可通过 `xcrun devicectl list devices` 查到。

```sh
WATCH_DEVICE_ID="替换为设备标识符" WATCH_BUNDLE_ID="替换为手表应用的Bundle-ID" ./WatchBrowser/ConfigureDeepSeekKey.command
```

可选阅读网关使用你自己的部署。为 Watch 构建设置 `BROWSER_RENDERER_BASE_URL` 后，网关地址会写入应用配置。日常离线查词和翻译无需配置网关。

## 重建公开词库

`LexiWatch/Tools` 包含将 ECDICT CSV 生成核心 JSON 和扩展 SQLite 的工具。公开词库以 ECDICT 提交 `bc015ed2e24a7abef49fc6dbbb7fe32c1dadaf8b` 的 CSV 为输入，SHA-256 是 `1a6947e04785db63613a92e14903cdae7954f7e84860b10e68e5c7cbb3f9c3cf`。扩展词头使用仓库内的 ESDB 覆盖表。

```sh
cd LexiWatch
python3 Tools/build_offline_dictionary.py /path/to/ecdict.csv LexiWatchWatchApp/Resources/offline_dictionary.json
python3 Tools/build_extended_dictionary.py Tools/Data/esdb70_coverage.tsv /path/to/ecdict.csv \
  LexiWatchWatchApp/Resources/offline_dictionary.json LexiWatchWatchApp/Resources/offline_dictionary_extended.sqlite
```

牛津导入工具需要 Python 的 `mdict-utils` 和 `lxml`。拥有可导入的本地牛津 MDX 时，可以使用 `LexiWatch/Tools/build_oxford_dictionary.py` 生成 `oxford_advanced_10_zh_hans.sqlite`，通过 Xcode 的 Copy Bundle Resources 加入个人构建。
