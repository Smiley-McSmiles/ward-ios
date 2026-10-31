import Foundation
import LocalAuthentication
import SwiftUI

@MainActor
final class AppLockManager: ObservableObject {
    @Published var locked = false
    @Published var biometricAvailable = false
    @Published var biometricName = "Face ID"
    @Published var error: String? = nil
    @Published var isAuthenticating = false

    private let defaults = UserDefaults.standard
    private var lastBackground: Date? = nil

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "ward.applock.enabled") }
    }
    @Published var useBiometrics: Bool {
        didSet { defaults.set(useBiometrics, forKey: "ward.applock.biometrics") }
    }
    @Published var delay: Int {
        didSet { defaults.set(delay, forKey: "ward.applock.delay") }
    }
    var hasPasscode: Bool { SecureStore.shared.passcodeHash() != nil }

    init() {
        enabled = defaults.bool(forKey: "ward.applock.enabled")
        useBiometrics = defaults.object(forKey: "ward.applock.biometrics") as? Bool ?? true
        delay = defaults.integer(forKey: "ward.applock.delay")
        if enabled && !hasPasscode {
            // Recover safely if the Keychain was wiped: never leave the UI in a state where any
            // four-digit sequence can dismiss the lock.
            enabled = false
        }
        locked = enabled
        checkBiometrics()
    }

    func checkBiometrics() {
        let context = LAContext()
        var error: NSError?
        biometricAvailable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        switch context.biometryType {
        case .faceID: biometricName = "Face ID"
        case .touchID: biometricName = "Touch ID"
        case .opticID: biometricName = "Optic ID"
        default: biometricName = "Biometrics"
        }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        locked = value
        objectWillChange.send()
    }

    func setPasscode(_ code: String) {
        SecureStore.shared.setPasscode(code)
        objectWillChange.send()
    }

    func clearPasscode() {
        SecureStore.shared.clearPasscode()
        enabled = false
        locked = false
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background, .inactive:
            if enabled { lastBackground = Date() }
        case .active:
            guard enabled else { return }
            if let last = lastBackground {
                let elapsed = Date().timeIntervalSince(last)
                if elapsed >= Double(delay) { locked = true }
            }
        @unknown default: break
        }
    }

    func lockNow() {
        if enabled { locked = true }
    }

    func authenticate() {
        guard enabled else { locked = false; return }
        error = nil
        if useBiometrics && biometricAvailable {
            Task { await authenticateBiometrics() }
        }
    }

    func authenticateBiometrics() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let context = LAContext()
        context.localizedCancelTitle = "Use passcode"
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                           localizedReason: "Unlock Ward")
            if success {
                withAnimation(.snappy) { locked = false }
                Haptics.success()
            }
        } catch {
            self.error = "Face ID did not recognise you. Use your passcode."
        }
    }

    func unlock(passcode: String) -> Bool {
        if SecureStore.shared.verifyPasscode(passcode) {
            withAnimation(.snappy) { locked = false }
            error = nil
            Haptics.success()
            return true
        }
        error = "That passcode is not correct."
        Haptics.error()
        return false
    }
}
