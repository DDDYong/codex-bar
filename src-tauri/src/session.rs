use std::{
    fs,
    path::{Path, PathBuf},
    time::{Duration, SystemTime},
};

pub fn live_status() -> Option<&'static str> {
    let root = dirs::home_dir()?.join(".codex/sessions");
    let path = newest_session_file(&root)?;
    let modified = path.metadata().ok()?.modified().ok()?;
    if SystemTime::now().duration_since(modified).ok()? > Duration::from_secs(15 * 60) {
        return None;
    }
    let contents = fs::read_to_string(path).ok()?;
    let lines: Vec<&str> = contents.lines().collect();
    let events: Vec<String> = lines
        .iter()
        .skip(lines.len().saturating_sub(200))
        .copied()
        .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
        .filter_map(|item| {
            item.get("payload")?
                .get("type")?
                .as_str()
                .map(str::to_owned)
        })
        .collect();
    status_from_events(&events)
}

fn newest_session_file(root: &Path) -> Option<PathBuf> {
    let mut newest = None;
    visit_sessions(root, &mut newest);
    newest.map(|(path, _)| path)
}

fn visit_sessions(directory: &Path, newest: &mut Option<(PathBuf, SystemTime)>) {
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            visit_sessions(&path, newest);
        } else if path
            .extension()
            .is_some_and(|extension| extension == "jsonl")
        {
            let Some(modified) = entry
                .metadata()
                .ok()
                .and_then(|metadata| metadata.modified().ok())
            else {
                continue;
            };
            if newest
                .as_ref()
                .is_none_or(|(_, current)| modified > *current)
            {
                *newest = Some((path, modified));
            }
        }
    }
}

pub fn status_from_events(events: &[String]) -> Option<&'static str> {
    match events.last()?.as_str() {
        "task_complete" | "message" => Some("completed"),
        "reasoning"
        | "agent_reasoning"
        | "custom_tool_call"
        | "function_call"
        | "custom_tool_call_output"
        | "function_call_output" => Some("running"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::status_from_events;

    #[test]
    fn task_complete_means_completed_but_recent_reasoning_means_running() {
        assert_eq!(
            status_from_events(&["task_complete".into()]),
            Some("completed")
        );
        assert_eq!(
            status_from_events(&["reasoning".into(), "custom_tool_call".into()]),
            Some("running")
        );
    }
}
