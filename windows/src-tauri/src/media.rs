use serde::Serialize;
use crate::media_selection::{player_identity, validate_source_id, validate_session_token, MediaSource, PlayerKind};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};
#[cfg(any(windows, test))]
use std::time::Duration;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaSnapshot {
    pub available: bool,
    pub source_id: String,
    pub session_token: Option<String>,
    pub player_name: String,
    pub player_kind: PlayerKind,
    pub sources: Vec<MediaSource>,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub playing: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub playback_rate: Option<f64>,
    pub position: Option<f64>,
    pub duration: Option<f64>,
    pub artwork: Option<String>,
    pub can_play_pause: bool,
    pub can_next: bool,
    pub can_previous: bool,
    pub can_seek: bool,
    pub sampled_at: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl MediaSnapshot {
    fn unavailable(source_id: Option<&str>, sources: Vec<MediaSource>, error: Option<String>) -> Self {
        let source_id = source_id.unwrap_or_default();
        let (player_kind, player_name) = player_identity(source_id);
        Self { available: false, source_id: source_id.into(), session_token: None, player_name, player_kind, sources, title: String::new(), artist: String::new(), album: String::new(), playing: false, playback_rate: None, position: None, duration: None, artwork: None, can_play_pause: false, can_next: false, can_previous: false, can_seek: false, sampled_at: now_millis(), error }
    }
}

#[derive(Default)]
struct SnapshotCache { value: Mutex<Option<(Option<String>, MediaSnapshot)>> }

impl SnapshotCache {
    fn remember(&self, preferred: Option<&str>, snapshot: &MediaSnapshot) {
        if let Ok(mut cached) = self.value.lock() { *cached = Some((preferred.map(str::to_owned), snapshot.clone())); }
    }

    #[cfg(any(windows, test))]
    fn temporary_error(&self, preferred: Option<&str>, selected: Option<&str>, sources: Option<Vec<MediaSource>>, error: String) -> MediaSnapshot {
        let cached = self.value.lock().ok().and_then(|value| value.clone());
        let known_sources = sources.unwrap_or_else(|| cached.as_ref().map(|(_, value)| value.sources.clone()).unwrap_or_default());
        let mut snapshot = match cached {
            Some((key, value)) if key.as_deref() == preferred && selected.is_none_or(|id| value.source_id == id) => value,
            _ => MediaSnapshot::unavailable(selected.or(preferred), Vec::new(), None),
        };
        snapshot.sources = known_sources;
        snapshot.error = Some(error);
        // 保留原采样时间及可见来源，短暂故障不伪装成播放器退出，也不允许使用过期控制状态。
        snapshot.can_play_pause = false; snapshot.can_next = false; snapshot.can_previous = false; snapshot.can_seek = false;
        snapshot
    }
}

pub fn now_millis() -> u64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis().min(u64::MAX as u128) as u64 }

pub struct MediaService {
    cache: SnapshotCache,
    #[cfg(windows)]
    state: tokio::sync::Mutex<windows_media::MediaState>,
}

impl Default for MediaService {
    fn default() -> Self { Self { cache: SnapshotCache::default(), #[cfg(windows)] state: tokio::sync::Mutex::new(windows_media::MediaState::default()) } }
}

impl MediaService {
    pub async fn open_player(&self, source_id: &str, session_token: &str) -> Result<(), String> {
        validate_source_id(source_id)?; validate_session_token(session_token)?;
        #[cfg(windows)]
        {
            let mut state = self.state.try_lock().map_err(|_| "媒体正在处理另一项请求，请稍后重试")?;
            deadline(state.open_player(source_id, session_token), Duration::from_secs(4)).await
        }
        #[cfg(not(windows))]
        { Err("播放器激活仅在 Windows 客户端提供".into()) }
    }
    pub async fn snapshot(&self, preferred: Option<&str>) -> MediaSnapshot {
        if preferred.is_some_and(|id| validate_source_id(id).is_err()) { return MediaSnapshot::unavailable(None, Vec::new(), Some("播放器来源标识无效".into())); }
        #[cfg(windows)]
        {
            let Ok(mut state) = self.state.try_lock() else { return self.cache.temporary_error(preferred, None, None, "媒体请求正在处理，请稍候".into()); };
            match deadline(state.snapshot(preferred), Duration::from_secs(5)).await {
                Ok(snapshot) => { self.cache.remember(preferred, &snapshot); snapshot }
                Err(error) => self.cache.temporary_error(preferred, preferred.or(state.selected_source.as_deref()), Some(state.sources.clone()), error),
            }
        }
        #[cfg(not(windows))]
        {
            let snapshot = MediaSnapshot::unavailable(preferred, Vec::new(), Some("系统媒体仅在 Windows 原生客户端可用".into()));
            self.cache.remember(preferred, &snapshot); snapshot
        }
    }

    pub async fn control(&self, source_id: &str, session_token: &str, action: &str, position: Option<f64>) -> Result<(), String> {
        validate_source_id(source_id)?;
        validate_session_token(session_token)?;
        validate_action(action, position)?;
        #[cfg(windows)]
        {
            let mut state = self.state.try_lock().map_err(|_| "媒体正在处理另一项请求，请稍后重试")?;
            deadline(state.control(source_id, session_token, action, position), Duration::from_secs(4)).await
        }
        #[cfg(not(windows))]
        { Err("媒体控制仅在 Windows 原生客户端可用".into()) }
    }
}

fn validate_action(action: &str, position: Option<f64>) -> Result<(), String> {
    if !matches!(action, "toggle" | "next" | "previous" | "seek") { return Err("未知媒体控制操作".into()); }
    if action == "seek" && !position.is_some_and(|value| value.is_finite() && (0.0..=604800.0).contains(&value)) { return Err("播放位置无效".into()); }
    Ok(())
}

#[cfg(any(windows, test))]
async fn deadline<T>(operation: impl std::future::Future<Output = Result<T, String>>, duration: Duration) -> Result<T, String> {
    tokio::time::timeout(duration, operation).await.map_err(|_| "系统媒体响应超时，请重试".to_string())?
}

fn normalize_playback_rate(rate: Option<f64>) -> f64 {
    rate.filter(|rate| rate.is_finite() && (0.0..=16.0).contains(rate)).unwrap_or(1.0)
}

/// GSMTC position 是 LastUpdatedTime 时的采样值，换算后才能交给前端继续插值。
pub fn timeline_position(start_ticks: i64, end_ticks: i64, position_ticks: i64, updated_unix_ms: i64, sampled_at: u64, playing: bool, rate: f64) -> (Option<f64>, Option<f64>) {
    let Some(length) = end_ticks.checked_sub(start_ticks).filter(|value| *value > 0) else { return (None, None); };
    let duration = length as f64 / 10_000_000.0;
    if duration > 604800.0 { return (None, None); }
    let Some(offset) = position_ticks.checked_sub(start_ticks) else { return (None, Some(duration)); };
    let elapsed = if playing && updated_unix_ms > 0 {
        (sampled_at as i128 - updated_unix_ms as i128).max(0) as f64 / 1000.0 * normalize_playback_rate(Some(rate))
    } else { 0.0 };
    (Some((offset as f64 / 10_000_000.0 + elapsed).clamp(0.0, duration)), Some(duration))
}

#[cfg(windows)]
mod windows_media {
    use super::*;
    use crate::media_selection::{group_sources, select_session, select_source, ControlBinding, SessionDescriptor};
    use base64::{Engine as _, engine::general_purpose::STANDARD};
    use windows::{Media::Control::{GlobalSystemMediaTransportControlsSession as Session, GlobalSystemMediaTransportControlsSessionManager as Manager, GlobalSystemMediaTransportControlsSessionPlaybackStatus as Status}, Storage::Streams::DataReader};

    const MAX_ARTWORK_BYTES: u64 = 2 * 1024 * 1024;

    // 外层超时或窗口退出丢弃 future 时，也取消 WinRT 操作，避免后台请求累积。
    struct CancelOnDrop<F: Fn()>(F);
    impl<F: Fn()> Drop for CancelOnDrop<F> { fn drop(&mut self) { (self.0)(); } }

    #[derive(Default)]
    pub struct MediaState {
        manager: Option<Manager>,
        artwork_key: String,
        artwork: Option<String>,
        artwork_checked_at: u64,
        pub sources: Vec<MediaSource>,
        pub selected_source: Option<String>,
        previous_auto_source: Option<String>,
        control_binding: Option<ControlBinding<Session>>,
    }

    struct SessionEntry { descriptor: SessionDescriptor, session: Session }

    fn message(error: windows::core::Error) -> String { format!("Windows 媒体服务：{error}") }

    impl MediaState {
        pub async fn open_player(&mut self, source_id: &str, session_token: &str) -> Result<(), String> {
            self.bound_session(source_id, session_token).await?;
            crate::platform::win::activate_player(source_id)
        }
        async fn manager(&mut self) -> Result<Manager, String> {
            if let Some(manager) = &self.manager { return Ok(manager.clone()); }
            let operation = Manager::RequestAsync().map_err(message)?;
            let _cancel = CancelOnDrop(|| { let _ = operation.Cancel(); });
            let result = tokio::time::timeout(Duration::from_secs(3), operation.clone()).await;
            let manager = match result {
                Ok(result) => result.map_err(message)?,
                Err(_) => { let _ = operation.Cancel(); return Err("请求 Windows 媒体服务超时".into()); }
            };
            self.manager = Some(manager.clone()); Ok(manager)
        }

        async fn enumerate(&mut self) -> Result<(Vec<SessionEntry>, Option<String>), String> {
            let manager = self.manager().await?;
            let mut unreadable = 0;
            let current = match manager.GetCurrentSession() {
                Ok(session) => Some(session),
                Err(error) if error.code() == windows::core::HRESULT(0x80004003_u32 as i32) => None,
                Err(_) => { unreadable += 1; None }
            };
            let sessions = match manager.GetSessions() {
                Ok(sessions) => sessions,
                Err(error) => { self.manager = None; return Err(message(error)); }
            };
            let size = sessions.Size().map_err(message)?;
            if size > 256 { return Err("系统媒体会话超过 256 个安全上限".into()); }
            let mut entries = Vec::new();
            for index in 0..size {
                // 一项会话失效只跳过该项，不影响其他播放器被发现。
                let session = match sessions.GetAt(index) { Ok(value) => value, Err(_) => { unreadable += 1; continue; } };
                let source_id = match session.SourceAppUserModelId() { Ok(id) => id.to_string(), Err(_) => { unreadable += 1; continue; } };
                if validate_source_id(&source_id).is_err() { unreadable += 1; continue; }
                let playing = match session.GetPlaybackInfo().and_then(|info| info.PlaybackStatus()) {
                    Ok(status) => status == Status::Playing,
                    Err(_) => { unreadable += 1; false }
                };
                let is_system_current = current.as_ref().is_some_and(|current| current == &session);
                entries.push(SessionEntry { descriptor: SessionDescriptor { source_id, playing, is_system_current }, session });
            }
            let warning = (unreadable > 0).then(|| format!("有 {unreadable} 项系统媒体信息暂时无法读取，其他播放器仍可使用"));
            Ok((entries, warning))
        }

        pub async fn snapshot(&mut self, preferred: Option<&str>) -> Result<MediaSnapshot, String> {
            let (entries, mut warning) = self.enumerate().await?;
            let descriptors: Vec<_> = entries.iter().map(|entry| entry.descriptor.clone()).collect();
            let sources = group_sources(&descriptors);
            if sources.is_empty() && warning.is_some() { return Err(warning.unwrap()); }
            let selected = select_source(&sources, preferred, self.previous_auto_source.as_deref()).cloned();
            self.sources = sources.clone();
            self.selected_source = selected.as_ref().map(|source| source.source_id.clone()).or_else(|| preferred.map(str::to_owned));
            let Some(selected) = selected else {
                self.control_binding = None; self.artwork_key.clear(); self.artwork = None;
                if warning.is_some() { return Err(warning.unwrap()); }
                return Ok(MediaSnapshot::unavailable(preferred, sources, preferred.map(|_| "所选播放器未公开媒体会话或已退出；不会切换到其他播放器".into())));
            };
            let index = select_session(&descriptors, &selected.source_id).ok_or("所选播放器会话已变化，请重试")?;
            let session = entries[index].session.clone();
            // 多个同 ID 会话只绑定本次实际读取的对象，控制时不能擅自换到同应用另一标签。
            if self.control_binding.as_ref().is_some_and(|bound| !bound.matches_session(&selected.source_id, &session)) { self.control_binding = None; }
            let operation = session.TryGetMediaPropertiesAsync().map_err(message)?;
            let _cancel = CancelOnDrop(|| { let _ = operation.Cancel(); });
            let properties = match tokio::time::timeout(Duration::from_secs(2), operation.clone()).await {
                Ok(result) => result.map_err(message)?,
                Err(_) => { let _ = operation.Cancel(); return Err("播放器曲目信息响应超时".into()); }
            };
            let source_id = selected.source_id;
            let title = properties.Title().map_err(message)?.to_string();
            let artist = properties.Artist().map_err(message)?.to_string();
            let album = properties.AlbumTitle().map_err(message)?.to_string();
            if [&source_id, &title, &artist, &album].iter().any(|text| text.len() > 16384) { return Err("播放器曲目信息超出长度上限".into()); }
            let playback = session.GetPlaybackInfo().map_err(message)?;
            let controls = playback.Controls().map_err(message)?;
            let playing = playback.PlaybackStatus().map_err(message)? == Status::Playing;
            let key = format!("{source_id}\0{title}\0{artist}\0{album}");
            if key != self.artwork_key || (self.artwork.is_none() && now_millis().saturating_sub(self.artwork_checked_at) >= 15_000) {
                self.artwork = None;
                // 封面失败不阻断文字与播放控制；每首歌只保留一个、最多 2 MiB 的封面。
                match tokio::time::timeout(Duration::from_millis(1200), artwork(&properties)).await {
                    Ok(Ok(value)) => self.artwork = value,
                    Ok(Err(error)) => append_warning(&mut warning, error),
                    Err(_) => append_warning(&mut warning, "封面读取超时".into()),
                }
                self.artwork_key = key;
                self.artwork_checked_at = now_millis();
            }
            let sampled_at = now_millis();
            let playback_rate = Some(normalize_playback_rate(playback.PlaybackRate().and_then(|rate| rate.Value()).ok()));
            let timeline_result = (|| {
                let timeline = session.GetTimelineProperties().map_err(message)?;
                    let start = timeline.StartTime().map_err(message)?.Duration;
                    let end = timeline.EndTime().map_err(message)?.Duration;
                    let position = timeline.Position().map_err(message)?.Duration;
                    let updated = timeline.LastUpdatedTime().map_err(message)?.UniversalTime.saturating_sub(116_444_736_000_000_000) / 10_000;
                    Ok::<_, String>(timeline_position(start, end, position, updated, sampled_at, playing, playback_rate.unwrap_or(1.0)))
            })();
            let (position, duration) = match timeline_result {
                Ok(value) => value,
                Err(error) => { append_warning(&mut warning, error); (None, None) }
            };
            let session_token = Some(ControlBinding::refresh(&mut self.control_binding, &source_id, session));
            if preferred.is_none() { self.previous_auto_source = Some(source_id.clone()); }
            Ok(MediaSnapshot { available: true, source_id, session_token, player_name: selected.name, player_kind: selected.kind, sources, title, artist, album, playing, playback_rate, position, duration, artwork: self.artwork.clone(),
                can_play_pause: controls.IsPlayPauseToggleEnabled().unwrap_or(false) || if playing { controls.IsPauseEnabled().unwrap_or(false) } else { controls.IsPlayEnabled().unwrap_or(false) },
                can_next: controls.IsNextEnabled().unwrap_or(false), can_previous: controls.IsPreviousEnabled().unwrap_or(false),
                can_seek: duration.is_some() && controls.IsPlaybackPositionEnabled().unwrap_or(false), sampled_at, error: warning })
        }

        async fn bound_session(&mut self, source_id: &str, session_token: &str) -> Result<Session, String> {
            let binding = self.control_binding.as_ref().ok_or("请等待所选播放器的信息刷新后再操作")?;
            let bound = binding.session_for_request(source_id, session_token)?.clone();
            let manager = self.manager().await?;
            let sessions = manager.GetSessions().map_err(message)?;
            let size = sessions.Size().map_err(message)?;
            if size > 256 { return Err("系统媒体会话超过安全上限".into()); }
            for index in 0..size {
                let Ok(candidate) = sessions.GetAt(index) else { continue; };
                if candidate != bound { continue; }
                let id = candidate.SourceAppUserModelId().map_err(message)?.to_string();
                if id == source_id { return Ok(candidate); }
            }
            self.control_binding = None;
            Err("所选播放器会话已退出或变化，请等待刷新；未控制其他播放器".into())
        }

        pub async fn control(&mut self, source_id: &str, session_token: &str, action: &str, position: Option<f64>) -> Result<(), String> {
            let session = self.bound_session(source_id, session_token).await?;
            let playback = session.GetPlaybackInfo().map_err(message)?;
            let controls = playback.Controls().map_err(message)?;
            let operation = match action {
                "toggle" if controls.IsPlayPauseToggleEnabled().unwrap_or(false) => session.TryTogglePlayPauseAsync(),
                "toggle" if playback.PlaybackStatus().map_err(message)? == Status::Playing && controls.IsPauseEnabled().unwrap_or(false) => session.TryPauseAsync(),
                "toggle" if playback.PlaybackStatus().map_err(message)? != Status::Playing && controls.IsPlayEnabled().unwrap_or(false) => session.TryPlayAsync(),
                "next" if controls.IsNextEnabled().unwrap_or(false) => session.TrySkipNextAsync(),
                "previous" if controls.IsPreviousEnabled().unwrap_or(false) => session.TrySkipPreviousAsync(),
                "seek" if controls.IsPlaybackPositionEnabled().unwrap_or(false) => {
                    let timeline = session.GetTimelineProperties().map_err(message)?;
                    let start = timeline.StartTime().map_err(message)?.Duration;
                    let end = timeline.EndTime().map_err(message)?.Duration;
                    let offset = (position.ok_or("缺少播放位置")? * 10_000_000.0).round() as i64;
                    let target = start.checked_add(offset).ok_or("播放位置超出范围")?;
                    if end <= start || target > end { return Err("播放位置超过曲目时长".into()); }
                    session.TryChangePlaybackPositionAsync(target)
                }
                _ => return Err("当前播放器不支持此操作".into()),
            }.map_err(message)?;
            let _cancel = CancelOnDrop(|| { let _ = operation.Cancel(); });
            match tokio::time::timeout(Duration::from_secs(3), operation.clone()).await {
                Ok(Ok(true)) => Ok(()),
                Ok(Ok(false)) => Err("播放器拒绝了这次操作".into()),
                Ok(Err(error)) => Err(message(error)),
                Err(_) => { let _ = operation.Cancel(); Err("播放器控制响应超时".into()) }
            }
        }
    }

    fn append_warning(warning: &mut Option<String>, message: String) {
        if let Some(previous) = warning { previous.push_str("；"); previous.push_str(&message); } else { *warning = Some(message); }
    }

    async fn artwork(properties: &windows::Media::Control::GlobalSystemMediaTransportControlsSessionMediaProperties) -> Result<Option<String>, String> {
        let operation = {
            let reference = match properties.Thumbnail() {
                Ok(value) => value,
                Err(error) if error.code() == windows::core::HRESULT(0x80004003_u32 as i32) => return Ok(None),
                Err(error) => return Err(message(error)),
            };
            reference.OpenReadAsync().map_err(message)?
        };
        let _cancel = CancelOnDrop(|| { let _ = operation.Cancel(); });
        // 原始流接口没有 Send；转换为敏捷 DataReader 后，在下一次 await 前释放接口。
        let (size, content_type, reader) = {
            let stream = operation.clone().await.map_err(message)?;
            let size = stream.Size().map_err(message)?;
            if size == 0 { return Ok(None); }
            if size > MAX_ARTWORK_BYTES { return Err("播放器封面超过 2 MiB 上限".into()); }
            let content_type = stream.ContentType().map_err(message)?.to_string();
            if !matches!(content_type.as_str(), "image/png" | "image/jpeg" | "image/webp" | "image/gif" | "image/bmp") { return Err("播放器封面格式不受支持".into()); }
            let reader = DataReader::CreateDataReader(&stream.GetInputStreamAt(0).map_err(message)?).map_err(message)?;
            (size, content_type, reader)
        };
        let operation = reader.LoadAsync(size as u32).map_err(message)?;
        let _cancel = CancelOnDrop(|| { let _ = operation.Cancel(); });
        let loaded = operation.clone().await.map_err(message)?;
        if loaded as u64 != size { return Err("播放器封面未完整读取".into()); }
        let mut bytes = vec![0; size as usize]; reader.ReadBytes(&mut bytes).map_err(message)?;
        Ok(Some(format!("data:{content_type};base64,{}", STANDARD.encode(bytes))))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn timeline_interpolates_playing_but_freezes_paused_and_clamps_seeks() {
        assert_eq!(timeline_position(0, 100_000_000, 20_000_000, 1000, 3000, true, 1.0), (Some(4.0), Some(10.0)));
        assert_eq!(timeline_position(0, 100_000_000, 20_000_000, 1000, 3000, false, 1.0).0, Some(2.0));
        assert_eq!(timeline_position(0, 100_000_000, 90_000_000, 1000, 9000, true, 1.0).0, Some(10.0));
        assert_eq!(timeline_position(0, 0, 0, 1000, 3000, true, 1.0), (None,None));
        assert_eq!(timeline_position(50_000_000, 150_000_000, 70_000_000, 3000, 1000, true, 1.0).0, Some(2.0));
    }
    #[test]
    fn playback_rate_is_preserved_and_invalid_rates_default_to_normal_speed() {
        for (rate, expected) in [(0.5, 3.0), (2.0, 6.0), (0.0, 2.0), (f64::NAN, 4.0), (-1.0, 4.0), (17.0, 4.0)] {
            assert_eq!(timeline_position(0, 100_000_000, 20_000_000, 1000, 3000, true, rate).0, Some(expected));
            assert_eq!(timeline_position(0, 100_000_000, 20_000_000, 1000, 3000, false, rate).0, Some(2.0));
        }
        assert_eq!(normalize_playback_rate(None), 1.0);
        assert_eq!(normalize_playback_rate(Some(f64::INFINITY)), 1.0);
        let mut snapshot = MediaSnapshot::unavailable(None, Vec::new(), None);
        assert!(serde_json::to_value(&snapshot).unwrap().get("playbackRate").is_none());
        snapshot.playback_rate = Some(0.5);
        assert_eq!(serde_json::to_value(&snapshot).unwrap()["playbackRate"], 0.5);
    }
    #[test]
    fn invalid_controls_rejected() {
        assert!(validate_action("seek", Some(f64::INFINITY)).is_err()); assert!(validate_action("seek", None).is_err());
        assert!(validate_action("seek", Some(-1.0)).is_err()); assert!(validate_action("shell", None).is_err());
    }
    #[tokio::test]
    async fn stalled_media_operation_has_bounded_deadline() {
        let result = deadline::<()>(std::future::pending(), Duration::from_millis(5)).await;
        assert!(result.unwrap_err().contains("超时"));
    }
    #[cfg(not(windows))]
    #[tokio::test]
    async fn unsupported_platform_never_fabricates_playback() {
        let service = MediaService::default(); let snapshot = service.snapshot(Some("chosen-player")).await;
        assert!(!snapshot.available); assert!(!snapshot.playing); assert!(snapshot.position.is_none()); assert!(snapshot.error.is_some());
        assert_eq!(snapshot.source_id, "chosen-player"); assert!(snapshot.sources.is_empty()); assert!(snapshot.session_token.is_none());
        let token = uuid::Uuid::new_v4().to_string();
        assert!(service.control("chosen-player", &token, "toggle", None).await.is_err());
        assert!(service.control("", &token, "toggle", None).await.is_err());
        assert!(service.control("chosen-player", "", "toggle", None).await.unwrap_err().contains("令牌"));
    }
    #[test]
    fn transient_error_preserves_sources_and_track_without_refreshing_sample_time() {
        let cache = SnapshotCache::default();
        let sources = vec![MediaSource { source_id: "A".into(), name: "Player A".into(), kind: PlayerKind::Other, playing: true, is_system_current: true }];
        let mut snapshot = MediaSnapshot::unavailable(Some("A"), sources.clone(), None);
        snapshot.available = true; snapshot.title = "Song A".into(); snapshot.sampled_at = 123; snapshot.can_play_pause = true;
        snapshot.session_token = Some(uuid::Uuid::new_v4().to_string());
        cache.remember(None, &snapshot);
        let result = cache.temporary_error(None, None, None, "正在处理".into());
        assert!(result.available); assert_eq!(result.title, "Song A"); assert_eq!(result.sampled_at, 123);
        assert_eq!(result.sources, sources); assert!(!result.can_play_pause); assert!(result.error.is_some());
        assert_eq!(result.session_token, snapshot.session_token);
    }
    #[test]
    fn transient_error_during_source_change_never_returns_old_song_or_controls() {
        let cache = SnapshotCache::default(); let mut snapshot = MediaSnapshot::unavailable(Some("A"), Vec::new(), None);
        snapshot.available = true; snapshot.title = "Song A".into(); cache.remember(Some("A"), &snapshot);
        let result = cache.temporary_error(Some("B"), Some("B"), None, "暂时不可读".into());
        assert!(!result.available); assert_eq!(result.source_id, "B"); assert!(result.title.is_empty()); assert!(!result.can_play_pause); assert!(result.session_token.is_none());
        cache.remember(None, &snapshot);
        let auto_changed = cache.temporary_error(None, Some("B"), None, "暂时不可读".into());
        assert!(!auto_changed.available); assert_eq!(auto_changed.source_id, "B");
    }
}
