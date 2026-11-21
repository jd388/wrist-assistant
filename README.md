# 腕上助手 · Wrist Assistant

Apple Watch 上的离线英汉词典、双向翻译和 DeepSeek 对话。词典和 Core ML 翻译在手表端运行。DeepSeek 对话需要网络和你自己的 API Key。

- `WatchBrowser/` 是合并版手表 App，含配套的 iPhone 工程和可选阅读网关源码。
- `LexiWatch/` 提供共享的查词界面、索引、翻译模型和独立词典 App。
- 公开版随附 ECDICT 词库、ESDB 的扩展词头和 OPUS-MT 模型。数据与模型的来源见 [第三方说明](THIRD_PARTY_NOTICES.md)。

## 构建

需要 macOS、Xcode 及 watchOS SDK。打开 `WatchBrowser/WatchBrowser.xcodeproj`，选择 WatchBrowser scheme。可先在 watchOS Simulator 上运行；在实体设备上运行时请用自己的开发团队和唯一 Bundle ID 签名。修改 Watch 与伴侣 App 标识时，请保持 Watch 的伴侣标识设置与 iPhone App 一致。

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

拥有可导入的本地牛津 MDX 时，可以使用 `LexiWatch/Tools/build_oxford_dictionary.py` 生成 `oxford_advanced_10_zh_hans.sqlite`，通过 Xcode 的 Copy Bundle Resources 加入个人构建。
