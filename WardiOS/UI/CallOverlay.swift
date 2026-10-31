import SwiftUI
import AVFoundation

// MARK: - Call overlay

struct CallOverlay: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    var call: CallState
    @State private var ringtone: AVAudioPlayer?

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 20)
                avatarSection
                statusSection
                Spacer(minLength: 30)
                controls
                Spacer(minLength: 30)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .ignoresSafeArea(edges: .all)
        .onAppear { playRingtoneIfNeeded() }
        .onDisappear { stopRingtone() }
        .onChange(of: call.status) { _, _ in
            if call.status != .ringing && call.status != .outgoing { stopRingtone() }
        }
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#14121A"), palette.accent.mix(with: .black, by: 0.55), Color(hex: "#0C0B10")],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(palette.accent.opacity(0.32)).frame(width: 380, height: 380)
                .blur(radius: 110).offset(x: 150, y: -220)
            Circle().fill(Color(hex: "#9141AC").opacity(0.26)).frame(width: 320, height: 320)
                .blur(radius: 110).offset(x: -160, y: 260)
            if call.kind == .video {
                Image(systemName: "person.crop.rectangle")
                    .font(.system(size: 180, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.06))
            }
        }
    }

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(call.kind == .video ? "Video call" : "Audio call")
                    .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                if let account = app.account(id: call.accountId) {
                    Text(account.jid).font(.caption2).foregroundStyle(.white.opacity(0.45))
                }
            }
            Spacer()
            Button { app.endCall() } label: {
                Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 36, height: 36).background(.white.opacity(0.1), in: Circle())
            }
        }
    }

    private var avatarSection: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(palette.accent.opacity(0.20 - Double(index) * 0.05), lineWidth: 1)
                    .frame(width: 160 + CGFloat(index) * 46, height: 160 + CGFloat(index) * 46)
                    .scaleEffect(call.status == .ringing || call.status == .outgoing ? 1.06 : 1)
                    .opacity(call.status == .ringing || call.status == .outgoing ? 1 : 0.35)
                    .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: true).delay(Double(index) * 0.35),
                               value: call.status)
            }
            AvatarView(name: app.contact(jid: call.peer, accountId: call.accountId)?.name ?? JID.local(call.peer),
                       jid: call.peer, size: 136,
                       imagePath: app.contact(jid: call.peer, accountId: call.accountId)?.avatar)
                .shadow(color: .black.opacity(0.4), radius: 30, y: 16)
        }
        .frame(height: 240)
    }

    private var statusSection: some View {
        VStack(spacing: 6) {
            Text(app.contact(jid: call.peer, accountId: call.accountId)?.name ?? JID.local(call.peer))
                .font(.system(size: 27, weight: .bold, design: .rounded)).foregroundStyle(.white)
            HStack(spacing: 6) {
                if call.status == .active, let started = call.startedAt {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(WardFormat.duration(context.date.timeIntervalSince(started)))
                            .font(.subheadline.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                    }
                } else {
                    Text(statusText)
                        .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                        .contentTransition(.opacity)
                }
                if call.muted {
                    Image(systemName: "mic.slash.fill").font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }

    private var statusText: String {
        switch call.status {
        case .outgoing: return "Calling…"
        case .ringing: return call.incoming ? "Incoming call" : "Ringing…"
        case .connecting: return "Connecting…"
        case .active: return "Connected"
        case .ended: return "Call ended"
        }
    }

    private var controls: some View {
        VStack(spacing: 22) {
            if call.incoming && call.status == .ringing {
                HStack(spacing: 60) {
                    CallButton(icon: "phone.down.fill", label: "Decline", color: Color(hex: "#E62D42"), dark: false) { app.rejectCall() }
                    CallButton(icon: call.kind == .video ? "video.fill" : "phone.fill", label: "Accept", color: Color(hex: "#2E8B3D"), dark: false) { app.acceptCall() }
                }
            } else {
                HStack(spacing: 22) {
                    CallButton(icon: call.muted ? "mic.slash.fill" : "mic.fill", label: "Mute",
                               color: call.muted ? .white : .white.opacity(0.14), dark: call.muted) { app.toggleMute() }
                    CallButton(icon: "speaker.wave.2.fill", label: "Speaker",
                               color: call.speaker ? .white : .white.opacity(0.14), dark: call.speaker) { app.toggleSpeaker() }
                    if call.kind == .video {
                        CallButton(icon: call.camera ? "video.fill" : "video.slash.fill", label: "Camera",
                                   color: call.camera ? .white : .white.opacity(0.14), dark: call.camera) { app.toggleCamera() }
                    }
                }
                CallButton(icon: "phone.down.fill", label: "End", color: Color(hex: "#E62D42"), dark: false) { app.endCall() }
                    .frame(width: 72, height: 72)
            }
        }
    }

    private func playRingtoneIfNeeded() {
        let key = call.incoming ? "calls.ringtone" : "calls.ringback"
        let setting = app.settings.string(key, "ward")
        guard setting != "none", let url = Bundle.main.url(forResource: call.incoming ? "ringtone" : "ringback", withExtension: "m4a") else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        ringtone = try? AVAudioPlayer(contentsOf: url)
        ringtone?.numberOfLoops = -1
        ringtone?.play()
    }

    private func stopRingtone() {
        ringtone?.stop()
        ringtone = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

private struct CallButton: View {
    var icon: String
    var label: String
    var color: Color
    var dark: Bool = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(dark ? .black : .white)
                    .frame(width: 62, height: 62)
                    .background(color, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.8))
                Text(label).font(.caption2.weight(.medium)).foregroundStyle(.white.opacity(0.8))
            }
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - App unlock

struct AppUnlockView: View {
    @EnvironmentObject private var lock: AppLockManager
    @Environment(\.ward) private var palette
    @State private var passcode = ""
    @State private var shake = false

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            backdrop
            VStack(spacing: 20) {
                Spacer()
                Image("WardLogo").resizable().scaledToFit().frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: palette.accent.opacity(0.3), radius: 20, y: 8)
                VStack(spacing: 5) {
                    Text(lock.hasPasscode ? "Enter your passcode" : "Unlock Ward")
                        .font(.title3.weight(.bold)).foregroundStyle(palette.text)
                    Text(lock.hasPasscode ? "Ward is locked." : "Confirm it is you to continue.")
                        .font(.caption).foregroundStyle(palette.secondaryText)
                }
                dots
                if let error = lock.error {
                    Text(error).font(.caption).foregroundStyle(palette.danger)
                        .transition(.opacity)
                }
                numpad
                if lock.biometricAvailable {
                    Button {
                        lock.authenticate()
                    } label: {
                        Label("Use \(lock.biometricName)", systemImage: lock.biometricName == "Touch ID" ? "touchid" : "faceid")
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(palette.accent)
                    .padding(.top, 4)
                }
                Spacer()
            }
            .padding(.horizontal, 34)
        }
        .onAppear {
            if lock.biometricAvailable && lock.useBiometrics { lock.authenticate() }
        }
        .offset(x: shake ? -9 : 0)
        .animation(shake ? .default.repeatCount(3, autoreverses: true) : .default, value: shake)
    }

    private var backdrop: some View {
        ZStack {
            palette.background.opacity(0.55)
            Circle().fill(palette.accent.opacity(0.2)).frame(width: 300, height: 300).blur(radius: 90).offset(x: 120, y: -260)
            Circle().fill(Color(hex: "#9141AC").opacity(0.16)).frame(width: 260, height: 260).blur(radius: 90).offset(x: -130, y: 280)
        }
        .ignoresSafeArea()
    }

    private var dots: some View {
        HStack(spacing: 12) {
            ForEach(0..<max(4, passcode.count), id: \.self) { index in
                Circle()
                    .fill(index < passcode.count ? palette.accent : palette.surfaceVariant)
                    .frame(width: 13, height: 13)
                    .overlay(Circle().strokeBorder(palette.outline.opacity(0.4), lineWidth: 0.5))
                    .scaleEffect(index < passcode.count ? 1.1 : 1)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: passcode.count)
            }
        }
        .padding(.vertical, 8)
    }

    private var numpad: some View {
        VStack(spacing: 11) {
            ForEach(Array(["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "delete"].chunked(into: 3)), id: \.self) { row in
                HStack(spacing: 14) {
                    ForEach(row, id: \.self) { key in
                        if key.isEmpty {
                            Color.clear.frame(width: 70, height: 62)
                        } else if key == "delete" {
                            Button {
                                if !passcode.isEmpty { passcode.removeLast() }
                                Haptics.soft()
                            } label: {
                                Image(systemName: "delete.left").font(.system(size: 19))
                                    .foregroundStyle(palette.secondaryText)
                                    .frame(width: 70, height: 62)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button {
                                passcode.append(key)
                                Haptics.soft()
                                if passcode.count >= 4 { attempt() }
                            } label: {
                                Text(key).font(.system(size: 25, weight: .medium, design: .rounded))
                                    .foregroundStyle(palette.text)
                                    .frame(width: 70, height: 62)
                                    .background(palette.surface.opacity(0.7), in: Circle())
                                    .overlay(Circle().strokeBorder(palette.outline.opacity(0.3), lineWidth: 0.5))
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                }
            }
        }
    }

    private func attempt() {
        guard lock.hasPasscode else {
            lock.locked = false
            return
        }
        if !lock.unlock(passcode: passcode) {
            shake = true
            passcode = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { shake = false }
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
