//! 只检查本仓库 Windows x64 NSIS 资产；版本来自 Windows 资产名，不使用 Mac 标签号。
use crate::storage::{atomic_write, read_bounded};
use serde::{Deserialize, Serialize};
use std::{path::PathBuf, time::{Duration, SystemTime, UNIX_EPOCH}};

const ENDPOINT: &str = "https://api.github.com/repos/Meteorkid/XNook/releases?per_page=100";
const TTL: u64 = 86400;
const MAX_BYTES: usize = 4 * 1024 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateStatus { pub current_version: String, pub latest_version: Option<String>, pub update_available: bool, pub url: Option<String>, pub checked_at: String, pub message: String }
#[derive(Serialize, Deserialize)]
struct Cache { version: u32, checked_at: u64, status: UpdateStatus }
#[derive(Deserialize)]
struct Release { html_url: String, draft: bool, assets: Vec<Asset> }
#[derive(Deserialize)]
struct Asset { name: String, browser_download_url: String }

pub struct UpdateService { client: reqwest::Client, path: PathBuf, cache: tokio::sync::Mutex<Option<Cache>> }
impl UpdateService {
    pub fn new(data_directory: PathBuf) -> Result<Self, String> {
        let client = reqwest::Client::builder().https_only(true).redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(5)).timeout(Duration::from_secs(15))
            .user_agent(concat!("XNook-Windows/", env!("CARGO_PKG_VERSION")))
            .build().map_err(|error|format!("更新检查初始化失败：{error}"))?;
        let path=data_directory.join("updates-v1.json");
        let cache=read_bounded(&path,64*1024).ok().and_then(|bytes|serde_json::from_slice::<Cache>(&bytes).ok()).filter(valid_cache);
        Ok(Self {client,path,cache:tokio::sync::Mutex::new(cache)})
    }
    pub async fn check(&self, force: bool) -> Result<UpdateStatus, String> {
        self.check_with(force, || async {
            let mut response=self.client.get(ENDPOINT).header("Accept","application/vnd.github+json").header("X-GitHub-Api-Version","2022-11-28")
                .send().await.map_err(|error|format!("更新检查网络错误：{error}"))?.error_for_status().map_err(|error|format!("更新服务错误：{error}"))?;
            if response.content_length().is_some_and(|bytes|bytes>MAX_BYTES as u64) {return Err("更新响应过大".into())}
            let mut bytes=Vec::new();
            while let Some(chunk)=response.chunk().await.map_err(|error|format!("更新响应读取失败：{error}"))? {
                if chunk.len()>MAX_BYTES.saturating_sub(bytes.len()) {return Err("更新响应过大".into())} bytes.extend_from_slice(&chunk);
            }
            Ok(bytes)
        }).await
    }
    async fn check_with<F,Fut>(&self, force:bool, fetch:F)->Result<UpdateStatus,String>
    where F:FnOnce()->Fut,Fut:std::future::Future<Output=Result<Vec<u8>,String>> {
        let mut cached=self.cache.lock().await;
        let now=now_seconds();
        if !force {if let Some(cache)=cached.as_ref().filter(|cache|cache.checked_at<=now && now-cache.checked_at<TTL) {return Ok(current_status(cache.status.clone()))}}
        let bytes=tokio::time::timeout(Duration::from_secs(20),fetch()).await.map_err(|_|"更新检查超时".to_string())??;
        let status=select_release(&bytes,now)?;
        let cache=Cache {version:1,checked_at:now,status:status.clone()};
        // 缓存不是用户数据，写失败不抹去已经完成的网络检查，也不把网络错误缓存为“无更新”。
        if let Ok(bytes)=serde_json::to_vec(&cache) {let _=atomic_write(&self.path,&bytes);}
        *cached=Some(cache);Ok(status)
    }
    pub fn latest_url(&self)->Result<Option<String>,String> {
        let cached=self.cache.try_lock().map_err(|_|"正在检查更新，请稍后重试")?;
        let url=cached.as_ref().and_then(|cache|cache.status.url.clone());
        if url.as_ref().is_some_and(|url|!valid_release_url(url)) {return Err("更新页面地址无效".into())} Ok(url)
    }
}
fn version(text:&str)->Option<[u64;3]> {
    let parts:Vec<_>=text.split('.').collect();if parts.len()!=3 {return None}
    let mut result=[0;3];for(index,part) in parts.iter().enumerate(){if part.is_empty()||!part.bytes().all(|c|c.is_ascii_digit()) {return None}result[index]=part.parse().ok()?;}Some(result)
}
fn asset_version(name:&str)->Option<&str> {
    let lower=name.to_ascii_lowercase();
    for (prefix,suffix) in [("xnook_","_x64-setup.exe"),("xnook-","-windows-x64-setup.exe")] {
        if lower.starts_with(prefix)&&lower.ends_with(suffix) {
            let value=&name[prefix.len()..name.len()-suffix.len()];version(value)?;return Some(value);
        }
    }
    None
}
fn project_segments(url:&str)->Option<Vec<String>> {
    let parsed=reqwest::Url::parse(url).ok()?;
    if parsed.scheme()!="https"||parsed.host_str()!=Some("github.com")||parsed.port().is_some()||!parsed.username().is_empty()||parsed.password().is_some()||parsed.query().is_some()||parsed.fragment().is_some() {return None}
    let parts:Vec<_>=parsed.path_segments()?.map(str::to_owned).collect();
    if parts.len()<4||!parts[0].eq_ignore_ascii_case("Meteorkid")||!parts[1].eq_ignore_ascii_case("XNook")||parts[2]!="releases"||parts.iter().any(|s|s.is_empty()||s.contains('%')||s.contains('\\')) {return None}Some(parts)
}
fn valid_release_url(url:&str)->bool {project_segments(url).is_some_and(|parts|parts.len()==5&&parts[3]=="tag")}
fn valid_asset_url(url:&str,name:&str,release_url:&str)->bool {
    match (project_segments(url),project_segments(release_url)) {(Some(asset),Some(release))=>asset.len()==6&&asset[3]=="download"&&asset[4]==release[4]&&asset[5]==name,_=>false}
}
fn select_release(bytes:&[u8],now:u64)->Result<UpdateStatus,String> {
    if bytes.len()>MAX_BYTES {return Err("更新响应过大".into())}
    let releases:Vec<Release>=serde_json::from_slice(bytes).map_err(|_|"更新服务返回了无效数据")?;
    if releases.len()>100 {return Err("更新列表超出上限".into())}
    let mut selected:Option<(String,String)>=None;
    for release in releases {
        if release.draft||!valid_release_url(&release.html_url) {continue}
        for asset in release.assets {
            let Some(remote)=asset_version(&asset.name) else {continue};
            if !valid_asset_url(&asset.browser_download_url,&asset.name,&release.html_url) {continue}
            if selected.as_ref().is_none_or(|(old,_)|version(remote)>version(old)) {selected=Some((remote.into(),release.html_url.clone()));}
        }
    }
    let (latest_version,url)=selected.map(|(version,url)|(Some(version),Some(url))).unwrap_or((None,None));
    Ok(current_status(UpdateStatus {current_version:env!("CARGO_PKG_VERSION").into(),latest_version,update_available:false,url,checked_at:timestamp(now),message:String::new()}))
}
fn current_status(mut status:UpdateStatus)->UpdateStatus {
    status.current_version=env!("CARGO_PKG_VERSION").into();
    status.update_available=status.latest_version.as_deref().and_then(version).zip(version(&status.current_version)).is_some_and(|(remote,current)|remote>current);
    status.message=if status.latest_version.is_none(){"最近 100 个发布中暂无 Windows x64 安装包"}else if status.update_available{"发现 Windows 新版本，可打开发布页查看"}else{"当前已是所发现的最新 Windows 版本"}.into();status
}
fn valid_cache(cache:&Cache)->bool {cache.version==1 && cache.status.latest_version.as_deref().is_none_or(|v|version(v).is_some()) && match (&cache.status.latest_version,&cache.status.url){(Some(_),Some(url))=>valid_release_url(url),(None,None)=>true,_=>false}}
fn now_seconds()->u64 {SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs()}
fn timestamp(seconds:u64)->String {let date=time::OffsetDateTime::from_unix_timestamp(seconds.min(i64::MAX as u64) as i64).unwrap_or(time::OffsetDateTime::UNIX_EPOCH);format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",date.year(),u8::from(date.month()),date.day(),date.hour(),date.minute(),date.second())}

#[cfg(test)]
mod tests {
    use super::*;
    fn release(asset:&str)->serde_json::Value {serde_json::json!({"tag_name":"v99.0.0","html_url":"https://github.com/Meteorkid/XNook/releases/tag/v99.0.0","draft":false,"assets":[{"name":asset,"browser_download_url":format!("https://github.com/Meteorkid/XNook/releases/download/v99.0.0/{asset}")}]})}
    #[test] fn mac_only_is_not_a_windows_update_and_asset_controls_version() {
        let mac=select_release(&serde_json::to_vec(&vec![release("XNook-99.0.0.dmg")]).unwrap(),1000).unwrap();assert!(mac.latest_version.is_none());assert!(!mac.update_available);
        let win=select_release(&serde_json::to_vec(&vec![release("XNook_0.9.0_x64-setup.exe")]).unwrap(),1000).unwrap();assert_eq!(win.latest_version.as_deref(),Some("0.9.0"));assert!(win.update_available);
    }
    #[test] fn arbitrary_urls_architectures_and_mac_tag_version_are_not_accepted() {
        for name in ["XNook_5.0.0_arm64-setup.exe","XNook_5.0.0_x64.msi","evil_5.0.0_x64-setup.exe"] {assert!(asset_version(name).is_none())}
        for url in ["https://github.com/other/XNook/releases/tag/v2","https://github.com/Meteorkid/XNook/releases/tag/v2?url=evil","https://evil.test/Meteorkid/XNook/releases/tag/v2","https://github.com/Meteorkid/XNook/releases/tag/a%2Fb"] {assert!(!valid_release_url(url))}
        let mut invalid=release("XNook_5.0.0_x64-setup.exe");invalid["assets"][0]["browser_download_url"]="https://evil.test/setup.exe".into();assert!(select_release(&serde_json::to_vec(&vec![invalid]).unwrap(),1000).unwrap().latest_version.is_none());assert!(select_release(b"bad gateway",0).is_err());
    }
    #[tokio::test] async fn cache_survives_restart_and_force_failure_does_not_replace_success() {
        let root=std::env::temp_dir().join(format!("xnook-updates-{}",uuid::Uuid::new_v4()));
        let service=UpdateService::new(root.clone()).unwrap();let bytes=serde_json::to_vec(&vec![release("XNook_0.9.0_x64-setup.exe")]).unwrap();
        let first=service.check_with(false,||async{Ok(bytes)}).await.unwrap();
        let restarted=UpdateService::new(root.clone()).unwrap();assert_eq!(restarted.check_with(false,||async{panic!("cached")}).await.unwrap().latest_version,first.latest_version);
        assert!(restarted.check_with(true,||async{Err("network".into())}).await.is_err());assert_eq!(restarted.latest_url().unwrap(),first.url);std::fs::remove_dir_all(root).unwrap();
    }
    #[tokio::test] async fn genuine_empty_is_cached_but_expired_cache_refetches() {
        let root=std::env::temp_dir().join(format!("xnook-updates-{}",uuid::Uuid::new_v4()));let service=UpdateService::new(root.clone()).unwrap();
        assert!(service.check_with(false,||async{Ok(b"[]".to_vec())}).await.unwrap().url.is_none());
        service.cache.lock().await.as_mut().unwrap().checked_at=0;
        assert!(service.check_with(false,||async{Err("fetch was required".into())}).await.is_err());std::fs::remove_dir_all(root).unwrap();
    }
    #[test] fn selection_uses_highest_valid_windows_asset_and_ignores_draft_or_cross_tag_download() {
        let mut draft=release("XNook_9.0.0_x64-setup.exe");draft["draft"]=true.into();
        let mut cross_tag=release("XNook_8.0.0_x64-setup.exe");
        cross_tag["assets"][0]["browser_download_url"]="https://github.com/Meteorkid/XNook/releases/download/other/XNook_8.0.0_x64-setup.exe".into();
        let result=select_release(&serde_json::to_vec(&vec![release("XNook_0.9.0_x64-setup.exe"),release("XNook_0.10.0_x64-setup.exe"),draft,cross_tag]).unwrap(),1000).unwrap();
        assert_eq!(result.latest_version.as_deref(),Some("0.10.0"));
        assert_eq!(result.checked_at,"1970-01-01T00:16:40Z");
        for url in ["http://github.com/Meteorkid/XNook/releases/tag/v2","https://user@github.com/Meteorkid/XNook/releases/tag/v2","https://github.com:444/Meteorkid/XNook/releases/tag/v2","https://github.com/Meteorkid/XNook/releases/tag/v2#download"] {assert!(!valid_release_url(url));}
    }
    #[tokio::test] async fn corrupt_cache_is_ignored_without_touching_user_store_or_becoming_no_update() {
        let root=std::env::temp_dir().join(format!("xnook-updates-{}",uuid::Uuid::new_v4()));std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("updates-v1.json"),b"broken cache").unwrap();
        std::fs::write(root.join("store.json"),b"user data").unwrap();
        let service=UpdateService::new(root.clone()).unwrap();
        assert!(service.latest_url().unwrap().is_none());
        assert!(service.check_with(false,||async{Err("network".into())}).await.is_err());
        assert_eq!(std::fs::read(root.join("updates-v1.json")).unwrap(),b"broken cache");
        assert_eq!(std::fs::read(root.join("store.json")).unwrap(),b"user data");
        std::fs::remove_dir_all(root).unwrap();
    }
}
