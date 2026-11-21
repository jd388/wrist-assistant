import SwiftUI

struct PhoneContentView: View {
    @EnvironmentObject private var controller: PhoneSessionController

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    connectionSection
                    gatewaySection
                    relaySection
                }

                Divider()
                browserPreview
            }
            .navigationTitle("腕上浏览中继")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("刷新", systemImage: "arrow.clockwise") {
                        controller.refreshConnection()
                    }
                    .accessibilityHint("重新读取手表连接和网关配置状态")
                }
            }
            .confirmationDialog(
                "删除 iPhone 上的网关设置？",
                isPresented: $controller.showsDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("删除网关设置", role: .destructive) {
                    controller.deleteConfiguration()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这会删除服务器地址和 iPhone Keychain 中的部署令牌，不会修改手表上的独立配置。")
            }
        }
    }

    private var browserPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("本地网页预览", systemImage: "iphone.gen3")
                    .font(.headline)
                Spacer()
                Text(controller.isLocalBrowserPreviewReady ? "前台就绪" : "等待前台")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        controller.isLocalBrowserPreviewReady ? Color.green : Color.secondary
                    )
            }

            PhoneBrowserHostView(controller: controller)
                .frame(maxWidth: .infinity)
                .frame(height: 178)

            Text("这是手表交互浏览使用的真实 WebKit 画面。浏览时请保持本页可见并让 iPhone 解锁。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.regularMaterial)
    }

    private var connectionSection: some View {
        Section {
            LabeledContent("连接会话", value: controller.activationText)
            statusRow(
                title: "已配对 Apple Watch",
                isReady: controller.isPaired
            )
            statusRow(
                title: "已安装手表 App",
                isReady: controller.isWatchAppInstalled
            )
            statusRow(
                title: "可即时中继",
                isReady: controller.isReachable
            )
        } header: {
            Text("手表连接")
        } footer: {
            Text("交互浏览优先在 iPhone 本地运行；首次载入网页和生成截图时，让“腕上浏览中继”保持前台最稳定。无法即时中继时，手表仍可按自身网络使用正文和 AI。")
        }
    }

    private var gatewaySection: some View {
        Section {
            TextField("https://你的网关域名", text: $controller.serverURLDraft)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("网关 HTTPS 地址")

            SecureField(
                controller.hasStoredToken ? "部署令牌（留空则保留）" : "部署令牌",
                text: $controller.tokenDraft
            )
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel("部署令牌")

            Button(controller.isConfigured ? "保存更改" : "保存并启用中继") {
                controller.saveConfiguration()
            }
            .disabled(
                controller.serverURLDraft
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            )

            if controller.isConfigured || controller.hasStoredToken {
                Button("删除网关设置", role: .destructive) {
                    controller.showsDeleteConfirmation = true
                }
            }

            Label {
                Text(controller.configurationFeedback)
            } icon: {
                Image(
                    systemName: controller.isConfigured
                        ? "checkmark.shield.fill"
                        : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(controller.isConfigured ? .green : .orange)
            }
        } header: {
            Text("免费网关")
        } footer: {
            Text("令牌仅保存在这台 iPhone 的本机 Keychain 中，不会同步、通过 WatchConnectivity 发送、显示或写入日志。iPhone 重启后需先解锁一次。首次载入网页或生成截图时保持本 App 前台最稳定；进入后台或锁屏后，iOS 可能暂停 WebKit 或 WatchConnectivity，不能保证持续响应。服务器必须使用 HTTPS。")
        }
    }

    private var relaySection: some View {
        Section("最近一次中继") {
            LabeledContent("结果", value: controller.lastRelayResult)
            if let date = controller.lastRelayDate {
                LabeledContent {
                    Text(date, style: .time)
                } label: {
                    Text("时间")
                }
            }
        }
    }

    private func statusRow(title: String, isReady: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(isReady ? .green : .secondary)
                .accessibilityHidden(true)
            Text(title)
            Spacer()
            Text(isReady ? "是" : "否")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    PhoneContentView()
        .environmentObject(PhoneSessionController())
}
