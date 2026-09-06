import AppKit
import SwiftUI

enum Screen {
    case tabs
    case interview(SessionConfig)
    case done(DoneInfo)
}

enum Tab: String, CaseIterable {
    case session = "Session"
    case stats = "Statistics"
    case settings = "Settings"
}

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.colorScheme) private var scheme
    @State private var screen: Screen = .tabs
    @State private var tab: Tab = .session

    var body: some View {
        let palette = Palette.forScheme(scheme)
        Group {
            switch screen {
            case .interview(let config):
                InterviewView(
                    config: config,
                    onDone: { screen = .done($0) },
                    onCancel: { screen = .tabs }
                )
            case .done(let info):
                DoneView(info: info, onHome: { screen = .tabs })
            case .tabs:
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Picker("", selection: $tab) {
                            ForEach(Tab.allCases, id: \.self) { t in
                                Text(t.rawValue).tag(t)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 320)
                        Spacer()
                    }
                    .padding(.top, 9)
                    .padding(.bottom, 9)
                    .background(palette.panel)
                    Divider().overlay(palette.border)
                    Group {
                        switch tab {
                        case .session:
                            ScrollView {
                                SessionTabView(onStart: { screen = .interview($0) })
                                    .frame(maxWidth: .infinity)
                            }
                        case .stats:
                            StatsView()
                        case .settings:
                            SettingsView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(palette.background)
        .frame(minWidth: 960, minHeight: 660)
        // The hidden title bar still reserves safe-area height; claim it so the
        // tab bar sits flush at the window top, in line with the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct VivaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store: AppStore
    @StateObject private var analysis: AnalysisManager
    @StateObject private var setup = SetupManager()

    init() {
        let s = AppStore()
        _store = StateObject(wrappedValue: s)
        _analysis = StateObject(wrappedValue: AnalysisManager(store: s))
    }

    private var preferredScheme: ColorScheme? {
        switch store.settings.theme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(analysis)
                .environmentObject(setup)
                .preferredColorScheme(preferredScheme)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
