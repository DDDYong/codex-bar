use std::{
    fs,
    path::Path,
    time::{Duration, SystemTime},
};

pub fn live_status() -> Option<&'static str> {
    let root = dirs::home_dir()?.join(".codex/sessions");
    let mut statuses = Vec::new();
    visit_sessions(&root, &mut statuses);
    aggregate_status(&statuses)
}

fn session_status(path: &Path) -> Option<&'static str> {
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
            let payload = item.get("payload")?;
            let kind = payload.get("type")?.as_str()?;
            if payload.get("name").and_then(|name| name.as_str()) == Some("request_user_input")
                || matches!(
                    kind,
                    "permission_request" | "approval_request" | "request_user_input"
                )
            {
                Some("waiting".into())
            } else if matches!(kind, "error" | "failure" | "failed") {
                Some("failed".into())
            } else {
                Some(kind.to_owned())
            }
        })
        .collect();
    status_from_events(&events)
}

fn visit_sessions(directory: &Path, statuses: &mut Vec<&'static str>) {
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            visit_sessions(&path, statuses);
        } else if path
            .extension()
            .is_some_and(|extension| extension == "jsonl")
        {
            if let Some(status) = session_status(&path) {
                statuses.push(status);
            }
        }
    }
}

pub fn aggregate_status(statuses: &[&str]) -> Option<&'static str> {
    if statuses.iter().any(|status| *status == "running") {
        Some("running")
    } else if statuses.iter().any(|status| *status == "waiting") {
        Some("waiting")
    } else if statuses.iter().any(|status| *status == "failed") {
        Some("failed")
    } else if statuses.iter().any(|status| *status == "completed") {
        Some("completed")
    } else {
        None
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
    use super::{aggregate_status, status_from_events};

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

    #[test]
    fn any_running_session_wins_over_completed_sessions() {
        assert_eq!(aggregate_status(&["completed", "running"]), Some("running"));
    }

    #[test]
    fn waiting_and_failed_sessions_keep_their_distinct_states() {
        assert_eq!(aggregate_status(&["completed", "waiting"]), Some("waiting"));
        assert_eq!(aggregate_status(&["completed", "failed"]), Some("failed"));
    }
}
