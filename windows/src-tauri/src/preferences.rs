use serde_json::Value;

pub fn validate(settings: &Value) -> Result<(), String> {
    let object = settings.as_object().ok_or("设置必须是对象")?;
    for key in ["followPointer", "hideInFullscreen", "lyricsEnabled"] {
        if !settings[key].is_boolean() { return Err(format!("设置 {key} 必须为布尔值")); }
    }
    for key in ["showHistory", "hoverExpand", "scrollExpand", "reduceMotion", "magnetic", "hideCursor", "showTicker", "reminderEnabled", "quietHoursEnabled", "autoRefreshCalendars", "autoCheckUpdates", "launchAtLogin", "visibleOnAllDesktops"] {
        if object.get(key).is_some_and(|value| !value.is_boolean()) { return Err(format!("设置 {key} 必须为布尔值")); }
    }
    for (key, min, max, integer) in [("panelWidth",160.0,1200.0,false),("panelHeight",160.0,1000.0,false),("islandWidth",40.0,600.0,false),("islandHeight",8.0,120.0,false),("lyricsIslandWidth",60.0,800.0,false),("lyricsIslandHeight",10.0,160.0,false),("historyLimit",1.0,20.0,true),("hoverExitDelayMs",0.0,10000.0,true),("idleCollapseMs",0.0,600000.0,true),("tickerSpeed",1.0,200.0,false),("reminderLeadMinutes",0.0,1440.0,true)] {
        if object.get(key).is_some_and(|value| !value.as_f64().is_some_and(|n| n.is_finite() && n >= min && n <= max && (!integer || n.fract() == 0.0))) { return Err(format!("设置 {key} 超出允许范围")); }
    }
    for (key, allowed) in [("appearance", vec!["dark","light","system"]),("language",vec!["auto","zh","en"]),("jellyIntensity",vec!["off","low","medium","high"]),("reminderSound",vec!["default","asterisk","exclamation"])] {
        if object.get(key).is_some_and(|value| !value.as_str().is_some_and(|text| allowed.contains(&text))) { return Err(format!("设置 {key} 的选项无效")); }
    }
    for key in ["quietHoursStart", "quietHoursEnd"] {
        if object.get(key).is_some_and(|value| !value.as_str().is_some_and(valid_time)) { return Err(format!("设置 {key} 必须为 HH:mm")); }
    }
    for key in ["preferredMediaSourceId", "selectedGifId"] {
        if object.get(key).is_some_and(|value| !value.is_null() && !value.as_str().is_some_and(|id| crate::media_selection::validate_source_id(id).is_ok())) { return Err(format!("设置 {key} 标识无效")); }
    }
    if let Some(widgets) = object.get("enabledWidgets") {
        let widgets = widgets.as_array().ok_or("工具列表必须是数组")?;
        let mut seen = std::collections::HashSet::new();
        if widgets.len() > 4 || !widgets.iter().all(|value| value.as_str().is_some_and(|name| ["media","calendar","notes","files"].contains(&name) && seen.insert(name))) { return Err("工具列表含未知或重复工具".into()); }
    }
    Ok(())
}

fn valid_time(text: &str) -> bool {
    let bytes = text.as_bytes();
    bytes.len() == 5 && bytes[2] == b':' && [bytes[0],bytes[1],bytes[3],bytes[4]].iter().all(u8::is_ascii_digit)
        && (bytes[0]-b'0') * 10 + bytes[1]-b'0' < 24 && (bytes[3]-b'0') * 10 + bytes[4]-b'0' < 60
}

#[cfg(test)]
mod tests {
    use super::*;
    fn old() -> Value { serde_json::json!({"followPointer":true,"hideInFullscreen":true,"lyricsEnabled":true}) }
    #[test] fn old_settings_and_valid_new_values_are_accepted() {
        let mut value = old(); assert!(validate(&value).is_ok());
        value["appearance"] = "system".into(); value["panelWidth"] = 1200.into(); value["idleCollapseMs"] = 0.into(); value["enabledWidgets"] = serde_json::json!([]); value["quietHoursStart"] = "23:59".into();
        assert!(validate(&value).is_ok());
    }
    #[test] fn new_settings_reject_wrong_types_ranges_and_duplicate_widgets() {
        for (key, invalid) in [("launchAtLogin",serde_json::json!("true")),("panelWidth",serde_json::json!(159)),("historyLimit",serde_json::json!(1.5)),("appearance",serde_json::json!("blue")),("quietHoursEnd",serde_json::json!("24:00")),("enabledWidgets",serde_json::json!(["media","media"])),("selectedGifId",serde_json::json!(""))] {
            let mut value = old(); value[key] = invalid; assert!(validate(&value).is_err(), "{key}");
        }
    }
    #[test]
    fn compact_mac_size_limits_and_existing_windows_values_are_accepted() {
        for (key, min, previous_min, max) in [("panelWidth",160.0,360.0,1200.0),("panelHeight",160.0,360.0,1000.0),
            ("islandWidth",40.0,180.0,600.0),("islandHeight",8.0,36.0,120.0),("lyricsIslandWidth",60.0,200.0,800.0),("lyricsIslandHeight",10.0,48.0,160.0)] {
            for size in [min, min + 0.25, previous_min, max] {
                let mut value = old(); value[key] = serde_json::json!(size);
                assert!(validate(&value).is_ok(), "{key}: {size}");
            }
            for size in [min - 0.01, max + 0.01] {
                let mut value = old(); value[key] = serde_json::json!(size);
                assert!(validate(&value).is_err(), "{key}: {size}");
            }
        }
    }
}
