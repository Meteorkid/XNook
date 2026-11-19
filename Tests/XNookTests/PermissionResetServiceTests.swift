import XCTest
@testable import XNook

/// 重置记录时要清的 TCC 服务清单。
///
/// 屏幕录制在 Sequoia 之后是两条独立记录（ScreenCapture 管画面、AudioCapture 管系统音频），
/// 只清一条会留下半新半旧的组合——表现是字幕能起来但没有声音，很难从界面上看出来。
@MainActor
final class PermissionResetServiceTests: XCTestCase {

    func testScreenRecordingResetsBothScreenAndAudioCapture() {
        XCTAssertEqual(
            PermissionCenter.resetServices(for: .screenRecording),
            ["ScreenCapture", "AudioCapture"],
            "屏幕录制必须成对清理，否则系统音频捕获会继续绑在旧身份上"
        )
    }

    func testOtherKindsResetOnlyTheirOwnService() {
        XCTAssertEqual(PermissionCenter.resetServices(for: .speechRecognition), ["SpeechRecognition"])
        XCTAssertEqual(PermissionCenter.resetServices(for: .calendar), ["Calendar"])
        XCTAssertEqual(PermissionCenter.resetServices(for: .automationMusic), ["AppleEvents"])
        XCTAssertEqual(PermissionCenter.resetServices(for: .automationSpotify), ["AppleEvents"])
    }

    func testKindsWithoutTCCServiceHaveNothingToReset() {
        XCTAssertTrue(PermissionCenter.resetServices(for: .loginItems).isEmpty)
    }
}
