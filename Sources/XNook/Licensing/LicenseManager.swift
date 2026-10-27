import AppKit
import Foundation
import Observation
import MeteorLicenseCore

/// 共享授权协议的界面适配器；凭据与设备令牌只保存在钥匙串。
@MainActor
@Observable
final class LicenseManager {
    static let shared = LicenseManager()
    static let purchaseURL = URL(string: "https://www.imagentx.top/zh/products/xnook")!

    private(set) var state: SoftwareLicenseState
    private(set) var lastError: String?
    private(set) var isWorking = false
    var onAccessChange: ((Bool) -> Void)?

    @ObservationIgnored private let session: SoftwareLicenseSession
    @ObservationIgnored private var checkTimer: Timer?
    @ObservationIgnored private var deadlineTimer: Timer?
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    init(session: SoftwareLicenseSession) {
        self.session = session
        self.state = session.state
        self.lastError = session.lastError
        session.onStateChange = { [weak self] state in self?.apply(state) }
    }

    private convenience init() {
        let store = KeychainLicenseStore(service: "com.meteorkid.xnook.software-license")
        let deviceStore = KeychainLicenseStore(service: "com.meteorkid.xnook.software-license", account: "device")
        let deviceID: String
        let sessionStore: any LicenseCredentialStore
        do {
            deviceID = try LicenseDeviceIdentity.resolve(store: deviceStore)
            sessionStore = store
        } catch {
            deviceID = ""
            sessionStore = UnavailableLicenseStore()
        }
        let origin = Bundle.main.object(forInfoDictionaryKey: "SoftwareLicenseAPIBaseURL") as? String
        let api = SoftwareLicenseAPI(baseURL: URL(string: origin ?? "https://www.imagentx.top") ?? Self.purchaseURL)
        self.init(session: SoftwareLicenseSession(
            productId: "xnook", deviceId: deviceID, deviceName: String((Host.current().localizedName ?? "Mac").prefix(100)),
            publicKeyBase64: Bundle.main.object(forInfoDictionaryKey: "SoftwareLicensePublicKey") as? String,
            api: api, store: sessionStore
        ))
    }

    var isLicensed: Bool {
        if case .active(let payload) = state { return payload.kind != .trial }
        return false
    }

    var remainingTrialDays: Int? {
        guard case .active(let payload) = state, payload.kind == .trial,
              let end = payload.entitlementExpiresAt else { return nil }
        return max(0, Int(ceil((end - session.effectiveNow().timeIntervalSince1970) / 86_400)))
    }

    var statusSummary: String {
        switch state {
        case .active(let payload):
            if payload.kind == .trial { return "试用中 · 剩余 \(remainingTrialDays ?? 0) 天" }
            switch payload.kind {
            case .lifetime: return "已激活 · 永久使用权"
            case .monthly: return "已激活 · 月度授权"
            case .annual: return "已激活 · 年度授权"
            case .trial: return "试用中"
            }
        case .unconfigured: return "此版本尚未配置授权公钥"
        case .needsConnection: return "请联网开始 14 天试用，或输入邀请码激活"
        case .expired: return "授权或离线使用期限已到，请联网验证或续费"
        case .blocked(let reason): return reason
        }
    }

    var expirySummary: String? {
        guard case .active(let payload) = state else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let offline = formatter.string(from: payload.deadline)
        if payload.kind == .lifetime { return "无需续费；最迟于 \(offline) 联网核验。" }
        if let entitlementEnd = payload.entitlementExpiresAt {
            return "使用权至 \(formatter.string(from: Date(timeIntervalSince1970: entitlementEnd)))；离线有效至 \(offline)。"
        }
        return nil
    }

    func refresh(now: Date = Date()) {
        session.checkAccess(now: now)
        lastError = session.lastError
        scheduleDeadline()
    }

    func startMonitoring() {
        guard checkTimer == nil else { return }
        refresh()
        let check = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(check, forMode: .common)
        checkTimer = check
        let renewal = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.connect() }
        }
        RunLoop.main.add(renewal, forMode: .common)
        refreshTimer = renewal
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                await self?.connect()
            }
        }
        Task { await connect() }
    }

    func stopMonitoring() {
        checkTimer?.invalidate(); checkTimer = nil
        refreshTimer?.invalidate(); refreshTimer = nil
        deadlineTimer?.invalidate(); deadlineTimer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    func connect() async {
        guard !isWorking else { return }
        isWorking = true
        await session.start()
        isWorking = false
        lastError = session.lastError
        refresh()
    }

    func activate(input: String) async -> ActivationOutcome {
        guard !isWorking else { return .failure("正在处理授权请求，请稍后再试。") }
        isWorking = true
        defer { isWorking = false; refresh() }
        do {
            try await session.activate(code: input)
            lastError = nil
            return .success
        } catch {
            lastError = error.localizedDescription
            return .failure(error.localizedDescription)
        }
    }

    func deactivate() async -> ActivationOutcome {
        guard !isWorking else { return .failure("正在处理授权请求，请稍后再试。") }
        isWorking = true
        defer { isWorking = false; refresh() }
        do {
            try await session.deactivate()
            lastError = nil
            return .success
        } catch {
            lastError = error.localizedDescription
            return .failure(error.localizedDescription)
        }
    }

    private func apply(_ newState: SoftwareLicenseState) {
        let previouslyAllowed = state.allowsAccess
        state = newState
        if newState.allowsAccess != previouslyAllowed {
            onAccessChange?(newState.allowsAccess)
            if newState.allowsAccess {
                NotificationCenter.default.post(name: .xnookLicenseActivated, object: nil)
            }
        }
        scheduleDeadline()
    }

    private func scheduleDeadline() {
        deadlineTimer?.invalidate()
        guard let deadline = session.nextDeadline else { deadlineTimer = nil; return }
        let interval = max(0.01, deadline.timeIntervalSince(session.effectiveNow()))
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer
    }
}

enum ActivationOutcome: Equatable {
    case success
    case failure(String)
}

private struct UnavailableLicenseStore: LicenseCredentialStore {
    func load() throws -> Data? { throw SoftwareLicenseError.storage(-1) }
    func save(_ data: Data) throws { throw SoftwareLicenseError.storage(-1) }
    func delete() throws { throw SoftwareLicenseError.storage(-1) }
}
