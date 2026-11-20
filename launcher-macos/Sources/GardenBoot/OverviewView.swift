import SwiftUI
import GardenBootCore

struct OverviewView: View {
    @ObservedObject var editor: ExperienceEditor
    let navigate: (SettingsPage) -> Void
    @State private var targetID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("你的启动体验").font(.system(size: 24, weight: .semibold))
                    Text("看看当前状态，再按自己的习惯调整。")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if editor.welcomeDismissed {
                    Button("查看使用引导") { editor.setWelcomeDismissed(false) }
                        .buttonStyle(GardenButtonStyle(kind: .text, small: true))
                }
            }
            if editor.overviewActive {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(spacing: 18) {
                        status(editor.overview(targetID: targetID))
                        updates(editor.updateOverview())
                    }
                }
            } else {
                status(editor.overview(targetID: targetID))
                updates(editor.updateOverview())
            }
            if !editor.welcomeDismissed { guide }
            if editor.isDirty {
                Text("你有未保存的修改。上方状态仍依据已保存设置；草稿可以先预览。")
                    .font(.system(size: 12)).foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("overview-draft-note")
            }
        }.accessibilityIdentifier("overview-page")
    }

    private func updates(_ snapshot: UpdateOverview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("版本与更新").font(.system(size: 15, weight: .semibold))
                    Text("Sakura \(snapshot.version)").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                Button(snapshot.checking ? "正在检查…" : "检查更新") { editor.checkForUpdates() }
                    .buttonStyle(GardenButtonStyle(kind: .secondary, small: true))
                    .disabled(!snapshot.connected || snapshot.checking || snapshot.installing)
                    .accessibilityIdentifier("overview-check-updates")
            }
            HStack(spacing: 12) {
                Text(snapshot.checking ? "正在检查更新…" : snapshot.message)
                    .font(.system(size: 12)).foregroundStyle(snapshot.availableVersion == nil ? Theme.textSecondary : Theme.success)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("overview-update-result")
                if snapshot.connected, snapshot.availableVersion != nil {
                    Spacer(minLength: 0)
                    Button(snapshot.installing ? "取消下载" : "更新") { editor.openUpdateDownload() }
                        .buttonStyle(GardenButtonStyle(kind: .primary, small: true))
                        .accessibilityIdentifier("overview-download-update")
                    Button("在 GitHub 查看") { editor.openUpdateFallback() }
                        .buttonStyle(GardenButtonStyle(kind: .secondary, small: true))
                }
            }
            Text(UpdateRules.gitHubRequirement)
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("overview-update-requirement")
            Rectangle().fill(Theme.divider).frame(height: 1)
            Toggle(isOn: Binding(get: { editor.updateOverview().automatic }, set: { editor.setAutomaticUpdates($0) })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("自动检查更新").font(.system(size: 13))
                    Text("每周检查一次，发现新版本时提醒你。")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }.toggleStyle(.switch).disabled(!snapshot.connected)
                .accessibilityLabel("自动检查更新")
                .accessibilityIdentifier("overview-auto-updates")
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
            .accessibilityIdentifier("overview-updates")
    }

    private func status(_ snapshot: OverviewSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("自动播放状态").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                Spacer()
                if !snapshot.targets.isEmpty {
                    Picker("查看应用", selection: Binding(get: { snapshot.selectedID ?? "" }, set: { targetID = $0 })) {
                        ForEach(snapshot.targets) { target in Text(target.name).tag(target.id) }
                    }.labelsHidden().fixedSize().accessibilityIdentifier("overview-target")
                }
            }
            Text(snapshot.connected ? snapshot.reason.title : "界面预览")
                .font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.heroText)
                .accessibilityIdentifier("overview-status-title")
            Text(snapshot.connected ? snapshot.reason.detail : "正式运行 Sakura 后，这里会显示所选应用的自动播放状态。")
                .font(.system(size: 13)).foregroundStyle(Theme.heroSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                if snapshot.connected, let title = actionTitle(snapshot.reason.action) {
                    Button(title) { perform(snapshot.reason.action) }
                        .buttonStyle(GardenButtonStyle(kind: .secondary, small: true))
                        .accessibilityIdentifier("overview-status-action")
                }
                Button("预览当前动画") { editor.preview() }
                    .buttonStyle(GardenButtonStyle(kind: .text, small: true))
                    .disabled(editor.pack == nil || editor.libraryBusy)
                    .accessibilityIdentifier("overview-preview")
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.hero, in: RoundedRectangle(cornerRadius: 14))
    }

    private var guide: some View {
        SettingsGroup {
            SettingsRow {
                HStack {
                    Text("使用引导").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("我已了解") { editor.setWelcomeDismissed(true) }
                        .buttonStyle(GardenButtonStyle(kind: .text, small: true))
                        .accessibilityIdentifier("welcome-dismiss")
                }
            }
            SettingsDivider()
            if !editor.greetingStepSkipped {
                SettingsRow {
                    GreetingSettingsView(editor: editor, title: "想让 Sakura 怎么称呼你？",
                                         skip: editor.skipGreetingStep)
                }
                SettingsDivider()
            }
            step("1", title: "选一个常用应用", detail: "添加或启用应用，保存后开始监听。", action: "选择应用") { navigate(.targets) }
            SettingsDivider()
            step("2", title: "挑一段动画", detail: "设为当前动画，或在应用页单独指定。", action: "选择动画") { navigate(.animation) }
            SettingsDivider()
            step("3", title: "预览并保存", detail: "预览使用草稿；左下角保存后用于自动播放。", action: "预览") { editor.preview() }
            SettingsDivider()
            SettingsRow {
                Text("关闭设置后仍在菜单栏运行。从花朵图标可以重新打开设置或退出 Sakura。")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityIdentifier("welcome-guide")
    }

    private func step(_ number: String, title: String, detail: String, action: String, run: @escaping () -> Void) -> some View {
        SettingsRow {
            HStack(spacing: 12) {
                Text(number).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 26, height: 26).background(Theme.accentSoft, in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(action, action: run).buttonStyle(GardenButtonStyle(kind: .text, small: true))
            }
        }
    }

    private func actionTitle(_ action: String) -> String? {
        switch action {
        case "targets": return "查看应用"
        case "animation": return "检查动画"
        case "playback": return "调整播放规则"
        case "unpause": return "取消暂停"
        case "unsnooze": return "结束临时暂停"
        default: return nil
        }
    }
    private func perform(_ action: String) {
        switch action {
        case "targets": navigate(.targets)
        case "animation": navigate(.animation)
        case "playback": navigate(.playback)
        default: editor.performOverviewAction(action)
        }
    }
}
