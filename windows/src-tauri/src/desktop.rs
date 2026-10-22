use crate::{files::{self, CalendarFile, FileInfo, FileStatus}, lyrics::{LyricsCandidate, LyricsClient}, media::{MediaService, MediaSnapshot}, storage::Store, windowing::{WindowController, WindowReport}};
use crate::exit_policy::{ExitPolicy, ExitRequest};
use crate::{gifs::{GifLibrary, GifInfo}, updates::{UpdateService, UpdateStatus}, platform};
use island_link::{Callbacks, Link, PeerStatus, IntegrationPreferences};
#[cfg(windows)]
use island_link::Identity;
use std::{path::PathBuf, sync::{Arc, Mutex}, time::Duration};
use tauri::{Emitter, Manager};
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons, MessageDialogKind};

struct DesktopState {
    store: Arc<Store>,
    window: Mutex<WindowController>,
    media: MediaService,
    lyrics: LyricsClient,
    gifs: Arc<GifLibrary>,
    updates: UpdateService,
    pinned: Mutex<bool>,
    link: Option<Arc<Link>>,
    exit: ExitPolicy,
    tray_actions: Mutex<Vec<TrayAction>>,
}

#[derive(Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
enum TrayAction { Settings, CheckUpdates }

fn push_tray_action(pending: &mut Vec<TrayAction>, action: TrayAction) {
    // WebView 尚未订阅时保留动作；重复点击不累积无界待办。
    if !pending.contains(&action) { pending.push(action); }
}

fn owner(window: &tauri::WebviewWindow) -> Result<(), String> {
    if window.label() == "main" { Ok(()) } else { Err("此操作只能由 XNook 主窗口发起".into()) }
}

#[tauri::command]
async fn read_store(window: tauri::WebviewWindow, state: tauri::State<'_, DesktopState>) -> Result<Option<String>, String> {
    owner(&window)?; let store = state.store.clone();
    tauri::async_runtime::spawn_blocking(move || store.read()).await.map_err(|error| error.to_string())?
}

#[tauri::command]
async fn write_store(window: tauri::WebviewWindow, state: tauri::State<'_, DesktopState>, content: String) -> Result<(), String> {
    owner(&window)?; let store = state.store.clone();
    tauri::async_runtime::spawn_blocking(move || store.write(&content)).await.map_err(|error| error.to_string())?
}

#[tauri::command]
async fn recover_store(window: tauri::WebviewWindow, state: tauri::State<'_, DesktopState>, content: String) -> Result<serde_json::Value, String> {
    owner(&window)?; let store = state.store.clone();
    let backup = tauri::async_runtime::spawn_blocking(move || store.recover(&content)).await.map_err(|error|error.to_string())??;
    Ok(serde_json::json!({"backupPath":backup}))
}

#[tauri::command]
fn apply_preferences(window: tauri::WebviewWindow, state: tauri::State<DesktopState>, settings: serde_json::Value) -> Result<(), String> {
    owner(&window)?; crate::preferences::validate(&settings)?;
    let pinned = settings["visibleOnAllDesktops"].as_bool().unwrap_or(false);
    {
        let previous = state.pinned.lock().map_err(|_| "虚拟桌面状态不可用")?;
        if *previous != pinned {
            #[cfg(windows)] { platform::win::pin_window(window.hwnd().map_err(|error|error.to_string())?.0 as _, pinned)?; }
            #[cfg(not(windows))] { return Err("跨 Windows 虚拟桌面驻留只能在 Windows 客户端设置".into()); }
            #[cfg(windows)] { let mut previous = previous; *previous = pinned; }
        }
    }
    let theme = match settings["appearance"].as_str().unwrap_or("dark") { "dark"=>Some(tauri::Theme::Dark),"light"=>Some(tauri::Theme::Light),_=>None };
    window.set_theme(theme).map_err(|error|error.to_string())?;
    // 隐藏光标仅作用于前端药丸悬停区；原生窗口必须保留编辑和设置区光标。
    window.set_cursor_visible(true).map_err(|error|error.to_string())?;
    state.window.lock().map_err(|_| "窗口状态不可用")?.configure(&window,settings["followPointer"].as_bool().unwrap_or(true),settings["hideInFullscreen"].as_bool().unwrap_or(false))?;
    Ok(())
}

#[tauri::command]
async fn get_launch_at_login(window: tauri::WebviewWindow) -> Result<bool, String> { owner(&window)?; tauri::async_runtime::spawn_blocking(platform::get_launch_at_login).await.map_err(|error|error.to_string())? }
#[tauri::command]
async fn set_launch_at_login(window: tauri::WebviewWindow, enabled: bool) -> Result<bool, String> { owner(&window)?; tauri::async_runtime::spawn_blocking(move ||platform::set_launch_at_login(enabled)).await.map_err(|error|error.to_string())? }

#[tauri::command]
async fn copy_files(window: tauri::WebviewWindow, paths: Vec<String>) -> Result<(), String> {
    owner(&window)?;
    let paths = tauri::async_runtime::spawn_blocking(move || files::inspect_files(&paths)).await.map_err(|error|error.to_string())??;
    #[cfg(windows)] { platform::win::copy_files(window.hwnd().map_err(|error|error.to_string())?.0 as _, &paths.into_iter().map(|file|file.path).collect::<Vec<_>>()) }
    #[cfg(not(windows))] { let _ = paths; Err("文件剪贴板仅在 Windows 客户端提供".into()) }
}

#[tauri::command]
async fn start_file_drag(window: tauri::WebviewWindow, app: tauri::AppHandle, state: tauri::State<'_, DesktopState>, paths: Vec<String>) -> Result<(), String> {
    owner(&window)?;
    let store = state.store.clone();
    let paths = tauri::async_runtime::spawn_blocking(move || {
        if paths.is_empty() || paths.len() > 128 { return Err("请选择 1–128 个文件".to_string()); }
        let content = store.read()?.ok_or("文件架尚未保存")?;
        let saved: serde_json::Value = serde_json::from_str(&content).map_err(|error|error.to_string())?;
        if paths.iter().any(|path| !saved["files"].as_array().is_some_and(|files|files.iter().any(|file|file["path"].as_str().is_some_and(|saved|saved.eq_ignore_ascii_case(path))))) { return Err("只能拖出已保存到文件架的文件".into()); }
        files::inspect_files(&paths).map(|items|items.into_iter().map(|item|PathBuf::from(item.path)).collect::<Vec<_>>())
    }).await.map_err(|error|error.to_string())??;
    #[cfg(windows)] {
        let (sender, receiver) = tokio::sync::oneshot::channel();
        app.run_on_main_thread(move || {
            let result = (|| {
                let app = window.app_handle(); let state = app.state::<DesktopState>();
                if unsafe { windows_sys::Win32::UI::Input::KeyboardAndMouse::GetAsyncKeyState(windows_sys::Win32::UI::Input::KeyboardAndMouse::VK_LBUTTON as i32) } as u16 & 0x8000 == 0 { return Err("请按住鼠标左键拖动文件架中的文件".into()); }
                { let mut controller = state.window.lock().map_err(|_| "窗口状态不可用")?; if !controller.owns_display() { return Err("当前窗口已让位".into()); } controller.set_interaction(&window,true)?; }
                let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| drag::start_drag(&window,drag::DragItem::Files(paths),drag::Image::Raw(include_bytes!("../icons/32x32.png").to_vec()),|_,_|{},drag::Options::default())))
                    .map_err(|_| "Windows 文件拖放初始化失败".to_string()).and_then(|result|result.map_err(|error|format!("文件拖放失败：{error}")));
                let release = state.window.lock().map_err(|_| "窗口状态不可用")?.set_interaction(&window,false);
                result?; release?; Ok(())
            })(); let _ = sender.send(result);
        }).map_err(|error|error.to_string())?;
        receiver.await.map_err(|_| "文件拖放回调已结束".to_string())?
    }
    #[cfg(not(windows))] { let _ = (app,paths); Err("文件拖出仅在 Windows 客户端提供".into()) }
}

#[tauri::command]
async fn list_gifs(window: tauri::WebviewWindow, state: tauri::State<'_, DesktopState>) -> Result<Vec<GifInfo>, String> { owner(&window)?; let gifs=state.gifs.clone(); tauri::async_runtime::spawn_blocking(move ||gifs.list()).await.map_err(|error|error.to_string())? }
#[tauri::command]
async fn import_gif(window: tauri::WebviewWindow, app: tauri::AppHandle, state: tauri::State<'_, DesktopState>) -> Result<Option<GifInfo>, String> {
    owner(&window)?; let gifs=state.gifs.clone();
    tauri::async_runtime::spawn_blocking(move || { let Some(file)=app.dialog().file().set_title("导入 GIF 副本").add_filter("GIF", &["gif"]).blocking_pick_file() else { return Ok(None); }; let path=file.into_path().map_err(|_|"请选择本地 GIF 文件")?; gifs.import(&path.to_string_lossy()).map(Some) }).await.map_err(|error|error.to_string())?
}
#[tauri::command]
async fn read_gif(window: tauri::WebviewWindow, state: tauri::State<'_, DesktopState>, id: String) -> Result<String, String> { owner(&window)?; let gifs=state.gifs.clone(); tauri::async_runtime::spawn_blocking(move ||gifs.read(&id)).await.map_err(|error|error.to_string())? }
#[tauri::command]
async fn delete_gif(window: tauri::WebviewWindow, state: tauri::State<'_, DesktopState>, id: String) -> Result<(), String> { owner(&window)?; let gifs=state.gifs.clone(); tauri::async_runtime::spawn_blocking(move ||gifs.delete(&id)).await.map_err(|error|error.to_string())? }

#[tauri::command]
async fn open_calendar(window: tauri::WebviewWindow, state: tauri::State<'_, DesktopState>, path: Option<String>) -> Result<(), String> {
    owner(&window)?; let store=state.store.clone();
    tauri::async_runtime::spawn_blocking(move || {
        if let Some(path) = &path { let content=store.read()?.ok_or("尚未导入日历")?; let saved:serde_json::Value=serde_json::from_str(&content).map_err(|error|error.to_string())?;
            if !saved["calendars"].as_array().is_some_and(|items|items.iter().any(|item|item["path"].as_str().is_some_and(|source|source.eq_ignore_ascii_case(path)))) { return Err("只能打开已导入的日历原件".into()); } }
        platform::open_calendar(path.as_deref())
    }).await.map_err(|error|error.to_string())?
}
#[tauri::command]
fn play_reminder_sound(window: tauri::WebviewWindow, sound: String) -> Result<(), String> { owner(&window)?; platform::play_sound(&sound) }

#[tauri::command]
async fn open_media_player(window: tauri::WebviewWindow, state: tauri::State<'_, DesktopState>, source_id:String, session_token:String) -> Result<(), String> { owner(&window)?; state.media.open_player(&source_id,&session_token).await }
#[tauri::command]
async fn check_updates(window: tauri::WebviewWindow, state: tauri::State<'_, DesktopState>, force:bool) -> Result<UpdateStatus,String> { owner(&window)?; state.updates.check(force).await }
#[tauri::command]
async fn open_update_page(window: tauri::WebviewWindow, state: tauri::State<'_, DesktopState>) -> Result<(),String> { owner(&window)?; let url=state.updates.latest_url()?.ok_or("尚无已验证的 Windows 更新页面，请先检查更新")?; tauri::async_runtime::spawn_blocking(move ||platform::open_update_url(&url)).await.map_err(|error|error.to_string())? }

#[tauri::command]
async fn island_get_preferences(window: tauri::WebviewWindow, state: tauri::State<'_, DesktopState>) -> Result<IntegrationPreferences,String> {
    owner(&window)?; let Some(link)=state.link.clone() else { return Ok(IntegrationPreferences::default()); };
    tauri::async_runtime::spawn_blocking(move ||link.preferences()).await.map_err(|error|error.to_string())?
}
#[tauri::command]
async fn island_set_preferences(window: tauri::WebviewWindow, state: tauri::State<'_, DesktopState>, preferences:IntegrationPreferences) -> Result<IntegrationPreferences,String> {
    owner(&window)?; let link=state.link.clone().ok_or("共享联动设置仅在 Windows 客户端提供")?;
    tauri::async_runtime::spawn_blocking(move ||link.set_preferences(preferences)).await.map_err(|error|error.to_string())?
}

#[tauri::command]
fn resize_island(window: tauri::WebviewWindow, state: tauri::State<DesktopState>, width: f64, height: f64, expanded: bool) -> Result<WindowReport, String> {
    owner(&window)?;
    state.window.lock().map_err(|_| "窗口状态不可用")?.resize(&window, width, height, expanded)
}

#[tauri::command]
fn configure_window(window: tauri::WebviewWindow, state: tauri::State<DesktopState>, follow_pointer: bool, hide_in_fullscreen: bool) -> Result<WindowReport, String> {
    owner(&window)?;
    state.window.lock().map_err(|_| "窗口状态不可用")?.configure(&window, follow_pointer, hide_in_fullscreen)
}

#[tauri::command]
fn focus_input(window: tauri::WebviewWindow, state: tauri::State<DesktopState>) -> Result<(), String> {
    owner(&window)?;
    if !state.window.lock().map_err(|_| "窗口状态不可用")?.owns_display() { return Err("XNook 当前已经让位".into()); }
    window.set_focusable(true).map_err(|error| error.to_string())?;
    window.set_focus().map_err(|error| error.to_string())
}

#[tauri::command]
fn drag_island(window: tauri::WebviewWindow, state: tauri::State<DesktopState>, phase: String) -> Result<WindowReport, String> {
    owner(&window)?;
    let mut controller = state.window.lock().map_err(|_| "窗口状态不可用")?;
    if !controller.owns_display() { return Err("XNook 当前已经让位".into()); }
    match phase.as_str() {
        "begin" => controller.begin_drag(&window), "update" => controller.update_drag(&window), "end" => controller.end_drag(&window),
        _ => Err("未知窗口拖动阶段".into()),
    }
}

#[tauri::command]
async fn pick_files(window: tauri::WebviewWindow, app: tauri::AppHandle) -> Result<Option<Vec<FileInfo>>, String> {
    owner(&window)?;
    tauri::async_runtime::spawn_blocking(move || {
        let Some(selected) = app.dialog().file().set_title("添加文件到 XNook").blocking_pick_files() else { return Ok(None); };
        let paths: Result<Vec<String>, String> = selected.into_iter().map(|file| file.into_path().map(|path| path.to_string_lossy().into_owned()).map_err(|_| "请选择本地文件".into())).collect();
        files::inspect_files(&paths?).map(Some)
    }).await.map_err(|error| error.to_string())?
}

#[tauri::command]
async fn inspect_files(window: tauri::WebviewWindow, paths: Vec<String>) -> Result<Vec<FileInfo>, String> {
    owner(&window)?;
    tauri::async_runtime::spawn_blocking(move || files::inspect_files(&paths)).await.map_err(|error| error.to_string())?
}

#[tauri::command]
async fn file_statuses(window: tauri::WebviewWindow, paths: Vec<String>) -> Result<Vec<FileStatus>, String> {
    owner(&window)?;
    tauri::async_runtime::spawn_blocking(move || files::file_statuses(&paths)).await.map_err(|error| error.to_string())?
}

#[tauri::command]
fn take_tray_actions(window: tauri::WebviewWindow, state: tauri::State<DesktopState>) -> Result<Vec<TrayAction>, String> {
    owner(&window)?;
    Ok(std::mem::take(&mut *state.tray_actions.lock().map_err(|_| "托盘动作状态不可用")?))
}

#[tauri::command]
async fn open_file(window: tauri::WebviewWindow, path: String) -> Result<(), String> {
    owner(&window)?;
    tauri::async_runtime::spawn_blocking(move || files::open_file(&path, false)).await.map_err(|error| error.to_string())?
}

#[tauri::command]
async fn reveal_file(window: tauri::WebviewWindow, path: String) -> Result<(), String> {
    owner(&window)?;
    tauri::async_runtime::spawn_blocking(move || files::open_file(&path, true)).await.map_err(|error| error.to_string())?
}

#[tauri::command]
async fn export_note(window: tauri::WebviewWindow, app: tauri::AppHandle, title: String, content: String, format: String) -> Result<bool, String> {
    owner(&window)?; let filename = files::export_name(&title, &format)?;
    if content.len() > files::MAX_NOTE_BYTES { return Err("笔记超过 8 MiB 导出上限".into()); }
    tauri::async_runtime::spawn_blocking(move || {
        let Some(destination) = app.dialog().file().set_title("导出笔记").set_file_name(filename).add_filter("笔记", &[format.as_str()]).blocking_save_file() else { return Ok(false); };
        let path = destination.into_path().map_err(|_| "请选择本地文件")?;
        files::export_note(&path, &content)?; Ok(true)
    }).await.map_err(|error| error.to_string())?
}

#[tauri::command]
async fn pick_calendar(window: tauri::WebviewWindow, app: tauri::AppHandle) -> Result<Option<CalendarFile>, String> {
    owner(&window)?;
    tauri::async_runtime::spawn_blocking(move || {
        let Some(destination) = app.dialog().file().set_title("导入本地日历").add_filter("iCalendar", &["ics"]).blocking_pick_file() else { return Ok(None); };
        let path = destination.into_path().map_err(|_| "请选择本地日历文件")?;
        files::read_calendar(&path.to_string_lossy()).map(Some)
    }).await.map_err(|error| error.to_string())?
}

#[tauri::command]
async fn read_calendar(window: tauri::WebviewWindow, path: String) -> Result<CalendarFile, String> {
    owner(&window)?;
    tauri::async_runtime::spawn_blocking(move || files::read_calendar(&path)).await.map_err(|error| error.to_string())?
}

#[tauri::command]
async fn media_snapshot(window: tauri::WebviewWindow, state: tauri::State<'_, DesktopState>, preferred_source_id: Option<String>) -> Result<MediaSnapshot, String> {
    owner(&window)?; Ok(state.media.snapshot(preferred_source_id.as_deref()).await)
}

#[tauri::command]
async fn media_control(window: tauri::WebviewWindow, state: tauri::State<'_, DesktopState>, source_id: String, session_token: String, action: String, position: Option<f64>) -> Result<(), String> {
    owner(&window)?; state.media.control(&source_id, &session_token, &action, position).await
}

#[tauri::command]
async fn lookup_lyrics(window: tauri::WebviewWindow, state: tauri::State<'_, DesktopState>, title: String, artist: String, album: String, duration: Option<f64>) -> Result<Vec<LyricsCandidate>, String> {
    owner(&window)?; state.lyrics.lookup(&title, &artist, &album, duration).await
}

#[tauri::command]
async fn island_peer_status(window: tauri::WebviewWindow, state: tauri::State<'_, DesktopState>) -> Result<PeerStatus, String> {
    owner(&window)?;
    let Some(link) = state.link.clone() else { return Ok(PeerStatus { installed: false, running: false, compatible: false, detail: "双应用联动仅在 Windows 客户端可用".into() }); };
    tauri::async_runtime::spawn_blocking(move || link.peer_status()).await.map_err(|error| error.to_string())?
}

#[tauri::command]
async fn switch_island(window: tauri::WebviewWindow, state: tauri::State<'_, DesktopState>) -> Result<(), String> {
    owner(&window)?;
    let link = state.link.clone().ok_or("双应用联动仅在 Windows 客户端可用")?;
    tauri::async_runtime::spawn_blocking(move || link.switch_to_peer(Duration::from_secs(8))).await.map_err(|error| error.to_string())?
}

#[tauri::command]
fn begin_exit(window: tauri::WebviewWindow, app: tauri::AppHandle) -> Result<(), String> {
    owner(&window)?;
    request_exit(&app); Ok(())
}

#[tauri::command]
fn cancel_exit(window: tauri::WebviewWindow, state: tauri::State<DesktopState>) -> Result<(), String> {
    owner(&window)?;
    state.exit.cancel_save()
}

#[tauri::command]
fn confirm_exit(window: tauri::WebviewWindow, app: tauri::AppHandle, state: tauri::State<DesktopState>) -> Result<(), String> {
    owner(&window)?;
    state.exit.confirm_saved()?;
    app.exit(0); Ok(())
}

fn request_exit(app: &tauri::AppHandle) {
    if let Some(state) = app.try_state::<DesktopState>() {
        match state.exit.request() {
            ExitRequest::SaveFirst => {
                if let Err(error) = app.emit_to("main", "request-exit", ()) { let _ = state.exit.cancel_save(); let _ = app.emit_to("main", "native-error", format!("无法请求安全退出：{error}")); }
            }
            ExitRequest::AskToForce => {
                let callback_app = app.clone();
                app.dialog().message("上一次退出请求尚未完成。强制退出可能放弃未保存修改，是否仍要退出？")
                    .title("确认强制退出 XNook")
                    .kind(MessageDialogKind::Warning)
                    .buttons(MessageDialogButtons::OkCancelCustom("强制退出".into(), "继续使用".into()))
                    .show(move |confirmed| {
                        if let Some(state) = callback_app.try_state::<DesktopState>() {
                            if state.exit.resolve_force(confirmed) { callback_app.exit(0); }
                        }
                    });
            }
            ExitRequest::Ignore => {}
        }
    }
}

fn request_show(app: &tauri::AppHandle) {
    request_show_with_action(app, None);
}

fn complete_tray_show(app: &tauri::AppHandle, action: Option<TrayAction>) {
    let Some(action) = action else { return; };
    let Some(state) = app.try_state::<DesktopState>() else { return; };
    match state.tray_actions.lock() {
        Ok(mut pending) => push_tray_action(&mut pending, action),
        Err(_) => { let _ = app.emit_to("main", "native-error", "托盘动作状态不可用"); return; }
    }
    // 前端先订阅再领取队列，既接收隐藏窗口事件，也补领启动前的动作。
    if let Err(error) = app.emit_to("main", "tray-actions-pending", ()) {
        let _ = app.emit_to("main", "native-error", format!("无法通知托盘动作：{error}"));
    }
}

fn request_show_with_action(app: &tauri::AppHandle, action: Option<TrayAction>) {
    let Some(state) = app.try_state::<DesktopState>() else { return; };
    if let Some(link) = state.link.clone() {
        let app = app.clone();
        tauri::async_runtime::spawn_blocking(move || {
            match link.request_show(Duration::from_secs(8)) {
                Ok(()) => complete_tray_show(&app, action),
                Err(error) => { let _ = app.emit_to("main", "island-link-error", error); }
            }
        });
    } else if let Some(window) = app.get_webview_window("main") {
        let result = state.window.lock().map_err(|_| "窗口状态不可用".to_string()).and_then(|mut controller| controller.show_owned(&window));
        match result {
            Ok(()) => complete_tray_show(app, action),
            Err(error) => { let _ = app.emit_to("main", "native-error", error); }
        }
    }
}

fn callback_window(app: &tauri::AppHandle, show: bool) -> Result<(), String> {
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    let task_app = app.clone();
    app.run_on_main_thread(move || {
        let result = (|| {
            let window = task_app.get_webview_window("main").ok_or("XNook 主窗口不可用")?;
            if show {
                task_app.state::<DesktopState>().window.lock().map_err(|_| "窗口状态不可用")?.show_owned(&window)
            } else { window.hide().map_err(|error| error.to_string()) }
        })();
        let _ = sender.send(result);
    }).map_err(|error| error.to_string())?;
    receiver.recv_timeout(Duration::from_secs(2)).map_err(|_| "窗口显示确认超时".to_string())?
}

fn data_directory(app: &tauri::App) -> Result<PathBuf, String> {
    if let Some(path) = std::env::var_os("XNOOK_DATA_DIR") {
        let path = PathBuf::from(path);
        if !path.is_absolute() { return Err("XNOOK_DATA_DIR 必须是绝对路径".into()); }
        Ok(path)
    } else { app.path().app_data_dir().map_err(|error| error.to_string()) }
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| request_show(app)))
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![read_store, write_store, resize_island, configure_window, focus_input, drag_island,
            pick_files, inspect_files, file_statuses, open_file, reveal_file, export_note, pick_calendar, read_calendar, media_snapshot, media_control,
            lookup_lyrics, island_peer_status, switch_island, begin_exit, cancel_exit, confirm_exit, recover_store, apply_preferences, get_launch_at_login, set_launch_at_login,
            copy_files, start_file_drag, list_gifs, import_gif, read_gif, delete_gif, open_calendar, play_reminder_sound, open_media_player,
            check_updates, open_update_page, island_get_preferences, island_set_preferences, take_tray_actions])
        .on_window_event(|window, event| {
            if window.label() != "main" { return; }
            match event {
                tauri::WindowEvent::Focused(false) => { let _ = window.set_focusable(false); }
                tauri::WindowEvent::CloseRequested { api, .. } => { api.prevent_close(); request_exit(window.app_handle()); }
                _ => {}
            }
        })
        .setup(|app| {
            let data = data_directory(app).map_err(std::io::Error::other)?;
            #[cfg(windows)]
            let link = Some(Link::open(Identity::XNook).map_err(std::io::Error::other)?);
            #[cfg(not(windows))]
            let link: Option<Arc<Link>> = None;
            let mut controller = WindowController::default();
            if let Some(link) = &link { controller.set_link(link.clone()); }
            app.manage(DesktopState { store: Arc::new(Store::new(data.join("store.json"))), window: Mutex::new(controller), media: MediaService::default(),
                lyrics: LyricsClient::new_with_directory(data.clone()).map_err(std::io::Error::other)?, gifs: Arc::new(GifLibrary::new(&data)), updates: UpdateService::new(data).map_err(std::io::Error::other)?, pinned: Mutex::new(false), link: link.clone(), exit: ExitPolicy::default(), tray_actions: Mutex::new(Vec::new()) });
            use tauri::{menu::{Menu, MenuItem}, tray::TrayIconBuilder};
            let show = MenuItem::with_id(app, "show", "显示 XNook", true, None::<&str>)?;
            let settings = MenuItem::with_id(app, "settings", "设置…", true, None::<&str>)?;
            let updates = MenuItem::with_id(app, "updates", "检查更新…", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "退出 XNook", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show, &settings, &updates, &quit])?;
            let mut tray = TrayIconBuilder::new().tooltip("XNook").menu(&menu).on_menu_event(|app, event| match event.id.as_ref() {
                "show" => request_show(app), "settings" => request_show_with_action(app, Some(TrayAction::Settings)),
                "updates" => request_show_with_action(app, Some(TrayAction::CheckUpdates)), "quit" => request_exit(app), _ => {}
            });
            if let Some(icon) = app.default_window_icon() { tray = tray.icon(icon.clone()); }
            tray.build(app)?;
            if let Some(link) = link {
                let show_app = app.handle().clone(); let hide_app = app.handle().clone(); let error_app = app.handle().clone();
                link.start(Callbacks { show: Arc::new(move || callback_window(&show_app, true)), hide: Arc::new(move || callback_window(&hide_app, false)),
                    on_error: Arc::new(move |error| { let _ = error_app.emit_to("main", "island-link-error", error); }) }).map_err(std::io::Error::other)?;
            }
            let handle = app.handle().clone();
            let calendar_app = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                // WebView2 隐藏后可能节流 JS 计时器；普通运行时计时不要求系统从睡眠唤醒。
                loop {
                    tokio::time::sleep(Duration::from_secs(30)).await;
                    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
                        .unwrap_or_default().as_millis() as u64;
                    if calendar_app.emit_to("main", "calendar-tick", now).is_err() { break; }
                }
            });
            tauri::async_runtime::spawn(async move {
                let mut wait = Duration::from_millis(500); let mut last_error = String::new();
                loop {
                    tokio::time::sleep(wait).await;
                    let (sender, receiver) = tokio::sync::oneshot::channel(); let task_app = handle.clone();
                    // 窗口 getter 会等待 UI 线程，不能在后台持有窗口锁再调用。
                    if handle.run_on_main_thread(move || {
                        let result = (|| {
                            let window = task_app.get_webview_window("main").ok_or("主窗口已关闭")?;
                            task_app.state::<DesktopState>().window.lock().map_err(|_| "窗口状态不可用")?.poll(&window)
                        })(); let _ = sender.send(result);
                    }).is_err() { break; }
                    let Ok(result) = receiver.await else { break; };
                    match result {
                        Ok(report) => { wait = Duration::from_millis(if report.dragging {16} else {500}); last_error.clear(); }
                        Err(error) => { if error != last_error { let _ = handle.emit_to("main", "native-error", &error); last_error = error; } }
                    }
                }
            });
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("XNook 桌面运行时初始化失败")
        .run(|app, event| match event {
            tauri::RunEvent::ExitRequested { api, .. } => {
                if !app.state::<DesktopState>().exit.authorized() { api.prevent_exit(); request_exit(app); }
            }
            tauri::RunEvent::Exit => { if let Some(link) = &app.state::<DesktopState>().link { link.shutdown(); } }
            _ => {}
        });
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn tray_actions_wait_for_frontend_and_repeated_clicks_are_bounded() {
        let mut pending = Vec::new();
        for _ in 0..100 { push_tray_action(&mut pending, TrayAction::Settings); }
        push_tray_action(&mut pending, TrayAction::CheckUpdates);
        assert_eq!(pending.len(), 2);
        let claimed = std::mem::take(&mut pending);
        assert!(pending.is_empty());
        assert_eq!(serde_json::to_value(claimed).unwrap(), serde_json::json!(["settings", "checkUpdates"]));
    }
}
