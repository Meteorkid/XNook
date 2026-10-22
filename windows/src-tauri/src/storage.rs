use std::{fs::{self, File, OpenOptions}, io::{Read, Write}, path::{Path, PathBuf}, sync::Mutex};

pub const MAX_STORE_BYTES: usize = 16 * 1024 * 1024;

pub struct Store {
    path: PathBuf,
    lock: Mutex<()>,
}

impl Store {
    pub fn new(path: PathBuf) -> Self { Self { path, lock: Mutex::new(()) } }

    pub fn read(&self) -> Result<Option<String>, String> {
        let _guard = self.lock.lock().map_err(|_| "存储锁不可用，请重启应用")?;
        read_store(&self.path)
    }

    pub fn write(&self, content: &str) -> Result<(), String> {
        validate_store(content)?;
        let _guard = self.lock.lock().map_err(|_| "存储锁不可用，请重启应用")?;
        // 前端的保存保护不能代替原生检查：读取失败或损坏的原件必须保留。
        read_store(&self.path)?;
        atomic_write(&self.path, content.as_bytes()).map_err(|error| format!("保存失败，原文件已保留：{error}"))
    }

    pub fn recover(&self, content: &str) -> Result<String, String> {
        validate_store(content)?;
        let value: serde_json::Value = serde_json::from_str(content).map_err(|error| error.to_string())?;
        if ["notes","files","calendars","history"].iter().any(|key| !value[*key].as_array().is_some_and(Vec::is_empty)) || !value["activeSession"].is_null()
            || value.get("remindedEvents").is_some_and(|items| !items.as_array().is_some_and(Vec::is_empty)) { return Err("恢复只能写入合法的空存储".into()); }
        let _guard = self.lock.lock().map_err(|_| "存储锁不可用")?;
        let mut original = File::open(&self.path).map_err(|error| format!("无法备份原文件，未恢复：{error}"))?;
        let before = original.metadata().map_err(|error| error.to_string())?;
        if !before.is_file() { return Err("原存储不是普通文件，已停止恢复".into()); }
        let parent = self.path.parent().ok_or("存储目录无效")?;
        let backup = parent.join(format!("store-backup-{}.json", uuid::Uuid::new_v4()));
        let mut destination = OpenOptions::new().create_new(true).write(true).open(&backup).map_err(|error| error.to_string())?;
        let copied = std::io::copy(&mut original, &mut destination).map_err(|error| format!("备份失败，未恢复：{error}"))?;
        destination.sync_all().map_err(|error| format!("备份未写入磁盘，未恢复：{error}"))?;
        let after = original.metadata().map_err(|error| error.to_string())?;
        let current = fs::metadata(&self.path).map_err(|error|error.to_string())?;
        if copied != before.len() || after.len() != before.len() || after.modified().ok() != before.modified().ok()
            || current.len() != before.len() || current.modified().ok() != before.modified().ok() { return Err("备份期间原文件发生变化，已停止恢复，请重试".into()); }
        atomic_write(&self.path, content.as_bytes()).map_err(|error| format!("空存储写入失败，备份位于 {}：{error}", backup.display()))?;
        Ok(backup.to_string_lossy().into_owned())
    }
}

pub fn validate_store(content: &str) -> Result<(), String> {
    if content.len() > MAX_STORE_BYTES { return Err("数据超过 16 MiB 上限".into()); }
    let value: serde_json::Value = serde_json::from_str(content).map_err(|error| format!("存储数据损坏：{error}"))?;
    if !validate_schema(&value) { return Err("存储格式不兼容或损坏，已阻止覆盖原件".into()); }
    Ok(())
}

fn validate_schema(value: &serde_json::Value) -> bool {
    use serde_json::Value;
    fn fields(value: &Value, names: &[&str]) -> bool { value.is_object() && names.iter().all(|name| value[*name].is_string()) }
    fn date(value: &Value) -> bool { value.as_str().is_some_and(|date| time::OffsetDateTime::parse(date, &time::format_description::well_known::Rfc3339).is_ok()) }
    fn file(value: &Value) -> bool { fields(value, &["id","path","name"]) && !value["path"].as_str().unwrap_or_default().is_empty() && value["isDirectory"].is_boolean() && date(&value["addedAt"]) }
    fn list(value: &Value, limit: usize, check: impl Fn(&Value) -> bool) -> bool { value.as_array().is_some_and(|items| items.len() <= limit && items.iter().all(check)) }
    fn session(value: &Value, ended: bool) -> bool {
        fields(value, &["id","title"]) && date(&value["startedAt"]) && (if ended { date(&value["endedAt"]) } else { value.get("endedAt") == Some(&Value::Null) })
            && value.get("scheduledEndAt").is_some_and(|date_value| date_value.is_null() || date(date_value))
            && value.get("eventId").is_some_and(|id| id.is_null() || id.is_string())
            && value.get("linkedNote").is_some_and(|note| note.is_null() || fields(note, &["id","title","content"]))
            && list(&value["linkedFiles"], 10000, file)
    }
    value.is_object() && value["version"].as_u64() == Some(1)
        && list(&value["notes"], 10000, |note| fields(note, &["id","title","content"]) && date(&note["createdAt"]) && date(&note["updatedAt"]))
        && list(&value["files"], 10000, file)
        && list(&value["calendars"], 100, |calendar| fields(calendar, &["id","path","name","content"]) && date(&calendar["importedAt"]))
        && list(&value["history"], 10000, |item| session(item, true))
        && value.get("activeSession").is_some_and(|active| active.is_null() || session(active, false))
        && crate::preferences::validate(&value["settings"]).is_ok()
        && value.get("remindedEvents").is_none_or(|items| list(items, 5000, |item| item.as_str().is_some_and(|id| crate::media_selection::validate_source_id(id).is_ok())))
        && ["notes","files","calendars","history"].iter().all(|key| {
            let mut ids = std::collections::HashSet::new();
            value[*key].as_array().is_some_and(|items| items.iter().all(|item| item["id"].as_str().is_some_and(|id| ids.insert(id))))
        })
}

fn read_store(path: &Path) -> Result<Option<String>, String> {
    match read_bounded(path, MAX_STORE_BYTES) {
        Ok(bytes) => {
            let text = String::from_utf8(bytes).map_err(|_| "存储文件不是 UTF-8，已保留原件")?;
            validate_store(&text)?;
            Ok(Some(text))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!("无法读取存储文件，已保留原件：{error}")),
    }
}

pub fn read_bounded(path: &Path, maximum: usize) -> std::io::Result<Vec<u8>> {
    let file = File::open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() { return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "只能读取普通文件")); }
    if metadata.len() > maximum as u64 { return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "文件超过大小上限")); }
    let mut bytes = Vec::with_capacity((metadata.len() as usize).min(maximum));
    // 读取过程中外部进程仍可能增大文件，因此不能只信任 metadata 的大小。
    file.take(maximum as u64 + 1).read_to_end(&mut bytes)?;
    if bytes.len() > maximum { return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "文件超过大小上限")); }
    Ok(bytes)
}

pub fn atomic_write(path: &Path, content: &[u8]) -> std::io::Result<()> {
    let parent = path.parent().ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidInput, "目标没有父目录"))?;
    fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(".xnook-{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut file = OpenOptions::new().create_new(true).write(true).open(&temporary)?;
        file.write_all(content)?;
        file.sync_all()?;
        drop(file);
        replace_file(&temporary, path)?;
        #[cfg(unix)]
        { File::open(parent)?.sync_all()?; }
        Ok(())
    })();
    if result.is_err() { let _ = fs::remove_file(&temporary); }
    result
}

#[cfg(not(windows))]
fn replace_file(source: &Path, destination: &Path) -> std::io::Result<()> { fs::rename(source, destination) }

#[cfg(windows)]
fn replace_file(source: &Path, destination: &Path) -> std::io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH};
    let source: Vec<u16> = source.as_os_str().encode_wide().chain(Some(0)).collect();
    let destination: Vec<u16> = destination.as_os_str().encode_wide().chain(Some(0)).collect();
    if unsafe { MoveFileExW(source.as_ptr(), destination.as_ptr(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) } == 0 {
        Err(std::io::Error::last_os_error())
    } else { Ok(()) }
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Scratch(PathBuf);
    impl Scratch {
        fn new() -> Self { let path = std::env::temp_dir().join(format!("xnook-store-test-{}", uuid::Uuid::new_v4())); fs::create_dir(&path).unwrap(); Self(path) }
    }
    impl Drop for Scratch { fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); } }
    fn empty() -> String { r#"{"version":1,"notes":[],"files":[],"calendars":[],"history":[],"activeSession":null,"settings":{"followPointer":true,"hideInFullscreen":false,"lyricsEnabled":true}}"#.into() }
    #[test] fn reminder_ledger_accepts_full_calendar_batch_and_rejects_overflow() {
        let mut value: serde_json::Value = serde_json::from_str(&empty()).unwrap();
        value["remindedEvents"] = serde_json::json!((0..5000).map(|i| format!("event-{i}@123")).collect::<Vec<_>>());
        assert!(validate_store(&value.to_string()).is_ok());
        value["remindedEvents"].as_array_mut().unwrap().push("extra@123".into());
        assert!(validate_store(&value.to_string()).is_err());
    }
    #[test] fn recovery_copies_corrupted_original_before_empty_store_and_rejects_nonempty() {
        let root = Scratch::new(); let path = root.0.join("store.json"); fs::write(&path, [0xff,0,1]).unwrap();
        let store = Store::new(path.clone()); let backup = store.recover(&empty()).unwrap();
        assert_eq!(fs::read(&backup).unwrap(), vec![0xff,0,1]); assert_eq!(store.read().unwrap().unwrap(), empty());
        let mut value: serde_json::Value = serde_json::from_str(&empty()).unwrap(); value["remindedEvents"] = serde_json::json!(["event"]);
        assert!(store.recover(&value.to_string()).is_err()); assert_eq!(store.read().unwrap().unwrap(), empty());
    }

    #[test]
    fn missing_store_is_empty_and_successful_replacement_is_exact() {
        let root = Scratch::new(); let store = Store::new(root.0.join("store.json"));
        assert_eq!(store.read().unwrap(), None);
        store.write(&empty()).unwrap();
        let mut second: serde_json::Value = serde_json::from_str(&empty()).unwrap(); second["settings"]["lyricsEnabled"] = false.into();
        let second = second.to_string(); store.write(&second).unwrap();
        assert_eq!(store.read().unwrap().unwrap(), second);
        assert_eq!(fs::read_dir(&root.0).unwrap().count(), 1);
    }
    #[test]
    fn corrupted_original_is_never_replaced_even_without_read_call() {
        let root = Scratch::new(); let path = root.0.join("store.json"); fs::write(&path, "broken").unwrap();
        let store = Store::new(path.clone()); assert!(store.write(&empty()).is_err());
        assert_eq!(fs::read_to_string(&path).unwrap(), "broken"); assert!(store.read().is_err());
    }
    #[test]
    fn invalid_and_oversized_input_preserve_previous_content() {
        let root = Scratch::new(); let path = root.0.join("store.json"); let store = Store::new(path);
        store.write(&empty()).unwrap(); assert!(store.write("[").is_err()); assert!(store.write("[]").is_err());
        assert!(store.write(&" ".repeat(MAX_STORE_BYTES + 1)).is_err()); assert_eq!(store.read().unwrap().unwrap(), empty());
    }
    #[test]
    fn incompatible_version_and_semantically_broken_original_remain_untouched() {
        let root = Scratch::new(); let path = root.0.join("store.json");
        let mut broken: serde_json::Value = serde_json::from_str(&empty()).unwrap();
        for mutation in [serde_json::json!({"version":2}), serde_json::json!({"notes":[{"id":"n"}]}), serde_json::json!({"activeSession":{}})] {
            let before = broken.clone();
            for (key, value) in mutation.as_object().unwrap() { broken[key] = value.clone(); }
            let text = broken.to_string(); fs::write(&path, &text).unwrap();
            let store = Store::new(path.clone()); assert!(store.write(&empty()).is_err()); assert_eq!(fs::read_to_string(&path).unwrap(), text);
            broken = before;
        }
    }
    #[test]
    fn replace_failure_preserves_destination_and_removes_temporary() {
        let root = Scratch::new(); let destination = root.0.join("blocked"); fs::create_dir(&destination).unwrap();
        fs::write(destination.join("keep"), "original").unwrap();
        assert!(atomic_write(&destination, b"new").is_err());
        assert_eq!(fs::read_to_string(destination.join("keep")).unwrap(), "original");
        assert_eq!(fs::read_dir(&root.0).unwrap().count(), 1);
    }
    #[test]
    fn read_limits_are_enforced_before_allocation() {
        let root = Scratch::new(); let path = root.0.join("large"); let file = File::create(&path).unwrap(); file.set_len(1024 * 1024).unwrap();
        assert!(read_bounded(&path, 10).is_err()); assert!(read_bounded(&root.0, 10).is_err());
    }
    #[test]
    fn media_preference_accepts_old_settings_null_and_raw_id() {
        assert!(validate_store(&empty()).is_ok());
        let mut value: serde_json::Value = serde_json::from_str(&empty()).unwrap();
        for preference in [serde_json::Value::Null, serde_json::Value::String("QQMusic.exe".into()), serde_json::Value::String("x".repeat(4096))] {
            value["settings"]["preferredMediaSourceId"] = preference;
            assert!(validate_store(&value.to_string()).is_ok());
        }
    }
    #[test]
    fn invalid_media_preference_preserves_original_and_rejects_new_data() {
        let root = Scratch::new(); let path = root.0.join("store.json");
        let mut value: serde_json::Value = serde_json::from_str(&empty()).unwrap();
        for preference in [serde_json::json!(false), serde_json::json!(7), serde_json::json!([]), serde_json::json!({}), serde_json::json!(""), serde_json::json!("  "), serde_json::json!("a\0b"), serde_json::json!("x".repeat(4097))] {
            value["settings"]["preferredMediaSourceId"] = preference; let invalid = value.to_string();
            assert!(validate_store(&invalid).is_err());
            fs::write(&path, &invalid).unwrap(); let store = Store::new(path.clone());
            assert!(store.write(&empty()).is_err()); assert_eq!(fs::read_to_string(&path).unwrap(), invalid);
        }
    }
}
