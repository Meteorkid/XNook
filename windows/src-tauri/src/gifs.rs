use crate::storage::{atomic_write, read_bounded};
use base64::{engine::general_purpose::STANDARD, Engine as _};
use serde::{Deserialize, Serialize};
use std::{fs, path::{Path, PathBuf}, sync::Mutex};

const MAX_GIF_BYTES: usize = 10 * 1024 * 1024;
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct GifInfo { pub id: String, pub name: String }

pub struct GifLibrary { root: PathBuf, lock: Mutex<()> }
impl GifLibrary {
    pub fn new(data: &Path) -> Self { Self { root: data.join("gifs"), lock: Mutex::new(()) } }
    fn valid_id(id: &str) -> bool { id.len() == 36 && uuid::Uuid::parse_str(id).is_ok() }
    fn is_link(metadata: &fs::Metadata) -> bool {
        #[cfg(windows)]
        { use std::os::windows::fs::MetadataExt; metadata.file_attributes() & 0x400 != 0 }
        #[cfg(not(windows))]
        { metadata.file_type().is_symlink() }
    }
    fn directory(path: &Path) -> Result<(), String> {
        let metadata = fs::symlink_metadata(path).map_err(|error| error.to_string())?;
        if !metadata.is_dir() || Self::is_link(&metadata) { return Err("GIF 目录不是本应用管理的普通目录".into()); }
        Ok(())
    }
    fn root_exists(&self) -> Result<bool, String> {
        match fs::symlink_metadata(&self.root) {
            Ok(_) => { Self::directory(&self.root)?; Ok(true) }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(error) => Err(error.to_string()),
        }
    }
    fn folder(&self, id: &str) -> Result<PathBuf, String> {
        if !Self::valid_id(id) { return Err("GIF 标识无效".into()); }
        self.root_exists()?;
        let path = self.root.join(id); Self::directory(&path)?; Ok(path)
    }
    fn regular(path: &Path) -> Result<(), String> {
        let metadata = fs::symlink_metadata(path).map_err(|error| error.to_string())?;
        if !metadata.is_file() || Self::is_link(&metadata) { return Err("GIF 资源不是本应用管理的普通文件".into()); }
        Ok(())
    }
    fn managed_files(folder: &Path) -> Result<Vec<PathBuf>, String> {
        Self::directory(folder)?;
        let mut files = Vec::new();
        for entry in fs::read_dir(folder).map_err(|error| error.to_string())? {
            let entry = entry.map_err(|error| error.to_string())?;
            if entry.file_name() != "image.gif" && entry.file_name() != "info.json" { return Err("GIF 目录含未知文件，已停止删除并保留原件".into()); }
            Self::regular(&entry.path())?; files.push(entry.path());
        }
        files.sort(); Ok(files)
    }
    fn clean_pending(folder: &Path, remove_file: &impl Fn(&Path) -> std::io::Result<()>) -> Result<(), String> {
        // 先检查完整白名单，再逐项清理；中途中断留下的缺失文件允许下一次继续。
        for path in Self::managed_files(folder)? {
            Self::directory(folder)?; Self::regular(&path)?;
            remove_file(&path).map_err(|error| error.to_string())?;
        }
        fs::remove_dir(folder).map_err(|error| error.to_string())
    }
    fn item_info(&self, id: &str) -> Result<GifInfo, String> {
        let folder = self.folder(id)?; Self::managed_files(&folder)?;
        Self::regular(&folder.join("image.gif"))?; Self::regular(&folder.join("info.json"))?;
        let info: GifInfo = serde_json::from_slice(&read_bounded(&folder.join("info.json"), 8192).map_err(|error| error.to_string())?).map_err(|_| "GIF 元数据损坏")?;
        if info.id != id || info.name.is_empty() || info.name.len() > 1024 { return Err("GIF 元数据无效".into()); }
        Ok(info)
    }
    pub fn list(&self) -> Result<Vec<GifInfo>, String> {
        let _guard = self.lock.lock().map_err(|_| "GIF 库不可用")?;
        if !self.root_exists()? { return Ok(Vec::new()); }
        let mut items = Vec::new();
        let entries: Vec<_> = fs::read_dir(&self.root).map_err(|error| error.to_string())?.collect();
        for entry in entries {
            let entry = match entry {
                Ok(entry) => entry,
                Err(error) => { items.push(GifInfo { id: String::new(), name: format!("GIF 库条目无法读取，已保留：{error}") }); continue; }
            };
            let id = entry.file_name().to_string_lossy().into_owned();
            if let Some(original_id) = id.strip_prefix(".deleting-").filter(|id| Self::valid_id(id)) {
                if let Err(error) = Self::clean_pending(&entry.path(), &|path| fs::remove_file(path)) {
                    // 移动成功后，原 UUID 仍能用于显式重试；冲突条目保留独立诊断。
                    let visible_id = if self.root.join(original_id).symlink_metadata().is_ok() { id.clone() } else { original_id.to_string() };
                    items.push(GifInfo { id: visible_id, name: format!("GIF 已移除，等待清理（{original_id}）：{error}") });
                }
            } else if Self::valid_id(&id) {
                items.push(self.item_info(&id).unwrap_or_else(|error| GifInfo { id: id.clone(), name: format!("损坏的 GIF（{id}）：{error}") }));
            } else {
                items.push(GifInfo { id: id.clone(), name: format!("未知 GIF 库条目（{id}），已保留，请在本地检查") });
            }
        }
        items.sort_by(|a,b|a.name.cmp(&b.name).then(a.id.cmp(&b.id))); Ok(items)
    }
    pub fn import(&self, raw: &str) -> Result<GifInfo, String> {
        let info = crate::files::inspect_files(&[raw.into()])?.pop().ok_or("未选择 GIF")?;
        if info.is_directory || !Path::new(&info.path).extension().is_some_and(|extension| extension.eq_ignore_ascii_case("gif")) { return Err("请选择 GIF 文件".into()); }
        let bytes = read_bounded(Path::new(&info.path), MAX_GIF_BYTES).map_err(|error| format!("GIF 读取失败（上限 10 MiB）：{error}"))?;
        validate_gif(&bytes)?;
        let _guard = self.lock.lock().map_err(|_| "GIF 库不可用")?;
        if !self.root_exists()? { fs::create_dir_all(&self.root).map_err(|error| error.to_string())?; }
        Self::directory(&self.root)?;
        let mut count = 0;
        let entries = fs::read_dir(&self.root).map_err(|error| error.to_string())?.collect::<Result<Vec<_>, _>>().map_err(|error| error.to_string())?;
        for entry in entries {
            let id = entry.file_name().to_string_lossy().into_owned();
            if Self::valid_id(&id) { count += 1; }
            else if id.strip_prefix(".deleting-").is_some_and(Self::valid_id) {
                // 删除已通过原子移动提交；清理失败不占新库条目的容量，列表仍展示诊断。
                let _ = Self::clean_pending(&entry.path(), &|path| fs::remove_file(path));
            }
        }
        if count >= 100 { return Err("最多保存 100 个 GIF，请先移除旧项目".into()); }
        let id = uuid::Uuid::new_v4().to_string(); let item = GifInfo { id: id.clone(), name: info.name };
        let pending = self.root.join(format!(".import-{id}")); fs::create_dir(&pending).map_err(|error| error.to_string())?;
        let result = (|| {
            atomic_write(&pending.join("image.gif"), &bytes).map_err(|error| error.to_string())?;
            atomic_write(&pending.join("info.json"), &serde_json::to_vec(&item).map_err(|error| error.to_string())?).map_err(|error| error.to_string())?;
            fs::rename(&pending, self.root.join(&id)).map_err(|error| error.to_string())?; Ok(item)
        })();
        if result.is_err() { let _ = Self::clean_pending(&pending, &|path| fs::remove_file(path)); } result
    }
    pub fn read(&self, id: &str) -> Result<String, String> {
        let _guard = self.lock.lock().map_err(|_| "GIF 库不可用")?; let path = self.folder(id)?.join("image.gif"); Self::regular(&path)?;
        let bytes = read_bounded(&path, MAX_GIF_BYTES).map_err(|error| error.to_string())?; validate_gif(&bytes)?;
        Ok(format!("data:image/gif;base64,{}", STANDARD.encode(bytes)))
    }
    pub fn delete(&self, id: &str) -> Result<(), String> { self.delete_with(id, |path| fs::remove_file(path)) }
    fn delete_with(&self, id: &str, remove_file: impl Fn(&Path) -> std::io::Result<()>) -> Result<(), String> {
        let _guard = self.lock.lock().map_err(|_| "GIF 库不可用")?;
        if !Self::valid_id(id) { return Err("GIF 标识无效".into()); }
        self.root_exists()?;
        let folder = self.root.join(id); let pending = self.root.join(format!(".deleting-{id}"));
        match fs::symlink_metadata(&folder) {
            Ok(_) => {
                Self::managed_files(&folder)?;
                match fs::symlink_metadata(&pending) {
                    Ok(_) => return Err("存在同标识的待清理 GIF，已停止删除并保留原件".into()),
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
                    Err(error) => return Err(error.to_string()),
                }
                fs::rename(&folder, &pending).map_err(|error| format!("GIF 未移除，原件已保留：{error}"))?;
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                match fs::symlink_metadata(&pending) {
                    Ok(_) => (),
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
                    Err(error) => return Err(error.to_string()),
                }
            }
            Err(error) => return Err(error.to_string()),
        }
        Self::clean_pending(&pending, &remove_file).map_err(|error| format!("GIF 已移入待清理目录，将在后续操作重试：{error}"))
    }
}

fn validate_gif(bytes: &[u8]) -> Result<(), String> {
    if bytes.len() > MAX_GIF_BYTES || bytes.len() < 14 || ![b"GIF87a".as_slice(), b"GIF89a".as_slice()].contains(&&bytes[..6]) { return Err("GIF 格式无效或超过 10 MiB".into()); }
    let mut options = gif::DecodeOptions::new(); options.check_frame_consistency(true); options.check_lzw_end_code(true);
    options.set_memory_limit(gif::MemoryLimit::Bytes(std::num::NonZeroU64::new(16 * 1024 * 1024).unwrap()));
    let mut decoder = options.read_info(bytes).map_err(|error| format!("GIF 损坏：{error}"))?;
    if decoder.width() == 0 || decoder.height() == 0 || decoder.width() > 2048 || decoder.height() > 2048 { return Err("GIF 尺寸须在 1–2048 像素之间".into()); }
    let mut count = 0; let mut pixels = 0u64;
    while let Some(frame) = decoder.read_next_frame().map_err(|error| format!("GIF 帧损坏：{error}"))? {
        count += 1; pixels += frame.width as u64 * frame.height as u64;
        if count > 500 || pixels > 64 * 1024 * 1024 { return Err("GIF 帧数或解码像素量过大".into()); }
    }
    if count == 0 || bytes.last() != Some(&0x3b) { return Err("GIF 缺少完整图像或结束标记".into()); }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Scratch(PathBuf);
    impl Scratch {
        fn new() -> Self { let path = std::env::temp_dir().join(format!("xnook-gifs-test-{}", uuid::Uuid::new_v4())); fs::create_dir(&path).unwrap(); Self(path) }
        fn source(&self) -> PathBuf { let path = self.0.join("original.gif"); fs::write(&path, image()).unwrap(); path }
    }
    impl Drop for Scratch { fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); } }
    fn image() -> Vec<u8> { let mut data = Vec::new(); { let mut encoder = gif::Encoder::new(&mut data, 1, 1, &[0,0,0,255,255,255]).unwrap(); encoder.write_frame(&gif::Frame { width:1,height:1,buffer:std::borrow::Cow::Borrowed(&[0]),..gif::Frame::default() }).unwrap(); } data }
    #[test] fn copied_gif_lifecycle_never_deletes_original() {
        let root = std::env::temp_dir().join(format!("xnook-gifs-{}",uuid::Uuid::new_v4())); fs::create_dir(&root).unwrap(); let source = root.join("original.gif"); fs::write(&source,image()).unwrap();
        let library = GifLibrary::new(&root); let item = library.import(&source.to_string_lossy()).unwrap(); assert_eq!(library.list().unwrap().len(),1); assert!(library.read(&item.id).unwrap().starts_with("data:image/gif;base64,"));
        assert!(library.delete("../original.gif").is_err()); library.delete(&item.id).unwrap(); assert!(source.is_file()); assert!(library.list().unwrap().is_empty()); fs::remove_dir_all(root).unwrap();
    }
    #[test] fn damaged_and_decompression_heavy_images_are_rejected() {
        assert!(validate_gif(b"GIF89a bad").is_err()); let mut truncated = image(); truncated.pop(); assert!(validate_gif(&truncated).is_err());
        let mut huge = image(); huge[6..8].copy_from_slice(&65535u16.to_le_bytes()); assert!(validate_gif(&huge).is_err());
    }
    #[test] fn corrupt_entry_remains_visible_without_blocking_healthy_items_or_import() {
        let root = Scratch::new(); let source = root.source(); let library = GifLibrary::new(&root.0);
        let healthy = library.import(&source.to_string_lossy()).unwrap();
        let broken = library.import(&source.to_string_lossy()).unwrap();
        fs::write(library.root.join(&broken.id).join("info.json"), b"broken").unwrap();
        let items = library.list().unwrap();
        assert_eq!(items.len(), 2); assert!(items.iter().any(|item| item.id == healthy.id && item.name == healthy.name));
        assert!(items.iter().any(|item| item.id == broken.id && item.name.contains("损坏")));
        assert!(library.import(&source.to_string_lossy()).is_ok());
        library.delete(&broken.id).unwrap(); assert!(!library.root.join(&broken.id).exists());
        assert_eq!(fs::read(source).unwrap(), image());
    }
    #[test] fn legacy_partial_deletions_can_be_explicitly_removed() {
        let root = Scratch::new(); let source = root.source(); let library = GifLibrary::new(&root.0);
        for missing in [vec!["image.gif"], vec!["info.json"], vec!["image.gif", "info.json"]] {
            let item = library.import(&source.to_string_lossy()).unwrap(); let folder = library.root.join(&item.id);
            for name in missing { fs::remove_file(folder.join(name)).unwrap(); }
            assert!(library.list().unwrap().iter().any(|value| value.id == item.id && value.name.contains("损坏")));
            library.delete(&item.id).unwrap(); assert!(!folder.exists());
        }
    }
    #[test] fn unknown_files_are_diagnosed_and_preserved() {
        let root = Scratch::new(); let source = root.source(); let library = GifLibrary::new(&root.0);
        let item = library.import(&source.to_string_lossy()).unwrap(); let folder = library.root.join(&item.id);
        fs::write(folder.join("keep.txt"), b"keep").unwrap();
        fs::write(library.root.join("personal.txt"), b"personal").unwrap();
        assert!(library.list().unwrap().iter().any(|value| value.name.contains("未知")));
        assert!(library.delete(&item.id).is_err()); assert!(library.delete("personal.txt").is_err());
        assert_eq!(fs::read(folder.join("keep.txt")).unwrap(), b"keep");
        assert_eq!(fs::read(library.root.join("personal.txt")).unwrap(), b"personal");
        assert!(library.import(&source.to_string_lossy()).is_ok());
    }
    #[test] fn failed_cleanup_commits_move_and_original_id_can_retry_partial_cleanup() {
        let root = Scratch::new(); let source = root.source(); let library = GifLibrary::new(&root.0);
        let item = library.import(&source.to_string_lossy()).unwrap(); let pending = library.root.join(format!(".deleting-{}", item.id));
        let error = library.delete_with(&item.id, |path| {
            assert!(!library.root.join(&item.id).exists()); assert!(pending.is_dir());
            if path.file_name().unwrap() == "info.json" { Err(std::io::Error::new(std::io::ErrorKind::PermissionDenied, "injected cleanup failure")) }
            else { fs::remove_file(path) }
        }).unwrap_err();
        assert!(error.contains("待清理")); assert!(!pending.join("image.gif").exists()); assert!(pending.join("info.json").exists());
        assert_eq!(fs::read(&source).unwrap(), image());
        library.delete(&item.id).unwrap(); assert!(!pending.exists()); assert!(library.list().unwrap().is_empty());
        library.delete(&item.id).unwrap();
    }
    #[test] fn interrupted_deletion_is_recovered_on_restart_and_import() {
        let root = Scratch::new(); let source = root.source(); let library = GifLibrary::new(&root.0);
        for recover_with_import in [false, true] {
            let item = library.import(&source.to_string_lossy()).unwrap(); let pending = library.root.join(format!(".deleting-{}", item.id));
            assert!(library.delete_with(&item.id, |_| Err(std::io::Error::other("interrupted after move"))).is_err());
            assert!(pending.join("image.gif").is_file()); assert!(pending.join("info.json").is_file());
            let restarted = GifLibrary::new(&root.0);
            if recover_with_import { assert!(restarted.import(&source.to_string_lossy()).is_ok()); }
            else { assert!(restarted.list().unwrap().is_empty()); }
            assert!(!pending.exists());
        }
        assert_eq!(fs::read(source).unwrap(), image());
    }
    #[test] fn pending_unknown_files_block_cleanup_but_remain_visible_and_allow_import() {
        let root = Scratch::new(); let source = root.source(); let library = GifLibrary::new(&root.0);
        let item = library.import(&source.to_string_lossy()).unwrap(); let pending = library.root.join(format!(".deleting-{}", item.id));
        assert!(library.delete_with(&item.id, |_| Err(std::io::Error::other("interrupted"))).is_err());
        fs::write(pending.join("keep.txt"), b"private").unwrap();
        let items = GifLibrary::new(&root.0).list().unwrap();
        assert!(items.iter().any(|value| value.id == item.id && value.name.contains("等待清理") && value.name.contains("未知")));
        assert!(library.delete(&item.id).is_err()); assert!(library.import(&source.to_string_lossy()).is_ok());
        assert_eq!(fs::read(pending.join("keep.txt")).unwrap(), b"private");
        assert_eq!(fs::read(pending.join("image.gif")).unwrap(), image()); assert!(pending.join("info.json").is_file());
    }
    #[test] fn unknown_directories_and_malformed_staging_names_are_never_cleaned() {
        let root = Scratch::new(); let source = root.source(); let library = GifLibrary::new(&root.0);
        fs::create_dir(&library.root).unwrap();
        for name in ["personal", ".deleting-not-a-uuid", ".import-not-a-uuid"] {
            let folder = library.root.join(name); fs::create_dir(&folder).unwrap(); fs::write(folder.join("image.gif"), b"private").unwrap();
            assert!(library.delete(name).is_err());
        }
        assert_eq!(library.list().unwrap().len(), 3); assert!(library.import(&source.to_string_lossy()).is_ok());
        for name in ["personal", ".deleting-not-a-uuid", ".import-not-a-uuid"] {
            assert_eq!(fs::read(library.root.join(name).join("image.gif")).unwrap(), b"private");
        }
    }
    #[test] fn corrupt_entries_count_toward_capacity_and_excess_can_still_be_removed() {
        let root = Scratch::new(); let source = root.source(); let library = GifLibrary::new(&root.0); fs::create_dir(&library.root).unwrap();
        let ids: Vec<_> = (0..101).map(|_| uuid::Uuid::new_v4().to_string()).collect();
        for id in &ids { fs::create_dir(library.root.join(id)).unwrap(); }
        assert_eq!(library.list().unwrap().len(), 101); assert!(library.import(&source.to_string_lossy()).unwrap_err().contains("100"));
        library.delete(&ids[0]).unwrap(); assert!(library.import(&source.to_string_lossy()).is_err());
        library.delete(&ids[1]).unwrap(); assert!(library.import(&source.to_string_lossy()).is_ok());
        assert_eq!(library.list().unwrap().len(), 100);
    }
    #[test] fn concurrent_imports_share_the_capacity_guard() {
        let root = Scratch::new(); let source = root.source(); let library = std::sync::Arc::new(GifLibrary::new(&root.0)); fs::create_dir(&library.root).unwrap();
        for _ in 0..99 { fs::create_dir(library.root.join(uuid::Uuid::new_v4().to_string())).unwrap(); }
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
        let threads: Vec<_> = (0..2).map(|_| {
            let library = library.clone(); let barrier = barrier.clone(); let source = source.clone();
            std::thread::spawn(move || { barrier.wait(); library.import(&source.to_string_lossy()) })
        }).collect();
        let succeeded = threads.into_iter().map(|thread| thread.join().unwrap()).filter(Result::is_ok).count();
        assert_eq!(succeeded, 1); assert_eq!(library.list().unwrap().len(), 100);
    }
    #[cfg(unix)]
    #[test] fn symlink_items_resources_and_pending_directories_preserve_targets() {
        use std::os::unix::fs::symlink;
        let root = Scratch::new(); let source = root.source(); let library = GifLibrary::new(&root.0);
        let item = library.import(&source.to_string_lossy()).unwrap(); let folder = library.root.join(&item.id);
        fs::remove_file(folder.join("image.gif")).unwrap(); symlink(&source, folder.join("image.gif")).unwrap();
        assert!(library.read(&item.id).is_err()); assert!(library.delete(&item.id).is_err());
        let outside = root.0.join("outside"); fs::create_dir(&outside).unwrap(); fs::write(outside.join("image.gif"), b"private").unwrap();
        let linked_id = uuid::Uuid::new_v4().to_string(); symlink(&outside, library.root.join(&linked_id)).unwrap();
        let pending_id = uuid::Uuid::new_v4().to_string(); let pending = library.root.join(format!(".deleting-{pending_id}")); symlink(&outside, &pending).unwrap();
        let items = library.list().unwrap(); assert_eq!(items.len(), 3); assert!(items.iter().all(|value| value.name.contains("普通")));
        assert!(library.delete(&linked_id).is_err()); assert!(library.delete(&pending_id).is_err());
        assert!(library.import(&source.to_string_lossy()).is_ok());
        assert!(folder.join("image.gif").symlink_metadata().unwrap().file_type().is_symlink());
        assert!(pending.symlink_metadata().unwrap().file_type().is_symlink());
        assert_eq!(fs::read(source).unwrap(), image()); assert_eq!(fs::read(outside.join("image.gif")).unwrap(), b"private");
    }
    #[cfg(unix)]
    #[test] fn symlink_library_root_is_rejected_before_any_mutation() {
        use std::os::unix::fs::symlink;
        let root = Scratch::new(); let source = root.source(); let library = GifLibrary::new(&root.0);
        let outside = root.0.join("outside"); fs::create_dir(&outside).unwrap(); symlink(&outside, &library.root).unwrap();
        let id = uuid::Uuid::new_v4().to_string(); let folder = outside.join(&id); fs::create_dir(&folder).unwrap(); fs::write(folder.join("image.gif"), b"private").unwrap();
        assert!(library.list().is_err()); assert!(library.read(&id).is_err()); assert!(library.delete(&id).is_err()); assert!(library.import(&source.to_string_lossy()).is_err());
        assert_eq!(fs::read(folder.join("image.gif")).unwrap(), b"private"); assert_eq!(fs::read(source).unwrap(), image());
    }
}
