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
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let workspaceNotifications: NotificationCenter
    @ObservationIgnored private var checkTimer: Timer?
    @ObservationIgnored private var deadlineTimer: Timer?
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var requestTask: Task<ActivationOutcome, Never>?
    @ObservationIgnored private var requestGeneration = 0
    @ObservationIgnored private var isStopped = false

    init(session: SoftwareLicenseSession, clock: @escaping () -> Date = Date.init,
         workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.session = session
        self.clock = clock
        self.workspaceNotifications = workspaceNotifications
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
        return max(0, Int(ceil((end - session.effectiveNow(now: clock()).timeIntervalSince1970) / 86_400)))
    }

    var statusSummary: String {
        switch state {
        case .active(let payload):
            if payload.kind == .trial {
                let days = remainingTrialDays ?? 0
                return L10n.localized(zh: "试用中 · 剩余 \(days) 天", en: "Trial · \(days) \(days == 1 ? "day" : "days") remaining")
            }
            switch payload.kind {
            case .lifetime: return L10n.localized(zh: "已激活 · 永久", en: "Activated · Lifetime")
            case .monthly: return L10n.localized(zh: "已激活 · 一个月", en: "Activated · 1 month")
            case .annual: return L10n.localized(zh: "已激活 · 一年", en: "Activated · 1 year")
            case .trial: return L10n.localized(zh: "试用中", en: "Trial")
            }
        case .unconfigured: return L10n.localized(zh: "此版本尚未配置授权公钥", en: "This build has no license public key configured")
        case .needsConnection: return L10n.localized(zh: "请联网开始 14 天试用，或输入激活码。", en: "Connect to start a 14-day trial, or enter an activation code.")
        case .expired: return L10n.localized(zh: "授权或离线使用期限已到，请联网验证或续费", en: "License or offline access has expired. Connect to verify or renew.")
        case .blocked(let reason): return reason
        }
    }

    var expirySummary: String? {
        guard case .active(let payload) = state else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.effectiveLanguage)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let offline = formatter.string(from: payload.deadline)
        if payload.kind == .lifetime {
            return L10n.localized(zh: "无需续费；最迟于 \(offline) 联网核验。", en: "No renewal needed. Verify online by \(offline).")
        }
        if let entitlementEnd = payload.entitlementExpiresAt {
            let entitlement = formatter.string(from: Date(timeIntervalSince1970: entitlementEnd))
            return L10n.localized(zh: "使用权至 \(entitlement)；离线有效至 \(offline)。", en: "Access until \(entitlement); offline access until \(offline).")
        }
        return nil
    }

    func refresh(now: Date? = nil) {
        guard !isStopped else { return }
        session.checkAccess(now: now ?? clock())
        apply(session.state)
        lastError = session.lastError
    }

    func startMonitoring() {
        guard checkTimer == nil else { return }
        isStopped = false
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
        wakeObserver = workspaceNotifications.addObserver(
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
        isStopped = true
        requestGeneration &+= 1
        requestTask?.cancel()
        requestTask = nil
        isWorking = false
        checkTimer?.invalidate(); checkTimer = nil
        refreshTimer?.invalidate(); refreshTimer = nil
        deadlineTimer?.invalidate(); deadlineTimer = nil
        if let wakeObserver { workspaceNotifications.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    func connect() async {
        _ = await performRequest { [session] in await session.start() }
    }

    func activate(input: String) async -> ActivationOutcome {
        await performRequest { [session] in try await session.activate(code: input) }
    }

    func deactivate() async -> ActivationOutcome {
        await performRequest { [session] in try await session.deactivate() }
    }

    private func performRequest(_ operation: @escaping @MainActor () async throws -> Void) async -> ActivationOutcome {
        guard !isStopped, !Task.isCancelled else { return .failure("授权操作已取消。") }
        guard !isWorking else { return .failure("正在处理授权请求，请稍后再试。") }
        isWorking = true
        requestGeneration &+= 1
        let generation = requestGeneration
        let task = Task { @MainActor () -> ActivationOutcome in
            do {
                try Task.checkCancellation()
                try await operation()
                try Task.checkCancellation()
                return .success
            } catch { return .failure(error.localizedDescription) }
        }
        requestTask = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        guard !isStopped, generation == requestGeneration else { return .failure("授权操作已取消。") }
        requestTask = nil
        isWorking = false
        refresh()
        // 先刷新状态再保留本次错误，避免预校验错误被 session 的空错误覆盖。
        if case .failure(let reason) = result { lastError = reason }
        return result
    }

    private func apply(_ newState: SoftwareLicenseState) {
        guard !isStopped else { return }
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
        let interval = max(0.01, deadline.timeIntervalSince(session.effectiveNow(now: clock())))
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
