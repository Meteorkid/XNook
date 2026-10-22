# Third-party notices

## ICAL.js 2.2.1

- Source: https://github.com/kewisch/ical.js
- Exact package source: https://registry.npmjs.org/ical.js/-/ical.js-2.2.1.tgz
- License: Mozilla Public License 2.0; the full text is included in `licenses/ICAL.js-LICENSE.txt`.
- XNook uses the library without modifying its source. Calendar integration code is maintained separately in `src/calendar.ts`.

Other frontend and Rust dependency versions and their license metadata are retained in `package-lock.json` and `src-tauri/Cargo.lock`, with upstream package manifests in the corresponding dependency distributions. XNook's own license remains in the repository root.

## Native desktop dependencies added in 0.2.0

- drag 2.1.1: MIT OR Apache-2.0, https://crates.io/crates/drag/2.1.1 — license texts in `licenses/drag-MIT.txt` and `licenses/drag-APACHE.txt`.
- gif 0.13.3: MIT OR Apache-2.0, https://github.com/image-rs/image-gif — license texts in `licenses/gif-MIT.txt` and `licenses/gif-APACHE.txt`.
- winvd 0.0.49: MIT, https://github.com/ciantic/VirtualDesktopAccessor/tree/rust/ — license text in `licenses/winvd-MIT.txt`. Runtime support is limited by this dependency's Windows build requirements and is checked before use.
- unicode-normalization and regex: versions are pinned in Cargo.lock; upstream licenses are included under their names in `licenses/`. Used to keep lyric matching normalization consistent between Rust and TypeScript.
