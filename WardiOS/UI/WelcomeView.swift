import SwiftUI

private enum WelcomePage { case start, signIn, create, invite }

struct WelcomeView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    @State private var page: WelcomePage = .start
    @State private var prefillJID = ""
    @State private var appeared = false

    var body: some View {
        ZStack {
            WelcomeBackground()
            VStack {
                switch page {
                case .start:
                    StartPage(prefill: prefillJID,
                              onSignIn: { withAnimation(.snappy) { page = .signIn } },
                              onCreate: { withAnimation(.snappy) { page = .create } },
                              onInvite: { withAnimation(.snappy) { page = .invite } })
                case .signIn:
                    SignInPage(prefill: prefillJID, onBack: { withAnimation(.snappy) { page = .start } })
                case .create:
                    CreateAccountPage(onBack: { withAnimation(.snappy) { page = .start } })
                case .invite:
                    InvitePage(onInvite: { jid in
                        prefillJID = jid
                        withAnimation(.snappy) { page = .signIn }
                    }, onBack: { withAnimation(.snappy) { page = .start } })
                }
            }
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
        }
    }
}

private struct WelcomeBackground: View {
    @Environment(\.ward) private var palette
    @State private var drift = false
    var body: some View {
        ZStack {
            palette.background
            Circle()
                .fill(palette.accent.opacity(0.28))
                .frame(width: 420, height: 420)
                .blur(radius: 90)
                .offset(x: drift ? -140 : -190, y: drift ? -300 : -250)
            Circle()
                .fill(Color(hex: "#9141AC").opacity(0.20))
                .frame(width: 380, height: 380)
                .blur(radius: 100)
                .offset(x: drift ? 180 : 130, y: drift ? 260 : 320)
            Circle()
                .fill(Color(hex: "#2190A4").opacity(0.16))
                .frame(width: 280, height: 280)
                .blur(radius: 90)
                .offset(x: drift ? 120 : 170, y: drift ? -240 : -190)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { drift = true }
        }
    }
}

private struct StartPage: View {
    @Environment(\.ward) private var palette
    var prefill: String
    var onSignIn: () -> Void
    var onCreate: () -> Void
    var onInvite: () -> Void
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 58)
                ZStack {
                    Circle().fill(palette.accent.opacity(0.14)).frame(width: 176, height: 176)
                        .blur(radius: 2)
                    Image("WardLogo")
                        .resizable().scaledToFit().frame(width: 128, height: 128)
                        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                        .shadow(color: palette.accent.opacity(0.35), radius: 26, y: 12)
                }
                .scaleEffect(appeared ? 1 : 0.86)
                .opacity(appeared ? 1 : 0)

                Text("Welcome to Ward")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.text)
                    .padding(.top, 24)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 10)

                Text("Private chats and groups on the open XMPP network. Use any server, manage your own keys, and keep the conversation yours.")
                    .font(.body)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 380)
                    .padding(.top, 10)
                    .padding(.horizontal, 28)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 12)

                VStack(spacing: 11) {
                    Button {
                        Haptics.tap(); onSignIn()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                            Text("Sign in")
                        }
                    }
                    .buttonStyle(WardPrimaryButtonStyle())
                    .frame(maxWidth: 360)

                    if !prefill.isEmpty {
                        Text("Continuing with \(prefill)")
                            .font(.caption).foregroundStyle(palette.secondaryText)
                    }

                    Button("Create an account", action: onCreate)
                        .buttonStyle(WardSecondaryButtonStyle())
                        .frame(maxWidth: 360)
                    Button("I have an invite link", action: onInvite)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.accent)
                        .padding(.top, 2)
                }
                .padding(.top, 34)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 18)

                Spacer(minLength: 30)
                HStack(spacing: 20) {
                    FeaturePill(icon: "lock.shield.fill", text: "Private")
                    FeaturePill(icon: "server.rack", text: "Any server")
                    FeaturePill(icon: "person.2.fill", text: "Groups")
                }
                .padding(.bottom, 28)
                .opacity(appeared ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.78).delay(0.08)) { appeared = true }
        }
    }
}

private struct FeaturePill: View {
    @Environment(\.ward) private var palette
    var icon: String
    var text: String
    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(palette.accent)
            Text(text).font(.caption2.weight(.medium)).foregroundStyle(palette.secondaryText)
        }
    }
}

private struct SignInPage: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.ward) private var palette
    @Environment(\.dismiss) private var dismiss
    var prefill: String
    var onBack: () -> Void
    @State private var jid = ""
    @State private var password = ""
    @State private var remember = true
    @State private var advanced = false
    @State private var host = ""
    @State private var port = ""
    @State private var tls = "auto"
    @State private var error = ""
    @State private var busy = false
    @FocusState private var focus: Field?
    private enum Field { case jid, password, host, port }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(palette.secondaryText)
                .padding(.top, 14)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Sign in").font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("Use the address and password you already have. Ward talks to any standard XMPP server.")
                        .font(.subheadline).foregroundStyle(palette.secondaryText)
                }

                VStack(spacing: 12) {
                    FieldBox(icon: "at", title: "Address") {
                        TextField("you@example.org", text: $jid)
                            .textContentType(.username)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .jid)
                            .submitLabel(.next)
                            .onSubmit { focus = .password }
                    }
                    FieldBox(icon: "lock", title: "Password") {
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .focused($focus, equals: .password)
                            .submitLabel(.go)
                            .onSubmit { Task { await submit() } }
                    }
                }

                Toggle(isOn: $remember) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remember this account").font(.subheadline.weight(.medium))
                        Text("The password is kept in the iOS Keychain.")
                            .font(.caption).foregroundStyle(palette.secondaryText)
                    }
                }
                .tint(palette.accent)

                DisclosureGroup(isExpanded: $advanced) {
                    VStack(spacing: 12) {
                        FieldBox(icon: "server.rack", title: "Server address") {
                            TextField("Automatic", text: $host)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($focus, equals: .host)
                        }
                        FieldBox(icon: "number", title: "Port") {
                            TextField("Automatic", text: $port)
                                .keyboardType(.numberPad)
                                .focused($focus, equals: .port)
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Connection security").font(.caption.weight(.medium)).foregroundStyle(palette.secondaryText)
                            Picker("Connection security", selection: $tls) {
                                Text("Automatic").tag("auto")
                                Text("Require STARTTLS").tag("starttls")
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    .padding(.top, 12)
                } label: {
                    Text("Advanced").font(.subheadline.weight(.semibold)).foregroundStyle(palette.text)
                }
                .tint(palette.accent)
                .padding(14)
                .background(palette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                if !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(palette.danger)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        if busy { ProgressView().tint(palette.onAccent) }
                        Text(busy ? "Signing in…" : "Sign in")
                    }
                }
                .buttonStyle(WardPrimaryButtonStyle())
                .disabled(busy)
                .opacity(busy ? 0.75 : 1)

                Text("Ward connects directly to your server. Your password is never sent anywhere else.")
                    .font(.caption2).foregroundStyle(palette.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
                Spacer(minLength: 30)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            if jid.isEmpty { jid = prefill }
            focus = .jid
        }
    }

    private func submit() async {
        guard !busy else { return }
        error = ""
        let address = jid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("@") else {
            error = "Enter an address like you@example.org."
            Haptics.error(); return
        }
        guard !password.isEmpty else {
            error = "Enter your password."
            Haptics.error(); return
        }
        busy = true
        do {
            _ = try await app.addAccount(jid: address, password: password, remember: remember,
                                         host: host, port: port, tls: tls)
            Haptics.success()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
        busy = false
    }
}

struct FieldBox<Content: View>: View {
    @Environment(\.ward) private var palette
    var icon: String
    var title: String
    let content: Content

    init(icon: String, title: String, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption2.weight(.semibold)).foregroundStyle(palette.tertiaryText)
                content
                    .font(.body)
                    .foregroundStyle(palette.text)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.outline.opacity(0.4), lineWidth: 0.5)
        }
    }
}

private struct CreateAccountPage: View {
    @Environment(\.ward) private var palette
    var onBack: () -> Void
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var error = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left").font(.subheadline.weight(.medium))
                }
                .foregroundStyle(palette.secondaryText).padding(.top, 14)

                Text("Create an account").font(.system(size: 32, weight: .bold, design: .rounded))
                Text("In-band registration depends on your server. Enter your server and desired username, or create the account on your provider's website and come back to sign in.")
                    .font(.subheadline).foregroundStyle(palette.secondaryText)

                VStack(spacing: 12) {
                    FieldBox(icon: "server.rack", title: "Server") {
                        TextField("example.org", text: $server)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    FieldBox(icon: "person", title: "Username") {
                        TextField("alice", text: $username)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    FieldBox(icon: "lock", title: "Password") {
                        SecureField("Choose a password", text: $password)
                    }
                }

                if !error.isEmpty {
                    Label(error, systemImage: "info.circle.fill")
                        .font(.footnote).foregroundStyle(palette.danger)
                }

                Button("Check registration support") {
                    error = "Account creation needs a server that supports XEP-0077. Ward for iOS is not wiring in-band registration in this build; create the account on your server and sign in."
                    Haptics.warning()
                }
                .buttonStyle(WardPrimaryButtonStyle())

                VStack(alignment: .leading, spacing: 8) {
                    Text("Recommended servers").font(.subheadline.weight(.semibold))
                    ForEach(["jabber.at", "conversations.im", "your own Prosody or ejabberd"], id: \.self) { item in
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.success)
                            Text(item).font(.subheadline).foregroundStyle(palette.secondaryText)
                        }
                    }
                }
                .padding(16)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 480).frame(maxWidth: .infinity)
        }
    }
}

private struct InvitePage: View {
    @Environment(\.ward) private var palette
    var onInvite: (String) -> Void
    var onBack: () -> Void
    @State private var link = ""
    @State private var error = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left").font(.subheadline.weight(.medium))
                }
                .foregroundStyle(palette.secondaryText).padding(.top, 14)

                Text("An invite").font(.system(size: 32, weight: .bold, design: .rounded))
                Text("Paste an invite link or an XMPP address. Ward will open a sign-in page for that account.")
                    .font(.subheadline).foregroundStyle(palette.secondaryText)

                FieldBox(icon: "link", title: "Invite link or address") {
                    TextField("xmpp:you@example.org", text: $link)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }

                if !error.isEmpty {
                    Text(error).font(.footnote).foregroundStyle(palette.danger)
                }

                Button("Continue") {
                    let value = link.replacingOccurrences(of: "xmpp:", with: "")
                        .split(separator: "?").first.map(String.init) ?? link
                    guard value.contains("@") else {
                        error = "That does not look like an XMPP address."
                        Haptics.error(); return
                    }
                    onInvite(value.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .buttonStyle(WardPrimaryButtonStyle())

                VStack(alignment: .leading, spacing: 8) {
                    Text("What is Ward?").font(.subheadline.weight(.semibold))
                    Text("Ward is a native messenger for the open XMPP network. Invites are ordinary XMPP addresses; you can bring your existing account or ask the person who invited you for a server recommendation.")
                        .font(.subheadline).foregroundStyle(palette.secondaryText)
                }
                .padding(16)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 480).frame(maxWidth: .infinity)
        }
    }
}
