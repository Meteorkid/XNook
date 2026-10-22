pub fn file_drop_bytes(paths: &[String]) -> Result<Vec<u8>, String> {
    if paths.is_empty() || paths.len() > 128 { return Err("请选择 1–128 个文件".into()); }
    let mut data = vec![0u8; 20];
    data[..4].copy_from_slice(&20u32.to_le_bytes()); data[16..20].copy_from_slice(&1u32.to_le_bytes());
    for path in paths {
        crate::files::local_path(path)?;
        for unit in path.encode_utf16().chain(Some(0)) { data.extend_from_slice(&unit.to_le_bytes()); }
    }
    data.extend_from_slice(&0u16.to_le_bytes()); Ok(data)
}

pub fn get_launch_at_login() -> Result<bool, String> {
    #[cfg(windows)] { win::get_login() }
    #[cfg(not(windows))] { Err("Windows 登录项只能在 Windows 客户端读取".into()) }
}
pub fn set_launch_at_login(enabled: bool) -> Result<bool, String> {
    #[cfg(windows)] { win::set_login(enabled) }
    #[cfg(not(windows))] { let _ = enabled; Err("Windows 登录项只能在 Windows 客户端设置".into()) }
}
pub fn play_sound(sound: &str) -> Result<(), String> {
    if !["default","asterisk","exclamation"].contains(&sound) { return Err("提示音选项无效".into()); }
    #[cfg(windows)] { win::play_sound(sound) }
    #[cfg(not(windows))] { Err("Windows 提示音只能在 Windows 客户端播放".into()) }
}
pub fn open_calendar(path: Option<&str>) -> Result<(), String> {
    if let Some(path) = path { crate::files::read_calendar(path)?; return crate::files::open_file(path, false); }
    #[cfg(windows)] { win::shell_open("outlookcal:").map_err(|error|format!("系统没有可用的日历入口，请选择 ICS 原件打开：{error}")) }
    #[cfg(not(windows))] { Err("系统日历入口仅在 Windows 客户端提供".into()) }
}
pub fn open_update_url(url: &str) -> Result<(), String> {
    let prefix = "https://github.com/Meteorkid/XNook/releases/tag/";
    if !url.starts_with(prefix) || url.len() > 2048 || url[prefix.len()..].is_empty() || url.chars().any(|c| c.is_control() || c == '"' || c == '\\') { return Err("更新地址不是已验证的 XNook GitHub 发布页".into()); }
    #[cfg(windows)] { win::shell_open(url) }
    #[cfg(not(windows))] { Err("打开更新页面仅在 Windows 客户端提供".into()) }
}

pub fn matches_player_process(source: &str, executable: &str, app_id: Option<&str>) -> bool {
    if app_id.is_some_and(|id| id == source) { return true; }
    let normalized = executable.strip_prefix(r"\\?\").unwrap_or(executable);
    if source.eq_ignore_ascii_case(normalized) { return true; }
    !source.contains(['\\','/',':','!']) && source.to_ascii_lowercase().ends_with(".exe")
        && normalized.rsplit(['\\','/']).next().is_some_and(|name| name.eq_ignore_ascii_case(source))
}

#[cfg(windows)]
pub mod win {
    use super::*;
    use windows_sys::Win32::{Foundation::*, System::{Memory::*, Registry::*, DataExchange::*}, UI::WindowsAndMessaging::*};
    const RUN: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
    fn wide(text: &str) -> Vec<u16> { text.encode_utf16().chain(Some(0)).collect() }
    fn fail(error: u32) -> String { std::io::Error::from_raw_os_error(error as i32).to_string() }
    fn read_registry(root: HKEY, key: &str, name: &str, flags: u32) -> Result<Option<Vec<u8>>, String> {
        let key = wide(key); let name = wide(name); let mut size = 0;
        let code = unsafe { RegGetValueW(root,key.as_ptr(),name.as_ptr(),flags,std::ptr::null_mut(),std::ptr::null_mut(),&mut size) };
        if code == ERROR_FILE_NOT_FOUND { return Ok(None); } if code != ERROR_SUCCESS { return Err(fail(code)); }
        if size > 65536 { return Err("注册表数据超出上限".into()); }
        let mut bytes = vec![0; size as usize];
        let code = unsafe { RegGetValueW(root,key.as_ptr(),name.as_ptr(),flags,std::ptr::null_mut(),bytes.as_mut_ptr().cast(),&mut size) };
        if code != ERROR_SUCCESS { return Err(fail(code)); } bytes.truncate(size as usize); Ok(Some(bytes))
    }
    fn read_text(root: HKEY, key: &str, name: &str) -> Result<Option<String>, String> {
        read_registry(root,key,name,RRF_RT_REG_SZ)?.map(|bytes| {
            if bytes.len() % 2 != 0 { return Err("注册表字符串损坏".into()); }
            let units: Vec<_> = bytes.chunks_exact(2).map(|pair|u16::from_le_bytes([pair[0],pair[1]])).take_while(|unit|*unit != 0).collect();
            String::from_utf16(&units).map_err(|_| "注册表字符串编码无效".into())
        }).transpose()
    }
    fn login_command() -> Result<String, String> {
        let exe = std::env::current_exe().map_err(|error|error.to_string())?;
        let exe = exe.to_str().ok_or("应用路径编码无效")?;
        if exe.contains(['"','\0']) { return Err("应用路径无效".into()); } Ok(format!("\"{exe}\""))
    }
    fn disabled_by_windows() -> Result<bool, String> {
        Ok(read_registry(HKEY_CURRENT_USER,r"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run","XNook",RRF_RT_REG_BINARY)?.is_some_and(|bytes| bytes.first() == Some(&3)))
    }
    pub fn get_login() -> Result<bool, String> { Ok(read_text(HKEY_CURRENT_USER,RUN,"XNook")?.as_deref() == Some(login_command()?.as_str()) && !disabled_by_windows()?) }
    pub fn set_login(enabled: bool) -> Result<bool, String> {
        let expected = login_command()?;
        if read_text(HKEY_CURRENT_USER,RUN,"XNook")?.is_some_and(|current| current != expected) { return Err("同名登录项指向其他路径，已保留原项，请先在系统设置处理".into()); }
        if enabled && disabled_by_windows()? { return Err("Windows 已禁用此启动项，请先在系统“启动应用”设置中启用 XNook".into()); }
        let mut key = std::ptr::null_mut(); let path = wide(RUN);
        let code = unsafe { RegCreateKeyExW(HKEY_CURRENT_USER,path.as_ptr(),0,std::ptr::null(),REG_OPTION_NON_VOLATILE,KEY_SET_VALUE,std::ptr::null(),&mut key,std::ptr::null_mut()) };
        if code != ERROR_SUCCESS { return Err(fail(code)); }
        let name = wide("XNook");
        let code = if enabled { let data = wide(&expected); unsafe { RegSetValueExW(key,name.as_ptr(),0,REG_SZ,data.as_ptr().cast(),(data.len()*2) as u32) } }
            else { unsafe { RegDeleteValueW(key,name.as_ptr()) } };
        unsafe { RegCloseKey(key); }
        if code != ERROR_SUCCESS && !(code == ERROR_FILE_NOT_FOUND && !enabled) { return Err(fail(code)); }
        let actual = get_login()?; if actual != enabled { return Err("Windows 登录项状态未按请求生效".into()); } Ok(actual)
    }
    pub fn copy_files(hwnd: HWND, paths: &[String]) -> Result<(), String> {
        let bytes = file_drop_bytes(paths)?;
        unsafe {
            let memory = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT,bytes.len()); if memory.is_null() { return Err("无法分配文件剪贴板内存".into()); }
            let pointer = GlobalLock(memory); if pointer.is_null() { GlobalFree(memory); return Err("无法锁定文件剪贴板内存".into()); }
            std::ptr::copy_nonoverlapping(bytes.as_ptr(),pointer.cast(),bytes.len()); GlobalUnlock(memory);
            if OpenClipboard(hwnd) == 0 { GlobalFree(memory); return Err("剪贴板正被其他程序占用，请重试".into()); }
            let result = if EmptyClipboard() == 0 { Err("无法清空剪贴板".to_string()) }
                else if SetClipboardData(15,memory).is_null() { Err("无法写入 CF_HDROP 文件剪贴板".into()) } else { Ok(()) };
            CloseClipboard(); if result.is_err() { GlobalFree(memory); } result
        }
    }
    pub fn shell_open(target: &str) -> Result<(), String> {
        let operation = wide("open"); let target = wide(target);
        let result = unsafe { windows_sys::Win32::UI::Shell::ShellExecuteW(std::ptr::null_mut(),operation.as_ptr(),target.as_ptr(),std::ptr::null(),std::ptr::null(),SW_SHOWNORMAL) };
        if result as isize <= 32 { Err(format!("Windows 打开失败（{}）",result as isize)) } else { Ok(()) }
    }
    pub fn play_sound(sound: &str) -> Result<(), String> {
        let kind = match sound { "default" => MB_OK, "asterisk" => MB_ICONASTERISK, "exclamation" => MB_ICONEXCLAMATION, _ => return Err("提示音选项无效".into()) };
        if unsafe { windows_sys::Win32::System::Diagnostics::Debug::MessageBeep(kind) } == 0 { Err(std::io::Error::last_os_error().to_string()) } else { Ok(()) }
    }
    pub fn pin_window(hwnd: HWND, enabled: bool) -> Result<(), String> {
        let key = r"SOFTWARE\Microsoft\Windows NT\CurrentVersion";
        let build = read_text(HKEY_LOCAL_MACHINE,key,"CurrentBuildNumber")?.and_then(|text|text.parse::<u32>().ok()).ok_or("无法读取 Windows 版本")?;
        let revision = read_registry(HKEY_LOCAL_MACHINE,key,"UBR",RRF_RT_REG_DWORD)?.and_then(|bytes|bytes.get(..4).map(|bytes|u32::from_le_bytes(bytes.try_into().unwrap()))).unwrap_or(0);
        if build < 26100 || (build == 26100 && revision < 2605) { return Err("跨虚拟桌面驻留需要 Windows 11 24H2 26100.2605 或更新版本；当前系统未支持此适配".into()); }
        let window = windows_vd::Win32::Foundation::HWND(hwnd);
        if enabled { winvd::pin_window(window) } else { winvd::unpin_window(window) }.map_err(|error|format!("Windows 虚拟桌面接口不可用：{error:?}"))?;
        if winvd::is_pinned_window(window).map_err(|error|format!("无法验证虚拟桌面状态：{error:?}"))? != enabled { return Err("Windows 未应用虚拟桌面驻留状态".into()); } Ok(())
    }
    pub fn activate_player(source: &str) -> Result<(), String> {
        use windows_sys::Win32::{System::Threading::*, Storage::Packaging::Appx::GetApplicationUserModelId};
        struct Search<'a> { source: &'a str, windows: Vec<HWND> }
        unsafe extern "system" fn visit(hwnd: HWND, data: LPARAM) -> windows_sys::core::BOOL {
            let search = &mut *(data as *mut Search);
            if IsWindowVisible(hwnd) == 0 || !GetWindow(hwnd,GW_OWNER).is_null() { return 1; }
            let mut pid = 0; GetWindowThreadProcessId(hwnd,&mut pid); if pid == std::process::id() { return 1; }
            let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,0,pid); if process.is_null() { return 1; }
            let mut path = vec![0u16;32768]; let mut length = path.len() as u32;
            let executable = if QueryFullProcessImageNameW(process,0,path.as_mut_ptr(),&mut length) != 0 { String::from_utf16_lossy(&path[..length as usize]) } else { String::new() };
            let mut app_id = vec![0u16;4096]; let mut size = app_id.len() as u32;
            let app_id = if GetApplicationUserModelId(process,&mut size,app_id.as_mut_ptr()) == ERROR_SUCCESS { Some(String::from_utf16_lossy(&app_id[..size.saturating_sub(1) as usize])) } else { None };
            CloseHandle(process);
            if matches_player_process(search.source,&executable,app_id.as_deref()) { search.windows.push(hwnd); } 1
        }
        let mut search = Search { source, windows: Vec::new() };
        unsafe { EnumWindows(Some(visit), &mut search as *mut Search as LPARAM); }
        let window = search.windows.first().copied().ok_or("未找到与当前媒体来源一致的可见播放器窗口；请从任务栏打开")?;
        unsafe { if IsIconic(window) != 0 { ShowWindow(window,SW_RESTORE); } if SetForegroundWindow(window) == 0 { return Err("Windows 未允许激活播放器，请从任务栏打开".into()); } }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn clipboard_dropfiles_is_utf16_with_double_nul() {
        let path = if cfg!(windows) { "C:\\资料\\一.txt" } else { "/tmp/资料/一.txt" };
        let bytes = file_drop_bytes(&[path.into()]).unwrap(); assert_eq!(&bytes[..4],&20u32.to_le_bytes()); assert_eq!(&bytes[16..20],&1u32.to_le_bytes()); assert!(bytes.ends_with(&[0,0,0,0]));
        assert!(file_drop_bytes(&[]).is_err()); assert!(file_drop_bytes(&["bad\0path".into()]).is_err());
    }
    #[test] fn player_activation_matches_identity_not_titles_or_substrings() {
        assert!(matches_player_process("QQMusic.exe",r"C:\QQMusic\QQMusic.exe",None));
        assert!(!matches_player_process("QQMusic.exe",r"C:\other\FakeQQMusic.exe",None));
        assert!(matches_player_process("Package!App",r"C:\app.exe",Some("Package!App")));
        assert!(!matches_player_process("Package!App",r"C:\Package!App.exe",None));
    }
    #[test] fn arbitrary_update_urls_and_sound_names_are_rejected() {
        assert!(open_update_url("https://evil.example/x").is_err()); assert!(open_update_url("https://github.com/Meteorkid/XNook/releases/tag/").is_err()); assert!(play_sound("custom.exe").is_err());
    }
}
