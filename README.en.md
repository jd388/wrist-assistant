# Wrist AI · 腕上助手

[简体中文](README.md) · **English**

> You're halfway through an English reading passage when you come across “We need to address this problem.” You know the words, but you're still unsure what the sentence means. You can't bring your phone to school, and you don't have a dictionary pen. What if you could look it up on your wrist?

Wrist AI grew out of that situation for middle and high school students in China. If you already have an Apple Watch and would rather skip buying a dictionary pen, you can look up `address` offline and translate the whole sentence on your watch. When your watch is online, ask DeepSeek, “Why does `address` mean ‘deal with’ here?” If you're stuck on an exercise, try “Give me a hint so I can work it out myself.”

It's also for anyone who wants to use AI on an Apple Watch. When a question comes to mind on your commute or your phone is out of reach, you can ask from your wrist and follow up in the same conversation.

## 0.9.27 (66)

- AI chat uses DeepSeek’s conversation title. The watch keeps a locally generated title when the API returns none.
- The direct web reader extracts text as content arrives. It reads up to 5 MB and keeps the text and links available when the limit is reached. You can open the page in Safari or use an optional reading gateway.
- AI answers display common mathematical and chemical notation. You can expand reasoning and search sources when enabled.
- Watch face and Smart Stack widgets open the app or show recent favorites, dictionary lookups, or AI questions.

## What you can do on your watch

- **Offline dictionary** supports English-to-Chinese lookup and reverse lookup from Chinese to English.
- **Offline translation** uses Core ML to translate between English and Chinese on the watch.
- **DeepSeek chat** supports questions, follow-ups, and conversation history. Sending a message requires an internet connection and your own API key.

## Project structure

- `WatchBrowser/` is the combined Apple Watch app. It includes the companion iPhone project and the source for the optional reading gateway.
- `LexiWatch/` provides the shared dictionary interface, search indexes, translation models, and standalone dictionary app.
- The public version bundles the ECDICT dictionary, an extended headword list based on ESDB, and OPUS-MT models. See [third-party notices](THIRD_PARTY_NOTICES.md) for data and model sources.

## Build

You'll need macOS, Xcode, and the watchOS SDK. Open `WatchBrowser/WatchBrowser.xcodeproj` and select the WatchBrowser scheme. Start with a watchOS simulator, or sign with your own development team and unique bundle IDs to run on a physical watch. Set the project-level `IOS_COMPANION_BUNDLE_ID` to update the iPhone, Watch, and widget identifiers together.

```sh
xcodebuild -project WatchBrowser/WatchBrowser.xcodeproj -scheme WatchBrowser \
  -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
swift test --package-path WatchBrowser
swift test --package-path LexiWatch
```

For a Debug build on a physical watch, run the following command in Terminal on your Mac. The script hides your input and saves the API key to the target watch's Keychain. Use `xcrun devicectl list devices` to find the device identifier.

```sh
WATCH_DEVICE_ID="YOUR_DEVICE_ID" WATCH_BUNDLE_ID="YOUR_WATCH_APP_BUNDLE_ID" ./WatchBrowser/ConfigureDeepSeekKey.command
```

If you use the optional reading gateway, deploy your own instance. Set `BROWSER_RENDERER_BASE_URL` when building the Watch app to include the gateway URL in its configuration. Offline lookup and translation work without a gateway.

## Rebuild the public dictionary

`LexiWatch/Tools` contains scripts that turn an ECDICT CSV into a core JSON dictionary and an extended SQLite dictionary. The public dictionary uses the CSV from ECDICT commit `bc015ed2e24a7abef49fc6dbbb7fe32c1dadaf8b`, with SHA-256 `1a6947e04785db63613a92e14903cdae7954f7e84860b10e68e5c7cbb3f9c3cf`. The extended dictionary uses the ESDB coverage list included in this repository.

```sh
cd LexiWatch
python3 Tools/build_offline_dictionary.py /path/to/ecdict.csv LexiWatchWatchApp/Resources/offline_dictionary.json
python3 Tools/build_extended_dictionary.py Tools/Data/esdb70_coverage.tsv /path/to/ecdict.csv \
  LexiWatchWatchApp/Resources/offline_dictionary.json LexiWatchWatchApp/Resources/offline_dictionary_extended.sqlite
```

The Oxford import tool requires the Python packages `mdict-utils` and `lxml`. If you have an Oxford MDX file you can import, use `LexiWatch/Tools/build_oxford_dictionary.py` to produce `oxford_advanced_10_zh_hans.sqlite`. Add it to your own build through Xcode's Copy Bundle Resources build phase.
