#!/usr/bin/env python3
"""校验最终签名包的资源能力，防止系统已允许但应用仍无法访问。"""

import plistlib
import subprocess
import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: verify-app-permissions.py <app-bundle>")
    app = Path(sys.argv[1])
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    result = subprocess.run(
        ["codesign", "-d", "--entitlements", ":-", str(app)],
        check=True, capture_output=True,
    )
    entitlements = plistlib.loads(result.stdout)
    missing = []
    for key in ["com.apple.security.personal-information.calendars",
                "com.apple.security.automation.apple-events",
                "com.apple.security.files.bookmarks.app-scope"]:
        if entitlements.get(key) is not True:
            missing.append(key)
    for key in ["NSCalendarsFullAccessUsageDescription", "NSAppleEventsUsageDescription"]:
        value = info.get(key)
        if not isinstance(value, str) or not value.strip():
            missing.append(key)
    if missing:
        raise SystemExit("App permission configuration missing: " + ", ".join(missing))
    print("App permissions verified: calendars, automation and file bookmarks")


if __name__ == "__main__":
    main()
