import SwiftUI

struct LoginView: View {
    @EnvironmentObject var app: AppState
    @State private var account = ""
    @State private var password = ""
    @FocusState private var focus: Field?
    private enum Field { case account, password }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Icon("electric_scooter", size: 44).foregroundStyle(T.primary)
                    Text("KQi Air").font(.system(size: 30, weight: .bold)).foregroundStyle(T.onSurface)
                    Text("Ride data and full control for your KQi Air.")
                        .font(.system(size: 14)).foregroundStyle(T.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 40)

                Panel {
                    VStack(alignment: .leading, spacing: 12) {
                        field("Account", text: $account, focused: .account, secure: false)
                        field("Password", text: $password, focused: .password, secure: true)
                        if let e = app.error {
                            Text(e).font(.system(size: 12)).foregroundStyle(T.error)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        OutlineButton(title: app.loading ? "Signing in…" : "Sign in", icon: "login",
                                      tint: T.primary, enabled: !app.loading && !account.isEmpty && !password.isEmpty) {
                            Task { await app.logIn(account: account, password: password) }
                        }
                    }
                }

                Text("Your NIU credentials go straight to NIU's own login endpoint. The session token is kept in the iOS Keychain; the password is never stored.")
                    .font(.system(size: 11)).foregroundStyle(T.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .background(T.surface)
    }

    private func field(_ label: String, text: Binding<String>, focused: Field, secure: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel(text: label)
            Group {
                if secure { SecureField("", text: text) } else { TextField("", text: text) }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .foregroundStyle(T.onSurface)
            .focused($focus, equals: focused)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(secure ? .default : .emailAddress)
            .padding(11)
            .background(T.surface)
            .overlay(Rectangle().strokeBorder(focus == focused ? T.primary : T.outline, lineWidth: T.hairline))
        }
    }
}
