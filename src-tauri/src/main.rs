mod codex;
mod models;
mod session;

use chrono::{DateTime, Datelike, Duration, Local};
use models::ProviderSnapshot;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Mutex,
};
use tauri::{
    menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu},
    tray::TrayIconBuilder,
    AppHandle, Manager,
};
use tauri_plugin_autostart::{MacosLauncher, ManagerExt};

struct AppState {
    client: reqwest::Client,
    snapshot: Mutex<Option<ProviderSnapshot>>,
    deepseek_snapshot: Mutex<Option<ProviderSnapshot>>,
    deepseek_error: Mutex<Option<String>>,
    display_mode: Mutex<DisplayMode>,
    refreshing: Mutex<bool>,
    deepseek_refreshing: Mutex<bool>,
}
#[derive(Clone, Copy, PartialEq)]
enum DisplayMode {
    Detailed,
    Compact,
    IconOnly,
}
static POLLING: AtomicBool = AtomicBool::new(false);
static QUOTA_POLLING: AtomicBool = AtomicBool::new(false);
const QUOTA_POLL_INTERVAL: std::time::Duration = std::time::Duration::from_secs(60);

fn reset_label_at(value: Option<&str>, now: DateTime<Local>) -> String {
    let Some(reset) = value
        .and_then(|v| DateTime::parse_from_rfc3339(v).ok())
        .map(|v| v.with_timezone(&Local))
    else {
        return "--".into();
    };
    let remaining = reset.signed_duration_since(now);
    if remaining <= Duration::zero() {
        "--".into()
    } else if remaining < Duration::hours(24) {
        reset.format("%H:%M").to_string()
    } else {
        ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
            [reset.weekday().num_days_from_monday() as usize]
            .into()
    }
}
fn summary(snapshot: Option<&ProviderSnapshot>) -> String {
    summary_at(snapshot, Local::now())
}
fn summary_at(snapshot: Option<&ProviderSnapshot>, now: DateTime<Local>) -> String {
    let Some(s) = snapshot.filter(|s| s.status == "ok") else {
        return "week -- · -- · --".into();
    };
    let percent = s
        .weekly_window
        .as_ref()
        .map(|w| format!("{:.0}%", w.remaining_percent))
        .unwrap_or_else(|| "--".into());
    let reset = reset_label_at(
        s.weekly_window
            .as_ref()
            .and_then(|w| w.resets_at.as_deref()),
        now,
    );
    let credits = active_reset_credit_count(s, now)
        .map(|n| format!("{n}次"))
        .unwrap_or_else(|| "--".into());
    format!("week {percent} · {reset} · {credits}")
}
fn active_reset_credit_count(snapshot: &ProviderSnapshot, now: DateTime<Local>) -> Option<u64> {
    if snapshot.reset_credit_expires_at.is_empty() {
        return snapshot.reset_credits;
    }
    snapshot
        .reset_credit_expires_at
        .iter()
        .filter_map(|value| DateTime::parse_from_rfc3339(value).ok())
        .any(|expiration| expiration.with_timezone(&Local) > now)
        .then_some(snapshot.reset_credits)
        .flatten()
}
fn balance_summary(snapshot: Option<&ProviderSnapshot>) -> Option<String> {
    let snapshot = snapshot.filter(|snapshot| snapshot.status == "ok")?;
    let balance = snapshot
        .balance
        .filter(|value| value.is_finite() && *value >= 0.0)?;
    let currency = snapshot.currency.as_deref()?;
    let amount = match currency {
        "CNY" => format!("¥{balance:.2}"),
        "USD" => format!("${balance:.2}"),
        _ => format!("{balance:.2} {currency}"),
    };
    Some(format!("{} 可用余额：{amount}", snapshot.display_name))
}
fn official_error_summary(snapshot: Option<&ProviderSnapshot>) -> Option<String> {
    let snapshot = snapshot.filter(|snapshot| snapshot.status != "ok")?;
    snapshot
        .message
        .as_ref()
        .map(|message| format!("CODEX：{message}"))
}
fn compact_summary(snapshot: Option<&ProviderSnapshot>) -> String {
    summary(snapshot)
        .split(" · ")
        .next()
        .unwrap_or("week --")
        .into()
}
fn tray_title(mode: DisplayMode, compact: &str, detailed: &str) -> String {
    match mode {
        DisplayMode::Detailed => detailed.into(),
        DisplayMode::Compact => compact.into(),
        DisplayMode::IconOnly => String::new(),
    }
}
fn status_light(value: Option<&serde_json::Value>) -> &'static str {
    let Some(value) = value.filter(|value| value.get("sessions").is_some()) else {
        return "⚪";
    };
    match value.get("state").and_then(|state| state.as_str()) {
        Some("running") => "🟡",
        Some("waiting") => "🟠",
        Some("completed") => "🟢",
        Some("failed") => "🔴",
        _ => "⚪",
    }
}
fn light(_snapshot: Option<&ProviderSnapshot>, _refreshing: bool) -> &'static str {
    if let Some(status) = session::live_status() {
        return match status {
            "running" => "🟡",
            "waiting" => "🟠",
            "completed" => "🟢",
            "failed" => "🔴",
            _ => "⚪",
        };
    }
    let path = dirs::home_dir().map(|home| home.join(".codex-bar/session-status.json"));
    let state = path
        .and_then(|path| std::fs::read_to_string(path).ok())
        .and_then(|raw| serde_json::from_str::<serde_json::Value>(&raw).ok());
    status_light(state.as_ref())
}
fn badge_icon(status: &str) -> tauri::image::Image<'static> {
    let base = tauri::image::Image::from_bytes(include_bytes!("../icons/32x32.png"))
        .expect("valid app icon");
    let width = base.width() as usize;
    let height = base.height() as usize;
    let mut rgba = base.rgba().to_vec();
    let color = match status {
        "🟡" => [250, 204, 21, 255],
        "🟠" => [249, 115, 22, 255],
        "🟢" => [34, 197, 94, 255],
        "🔴" => [239, 68, 68, 255],
        _ => [148, 163, 184, 255],
    };
    let cx = width.saturating_sub(5) as isize;
    let cy = height.saturating_sub(5) as isize;
    for y in -3..=3 {
        for x in -3..=3 {
            if x * x + y * y <= 9 {
                let px = cx + x;
                let py = cy + y;
                if px >= 0 && py >= 0 && (px as usize) < width && (py as usize) < height {
                    let index = (py as usize * width + px as usize) * 4;
                    rgba[index..index + 4].copy_from_slice(&color);
                }
            }
        }
    }
    tauri::image::Image::new_owned(rgba, width as u32, height as u32)
}
fn expiration_lines(snapshot: Option<&ProviderSnapshot>) -> Vec<String> {
    expiration_lines_at(snapshot, Local::now())
}
fn expiration_lines_at(snapshot: Option<&ProviderSnapshot>, now: DateTime<Local>) -> Vec<String> {
    snapshot
        .filter(|s| s.reset_credits != Some(0))
        .map(|s| {
            s.reset_credit_expires_at
                .iter()
                .filter_map(|value| {
                    let date = DateTime::parse_from_rfc3339(value)
                        .ok()?
                        .with_timezone(&Local);
                    (date > now).then_some(date)
                })
                .enumerate()
                .map(|(i, date)| {
                    let date = date.format("%Y/%m/%d %H:%M");
                    format!("第 {} 次 · {date} 到期", i + 1)
                })
                .collect()
        })
        .unwrap_or_default()
}

fn begin_refresh(refreshing: &mut bool) -> bool {
    if *refreshing {
        false
    } else {
        *refreshing = true;
        true
    }
}

fn finish_official_refresh(
    snapshot_slot: &Mutex<Option<ProviderSnapshot>>,
    refreshing: &Mutex<bool>,
    snapshot: ProviderSnapshot,
) {
    *snapshot_slot.lock().unwrap() = Some(snapshot);
    *refreshing.lock().unwrap() = false;
}

fn finish_deepseek_refresh(
    snapshot_slot: &Mutex<Option<ProviderSnapshot>>,
    error_slot: &Mutex<Option<String>>,
    refreshing: &Mutex<bool>,
    result: Result<ProviderSnapshot, &'static str>,
) {
    match result {
        Ok(snapshot) => {
            *snapshot_slot.lock().unwrap() = Some(snapshot);
            *error_slot.lock().unwrap() = None;
        }
        Err(message) => {
            *error_slot.lock().unwrap() = Some(message.into());
        }
    }
    *refreshing.lock().unwrap() = false;
}

fn refresh(app: &AppHandle) {
    start_status_polling(app.clone());
    let state = app.state::<AppState>();
    let refresh_official = begin_refresh(&mut state.refreshing.lock().unwrap());
    let refresh_deepseek = begin_refresh(&mut state.deepseek_refreshing.lock().unwrap());
    if !refresh_official && !refresh_deepseek {
        return;
    }
    update(app);
    if refresh_official {
        let official_app = app.clone();
        tauri::async_runtime::spawn(async move {
            let state = official_app.state::<AppState>();
            let official = codex::fetch_snapshot(&state.client).await;
            finish_official_refresh(&state.snapshot, &state.refreshing, official);
            update(&official_app);
        });
    }
    if refresh_deepseek {
        let deepseek_app = app.clone();
        tauri::async_runtime::spawn(async move {
            let state = deepseek_app.state::<AppState>();
            let result = codex::fetch_deepseek_balance(&state.client).await;
            finish_deepseek_refresh(
                &state.deepseek_snapshot,
                &state.deepseek_error,
                &state.deepseek_refreshing,
                result,
            );
            update(&deepseek_app);
        });
    }
}
fn start_status_polling(app: AppHandle) {
    if POLLING.swap(true, Ordering::Relaxed) {
        return;
    }
    std::thread::spawn(move || loop {
        std::thread::sleep(std::time::Duration::from_secs(1));
        update_title(&app);
    });
}
fn start_quota_polling(app: AppHandle) {
    if QUOTA_POLLING.swap(true, Ordering::Relaxed) {
        return;
    }
    std::thread::spawn(move || loop {
        std::thread::sleep(QUOTA_POLL_INTERVAL);
        refresh(&app);
    });
}
fn update_title(app: &AppHandle) {
    let state = app.state::<AppState>();
    let snapshot = state.snapshot.lock().unwrap().clone();
    let display_mode = *state.display_mode.lock().unwrap();
    let refreshing = *state.refreshing.lock().unwrap();
    let status = light(snapshot.as_ref(), refreshing);
    let tray = app.tray_by_id("main").unwrap();
    let _ = tray.set_title(Some(tray_title(
        display_mode,
        &compact_summary(snapshot.as_ref()),
        &summary(snapshot.as_ref()),
    )));
    let _ = tray.set_icon(Some(badge_icon(status)));
}
fn update(app: &AppHandle) {
    let state = app.state::<AppState>();
    let snapshot = state.snapshot.lock().unwrap().clone();
    let deepseek_snapshot = state.deepseek_snapshot.lock().unwrap().clone();
    let deepseek_error = state.deepseek_error.lock().unwrap().clone();
    let display_mode = *state.display_mode.lock().unwrap();
    let tray = app.tray_by_id("main").unwrap();
    update_title(app);
    let info =
        MenuItem::with_id(app, "info", summary(snapshot.as_ref()), false, None::<&str>).unwrap();
    let mut items: Vec<Box<dyn tauri::menu::IsMenuItem<tauri::Wry>>> = vec![Box::new(info)];
    if let Some(line) = official_error_summary(snapshot.as_ref()) {
        items.push(Box::new(
            MenuItem::with_id(app, "official-error", line, false, None::<&str>).unwrap(),
        ));
    }
    for (i, line) in expiration_lines(snapshot.as_ref()).iter().enumerate() {
        items.push(Box::new(
            MenuItem::with_id(app, format!("expiry-{i}"), line, false, None::<&str>).unwrap(),
        ));
    }
    if let Some(line) = balance_summary(deepseek_snapshot.as_ref()) {
        items.push(Box::new(
            MenuItem::with_id(app, "deepseek-balance", line, false, None::<&str>).unwrap(),
        ));
    }
    if let Some(message) = deepseek_error {
        items.push(Box::new(
            MenuItem::with_id(
                app,
                "deepseek-error",
                format!("DeepSeek：{message}"),
                false,
                None::<&str>,
            )
            .unwrap(),
        ));
    }
    items.push(Box::new(PredefinedMenuItem::separator(app).unwrap()));
    items.push(Box::new(
        MenuItem::with_id(app, "refresh", "立即刷新", true, None::<&str>).unwrap(),
    ));
    let detailed_item = CheckMenuItem::with_id(
        app,
        "detailed",
        "详细",
        true,
        display_mode == DisplayMode::Detailed,
        None::<&str>,
    )
    .unwrap();
    let compact_item = CheckMenuItem::with_id(
        app,
        "compact",
        "简略",
        true,
        display_mode == DisplayMode::Compact,
        None::<&str>,
    )
    .unwrap();
    let icon_item = CheckMenuItem::with_id(
        app,
        "icon",
        "仅图标",
        true,
        display_mode == DisplayMode::IconOnly,
        None::<&str>,
    )
    .unwrap();
    items.push(Box::new(
        Submenu::with_items(
            app,
            "显示方式",
            true,
            &[&detailed_item, &compact_item, &icon_item],
        )
        .unwrap(),
    ));
    let autostart = CheckMenuItem::with_id(
        app,
        "autostart",
        "开机启动",
        true,
        app.autolaunch().is_enabled().unwrap_or(false),
        None::<&str>,
    )
    .unwrap();
    items.push(Box::new(autostart));
    items.push(Box::new(PredefinedMenuItem::separator(app).unwrap()));
    items.push(Box::new(
        MenuItem::with_id(app, "quit", "退出", true, None::<&str>).unwrap(),
    ));
    let refs: Vec<&dyn tauri::menu::IsMenuItem<tauri::Wry>> =
        items.iter().map(|v| v.as_ref()).collect();
    let _ = tray.set_menu(Some(Menu::with_items(app, &refs).unwrap()));
}
fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_autostart::init(
            MacosLauncher::LaunchAgent,
            None,
        ))
        .setup(|app| {
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            let client = reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(12))
                .https_only(true)
                .redirect(codex::authenticated_redirect_policy())
                .user_agent("CodexBar/0.1")
                .build()?;
            app.manage(AppState {
                client,
                snapshot: Mutex::new(None),
                deepseek_snapshot: Mutex::new(None),
                deepseek_error: Mutex::new(None),
                display_mode: Mutex::new(DisplayMode::IconOnly),
                refreshing: Mutex::new(false),
                deepseek_refreshing: Mutex::new(false),
            });
            let mut tray = TrayIconBuilder::with_id("main")
                .tooltip("Codex Bar")
                .icon_as_template(false);
            if let Some(icon) = app.default_window_icon() {
                tray = tray.icon(icon.clone());
            }
            tray.on_menu_event(|app, event| match event.id.as_ref() {
                "refresh" => refresh(app),
                "detailed" => {
                    *app.state::<AppState>().display_mode.lock().unwrap() = DisplayMode::Detailed;
                    update(app);
                }
                "compact" => {
                    *app.state::<AppState>().display_mode.lock().unwrap() = DisplayMode::Compact;
                    update(app);
                }
                "icon" => {
                    *app.state::<AppState>().display_mode.lock().unwrap() = DisplayMode::IconOnly;
                    update(app);
                }
                "autostart" => {
                    let manager = app.autolaunch();
                    let _ = if manager.is_enabled().unwrap_or(false) {
                        manager.disable()
                    } else {
                        manager.enable()
                    };
                    update(app);
                }
                "quit" => app.exit(0),
                _ => {}
            })
            .build(app)?;
            update(app.handle());
            start_quota_polling(app.handle().clone());
            refresh(app.handle());
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("failed to run Codex Bar");
}

#[cfg(test)]
mod tests {
    use super::{
        balance_summary, begin_refresh, expiration_lines_at, finish_deepseek_refresh,
        finish_official_refresh, reset_label_at, status_light, summary_at, tray_title, DisplayMode,
        QUOTA_POLL_INTERVAL,
    };
    use crate::models::ProviderSnapshot;
    use chrono::{DateTime, Local};
    use std::sync::Mutex;

    #[test]
    fn quota_refreshes_once_per_minute_without_overlapping_requests() {
        assert_eq!(QUOTA_POLL_INTERVAL, std::time::Duration::from_secs(60));

        let mut refreshing = false;
        assert!(begin_refresh(&mut refreshing));
        assert!(!begin_refresh(&mut refreshing));
    }

    #[test]
    fn display_modes_never_put_session_light_in_the_title() {
        assert_eq!(
            tray_title(DisplayMode::Detailed, "week 68%", "week 68% · 周五 · 2次"),
            "week 68% · 周五 · 2次"
        );
        assert_eq!(
            tray_title(DisplayMode::Compact, "week 68%", "week 68% · 周五 · 2次"),
            "week 68%"
        );
        assert_eq!(
            tray_title(DisplayMode::IconOnly, "week 68%", "week 68% · 周五 · 2次"),
            ""
        );
    }

    #[test]
    fn legacy_status_without_sessions_is_not_shown_as_completed() {
        assert_eq!(
            status_light(Some(&serde_json::json!({"state": "completed"}))),
            "⚪"
        );
        assert_eq!(
            status_light(Some(
                &serde_json::json!({"state": "completed", "sessions": {}})
            )),
            "🟢"
        );
    }

    #[test]
    fn deepseek_balance_is_presented_without_replacing_the_official_summary() {
        let snapshot = ProviderSnapshot {
            display_name: "DeepSeek".into(),
            weekly_window: None,
            reset_credits: None,
            reset_credit_expires_at: vec![],
            status: "ok".into(),
            message: None,
            balance: Some(11.61),
            currency: Some("CNY".into()),
        };

        assert_eq!(
            balance_summary(Some(&snapshot)),
            Some("DeepSeek 可用余额：¥11.61".into())
        );
        assert_eq!(
            tray_title(DisplayMode::Compact, "week 68%", "ignored"),
            "week 68%"
        );
    }

    #[test]
    fn past_reset_timestamp_is_not_presented_as_a_future_clock_time() {
        let now = DateTime::parse_from_rfc3339("2026-08-11T08:00:00Z")
            .unwrap()
            .with_timezone(&Local);
        assert_eq!(reset_label_at(Some("2000-01-01T00:00:00Z"), now), "--");
    }

    #[test]
    fn menu_hides_expired_reset_credits_and_keeps_only_future_expirations() {
        let now = DateTime::parse_from_rfc3339("2026-08-11T08:00:00Z")
            .unwrap()
            .with_timezone(&Local);
        let expired = ProviderSnapshot {
            display_name: "CODEX".into(),
            weekly_window: None,
            reset_credits: Some(2),
            reset_credit_expires_at: vec![
                "2026-08-11T07:59:59Z".into(),
                "2026-08-11T08:00:00Z".into(),
            ],
            status: "ok".into(),
            message: None,
            balance: None,
            currency: None,
        };

        assert_eq!(summary_at(Some(&expired), now), "week -- · -- · --");
        assert!(expiration_lines_at(Some(&expired), now).is_empty());

        let mixed = ProviderSnapshot {
            reset_credit_expires_at: vec![
                "2026-08-11T07:59:59Z".into(),
                "2026-08-11T08:00:01Z".into(),
            ],
            ..expired
        };
        assert_eq!(summary_at(Some(&mixed), now), "week -- · -- · 2次");
        let lines = expiration_lines_at(Some(&mixed), now);
        assert_eq!(lines.len(), 1);
        assert!(lines[0].starts_with("第 1 次"));

        let exhausted = ProviderSnapshot {
            reset_credits: Some(0),
            ..mixed
        };
        assert!(expiration_lines_at(Some(&exhausted), now).is_empty());
    }

    #[test]
    fn official_result_is_published_while_deepseek_is_still_refreshing() {
        let official_slot = Mutex::new(None);
        let official_refreshing = Mutex::new(true);
        let deepseek_refreshing = Mutex::new(true);

        finish_official_refresh(
            &official_slot,
            &official_refreshing,
            ProviderSnapshot::failure("unavailable", "official error"),
        );

        assert!(official_slot.lock().unwrap().is_some());
        assert!(!*official_refreshing.lock().unwrap());
        assert!(*deepseek_refreshing.lock().unwrap());
    }

    #[test]
    fn deepseek_error_is_independent_and_keeps_the_last_success() {
        let previous = ProviderSnapshot {
            display_name: "DeepSeek".into(),
            weekly_window: None,
            reset_credits: None,
            reset_credit_expires_at: vec![],
            status: "ok".into(),
            message: None,
            balance: Some(11.61),
            currency: Some("CNY".into()),
        };
        let snapshot_slot = Mutex::new(Some(previous));
        let error_slot = Mutex::new(None);
        let refreshing = Mutex::new(true);

        finish_deepseek_refresh(
            &snapshot_slot,
            &error_slot,
            &refreshing,
            Err("DeepSeek 余额查询失败"),
        );

        assert_eq!(
            snapshot_slot.lock().unwrap().as_ref().unwrap().balance,
            Some(11.61)
        );
        assert_eq!(
            error_slot.lock().unwrap().as_deref(),
            Some("DeepSeek 余额查询失败")
        );
        assert!(!*refreshing.lock().unwrap());
    }
}
