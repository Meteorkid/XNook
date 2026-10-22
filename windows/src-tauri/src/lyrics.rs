use serde::{Deserialize, Serialize};
use regex::Regex;
use std::{path::{Path, PathBuf}, sync::{Mutex, OnceLock}, time::{Duration, SystemTime, UNIX_EPOCH}};
use unicode_normalization::UnicodeNormalization;
use crate::storage::{atomic_write, read_bounded};

pub const MAX_RESPONSE_BYTES: usize = 2 * 1024 * 1024;
const CACHE_VERSION: u32 = 1;
const CACHE_BYTES: u64 = 5 * 1024 * 1024;
const SUCCESS_TTL: u64 = 30 * 86400;
const EMPTY_TTL: u64 = 300;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LyricsCandidate {
    pub id: u64,
    pub track_name: String,
    pub artist_name: String,
    pub album_name: String,
    pub duration: f64,
    pub instrumental: bool,
    pub synced_lyrics: Option<String>,
    pub plain_lyrics: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct CacheEntry { version: u32, key: String, fetched_at: u64, accessed_at: u64, successful: bool, candidates: Vec<LyricsCandidate> }
#[derive(Clone, Debug)]
struct LookupRequest { exact: bool, parameters: Vec<(&'static str, String)> }

pub struct LyricsClient { client: reqwest::Client, in_flight: tokio::sync::Semaphore, directory: Option<PathBuf>, cache_lock: Mutex<()> }

impl LyricsClient {
    pub fn new() -> Result<Self, String> { Self::create(None) }
    pub fn new_with_directory(data_directory: PathBuf) -> Result<Self, String> { Self::create(Some(data_directory.join("lyrics-cache-v1"))) }
    fn create(directory: Option<PathBuf>) -> Result<Self, String> {
        let client = reqwest::Client::builder().https_only(true).redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(5)).timeout(Duration::from_secs(10))
            .user_agent(concat!("XNook-Windows/", env!("CARGO_PKG_VERSION")))
            .build().map_err(|error| format!("歌词服务初始化失败：{error}"))?;
        Ok(Self { client, in_flight: tokio::sync::Semaphore::new(2), directory, cache_lock: Mutex::new(()) })
    }

    pub async fn lookup(&self, title: &str, artist: &str, album: &str, duration: Option<f64>) -> Result<Vec<LyricsCandidate>, String> {
        self.lookup_with(title, artist, album, duration, |request| self.fetch(request)).await
    }

    async fn lookup_with<F, Fut>(&self, title: &str, artist: &str, album: &str, duration: Option<f64>, fetch: F) -> Result<Vec<LyricsCandidate>, String>
    where F: FnMut(LookupRequest) -> Fut, Fut: std::future::Future<Output=Result<Vec<LyricsCandidate>, String>> {
        validate_query(title, artist, album, duration)?;
        let _permit = self.in_flight.try_acquire().map_err(|_| "歌词查询过于频繁，请稍后重试")?;
        // 完整查询参与键，尤其保留版本标记与时长；文件内再次核对键，防止哈希碰撞串曲。
        let key = serde_json::to_string(&(title.trim(), artist.trim(), album.trim(), duration)).map_err(|error|error.to_string())?;
        if let Some(cached) = self.read_cache(&key, now_seconds()) {
            // 旧缓存可能使用过不同的匹配规则；不让已不匹配的长缓存阻止重新检索。
            if cached.is_empty() || cached.iter().any(|candidate|usable_match(candidate,title,artist,duration)) {return Ok(cached);}
        }
        let result = tokio::time::timeout(Duration::from_secs(25), fetch_chain(title, artist, album, duration, fetch)).await
            .map_err(|_| "歌词请求超时，请重试".to_string())??;
        let successful = result.iter().any(|candidate| usable_match(candidate, title, artist, duration));
        self.write_cache(&key, &result, successful, now_seconds());
        Ok(result)
    }

    async fn fetch(&self, request: LookupRequest) -> Result<Vec<LyricsCandidate>, String> {
        // 只访问固定 HTTPS 服务；宽松查询仅扩大候选召回，前端仍严格匹配。
        let url = if request.exact { "https://lrclib.net/api/get" } else { "https://lrclib.net/api/search" };
        let mut response = self.client.get(url).query(&request.parameters).send().await
            .map_err(|error| if error.is_timeout() { "歌词请求超时，请重试".into() } else { format!("歌词网络请求失败：{error}") })?;
        if request.exact && response.status() == reqwest::StatusCode::NOT_FOUND { return Ok(Vec::new()); }
        response = response.error_for_status().map_err(|error| format!("歌词服务返回错误：{error}"))?;
        if response.content_length().is_some_and(|size| size > MAX_RESPONSE_BYTES as u64) { return Err("歌词服务响应过大".into()); }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|error|format!("歌词网络响应读取失败：{error}"))? { append_bounded(&mut bytes, &chunk, MAX_RESPONSE_BYTES)?; }
        if request.exact {
            let candidate: LyricsCandidate = serde_json::from_slice(&bytes).map_err(|_| "歌词服务返回了无法识别的数据")?;
            validate_candidates(std::slice::from_ref(&candidate))?; Ok(vec![candidate])
        } else { parse_candidates(&bytes) }
    }

    fn cache_path(directory: &Path, key: &str) -> PathBuf {
        let hash = key.bytes().fold(5381_u64, |hash, byte| hash.wrapping_mul(33) ^ u64::from(byte));
        directory.join(format!("{hash:016x}.json"))
    }
    fn read_cache(&self, key: &str, now: u64) -> Option<Vec<LyricsCandidate>> {
        let directory = self.directory.as_ref()?;
        let _guard = self.cache_lock.lock().ok()?;
        let path = Self::cache_path(directory, key);
        let mut entry: CacheEntry = serde_json::from_slice(&read_bounded(&path, MAX_RESPONSE_BYTES + 16384).ok()?).ok()?;
        let ttl = if entry.successful { SUCCESS_TTL } else { EMPTY_TTL };
        if entry.version != CACHE_VERSION || entry.key != key || entry.fetched_at > now || now - entry.fetched_at >= ttl || validate_candidates(&entry.candidates).is_err() { return None; }
        entry.accessed_at = now;
        if let Ok(bytes) = serde_json::to_vec(&entry) { let _ = atomic_write(&path, &bytes); }
        Some(entry.candidates)
    }
    fn write_cache(&self, key: &str, candidates: &[LyricsCandidate], successful: bool, now: u64) {
        let Some(directory) = &self.directory else { return; };
        let Ok(_guard) = self.cache_lock.lock() else { return; };
        let entry = CacheEntry { version: CACHE_VERSION, key: key.into(), fetched_at: now, accessed_at: now, successful, candidates: candidates.to_vec() };
        let Ok(bytes) = serde_json::to_vec(&entry) else { return; };
        if bytes.len() > MAX_RESPONSE_BYTES + 16384 { return; }
        if atomic_write(&Self::cache_path(directory, key), &bytes).is_err() { return; }
        evict_cache(directory);
    }
}

async fn fetch_chain<F, Fut>(title: &str, artist: &str, album: &str, duration: Option<f64>, mut fetch: F) -> Result<Vec<LyricsCandidate>, String>
where F: FnMut(LookupRequest) -> Fut, Fut: std::future::Future<Output=Result<Vec<LyricsCandidate>, String>> {
    let base = vec![("track_name", title.trim().to_owned()), ("artist_name", artist.trim().to_owned())];
    let mut requests = Vec::new();
    if let Some(duration) = duration.filter(|value| *value > 0.0 && !album.trim().is_empty()) {
        let mut parameters = base.clone(); parameters.push(("album_name", album.trim().into())); parameters.push(("duration", duration.round().to_string()));
        requests.push(LookupRequest { exact: true, parameters });
    }
    requests.push(LookupRequest { exact: false, parameters: base });
    requests.push(LookupRequest { exact: false, parameters: vec![("q", format!("{} {}", title.trim(), artist.trim()).trim().into())] });
    let mut candidates = Vec::new(); let mut last_error = None;
    for request in requests {
        match fetch(request).await {
            Ok(items) => {
                validate_candidates(&items)?;
                for item in items.into_iter().filter(|item|usable_match(item,title,artist,duration)) {
                    if let Some(index)=candidates.iter().position(|old: &LyricsCandidate|old.id==item.id) {
                        if lyric_quality(&item)>lyric_quality(&candidates[index]) {candidates[index]=item;}
                    } else {candidates.push(item);}
                }
                // 无关结果不占候选额度；后续检索找到的同步歌词可替换已有纯文本候选。
                candidates.sort_by_key(|candidate|std::cmp::Reverse(lyric_quality(candidate)));
                candidates.truncate(100);
                if candidates.iter().any(|candidate| usable_match(candidate, title, artist, duration) && (candidate.instrumental || candidate.synced_lyrics.as_ref().is_some_and(|text|has_synced_lines(text)))) { return Ok(candidates); }
            }
            Err(error) => last_error = Some(error),
        }
    }
    if candidates.iter().any(|candidate| usable_match(candidate, title, artist, duration)) { return Ok(candidates); }
    // 某级请求失败时，“搜索为空”并不是可靠否定结果，不能写入负缓存。
    if let Some(error) = last_error { return Err(error); }
    Ok(candidates)
}

fn has_synced_lines(text: &str) -> bool {
    static STAMP:OnceLock<Regex>=OnceLock::new();
    static OFFSET:OnceLock<Regex>=OnceLock::new();
    let offset=OFFSET.get_or_init(||Regex::new(r"(?i)\[offset:([+-]?[0-9]+)\]").unwrap()).captures(text)
        .and_then(|value|value[1].parse::<f64>().ok()).map(|offset|offset/1000.0).filter(|offset|offset.is_finite()).unwrap_or(0.0);
    STAMP.get_or_init(||Regex::new(r"\[([0-9]+):([0-9]{2})(?:[.:]([0-9]{1,3}))?\]").unwrap()).captures_iter(text).any(|stamp| {
        let fraction=stamp.get(3).map(|value|value.as_str().parse::<f64>().unwrap_or(0.0)/10_f64.powi(value.as_str().len() as i32)).unwrap_or(0.0);
        stamp[1].parse::<f64>().is_ok_and(|minutes| (minutes*60.0+stamp[2].parse::<f64>().unwrap_or(60.0)+fraction+offset).is_finite())
            && stamp[2].parse::<u8>().is_ok_and(|seconds|seconds<60)
    })
}
fn javascript_spaces()->&'static Regex {
    static SPACE:OnceLock<Regex>=OnceLock::new();
    SPACE.get_or_init(||Regex::new(r"[\p{Z}\x09-\x0D\u{FEFF}]+").unwrap())
}
fn has_plain_lyrics(text:&str)->bool {javascript_spaces().split(text).any(|part|!part.is_empty())}
fn lyric_quality(candidate:&LyricsCandidate)->u8 {
    if candidate.instrumental || candidate.synced_lyrics.as_deref().is_some_and(has_synced_lines) {2}
    else if candidate.plain_lyrics.as_deref().is_some_and(has_plain_lyrics) {1} else {0}
}
fn usable_match(candidate: &LyricsCandidate, title: &str, artist: &str, duration: Option<f64>) -> bool {
    // 与前端 NFKC + toLowerCase + Unicode P/Z/ECMAScript 空白规则一致，符号不等于标点。
    static TITLE_SEPARATOR:OnceLock<Regex>=OnceLock::new();
    let normalized=|text:&str|text.nfkc().collect::<String>().to_lowercase();
    let normalize=|text:&str|TITLE_SEPARATOR.get_or_init(||Regex::new(r"[\p{P}\p{Z}\x09-\x0D\u{FEFF}]").unwrap()).replace_all(&normalized(text),"").into_owned();
    let normalize_artist=|text:&str|javascript_spaces().replace_all(&normalized(text)," ").trim_matches(' ').replace(" /","/").replace("/ ","/");
    !normalize(title).is_empty() && !normalize_artist(artist).is_empty() && normalize(&candidate.track_name) == normalize(title)
        && normalize_artist(&candidate.artist_name) == normalize_artist(artist)
        && duration.is_none_or(|duration|(candidate.duration-duration).abs() <= 8.0)
        && lyric_quality(candidate)>0
}
fn evict_cache(directory: &Path) {
    let Ok(entries) = std::fs::read_dir(directory) else { return; };
    let mut entries: Vec<_> = entries.flatten().filter_map(|entry| {
        let path = entry.path(); let metadata = entry.metadata().ok()?;
        if !metadata.is_file() || path.extension().and_then(|value|value.to_str()) != Some("json") { return None; }
        let access = read_bounded(&path, MAX_RESPONSE_BYTES + 16384).ok().and_then(|bytes|serde_json::from_slice::<CacheEntry>(&bytes).ok()).map(|entry|entry.accessed_at).unwrap_or(0);
        Some((path, metadata.len(), access))
    }).collect();
    let mut size: u64 = entries.iter().map(|entry|entry.1).sum(); let mut count = entries.len();
    if size <= CACHE_BYTES && count <= 150 { return; }
    entries.sort_by_key(|entry|entry.2);
    for (path, bytes, _) in entries { if size <= CACHE_BYTES * 8 / 10 && count <= 120 { break; } if std::fs::remove_file(path).is_ok() { size=size.saturating_sub(bytes); count-=1; } }
}
fn now_seconds() -> u64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() }
fn validate_query(title: &str, artist: &str, album: &str, duration: Option<f64>) -> Result<(), String> {
    if title.trim().is_empty() { return Err("歌曲标题为空，无法查找歌词".into()); }
    if [title, artist, album].iter().any(|text| text.len() > 2048 || text.contains('\0')) { return Err("曲目信息过长或无效".into()); }
    if duration.is_some_and(|value| !value.is_finite() || value < 0.0 || value > 604800.0) { return Err("歌曲时长无效".into()); }
    Ok(())
}
fn append_bounded(bytes: &mut Vec<u8>, chunk: &[u8], maximum: usize) -> Result<(), String> {
    if chunk.len() > maximum.saturating_sub(bytes.len()) { return Err("歌词服务响应过大".into()); }
    bytes.extend_from_slice(chunk); Ok(())
}
fn validate_candidates(candidates: &[LyricsCandidate]) -> Result<(), String> {
    if candidates.len() > 100 || candidates.iter().any(|entry| !entry.duration.is_finite() || entry.duration < 0.0 || entry.duration > 604800.0 || entry.track_name.len() > 16384 || entry.artist_name.len() > 16384 || entry.album_name.len() > 16384
        || entry.synced_lyrics.as_ref().is_some_and(|text|text.len()>MAX_RESPONSE_BYTES) || entry.plain_lyrics.as_ref().is_some_and(|text|text.len()>MAX_RESPONSE_BYTES)) { return Err("歌词服务返回了超出范围的数据".into()); }
    Ok(())
}
fn parse_candidates(bytes: &[u8]) -> Result<Vec<LyricsCandidate>, String> {
    if bytes.len() > MAX_RESPONSE_BYTES { return Err("歌词服务响应过大".into()); }
    let candidates: Vec<LyricsCandidate> = serde_json::from_slice(bytes).map_err(|_| "歌词服务返回了无法识别的数据")?;
    validate_candidates(&candidates)?; Ok(candidates)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn song() -> LyricsCandidate { LyricsCandidate { id:1, track_name:"歌".into(), artist_name:"人".into(), album_name:"专辑".into(), duration:60., instrumental:false, synced_lyrics:Some("[00:01]词".into()), plain_lyrics:None } }
    fn directory() -> PathBuf { std::env::temp_dir().join(format!("xnook-lyrics-{}",uuid::Uuid::new_v4())) }
    #[test] fn malformed_queries_fail_before_network() { assert!(validate_query("", "", "", None).is_err()); assert!(validate_query("歌", "人", "", Some(f64::NAN)).is_err()); assert!(validate_query("歌?&/", "人", "", Some(60.)).is_ok()); }
    #[test] fn empty_is_distinct_from_invalid_response() { assert!(parse_candidates(b"[]").unwrap().is_empty()); assert!(parse_candidates(b"bad gateway").is_err()); assert!(parse_candidates(br#"[{"id":1}]"#).is_err()); }
    #[test] fn chunk_limit_prevents_unbounded_allocation_without_content_length() { let mut bytes=vec![1,2];assert!(append_bounded(&mut bytes,&[3,4],3).is_err());assert_eq!(bytes,vec![1,2]); }
    #[tokio::test] async fn exact_search_then_query_preserves_strict_candidates() {
        let mut paths=Vec::new(); let result=fetch_chain("歌","人","专辑",Some(60.),|request| {paths.push(request.clone()); let items=if paths.len()==3 {vec![song()]} else {Vec::new()};async move {Ok(items)}}).await.unwrap();
        assert_eq!(result.len(),1);assert!(paths[0].exact);assert_eq!(paths[0].parameters.last().unwrap().0,"duration");assert_eq!(paths[1].parameters[0].0,"track_name");assert_eq!(paths[2].parameters[0].0,"q");
    }
    #[tokio::test] async fn network_failure_is_not_cached_as_empty_and_restart_hits_success() {
        let root=directory();let client=LyricsClient::new_with_directory(root.clone()).unwrap();
        assert!(client.lookup_with("歌","人","专辑",Some(60.), |_|async{Err("network".into())}).await.is_err());
        let result=client.lookup_with("歌","人","专辑",Some(60.), |_|async{Ok(vec![song()])}).await.unwrap();assert_eq!(result.len(),1);
        let restarted=LyricsClient::new_with_directory(root.clone()).unwrap();assert_eq!(restarted.lookup_with("歌","人","专辑",Some(60.), |_|async{panic!("cache must survive restart")}).await.unwrap().len(),1);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test] fn distinct_ttls_version_and_key_collision_are_checked() {
        let root=directory();let client=LyricsClient::new_with_directory(root.clone()).unwrap();
        client.write_cache("positive",&[song()],true,1000);client.write_cache("negative",&[],false,1000);
        assert!(client.read_cache("positive",1301).is_some());assert!(client.read_cache("negative",1301).is_none());assert!(client.read_cache("positive",1000+SUCCESS_TTL).is_none());
        let path=LyricsClient::cache_path(client.directory.as_ref().unwrap(),"positive");let mut entry:CacheEntry=serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();entry.key="another song".into();atomic_write(&path,&serde_json::to_vec(&entry).unwrap()).unwrap();assert!(client.read_cache("positive",1001).is_none());
        entry.key="positive".into();entry.version=99;atomic_write(&path,&serde_json::to_vec(&entry).unwrap()).unwrap();assert!(client.read_cache("positive",1001).is_none());std::fs::remove_dir_all(root).unwrap();
    }
    #[tokio::test] async fn partial_error_with_other_empty_results_remains_error() { let mut call=0;assert!(fetch_chain("歌","人","专辑",Some(60.), |_|{call+=1;let result=if call==1 {Err("timeout".into())} else {Ok(vec![])};async move {result}}).await.is_err()); }
    #[test] fn bounded_cache_evicts_oldest_entries() {let root=directory();let client=LyricsClient::new_with_directory(root.clone()).unwrap();for index in 0..151 {client.write_cache(&index.to_string(),&[],false,index);}assert!(client.read_cache("0",151).is_none());assert!(client.read_cache("150",151).is_some());assert!(std::fs::read_dir(client.directory.as_ref().unwrap()).unwrap().count()<=150);std::fs::remove_dir_all(root).unwrap();}
    #[tokio::test] async fn true_empty_survives_restart_without_hiding_network_failures() {
        let root=directory();let client=LyricsClient::new_with_directory(root.clone()).unwrap();
        assert!(client.lookup_with("歌","人","专辑",Some(60.), |_|async{Ok(vec![])}).await.unwrap().is_empty());
        let restarted=LyricsClient::new_with_directory(root.clone()).unwrap();assert!(restarted.lookup_with("歌","人","专辑",Some(60.), |_|async{panic!("negative cache must survive restart")}).await.unwrap().is_empty());
        std::fs::remove_dir_all(root).unwrap();
    }
    #[tokio::test] async fn cancelled_lookup_releases_permit_and_does_not_write_negative_cache() {
        let root=directory();let client=LyricsClient::new_with_directory(root.clone()).unwrap();
        let pending=client.lookup_with("歌","人","专辑",Some(60.), |_|std::future::pending::<Result<Vec<LyricsCandidate>,String>>());
        assert!(tokio::time::timeout(Duration::from_millis(5),pending).await.is_err());
        assert!(!root.exists());assert_eq!(client.lookup_with("歌","人","专辑",Some(60.), |_|async{Ok(vec![song()])}).await.unwrap().len(),1);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[tokio::test] async fn invalid_synced_result_continues_to_search_for_usable_plain_lyrics() {
        let mut calls=0;
        let result=fetch_chain("歌","人","专辑",Some(60.), |_| {calls+=1;let mut candidate=song();candidate.id=calls;candidate.synced_lyrics=Some("[00:99]invalid".into());if calls==2 {candidate.plain_lyrics=Some("可读原文".into());}async move{Ok(vec![candidate])}}).await.unwrap();
        assert_eq!(calls,3);assert!(result.iter().any(|candidate|candidate.plain_lyrics.as_deref()==Some("可读原文")));
    }

    #[test] fn match_normalization_and_timestamp_grammar_follow_frontend() {
        let mut candidate=song();candidate.track_name="AB".into();
        assert!(!usable_match(&candidate,"A+B","人",Some(60.)));
        candidate.track_name="Ａ＋Ｂ".into();candidate.artist_name=" ＡＣ ／ ＤＣ ".into();
        assert!(usable_match(&candidate,"A+B","AC/DC",Some(60.)));
        candidate.track_name="A+B (Live)".into();assert!(!usable_match(&candidate,"A+B","AC/DC",Some(60.)));
        for text in ["[00:1]bad","[00:01.1234]bad","[00:01e0]bad","[00:60]bad","[00:01.]bad"] {assert!(!has_synced_lines(text),"{text}");}
        for text in ["[00:01]词","[00:01.123]词","[00:01:20]词"] {assert!(has_synced_lines(text),"{text}");}
        assert!(!has_synced_lines(&format!("[{}:01]bad","9".repeat(400))));
        assert!(has_synced_lines(&format!("[offset:{}]\n[00:01]词","9".repeat(400))));
        assert!(!has_plain_lyrics("\u{FEFF}\u{2028} \t"));
        // U+0085 不是 ECMAScript 空白，不能使用 Rust trim() 改变前端含义。
        assert!(has_plain_lyrics("\u{0085}"));
    }
    #[tokio::test] async fn fallback_can_upgrade_same_id_and_reject_irrelevant_full_page() {
        let mut calls=0;
        let result=fetch_chain("歌","人","专辑",Some(60.), |_| {calls+=1;let mut candidate=song();candidate.synced_lyrics=None;
            if calls==2 {candidate.plain_lyrics=Some("可读原文".into());}
            async move{Ok(vec![candidate])}}).await.unwrap();
        assert!(result.iter().any(|candidate|candidate.plain_lyrics.as_deref()==Some("可读原文")));
        let mut calls=0;
        let result=fetch_chain("歌","人","专辑",Some(60.), |_| {calls+=1;let candidates=if calls==3 {vec![song()]} else {
            (2..102).map(|id|{let mut candidate=song();candidate.id=id;candidate.track_name="错误歌曲".into();candidate}).collect()};
            async move{Ok(candidates)}}).await.unwrap();
        assert!(result.iter().any(|candidate|usable_match(candidate,"歌","人",Some(60.))));
    }
    #[tokio::test] async fn invalid_old_positive_cache_refetches_and_corrupt_cache_does_not_modify_user_store() {
        let root=directory();let client=LyricsClient::new_with_directory(root.clone()).unwrap();
        let key=serde_json::to_string(&("歌","人","专辑",Some(60_f64))).unwrap();
        let mut old=song();old.track_name="错误曲目".into();client.write_cache(&key,&[old],true,now_seconds());
        assert_eq!(client.lookup_with("歌","人","专辑",Some(60.), |_|async{Ok(vec![song()])}).await.unwrap()[0].track_name,"歌");
        let path=LyricsClient::cache_path(client.directory.as_ref().unwrap(),&key);
        std::fs::write(&path,b"corrupt").unwrap();std::fs::write(root.join("store.json"),b"user data").unwrap();
        assert!(client.lookup_with("歌","人","专辑",Some(60.), |_|async{Err("network".into())}).await.is_err());
        assert_eq!(std::fs::read(path).unwrap(),b"corrupt");assert_eq!(std::fs::read(root.join("store.json")).unwrap(),b"user data");
        std::fs::remove_dir_all(root).unwrap();
    }
    #[tokio::test] async fn negative_cache_does_not_hide_match_after_fractional_duration_changes() {
        let root=directory();let client=LyricsClient::new_with_directory(root.clone()).unwrap();let mut calls=0;
        assert!(client.lookup_with("歌","人","专辑",Some(68.4), |_| {calls+=1;async{Ok(vec![song()])}}).await.unwrap().is_empty());
        let previous=calls;
        assert_eq!(client.lookup_with("歌","人","专辑",Some(67.6), |_| {calls+=1;async{Ok(vec![song()])}}).await.unwrap().len(),1);
        assert!(calls>previous);std::fs::remove_dir_all(root).unwrap();
    }

}
