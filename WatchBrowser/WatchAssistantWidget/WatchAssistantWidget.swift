import AppIntents
import SwiftUI
import WidgetKit

private struct AssistantEntry: TimelineEntry {
    let date: Date
}

private struct AssistantProvider: TimelineProvider {
    func placeholder(in context: Context) -> AssistantEntry {
        AssistantEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (AssistantEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AssistantEntry>) -> Void) {
        completion(Timeline(entries: [placeholder(in: context)], policy: .never))
    }
}

private struct AssistantWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if family == .accessoryCircular {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 22, weight: .semibold))
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "character.book.closed")
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("腕上助手").font(.headline)
                        Text("词典 · AI").font(.caption2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "wristassistant://home"))
        .accessibilityLabel("打开腕上助手")
    }
}

struct WatchAssistantWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchAssistantLauncher", provider: AssistantProvider()) { _ in
            AssistantWidgetView()
        }
        .configurationDisplayName("腕上助手")
        .description("打开词典、AI 和设置。")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

enum AssistantActivityKind: String, AppEnum {
    case favorite, lookup, question

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "内容"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .favorite: "最近收藏", .lookup: "最近查词", .question: "最近 AI 提问"
    ]

    var label: String {
        switch self {
        case .favorite: "最近收藏"
        case .lookup: "最近查词"
        case .question: "最近 AI 提问"
        }
    }

    var icon: String {
        switch self {
        case .favorite: "bookmark"
        case .lookup: "character.book.closed"
        case .question: "sparkles"
        }
    }

    var destination: URL? {
        URL(string: self == .question ? "wristassistant://ai" : "wristassistant://dictionary")
    }

    func text(in activity: AssistantActivitySnapshot) -> String? {
        switch self {
        case .favorite: activity.favorite
        case .lookup: activity.lookup
        case .question: activity.question
        }
    }
}

struct AssistantActivityIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "腕上助手最近活动"
    static let description = IntentDescription("选择智能叠放中显示的内容。")

    @Parameter(title: "显示", default: .favorite)
    var kind: AssistantActivityKind

    init() {}

    init(kind: AssistantActivityKind) {
        self.kind = kind
    }
}

private struct AssistantActivityEntry: TimelineEntry {
    let date: Date
    let kind: AssistantActivityKind
    let text: String?
}

private struct AssistantActivityProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> AssistantActivityEntry {
        AssistantActivityEntry(date: .now, kind: .favorite, text: nil)
    }

    func snapshot(for configuration: AssistantActivityIntent, in context: Context) async -> AssistantActivityEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: AssistantActivityIntent, in context: Context) async -> Timeline<AssistantActivityEntry> {
        Timeline(entries: [entry(for: configuration)], policy: .never)
    }

    func recommendations() -> [AppIntentRecommendation<AssistantActivityIntent>] {
        [.favorite, .lookup, .question].map { kind in
            AppIntentRecommendation(intent: AssistantActivityIntent(kind: kind), description: kind.label)
        }
    }

    private func entry(for intent: AssistantActivityIntent) -> AssistantActivityEntry {
        AssistantActivityEntry(date: .now, kind: intent.kind,
                               text: intent.kind.text(in: AssistantActivitySnapshot.read()))
    }
}

struct AssistantActivityWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: AssistantActivitySnapshot.widgetKind, intent: AssistantActivityIntent.self,
                               provider: AssistantActivityProvider()) { entry in
            VStack(alignment: .leading, spacing: 3) {
                Label(entry.kind.label, systemImage: entry.kind.icon)
                    .font(.caption2.weight(.semibold))
                    .widgetAccentable()
                if let text = entry.text {
                    Text(text)
                        .font(.headline)
                        .lineLimit(2)
                        .privacySensitive()
                } else {
                    Text("暂无记录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(entry.kind.destination)
        }
        .configurationDisplayName("腕上助手最近活动")
        .description("查看最近收藏、查词或 AI 提问。")
        .supportedFamilies([.accessoryRectangular])
    }
}

@main
struct WatchAssistantWidgets: WidgetBundle {
    var body: some Widget {
        WatchAssistantWidget()
        AssistantActivityWidget()
    }
}
