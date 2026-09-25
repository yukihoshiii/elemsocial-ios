import Foundation

final class AuthTokenStore {
    private let key = "element_session_s_key"
    private let accountStore = AccountStore()

    func save(sessionKey: String) {
        UserDefaults.standard.set(sessionKey, forKey: key)
    }

    func load() -> String? {
        if let current = accountStore.currentAccount() {
            return current.sKey
        }
        return UserDefaults.standard.string(forKey: key)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

final class AccountStore {
    private struct State: Codable {
        var accounts: [StoredAccount]
        var currentAccountID: String?
    }

    struct StoredAccount: Identifiable, Codable {
        let id: String
        var userID: Int?
        var name: String?
        var username: String?
        var email: String?
        var avatar: PostAuthorAvatar?
        var sKey: String
        var lastUsedAt: Date

        var displayName: String {
            if let name, !name.isEmpty { return name }
            if let username, !username.isEmpty { return username }
            if let email, !email.isEmpty { return email }
            return "Аккаунт"
        }
    }

    private let storeKey = "element_accounts_v1"
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    func accounts() -> [StoredAccount] {
        loadState().accounts
    }

    func currentAccount() -> StoredAccount? {
        let state = loadState()
        guard let currentID = state.currentAccountID else { return nil }
        return state.accounts.first { $0.id == currentID }
    }

    func currentAccountID() -> String? {
        loadState().currentAccountID
    }

    func setCurrentAccount(id: String) {
        var state = loadState()
        state.currentAccountID = id
        if let index = state.accounts.firstIndex(where: { $0.id == id }) {
            state.accounts[index].lastUsedAt = Date()
        }
        saveState(state)
    }

    func addOrUpdate(sKey: String, summary: APIClient.AccountSummary) -> StoredAccount {
        var state = loadState()
        let matchIndex = indexForMatch(in: state.accounts, summary: summary)

        if let index = matchIndex {
            state.accounts[index].sKey = sKey
            state.accounts[index].userID = summary.userID
            state.accounts[index].name = summary.name
            state.accounts[index].username = summary.username
            state.accounts[index].email = summary.email
            state.accounts[index].avatar = summary.avatar
            state.accounts[index].lastUsedAt = Date()
            saveState(state)
            return state.accounts[index]
        }

        let account = StoredAccount(
            id: UUID().uuidString,
            userID: summary.userID,
            name: summary.name,
            username: summary.username,
            email: summary.email,
            avatar: summary.avatar,
            sKey: sKey,
            lastUsedAt: Date()
        )
        state.accounts.append(account)
        state.currentAccountID = account.id
        saveState(state)
        return account
    }

    func updateCurrent(summary: APIClient.AccountSummary) {
        var state = loadState()
        guard let currentID = state.currentAccountID,
              let index = state.accounts.firstIndex(where: { $0.id == currentID }) else {
            return
        }
        state.accounts[index].userID = summary.userID
        state.accounts[index].name = summary.name
        state.accounts[index].username = summary.username
        state.accounts[index].email = summary.email
        state.accounts[index].avatar = summary.avatar
        state.accounts[index].lastUsedAt = Date()
        saveState(state)
    }

    func removeAccount(id: String) {
        var state = loadState()
        state.accounts.removeAll { $0.id == id }
        if state.currentAccountID == id {
            state.currentAccountID = state.accounts.first?.id
        }
        saveState(state)
    }

    func removeAll() {
        saveState(State(accounts: [], currentAccountID: nil))
    }

    private func indexForMatch(in accounts: [StoredAccount], summary: APIClient.AccountSummary) -> Int? {
        if let userID = summary.userID,
           let index = accounts.firstIndex(where: { $0.userID == userID }) {
            return index
        }

        if let username = summary.username?.lowercased(), !username.isEmpty,
           let index = accounts.firstIndex(where: { $0.username?.lowercased() == username }) {
            return index
        }

        if let email = summary.email?.lowercased(), !email.isEmpty,
           let index = accounts.firstIndex(where: { $0.email?.lowercased() == email }) {
            return index
        }

        return nil
    }

    private func loadState() -> State {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let state = try? decoder.decode(State.self, from: data) else {
            return State(accounts: [], currentAccountID: nil)
        }
        return state
    }

    private func saveState(_ state: State) {
        if let data = try? encoder.encode(state) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }
}
