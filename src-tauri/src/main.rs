mod codex;
mod models;

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
    detailed: Mutex<bool>,
    refreshing: Mutex<bool>,
}
static POLLING: AtomicBool = AtomicBool::new(false);

#[cfg(test)]
mod tests {
    use super::{status_light, tray_title};

    #[test]
    fn display_modes_never_put_session_light_in_the_title() {
        assert_eq!(
            tray_title(true, "week 68% · 周五 · 2次"),
            "week 68% · 周五 · 2次"
        );
        assert_eq!(tray_title(false, "week 68% · 周五 · 2次"), "");
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
}

fn reset_label(value: Option<&str>) -> String {
    let Some(reset) = value
        .and_then(|v| DateTime::parse_from_rfc3339(v).ok())
        .map(|v| v.with_timezone(&Local))
    else {
        return "--".into();
    };
    if reset.signed_duration_since(Local::now()) < Duration::hours(24) {
        reset.format("%H:%M").to_string()
    } else {
        ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
            [reset.weekday().num_days_from_monday() as usize]
            .into()
    }
}
fn summary(snapshot: Option<&ProviderSnapshot>) -> String {
    let Some(s) = snapshot.filter(|s| s.status == "ok") else {
        return "week -- · -- · --".into();
    };
    let percent = s
        .weekly_window
        .as_ref()
        .map(|w| format!("{:.0}%", w.remaining_percent))
        .unwrap_or_else(|| "--".into());
    let reset = reset_label(
        s.weekly_window
            .as_ref()
            .and_then(|w| w.resets_at.as_deref()),
    );
    let credits = s
        .reset_credits
        .map(|n| format!("{n}次"))
        .unwrap_or_else(|| "--".into());
    format!("week {percent} · {reset} · {credits}")
}
fn tray_title(detailed: bool, summary: &str) -> String {
    if detailed {
        summary.into()
    } else {
        String::new()
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
                    let index = ((py as usize * width + px as usize) * 4) as usize;
                    rgba[index..index + 4].copy_from_slice(&color);
                }
            }
        }
    }
    tauri::image::Image::new_owned(rgba, width as u32, height as u32)
}
fn expiration_lines(snapshot: Option<&ProviderSnapshot>) -> Vec<String> {
    snapshot
        .map(|s| {
            s.reset_credit_expires_at
                .iter()
                .enumerate()
                .map(|(i, v)| {
                    let date = DateTime::parse_from_rfc3339(v)
                        .ok()
                        .map(|d| d.with_timezone(&Local).format("%Y/%m/%d %H:%M").to_string())
                        .unwrap_or_else(|| "--".into());
                    format!("第 {} 次 · {date} 到期", i + 1)
                })
                .collect()
        })
        .unwrap_or_default()
}
fn refresh(app: &AppHandle) {
    start_status_polling(app.clone());
    let state = app.state::<AppState>();
    *state.refreshing.lock().unwrap() = true;
    update(app);
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let state = app.state::<AppState>();
        let next = codex::fetch_snapshot(&state.client).await;
        *state.snapshot.lock().unwrap() = Some(next);
        *state.refreshing.lock().unwrap() = false;
        update(&app);
    });
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
fn update_title(app: &AppHandle) {
    let state = app.state::<AppState>();
    let snapshot = state.snapshot.lock().unwrap().clone();
    let detailed = *state.detailed.lock().unwrap();
    let refreshing = *state.refreshing.lock().unwrap();
    let status = light(snapshot.as_ref(), refreshing);
    let tray = app.tray_by_id("main").unwrap();
    let _ = tray.set_title(Some(tray_title(detailed, &summary(snapshot.as_ref()))));
    let _ = tray.set_icon(Some(badge_icon(status)));
}
fn update(app: &AppHandle) {
    let state = app.state::<AppState>();
    let snapshot = state.snapshot.lock().unwrap().clone();
    let detailed = *state.detailed.lock().unwrap();
    let tray = app.tray_by_id("main").unwrap();
    update_title(app);
    let info =
        MenuItem::with_id(app, "info", summary(snapshot.as_ref()), false, None::<&str>).unwrap();
    let mut items: Vec<Box<dyn tauri::menu::IsMenuItem<tauri::Wry>>> = vec![Box::new(info)];
    for (i, line) in expiration_lines(snapshot.as_ref()).iter().enumerate() {
        items.push(Box::new(
            MenuItem::with_id(app, format!("expiry-{i}"), line, false, None::<&str>).unwrap(),
        ));
    }
    items.push(Box::new(PredefinedMenuItem::separator(app).unwrap()));
    items.push(Box::new(
        MenuItem::with_id(app, "refresh", "立即刷新", true, None::<&str>).unwrap(),
    ));
    let detailed_item =
        CheckMenuItem::with_id(app, "detailed", "详细", true, detailed, None::<&str>).unwrap();
    let icon_item =
        CheckMenuItem::with_id(app, "icon", "仅图标", true, !detailed, None::<&str>).unwrap();
    items.push(Box::new(
        Submenu::with_items(app, "显示方式", true, &[&detailed_item, &icon_item]).unwrap(),
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
                .user_agent("CodexBar/0.1")
                .build()?;
            app.manage(AppState {
                client,
                snapshot: Mutex::new(None),
                detailed: Mutex::new(false),
                refreshing: Mutex::new(false),
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
                    *app.state::<AppState>().detailed.lock().unwrap() = true;
                    update(app);
                }
                "icon" => {
                    *app.state::<AppState>().detailed.lock().unwrap() = false;
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
            refresh(app.handle());
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("failed to run Codex Bar");
}
