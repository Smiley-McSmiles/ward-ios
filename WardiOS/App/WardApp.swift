import SwiftUI
import UIKit

@main
struct WardApp: App {
    @UIApplicationDelegateAdaptor(WardAppDelegate.self) private var appDelegate
    @StateObject private var app = AppModel()
    @StateObject private var lock = AppLockManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .wardTheme()
                .environmentObject(app)
                .environmentObject(app.settings)
                .environmentObject(lock)
                .onAppear {
                    app.start()
                    WardAppDelegate.replyHandler = { [weak app] chatId, text in
                        app?.reply(to: chatId, text: text)
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    app.setForeground(phase == .active)
                    lock.scenePhaseChanged(phase)
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var lock: AppLockManager
    @Environment(\.ward) private var palette
    @State private var shroud = false
    @State private var screenCaptured = false

    var body: some View {
        ZStack {
            if !app.isReady {
                SplashView()
            } else if let error = app.startupError {
                startupError(error)
            } else if app.accounts.isEmpty {
                WelcomeView()
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            } else {
                MainView()
                    .transition(.opacity)
            }

            if lock.locked && app.isReady {
                AppUnlockView()
                    .environmentObject(lock)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .zIndex(20)
            }

            if let call = app.call {
                CallOverlay(call: call)
                    .environmentObject(app)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(30)
            }

            if let toast = app.toast {
                VStack {
                    Spacer()
                    ToastView(text: toast, error: app.toastIsError)
                        .padding(.bottom, 88)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .allowsHitTesting(false)
                .zIndex(40)
            }

            if shroud {
                Rectangle().fill(palette.background).ignoresSafeArea().zIndex(50)
                Image("WardLogo").resizable().scaledToFit().frame(width: 92)
                    .opacity(0.5).zIndex(51)
            }

            if screenCaptured && !shroud {
                VStack {
                    Label("Screen recording is blocked", systemImage: "eye.slash.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                }
                .padding(.top, 8)
                .allowsHitTesting(false)
                .zIndex(45)
            }
        }
        .animation(.snappy(duration: 0.32), value: lock.locked)
        .animation(.snappy(duration: 0.3), value: app.isReady)
        .animation(.snappy(duration: 0.26), value: app.toast)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            shroud = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            shroud = false
            if lock.locked { lock.authenticate() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            screenCaptured = UIScreen.main.isCaptured && app.settings.bool("security.block_screenshots")
        }
        .onReceive(NotificationCenter.default.publisher(for: .wardOpenChat)) { note in
            if let id = note.userInfo?["chatId"] as? Int64 { app.selectChat(id) } else if let id = note.userInfo?["chatId"] as? Int { app.selectChat(Int64(id)) }
        }
        .onOpenURL { url in app.handleURL(url) }
        .task {
            screenCaptured = UIScreen.main.isCaptured && app.settings.bool("security.block_screenshots")
        }
        .preferredColorScheme(preferredScheme)
    }

    private var preferredScheme: ColorScheme? {
        switch app.settings.string("appearance.style", "system") {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private func startupError(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42)).foregroundStyle(palette.danger)
            Text("Ward could not start").font(.title2.weight(.bold))
            Text(message).font(.subheadline).foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WardBackground())
    }
}

struct SplashView: View {
    @Environment(\.ward) private var palette
    @State private var appeared = false
    @State private var breathe = false

    var body: some View {
        ZStack {
            WardBackground()
            VStack(spacing: 18) {
                Image("WardLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 116, height: 116)
                    .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
                    .shadow(color: palette.accent.opacity(0.35), radius: 30, y: 14)
                    .scaleEffect(appeared ? (breathe ? 1.02 : 0.98) : 0.7)
                    .opacity(appeared ? 1 : 0)
                VStack(spacing: 5) {
                    Text("Ward").font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.text)
                    Text("Private messaging, in your pocket")
                        .font(.subheadline).foregroundStyle(palette.secondaryText)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 8)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.72)) { appeared = true }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}
