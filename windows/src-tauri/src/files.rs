use crate::storage::{atomic_write, read_bounded};
use serde::Serialize;
use std::{collections::HashSet, path::{Path, PathBuf}};

pub const MAX_CALENDAR_BYTES: usize = 5 * 1024 * 1024;
pub const MAX_NOTE_BYTES: usize = 8 * 1024 * 1024;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileInfo { pub path: String, pub name: String, pub is_directory: bool }

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileStatus {
    pub path: String,
    pub available: bool,
    pub error: Option<String>,
    pub size_bytes: Option<u64>,
    pub is_directory: Option<bool>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CalendarFile { pub path: String, pub name: String, pub content: String }

pub fn local_path(raw: &str) -> Result<PathBuf, String> {
    if raw.is_empty() || raw.len() > 32768 || raw.contains('\0') || raw.contains('\n') || raw.contains('\r') {
        return Err("文件路径无效".into());
    }
    #[cfg(windows)]
    {
        // 仅支持本地盘符路径。拒绝设备命名空间、网络共享和备用数据流。
        let normal = raw.strip_prefix(r"\\?\").unwrap_or(raw);
        let bytes = normal.as_bytes();
        if bytes.len() < 3 || !bytes[0].is_ascii_alphabetic() || bytes[1] != b':' || !matches!(bytes[2], b'\\' | b'/') || normal[2..].contains(':') {
            return Err("请选择本地磁盘上的文件，不支持网络或设备路径".into());
        }
    }
    let path = Path::new(raw);
    if !path.is_absolute() { return Err("文件路径必须是绝对路径".into()); }
    Ok(path.to_path_buf())
}

pub fn inspect_files(paths: &[String]) -> Result<Vec<FileInfo>, String> {
    if paths.len() > 128 { return Err("每次最多添加 128 个文件".into()); }
    let mut seen = HashSet::new(); let mut result = Vec::new();
    for raw in paths {
        let path = local_path(raw)?.canonicalize().map_err(|error| format!("文件不存在或无法访问：{error}"))?;
        let metadata = path.metadata().map_err(|error| format!("无法读取文件属性：{error}"))?;
        if !metadata.is_file() && !metadata.is_dir() { return Err("仅支持普通文件和文件夹".into()); }
        let path_text = display_path(&path);
        local_path(&path_text)?;
        if !seen.insert(path_text.clone()) { continue; }
        result.push(FileInfo { name: path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_else(|| path_text.clone()), path: path_text, is_directory: metadata.is_dir() });
    }
    Ok(result)
}

pub fn file_statuses(paths: &[String]) -> Result<Vec<FileStatus>, String> {
    if paths.len() > 128 { return Err("每次最多检查 128 个文件".into()); }
    Ok(paths.iter().map(|raw| {
        let metadata = (|| {
            let path = local_path(raw)?.canonicalize().map_err(|error| format!("文件不存在或无法访问：{error}"))?;
            local_path(&display_path(&path))?;
            let metadata = path.metadata().map_err(|error| format!("无法读取文件属性：{error}"))?;
            if !metadata.is_file() && !metadata.is_dir() { return Err("仅支持普通文件和文件夹".into()); }
            Ok::<_, String>(metadata)
        })();
        match metadata {
            Ok(metadata) => FileStatus { path: raw.clone(), available: true, error: None,
                // 文件夹的目录项长度不代表内容总大小；不为状态刷新递归扫描用户文件。
                size_bytes: metadata.is_file().then(|| metadata.len()), is_directory: Some(metadata.is_dir()) },
            Err(error) => FileStatus { path: raw.clone(), available: false, error: Some(error), size_bytes: None, is_directory: None },
        }
    }).collect())
}

fn display_path(path: &Path) -> String {
    let text = path.to_string_lossy().into_owned();
    #[cfg(windows)]
    { text.strip_prefix(r"\\?\").unwrap_or(&text).to_string() }
    #[cfg(not(windows))]
    { text }
}

pub fn read_calendar(raw: &str) -> Result<CalendarFile, String> {
    let info = inspect_files(&[raw.into()])?.pop().ok_or("未选择日历文件")?;
    if info.is_directory || !Path::new(&info.path).extension().is_some_and(|extension| extension.eq_ignore_ascii_case("ics")) {
        return Err("请选择 .ics 日历文件".into());
    }
    let bytes = read_bounded(Path::new(&info.path), MAX_CALENDAR_BYTES).map_err(|error| format!("日历读取失败（上限 5 MiB）：{error}"))?;
    let content = String::from_utf8(bytes).map_err(|_| "日历文件必须使用 UTF-8 编码")?;
    let content = content.trim_start_matches('\u{feff}').to_string();
    if !content.lines().any(|line| line.trim().eq_ignore_ascii_case("BEGIN:VCALENDAR")) || !content.lines().any(|line| line.trim().eq_ignore_ascii_case("END:VCALENDAR")) {
        return Err("文件不包含完整的 VCALENDAR 日历".into());
    }
    Ok(CalendarFile { path: info.path, name: info.name, content })
}

pub fn export_name(title: &str, format: &str) -> Result<String, String> {
    if !matches!(format, "md" | "txt") { return Err("只支持 Markdown 或纯文本导出".into()); }
    let clean: String = title.chars().filter(|c| !c.is_control() && !"<>:\"/\\|?*".contains(*c)).take(80).collect();
    let clean = clean.trim().trim_matches('.');
    let clean = if clean.is_empty() { "XNook-note" } else { clean };
    // Windows 保留设备名不能用作对话框建议文件名。
    let upper = clean.split('.').next().unwrap_or_default().to_ascii_uppercase();
    let reserved = matches!(upper.as_str(), "CON" | "PRN" | "AUX" | "NUL") || ["COM", "LPT"].iter().any(|prefix| upper.strip_prefix(prefix).is_some_and(|suffix| matches!(suffix, "1"|"2"|"3"|"4"|"5"|"6"|"7"|"8"|"9")));
    Ok(format!("{}{clean}.{format}", if reserved { "_" } else { "" }))
}

pub fn export_note(destination: &Path, content: &str) -> Result<(), String> {
    if content.len() > MAX_NOTE_BYTES { return Err("笔记超过 8 MiB 导出上限".into()); }
    local_path(&destination.to_string_lossy())?;
    atomic_write(destination, content.as_bytes()).map_err(|error| format!("笔记导出失败：{error}"))
}

pub fn open_file(raw: &str, reveal: bool) -> Result<(), String> {
    let info = inspect_files(&[raw.into()])?.pop().ok_or("未提供文件路径")?;
    #[cfg(windows)]
    {
        use windows_sys::Win32::UI::{Shell::ShellExecuteW, WindowsAndMessaging::SW_SHOWNORMAL};
        let wide = |text: &str| -> Vec<u16> { text.encode_utf16().chain(Some(0)).collect() };
        let operation = wide("open");
        let target = wide(if reveal { "explorer.exe" } else { &info.path });
        // 参数只交给 explorer；路径已经排除 NUL，双引号不可能出现在 Windows 文件名。
        let parameters = wide(&if reveal { format!("/select,\"{}\"", info.path) } else { String::new() });
        let result = unsafe { ShellExecuteW(std::ptr::null_mut(), operation.as_ptr(), target.as_ptr(), if reveal { parameters.as_ptr() } else { std::ptr::null() }, std::ptr::null(), SW_SHOWNORMAL) };
        if result as isize <= 32 { Err(format!("Windows 无法打开文件（错误 {}）", result as isize)) } else { Ok(()) }
    }
    #[cfg(not(windows))]
    { let _ = (info, reveal); Err("文件打开与定位仅在 Windows 原生客户端提供".into()) }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_urls_relative_paths_and_embedded_nul() {
        for path in ["https://example.com/a", "../secret", "x\0y", "\n"] { assert!(local_path(path).is_err()); }
    }
    #[test]
    fn export_preserves_body_and_cleans_suggested_name() {
        assert_eq!(export_name("../我的:笔记?", "md").unwrap(), "我的笔记.md");
        assert_eq!(export_name("CON", "txt").unwrap(), "_CON.txt");
        assert!(export_name("title", "exe").is_err());
        let root = std::env::temp_dir().join(format!("xnook-files-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap(); let path = root.join("note.md");
        let text = "# 标题\n\n中文\r\n```txt\n原文\n```\n"; export_note(&path, text).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), text);
        let files = inspect_files(&[path.to_string_lossy().into(), path.to_string_lossy().into()]).unwrap(); assert_eq!(files.len(), 1);
        let calendar = root.join("日历.ics"); std::fs::write(&calendar, "\u{feff}BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n").unwrap();
        assert!(read_calendar(&calendar.to_string_lossy()).unwrap().content.starts_with("BEGIN:"));
        std::fs::write(&calendar, "BEGIN:VCALENDAR").unwrap(); assert!(read_calendar(&calendar.to_string_lossy()).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn too_many_dropped_files_are_rejected() { assert!(inspect_files(&vec!["/missing".into();129]).is_err()); }
    #[test]
    fn file_statuses_keep_mixed_missing_invalid_and_chinese_paths_independent() {
        let root = std::env::temp_dir().join(format!("xnook-status-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let file = root.join("中文 文件.txt"); std::fs::write(&file, "中文").unwrap();
        let paths = vec![root.join("已移走.txt").to_string_lossy().into_owned(), file.to_string_lossy().into_owned(), "relative".into(), root.to_string_lossy().into_owned()];
        let statuses = file_statuses(&paths).unwrap();
        assert_eq!(statuses.len(), paths.len());
        for (status, path) in statuses.iter().zip(&paths) { assert_eq!(&status.path, path); }
        assert!(!statuses[0].available); assert!(statuses[0].error.is_some());
        assert!(statuses[1].available); assert_eq!(statuses[1].size_bytes, Some(6)); assert_eq!(statuses[1].is_directory, Some(false));
        assert!(!statuses[2].available); assert!(statuses[2].error.is_some());
        assert!(statuses[3].available); assert_eq!(statuses[3].size_bytes, None); assert_eq!(statuses[3].is_directory, Some(true));
        let encoded = serde_json::to_value(&statuses[1]).unwrap();
        assert_eq!(encoded["sizeBytes"], 6); assert_eq!(encoded["isDirectory"], false);
        std::fs::remove_dir_all(&root).unwrap();
        let disconnected = file_statuses(&paths).unwrap();
        assert!(disconnected.iter().all(|status| !status.available && status.size_bytes.is_none() && status.is_directory.is_none()));
    }
    #[test]
    fn status_checks_are_read_only_and_preserve_duplicate_references() {
        let root = std::env::temp_dir().join(format!("xnook-status-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let file = root.join("original.txt"); std::fs::write(&file, "untouched").unwrap();
        let path = file.to_string_lossy().into_owned();
        let statuses = file_statuses(&[path.clone(), path]).unwrap();
        assert_eq!(statuses.len(), 2); assert!(statuses.iter().all(|status| status.available));
        assert_eq!(std::fs::read_to_string(&file).unwrap(), "untouched");
        assert!(file_statuses(&[]).unwrap().is_empty());
        assert!(file_statuses(&vec![String::new(); 129]).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }
}
