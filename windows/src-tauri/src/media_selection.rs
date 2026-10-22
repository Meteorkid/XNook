use serde::Serialize;
use std::collections::BTreeMap;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum PlayerKind { Netease, Qqmusic, Other }

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaSource {
    pub source_id: String,
    pub name: String,
    pub kind: PlayerKind,
    pub playing: bool,
    pub is_system_current: bool,
}

#[derive(Clone, Debug)]
pub struct SessionDescriptor {
    pub source_id: String,
    pub playing: bool,
    pub is_system_current: bool,
}

pub struct ControlBinding<T> {
    source_id: String,
    session_token: String,
    session: T,
}

impl<T: PartialEq> ControlBinding<T> {
    pub fn matches_session(&self, source_id: &str, session: &T) -> bool { self.source_id == source_id && &self.session == session }

    pub fn refresh(binding: &mut Option<Self>, source_id: &str, session: T) -> String {
        if !binding.as_ref().is_some_and(|current| current.matches_session(source_id, &session)) {
            *binding = Some(Self { source_id: source_id.into(), session_token: uuid::Uuid::new_v4().to_string(), session });
        }
        binding.as_ref().expect("binding was initialized").session_token.clone()
    }

    pub fn session_for_request(&self, source_id: &str, session_token: &str) -> Result<&T, String> {
        if self.source_id != source_id || self.session_token != session_token {
            return Err("播放器会话已变化，请等待界面刷新后重试；未控制其他会话".into());
        }
        Ok(&self.session)
    }
}

pub fn validate_session_token(token: &str) -> Result<(), String> {
    if token.len() != 36 || uuid::Uuid::parse_str(token).is_err() { return Err("媒体会话令牌无效，请刷新播放器信息".into()); }
    Ok(())
}

pub fn validate_source_id(source_id: &str) -> Result<(), String> {
    if source_id.trim().is_empty() || source_id.contains('\0') || source_id.encode_utf16().count() > 4096 {
        Err("播放器来源标识无效".into())
    } else { Ok(()) }
}

pub fn player_identity(source_id: &str) -> (PlayerKind, String) {
    // 精确标识依据：Lyrix 26.10.1 的 music_player.rs::id2player 实际 GSMTC 映射。
    // https://docs.rs/crate/lyrix/26.10.1/source/src/models/music_player.rs
    // 不推断包家族；文件路径只提取绝对 Windows 路径的完整基名，未知 AUMID 仍可手选。
    let path = source_id.strip_prefix(r"\\?\").unwrap_or(source_id);
    let bytes = path.as_bytes();
    let filename = if bytes.len() >= 3 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' && matches!(bytes[2], b'\\' | b'/') {
        path.rsplit(['\\', '/']).next().unwrap_or(path)
    } else { source_id };
    match filename.to_ascii_lowercase().as_str() {
        "cloudmusic.exe" => (PlayerKind::Netease, "网易云音乐".into()),
        "qqmusic.exe" => (PlayerKind::Qqmusic, "QQ 音乐".into()),
        _ => (PlayerKind::Other, source_id.to_string()),
    }
}

pub fn group_sources(sessions: &[SessionDescriptor]) -> Vec<MediaSource> {
    let mut groups: BTreeMap<String, MediaSource> = BTreeMap::new();
    for session in sessions {
        if validate_source_id(&session.source_id).is_err() { continue; }
        let (kind, name) = player_identity(&session.source_id);
        let group = groups.entry(session.source_id.clone()).or_insert_with(|| MediaSource {
            source_id: session.source_id.clone(), name, kind, playing: false, is_system_current: false,
        });
        group.playing |= session.playing;
        group.is_system_current |= session.is_system_current;
    }
    groups.into_values().collect()
}

pub fn select_source<'a>(sources: &'a [MediaSource], preferred: Option<&str>, previous: Option<&str>) -> Option<&'a MediaSource> {
    if let Some(preferred) = preferred { return sources.iter().find(|source| source.source_id == preferred); }
    let priority: Vec<_> = sources.iter().filter(|source| source.playing && source.kind != PlayerKind::Other).collect();
    if !priority.is_empty() {
        return priority.iter().copied().find(|source| source.is_system_current)
            .or_else(|| priority.iter().copied().find(|source| Some(source.source_id.as_str()) == previous))
            .or_else(|| priority.into_iter().min_by(|a, b| a.source_id.cmp(&b.source_id)));
    }
    sources.iter().find(|source| source.is_system_current)
        .or_else(|| sources.iter().find(|source| Some(source.source_id.as_str()) == previous))
        .or_else(|| sources.iter().filter(|source| source.playing).min_by(|a, b| a.source_id.cmp(&b.source_id)))
        .or_else(|| sources.iter().min_by(|a, b| a.source_id.cmp(&b.source_id)))
}

pub fn select_session(sessions: &[SessionDescriptor], source_id: &str) -> Option<usize> {
    sessions.iter().position(|session| session.source_id == source_id && session.is_system_current)
        .or_else(|| sessions.iter().position(|session| session.source_id == source_id && session.playing))
        .or_else(|| sessions.iter().position(|session| session.source_id == source_id))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn source(id: &str, kind: PlayerKind, playing: bool, current: bool) -> MediaSource {
        MediaSource { source_id: id.into(), name: id.into(), kind, playing, is_system_current: current }
    }
    #[test]
    fn automatic_prioritizes_playing_target_then_system_current_and_stability() {
        let mut sources = vec![source("browser", PlayerKind::Other, true, true), source("netease", PlayerKind::Netease, true, false), source("qq", PlayerKind::Qqmusic, true, false)];
        assert_eq!(select_source(&sources, None, Some("qq")).unwrap().source_id, "qq");
        assert_eq!(select_source(&sources, None, None).unwrap().source_id, "netease");
        sources[1].is_system_current = true;
        assert_eq!(select_source(&sources, None, Some("qq")).unwrap().source_id, "netease");
        sources[1].is_system_current = false; sources[1].playing = false; sources[2].playing = false;
        assert_eq!(select_source(&sources, None, Some("qq")).unwrap().source_id, "browser");
    }
    #[test]
    fn manual_offline_never_falls_back_and_raw_ids_are_not_merged() {
        let sources = vec![source("QQMusic.exe", PlayerKind::Qqmusic, true, true), source("cloudmusic.exe", PlayerKind::Netease, false, false)];
        assert_eq!(select_source(&sources, Some("cloudmusic.exe"), None).unwrap().source_id, "cloudmusic.exe");
        assert!(select_source(&sources, Some("missing"), Some("QQMusic.exe")).is_none());
        assert!(select_source(&sources, Some("qqmusic.exe"), None).is_none());
    }
    #[test]
    fn duplicate_sources_are_grouped_but_session_selection_is_within_requested_group() {
        let sessions = vec![SessionDescriptor { source_id: "browser".into(), playing: false, is_system_current: true },
            SessionDescriptor { source_id: "browser".into(), playing: true, is_system_current: false },
            SessionDescriptor { source_id: "music".into(), playing: true, is_system_current: false }];
        let groups = group_sources(&sessions); assert_eq!(groups.len(), 2); assert!(groups[0].playing); assert!(groups[0].is_system_current);
        assert_eq!(select_session(&sessions, "browser"), Some(0)); assert_eq!(select_session(&sessions, "music"), Some(2));
        assert_eq!(select_session(&sessions, "missing"), None);
    }
    #[test]
    fn source_ids_reject_empty_nul_and_overlong_utf16() {
        for invalid in ["", "  ", "bad\0id"] { assert!(validate_source_id(invalid).is_err()); }
        assert!(validate_source_id(&"x".repeat(4096)).is_ok()); assert!(validate_source_id(&"x".repeat(4097)).is_err());
        assert!(validate_source_id(&"🎵".repeat(2048)).is_ok()); assert!(validate_source_id(&"🎵".repeat(2049)).is_err());
    }
    #[test]
    fn verified_executable_ids_and_absolute_paths_are_exactly_recognized() {
        for id in ["cloudmusic.exe", "CLOUDMUSIC.EXE", r"C:\Program Files\NetEase\CloudMusic\cloudmusic.exe"] {
            assert_eq!(player_identity(id), (PlayerKind::Netease, "网易云音乐".into()));
        }
        for id in ["qqmusic.exe", "QQMusic.exe", r"D:\QQMusic\QQMusic.exe", r"\\?\C:\QQMusic\QQMusic.exe"] {
            assert_eq!(player_identity(id), (PlayerKind::Qqmusic, "QQ 音乐".into()));
        }
    }
    #[test]
    fn unrelated_ids_containing_brand_words_never_get_priority() {
        for id in ["Netease.CloudMusic", "Tencent.QQMusic_abc!App", "QQMusic.exe.Helper", "mycloudmusic.exe", "cloudmusic.exe --arg", "https://example.com/qqmusic.exe", "relative/qqmusic.exe", "Spotify.exe"] {
            assert_eq!(player_identity(id).0, PlayerKind::Other, "{id}");
        }
    }
    #[test]
    fn recognized_player_is_prioritized_without_rewriting_its_raw_id() {
        let sessions = vec![SessionDescriptor { source_id: "browser.exe".into(), playing: true, is_system_current: true },
            SessionDescriptor { source_id: "QQMusic.exe".into(), playing: true, is_system_current: false }];
        let sources = group_sources(&sessions);
        assert_eq!(select_source(&sources, None, None).unwrap().source_id, "QQMusic.exe");
        assert_eq!(sources[0].source_id, "QQMusic.exe");
    }
    #[test]
    fn same_session_polling_keeps_token_but_replacement_rejects_old_click() {
        let mut binding = None;
        let first = ControlBinding::refresh(&mut binding, "QQMusic.exe", 10);
        let next_poll = ControlBinding::refresh(&mut binding, "QQMusic.exe", 10);
        assert_eq!(first, next_poll);
        assert_eq!(*binding.as_ref().unwrap().session_for_request("QQMusic.exe", &first).unwrap(), 10);
        // 新会话快照尚未送到前端时，旧按钮仍带旧令牌；不能把操作转给同 ID 的新对象。
        let replacement = ControlBinding::refresh(&mut binding, "QQMusic.exe", 20);
        assert_ne!(first, replacement);
        assert!(binding.as_ref().unwrap().session_for_request("QQMusic.exe", &first).is_err());
        assert_eq!(*binding.as_ref().unwrap().session_for_request("QQMusic.exe", &replacement).unwrap(), 20);
    }
    #[test]
    fn source_change_and_disconnect_invalidate_previous_session_tokens() {
        let mut binding = None;
        let old = ControlBinding::refresh(&mut binding, "source-a", 1);
        let next = ControlBinding::refresh(&mut binding, "source-b", 1);
        assert_ne!(old, next);
        assert!(binding.as_ref().unwrap().session_for_request("source-a", &next).is_err());
        binding = None;
        let restored = ControlBinding::refresh(&mut binding, "source-b", 1);
        assert_ne!(restored, next);
        assert!(binding.as_ref().unwrap().session_for_request("source-b", &next).is_err());
    }
    #[test]
    fn session_tokens_are_required_and_bounded_before_native_control() {
        assert!(validate_session_token(&uuid::Uuid::new_v4().to_string()).is_ok());
        for token in ["", "not-a-token", "00000000-0000-0000-0000-00000000000Z"] { assert!(validate_session_token(token).is_err()); }
        assert!(validate_session_token(&"x".repeat(4096)).is_err());
    }
}
