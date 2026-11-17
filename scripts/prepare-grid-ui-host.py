#!/usr/bin/env python3
"""仅准备隔离 XCTest App 壳；不构建、不启动测试、不注册全局服务。"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone


BUNDLE_ID = "dev.xnook.tests.grid-editor"
APP_NAME = "XNook Grid Test.app"
TEST_FILTER = "XNookTests.PanelGridNativeTests/testRunIsolatedLiveGridEditor"


def command(*arguments: str) -> str:
    result = subprocess.run(arguments, check=True, text=True, capture_output=True)
    return result.stdout + result.stderr


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() if sys.version_info >= (3, 11) else hashlib.sha256(stream.read()).hexdigest()


def rpaths(binary: Path) -> list[str]:
    output = command("/usr/bin/otool", "-l", str(binary))
    return list(dict.fromkeys(re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.+) \(offset \d+\)", output)))


def rpath_dependencies(binary: Path) -> list[str]:
    output = command("/usr/bin/otool", "-L", str(binary))
    return list(dict.fromkeys(re.findall(r"^\s+@rpath/(.+?) \(compatibility", output, re.MULTILINE)))


def resolve_rpath(value: str, binary: Path) -> Path | None:
    for token in ("@executable_path", "@loader_path"):
        if value.startswith(token + "/"):
            return (binary.parent / value[len(token) + 1:]).resolve()
    return Path(value) if value.startswith("/") else None


def main() -> None:
    if sys.platform != "darwin":
        raise RuntimeError("此准备脚本只支持 macOS")
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xctest", type=Path, default=Path("/Applications/Xcode.app/Contents/Developer/usr/bin/xctest"))
    parser.add_argument("--test-bundle", type=Path, default=root / ".build/out/Products/Debug/XNookTests.xctest")
    args = parser.parse_args()
    source = args.xctest.resolve(strict=True)
    test_bundle = args.test_bundle.resolve(strict=True)
    with (test_bundle / "Contents/Info.plist").open("rb") as stream:
        test_info = plistlib.load(stream)
    test_binary = (test_bundle / "Contents/MacOS" / test_info["CFBundleExecutable"]).resolve(strict=True)
    evidence = (root / ".build/grid-editor-evidence").resolve()
    if not evidence.is_relative_to(root):
        raise RuntimeError("证据目录必须位于本 worktree 内")
    evidence.mkdir(parents=True, exist_ok=True)
    destination = evidence / APP_NAME
    if destination.is_symlink():
        raise RuntimeError("拒绝替换符号链接形式的测试 App")

    original_hash = sha256(source)
    original_rpaths = rpaths(source)
    source_roots = [resolved for value in original_rpaths if (resolved := resolve_rpath(value, source)) is not None]
    test_roots = [resolved for value in rpaths(test_binary) if (resolved := resolve_rpath(value, test_binary)) is not None]
    dependencies: dict[str, str] = {}
    for dependency in set(rpath_dependencies(source) + rpath_dependencies(test_binary)):
        located = next((base / dependency for base in source_roots + test_roots if (base / dependency).exists()), None)
        if located is None:
            raise RuntimeError(f"找不到测试依赖：@rpath/{dependency}")
        dependencies[dependency] = str(located)
    if "XCTest.framework/Versions/A/XCTest" not in dependencies:
        raise RuntimeError("官方 runner 未包含预期的 XCTest Framework 依赖")
    # runner 没有足够 header padding 扩长全部旧 rpath。仅保留直接依赖的入口，
    # XCTest/SwiftSupport 自身的 @loader_path 会继续定位其内部 PrivateFrameworks。
    required_rpaths = list(dict.fromkeys(
        str(Path(dependencies[dependency]).parents[len(Path(dependency).parts) - 1])
        for dependency in sorted(dependencies)
    ))

    prepared_at = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    backup: Path | None = None
    with tempfile.TemporaryDirectory(prefix="grid-ui-host-", dir=evidence) as temporary:
        staged = Path(temporary) / APP_NAME
        contents = staged / "Contents"
        executable = contents / "MacOS/xctest"
        executable.parent.mkdir(parents=True)
        shutil.copy2(source, executable)
        executable.chmod(0o755)
        info = {
            "CFBundleIdentifier": BUNDLE_ID,
            "CFBundleExecutable": "xctest",
            "CFBundleName": "XNook Grid Test",
            "CFBundleDisplayName": "XNook Grid Test",
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0",
            "CFBundleSupportedPlatforms": ["MacOSX"],
            "LSMinimumSystemVersion": "14.0",
            "LSUIElement": False,
            "NSHighResolutionCapable": True,
            "NSPrincipalClass": "NSApplication",
        }
        with (contents / "Info.plist").open("wb") as stream:
            plistlib.dump(info, stream)
        (contents / "PkgInfo").write_bytes(b"APPL????")
        command("/usr/bin/codesign", "--remove-signature", str(executable))
        install_arguments = ["/usr/bin/xcrun", "install_name_tool"]
        for value in original_rpaths:
            install_arguments.extend(["-delete_rpath", value])
        for value in required_rpaths:
            install_arguments.extend(["-add_rpath", value])
        command(*install_arguments, str(executable))
        command("/usr/bin/codesign", "--force", "--sign", "-", "--identifier", BUNDLE_ID,
                "--timestamp=none", str(staged))
        command("/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(staged))
        signature = command("/usr/bin/codesign", "-d", "--verbose=4", str(staged))
        if f"Identifier={BUNDLE_ID}" not in signature:
            raise RuntimeError("测试 App 签名标识与目标标识不一致")
        prepared_rpaths = rpaths(executable)
        if set(required_rpaths) != set(prepared_rpaths):
            raise RuntimeError("测试 App 的 Xcode 库搜索路径未完整写入")
        if sha256(source) != original_hash:
            raise RuntimeError("官方 xctest 哈希发生变化；停止交付")
        if destination.exists():
            backup = evidence / f"XNook Grid Test.previous-{prepared_at}.app"
            destination.rename(backup)
        staged.rename(destination)

    executable = destination / "Contents/MacOS/xctest"
    launch = ["/usr/bin/env", "XNOOK_GRID_LIVE=1", "XNOOK_GRID_LIVE_SECONDS=600",
              str(executable), "-XCTest", TEST_FILTER, str(test_bundle)]
    report = {
        "preparedAtUTC": prepared_at, "appPath": str(destination), "bundleIdentifier": BUNDLE_ID,
        "sourceExecutable": str(source), "sourceSHA256Before": original_hash,
        "sourceSHA256After": sha256(source), "preparedExecutableSHA256": sha256(executable),
        "testBundle": str(test_bundle), "testBinarySHA256": sha256(test_binary),
        "originalRpaths": original_rpaths, "preparedRpaths": prepared_rpaths,
        "resolvedDependencies": dependencies, "previousAppBackup": str(backup) if backup else None,
        "signatureVerified": True, "runtimeVerified": False, "cuaBindingVerified": False,
        "launchCommand": shlex.join(launch),
    }
    report_path = evidence / "grid-ui-host-preparation.json"
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"已准备并校验：{destination}")
    print(f"准备证据：{report_path}")
    print("未启动测试。清理本任务 live/stop 标记后，可从仓库根目录运行：")
    print(shlex.join(launch))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"准备失败：{error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr, file=sys.stderr)
        raise SystemExit(1) from error
