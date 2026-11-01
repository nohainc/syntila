import SwiftUI
import AppKit

struct Account: Decodable, Identifiable, Hashable {
    let id: String
    let email: String
    let display_name: String
    let status: String
    let email_verified: Int
    let created_at: String
    let spaces: Int
    let workspaces: Int
    let requests: Int
    let failed_requests: Int
    let last_request_at: String?
    let messages: Int
    let last_message_at: String?
    let plan: String?
    let plan_source: String?
    let plan_period_end: String?
    var isPaid: Bool { plan == "paid" }
}
struct Reply: Decodable {
    let users: [Account]?
    let message: String?
    let error: String?
}
struct Bridge {
    static func request(_ payload: [String: String]) async throws -> Reply {
        let data = try JSONEncoder().encode(payload)
        return try await Task.detached {
            let process = Process()
            let input = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            let resource = Bundle.main.resourceURL?.appendingPathComponent("repository.txt")
            let savedRoot = resource.flatMap { try? String(contentsOf: $0, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) }
            let root = ProcessInfo.processInfo.environment["SYNTILA_REPOSITORY"] ?? savedRoot ?? FileManager.default.currentDirectoryPath
            process.currentDirectoryURL = URL(fileURLWithPath: root)
            process.arguments = ["node", root + "/apps/cloud/scripts/account-manager.mjs"]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
            process.environment = env
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            input.fileHandleForWriting.write(data)
            try input.fileHandleForWriting.close()
            let result = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard !result.isEmpty else { throw NSError(domain: "AccountManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not run the database bridge. Check that Node.js and repository dependencies are installed."]) }
            let reply = try JSONDecoder().decode(Reply.self, from: result)
            if let error = reply.error { throw NSError(domain: "AccountManager", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
            guard process.terminationStatus == 0 else { throw NSError(domain: "AccountManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Account operation failed."]) }
            return reply
        }.value
    }
}

@MainActor final class Model: ObservableObject {
    @Published var environment = "local"
    @Published var search = ""
    @Published var accounts: [Account] = []
    @Published var selected: String?
    @Published var busy = false
    @Published var message = "Search accounts by name, email, or user ID."
    @Published var failed = false
    var current: Account? { accounts.first { $0.id == selected } }
    func load(clear: Bool = false) async {
        guard !busy else { return }
        if clear { accounts = []; selected = nil }
        busy = true
        defer { busy = false }
        do {
            let reply = try await Bridge.request(["environment": environment, "action": "list", "search": search])
            accounts = reply.users ?? []
            if !accounts.contains(where: { $0.id == selected }) { selected = nil }
            message = accounts.count > 200 ? "Showing the first 200 accounts. Refine your search for more results." : "\(accounts.count) accounts · \(environment == "local" ? "Local database" : "Production database")"
            accounts = Array(accounts.prefix(200))
            failed = false
        } catch { message = error.localizedDescription; failed = true; accounts = []; selected = nil }
    }
    func perform(_ action: String, account: Account, confirmation: String) async {
        guard !busy else { return }
        busy = true
        do {
            var payload = ["environment": environment, "action": action, "id": account.id, "email": account.email]
            if action == "unlock" || action == "reset" { payload["confirmEmail"] = confirmation }
            let reply = try await Bridge.request(payload)
            let success = reply.message ?? "Done."
            busy = false
            await load()
            if !failed { message = success }
        } catch { message = error.localizedDescription; failed = true; busy = false }
    }
}

struct ContentView: View {
    @StateObject private var model = Model()
    @State private var pending: String?
    @State private var confirmation = ""
    @State private var target: Account?
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    if let url = Bundle.main.url(forResource: "Logo", withExtension: "png"), let logo = NSImage(contentsOf: url) {
                        Image(nsImage: logo).resizable().interpolation(.high).frame(width: 28, height: 28).accessibilityHidden(true)
                    }
                    Text("Syntila Accounts").font(.title2.bold())
                }
                Picker("Database", selection: $model.environment) {
                    Text("Local").tag("local")
                    Text("Production").tag("production")
                }.pickerStyle(.segmented).disabled(model.busy)
                Text(model.environment == "production" ? "PRODUCTION · Live user accounts" : "LOCAL · Development accounts")
                    .font(.caption.bold()).foregroundStyle(model.environment == "production" ? .orange : .secondary)
                HStack {
                    TextField("Name, email, or user ID", text: $model.search).onSubmit { Task { await model.load() } }
                    Button { Task { await model.load() } } label: { Image(systemName: "magnifyingglass") }.disabled(model.busy)
                }
                List(model.accounts, selection: $model.selected) { account in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.display_name).font(.headline)
                        Text(account.email).font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text(account.status.capitalized).foregroundStyle(account.status == "active" ? .green : .orange)
                            if account.isPaid { Text("Paid").foregroundStyle(.blue) }
                        }.font(.caption2)
                    }.padding(.vertical, 4).tag(account.id)
                }.listStyle(.inset)
            }.padding().navigationSplitViewColumnWidth(min: 300, ideal: 340)
        } detail: {
            VStack(alignment: .leading, spacing: 20) {
                if let account = model.current {
                    HStack {
                        Image(systemName: "person.crop.circle").font(.system(size: 48)).foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(account.display_name).font(.largeTitle.bold())
                            Text(account.email).textSelection(.enabled)
                        }
                        Spacer()
                        Text(account.status.capitalized).font(.headline).foregroundStyle(account.status == "active" ? .green : .orange)
                    }
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                        row("User ID", account.id)
                        row("Email verified", account.email_verified == 1 ? "Yes" : "No")
                        row("Created", account.created_at)
                        row("Last work request", account.last_request_at ?? "None")
                        row("Last message (UTC)", account.last_message_at ?? "None")
                        row("Membership", planText(account))
                    }.textSelection(.enabled)
                    HStack(spacing: 28) {
                        metric("Workspaces", account.workspaces)
                        metric("Spaces", account.spaces)
                        metric("Messages", account.messages)
                        metric("Work requests", account.requests)
                        metric("Failed requests", account.failed_requests)
                    }.padding(.vertical)
                    Text("Lifetime activity recorded by Syntila. Messages counts thread discussion messages; Chat/Work request prompts are excluded.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(account.status == "suspended" ? "Unlock account" : "Lock account") { prepare(account.status == "suspended" ? "unlock" : "lock", account) }
                            .disabled(model.busy || account.status == "deactivated")
                        Button("Send password reset email") { prepare("reset", account) }
                            .disabled(model.busy || account.status != "active")
                        Button(account.isPaid ? "Disable paid membership" : "Enable paid membership") { prepare(account.isPaid ? "revoke_paid" : "grant_paid", account) }
                            .disabled(model.busy)
                    }
                    Spacer()
                } else {
                    ContentUnavailableView("Select an account", systemImage: "person.crop.circle", description: Text("Search and select a user to inspect their account and activity."))
                }
                Divider()
                HStack {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.message).font(.callout).foregroundStyle(model.failed ? .red : .secondary).textSelection(.enabled)
                    Spacer()
                    Button("Refresh") { Task { await model.load() } }.disabled(model.busy)
                }
            }.padding(28)
        }
        .frame(minWidth: 1000, minHeight: 620)
        .task { await model.load() }
        .onChange(of: model.environment) { Task { await model.load(clear: true) } }
        .sheet(isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Confirm \(actionTitle(pending)) · \(model.environment.capitalized)").font(.title2.bold())
                Text(target?.email ?? "").font(.headline)
                Text(actionDetail(pending))
                if pending == "unlock" || pending == "reset" {
                    TextField("Retype the account email", text: $confirmation)
                }
                HStack {
                    Button("Cancel") { pending = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Confirm") {
                        if let action = pending, let account = target {
                            let typed = confirmation
                            pending = nil
                            Task { await model.perform(action, account: account, confirmation: typed) }
                        }
                    }.disabled((pending == "unlock" || pending == "reset") && confirmation != target?.email).keyboardShortcut(.defaultAction)
                }
            }.padding(28).frame(width: 480)
        }
    }
    private func prepare(_ action: String, _ account: Account) { target = account; confirmation = ""; pending = action }
    private func planText(_ account: Account) -> String {
        guard account.isPaid else { return account.plan_source == nil ? "Free" : "Free (paid membership ended)" }
        let source = account.plan_source == "manual" ? "manual grant" : "subscription"
        return "Paid · \(source)" + (account.plan_period_end.map { " · until \($0)" } ?? "")
    }
    private func actionTitle(_ action: String?) -> String {
        switch action {
        case "grant_paid": return "enable paid membership"
        case "revoke_paid": return "disable paid membership"
        default: return action ?? ""
        }
    }
    private func actionDetail(_ action: String?) -> String {
        switch action {
        case "reset": return "Request an email containing a time-limited password reset link. Email delivery is not guaranteed by the request response."
        case "grant_paid": return "Grants Syntila Plus with no end date until disabled here. This replaces any existing subscription record for this user."
        case "revoke_paid": return "Moves the user to Free. Paid features stop and Workspaces they share are paused for other people; existing grants return if re-enabled. Running work is not cancelled."
        default: return "This changes access to Syntila. Locking revokes human sessions; work already running is not cancelled."
        }
    }
    private func row(_ title: String, _ value: String) -> some View { GridRow { Text(title).foregroundStyle(.secondary); Text(value) } }
    private func metric(_ title: String, _ count: Int) -> some View { VStack(alignment: .leading) { Text("\(count)").font(.title.bold()); Text(title).font(.caption).foregroundStyle(.secondary) } }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct AccountManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { WindowGroup("Syntila Accounts") { ContentView() } }
}
