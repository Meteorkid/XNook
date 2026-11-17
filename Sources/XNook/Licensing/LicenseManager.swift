import Foundation
import CryptoKit
import Observation
import XNookLicenseCore

/// 授权状态。
enum LicenseState: Equatable {
    /// 试用中，携带剩余天数（1…14）
    case trial(remainingDays: Int)
    /// 已激活（永久授权）
    case licensed(serial: UInt32, flags: LicenseFlags)
    /// 试用到期且未激活
    case expired
    /// 公钥尚未配置（开发态），一切激活都会被拒绝
    case unconfigured

    /// 是否允许使用完整功能
    var allowsFullAccess: Bool {
        switch self {
        case .trial, .licensed: return true
        case .expired, .unconfigured: return false
        }
    }

    /// 是否已付费激活
    var isLicensed: Bool {
        if case .licensed = self { return true }
        return false
    }
}

/// 激活结果。
enum ActivationOutcome: Equatable {
    case success(serial: UInt32, flags: LicenseFlags)
    case failure(String)
}

/// 授权管理器。
///
/// ## 职责
/// - 判定当前授权状态（试用 / 已激活 / 已到期）
/// - 校验并落盘邀请码
/// - 可选的在线登记（失败不影响本地放行）
///
/// ## 关键设计：放行决策在本地
///
/// 在线登记**不参与**放行判定。这样服务器故障、断网、DNS 异常
/// 都不会导致用户无法使用已购买的软件。登记只用于统计与后续运营。
@MainActor
@Observable
final class LicenseManager {

    static let shared = LicenseManager()

    /// 已激活凭证的持久化键
    private static let credentialKey = "xnook.license.credential"

    /// 当前授权状态
    private(set) var state: LicenseState

    /// 已激活的邀请码原文（便于用户查看/迁移）
    private(set) var activatedCode: String?

    /// 试用锚点
    private(set) var anchor: AnchorRecord

    /// 在线登记端点。为空表示不启用登记（纯离线模式）。
    ///
    /// 留空即可获得完全离线的行为——这是默认值。
    /// 填入形如 `https://your-host/api/activate` 即启用。
    static var registrationEndpoint: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "XNookLicenseEndpoint") as? String,
              !raw.isEmpty,
              let url = URL(string: raw) else { return nil }
        return url
    }

    /// 公钥是否已配置
    var isPublicKeyConfigured: Bool {
        LicenseManager.resolvedPublicKey() != nil
    }

    /// 公钥解析。
    ///
    /// 生产环境从 `LicensePublicKey` 读取；单元测试通过 `publicKeyOverride`
    /// 注入临时密钥，以便覆盖真实的激活/验签路径。
    /// 这个注入点本身不构成安全弱点——它只影响验签用哪把公钥，
    /// 无法凭它构造出有效签名。
    nonisolated(unsafe) static var publicKeyOverride: Curve25519.Signing.PublicKey?

    static func resolvedPublicKey() -> Curve25519.Signing.PublicKey? {
        publicKeyOverride ?? LicensePublicKey.publicKey
    }

    // MARK: - 初始化

    /// 注入的 UserDefaults。生产为 `.standard`，测试用独立 suite 避免相互污染。
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        let (loadedAnchor, _) = TrialAnchor.loadOrCreate(defaults: defaults, now: now)
        self.anchor = loadedAnchor

        // 优先恢复已激活状态
        if let restored = LicenseManager.restoreCredential(defaults: defaults) {
            self.state = .licensed(serial: restored.serial, flags: restored.flags)
            self.activatedCode = restored.code
        } else if LicenseManager.resolvedPublicKey() == nil {
            // 未配置公钥：开发态。此时不消耗试用期，但也不放行。
            self.state = .unconfigured
        } else {
            let remaining = TrialAnchor.remainingDays(of: loadedAnchor, now: now)
            self.state = remaining > 0 ? .trial(remainingDays: remaining) : .expired
        }
    }

    // MARK: - 状态刷新

    /// 刷新试用剩余天数。应在每次启动与跨天后调用。
    func refresh(now: Date = Date()) {
        // 已激活的不再变动
        if state.isLicensed { return }

        guard LicenseManager.resolvedPublicKey() != nil else {
            state = .unconfigured
            return
        }

        // 每次刷新时更新 lastSeen，抵御时钟回拨
        let (updated, _) = TrialAnchor.loadOrCreate(defaults: defaults, now: now)
        anchor = updated

        let remaining = TrialAnchor.remainingDays(of: updated, now: now)
        state = remaining > 0 ? .trial(remainingDays: remaining) : .expired
    }

    // MARK: - 激活

    /// 校验并激活邀请码。
    ///
    /// - Parameter input: 用户输入或来自激活链接的邀请码
    /// - Returns: 激活结果。失败时返回面向用户的错误文案。
    func activate(input: String, now: Date = Date()) async -> ActivationOutcome {
        guard let publicKey = LicenseManager.resolvedPublicKey() else {
            return .failure(LicenseError.text(
                "软件未配置授权公钥，无法激活。请联系开发者获取正式版本。",
                "This build has no license public key configured and cannot activate. Please obtain an official release."
            ))
        }

        // 1. 解析
        let code: LicenseCode
        do {
            code = try LicenseCode(parsing: input)
        } catch let error as LicenseError {
            return .failure(error.errorDescription ?? "邀请码无效")
        } catch {
            return .failure(error.localizedDescription)
        }

        // 2. 验签——这一步决定邀请码真伪，必须通过
        guard LicenseSigning.verify(code, using: publicKey) else {
            return .failure(LicenseError.invalidSignature.errorDescription ?? "邀请码无效")
        }

        // 3. 落盘
        let credential = Credential(
            code: code.encoded,
            serial: code.payload.serial,
            flags: code.payload.flags.rawValue,
            activatedAt: now
        )
        persist(credential)

        state = .licensed(serial: code.payload.serial, flags: code.payload.flags)
        activatedCode = code.encoded

        // 4. 在线登记（尽力而为，失败不影响放行）
        await register(code: code)

        return .success(serial: code.payload.serial, flags: code.payload.flags)
    }

    /// 解除激活（供用户换机或排障使用，会退回试用/到期状态）
    func deactivate(now: Date = Date()) {
        defaults.removeObject(forKey: LicenseManager.credentialKey)
        activatedCode = nil
        let remaining = TrialAnchor.remainingDays(of: anchor, now: now)
        if LicenseManager.resolvedPublicKey() == nil {
            state = .unconfigured
        } else {
            state = remaining > 0 ? .trial(remainingDays: remaining) : .expired
        }
    }

    // MARK: - 凭证持久化

    /// 落盘的激活凭证。
    ///
    /// 只存邀请码原文与冗余的元信息——验证时仍会重新验签，
    /// 因此即使用户改写这个文件，也必须拥有私钥才能构造出有效签名。
    private struct Credential: Codable {
        let code: String
        let serial: UInt32
        let flags: UInt8
        let activatedAt: Date
    }

    private func persist(_ credential: Credential) {
        guard let data = try? JSONEncoder().encode(credential) else { return }
        defaults.set(data, forKey: LicenseManager.credentialKey)
    }

    /// 恢复凭证并**重新验签**。
    ///
    /// 关键：不信任落盘内容。即使用户手工写入一条伪造凭证，
    /// 缺少私钥就无法产生有效签名，验签会失败并被丢弃。
    private static func restoreCredential(
        defaults: UserDefaults
    ) -> (code: String, serial: UInt32, flags: LicenseFlags)? {
        guard let publicKey = LicenseManager.resolvedPublicKey(),
              let data = defaults.data(forKey: credentialKey),
              let credential = try? JSONDecoder().decode(Credential.self, from: data),
              let code = try? LicenseCode(parsing: credential.code),
              LicenseSigning.verify(code, using: publicKey) else {
            return nil
        }
        return (code.encoded, code.payload.serial, code.payload.flags)
    }

    // MARK: - 在线登记

    /// 向登记端点上报一次激活。
    ///
    /// 刻意不重试、不阻塞、不因失败改变授权状态。
    /// 上报内容不含任何个人身份信息，仅邀请码序列号与版本号。
    private func register(code: LicenseCode) async {
        guard let endpoint = LicenseManager.registrationEndpoint else { return }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8

        let body: [String: Any] = [
            "serial": code.payload.serial,
            "shortId": code.payload.shortIdentifier,
            "flags": code.payload.flags.rawValue,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "platform": "macos",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // 失败静默处理——登记是增量信息，不是放行前提
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - 展示辅助

    /// 状态摘要文案
    var statusSummary: String {
        switch state {
        case .licensed(let serial, let flags):
            let suffix = flags.contains(.earlySupporter)
                ? LicenseError.text("（早期支持者）", " (Early Supporter)")
                : ""
            return LicenseError.text(
                "已激活 · 永久授权\(suffix) · 编号 \(String(format: "XN-%06u", serial))",
                "Activated · Perpetual license\(suffix) · ID \(String(format: "XN-%06u", serial))"
            )
        case .trial(let days):
            return LicenseError.text(
                "试用中 · 剩余 \(days) 天",
                "Trial · \(days) day\(days == 1 ? "" : "s") remaining"
            )
        case .expired:
            return LicenseError.text(
                "试用已结束 · 请输入邀请码激活",
                "Trial ended · Enter an activation code to continue"
            )
        case .unconfigured:
            return LicenseError.text(
                "未配置授权公钥（开发版本）",
                "No license public key configured (development build)"
            )
        }
    }
}
