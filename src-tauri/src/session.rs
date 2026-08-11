use std::{
    collections::BTreeSet,
    fs::{self, File},
    io::{self, Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    time::{Duration, SystemTime},
};

const MAX_EVENT_TAIL_BYTES: u64 = 256 * 1024;
const LIVE_SESSION_AGE: Duration = Duration::from_secs(15 * 60);

pub fn live_status() -> Option<&'static str> {
    let root = dirs::home_dir()?.join(".codex/sessions");
    live_status_in(&root, SystemTime::now())
}

fn live_status_in(root: &Path, now: SystemTime) -> Option<&'static str> {
    let mut statuses = Vec::new();
    for directory in recent_session_directories(root, now) {
        visit_sessions(&directory, &mut statuses, now);
    }
    aggregate_status(&statuses)
}

fn recent_session_directories(root: &Path, now: SystemTime) -> Vec<PathBuf> {
    let utc: chrono::DateTime<chrono::Utc> = now.into();
    let local = utc.with_timezone(&chrono::Local);
    let mut directories = BTreeSet::new();
    for date in [utc.date_naive(), local.date_naive()] {
        for days_ago in 0..=1 {
            if let Some(date) = date.checked_sub_days(chrono::Days::new(days_ago)) {
                directories.insert(root.join(date.format("%Y/%m/%d").to_string()));
            }
        }
    }
    directories.into_iter().collect()
}

fn session_status(path: &Path, now: SystemTime) -> Option<&'static str> {
    let modified = path.metadata().ok()?.modified().ok()?;
    if now.duration_since(modified).unwrap_or(Duration::ZERO) > LIVE_SESSION_AGE {
        return None;
    }
    let mut file = File::open(path).ok()?;
    let contents = read_tail(&mut file, MAX_EVENT_TAIL_BYTES).ok()?;
    let recent_lines: Vec<&str> = contents.lines().rev().take(200).collect();
    let events: Vec<String> = recent_lines
        .into_iter()
        .rev()
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

fn read_tail<R: Read + Seek>(reader: &mut R, maximum_bytes: u64) -> io::Result<String> {
    let length = reader.seek(SeekFrom::End(0))?;
    let start = length.saturating_sub(maximum_bytes);
    reader.seek(SeekFrom::Start(start))?;
    let mut bytes = Vec::with_capacity((length - start) as usize);
    reader.read_to_end(&mut bytes)?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

fn visit_sessions(directory: &Path, statuses: &mut Vec<&'static str>, now: SystemTime) {
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            visit_sessions(&path, statuses, now);
        } else if path
            .extension()
            .is_some_and(|extension| extension == "jsonl")
        {
            if let Some(status) = session_status(&path, now) {
                statuses.push(status);
            }
        }
    }
}

pub fn aggregate_status(statuses: &[&str]) -> Option<&'static str> {
    if statuses.contains(&"running") {
        Some("running")
    } else if statuses.contains(&"waiting") {
        Some("waiting")
    } else if statuses.contains(&"failed") {
        Some("failed")
    } else if statuses.contains(&"completed") {
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
    use super::{
        aggregate_status, live_status_in, read_tail, recent_session_directories, status_from_events,
    };
    use std::{
        fs,
        io::Cursor,
        time::{SystemTime, UNIX_EPOCH},
    };

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

    #[test]
    fn event_reader_only_loads_the_bounded_tail() {
        let mut contents = b"private-prefix\n".to_vec();
        contents.extend(vec![b'x'; 1024]);
        contents.extend_from_slice(b"\nrecent-event\n");
        let tail = read_tail(&mut Cursor::new(contents), 64).unwrap();

        assert!(!tail.contains("private-prefix"));
        assert!(tail.contains("recent-event"));
        assert!(tail.len() <= 66);
    }

    #[test]
    fn live_status_scans_only_recent_date_directories() {
        let now = SystemTime::now();
        let unique = now.duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let root = std::env::temp_dir().join(format!(
            "codex-bar-session-test-{}-{unique}",
            std::process::id()
        ));
        let current = recent_session_directories(&root, now)
            .into_iter()
            .next()
            .unwrap();
        let old = root.join("2000/01/01");
        fs::create_dir_all(&current).unwrap();
        fs::create_dir_all(&old).unwrap();
        fs::write(
            current.join("completed.jsonl"),
            "{\"payload\":{\"type\":\"message\"}}\n",
        )
        .unwrap();
        fs::write(
            old.join("running.jsonl"),
            "{\"payload\":{\"type\":\"reasoning\"}}\n",
        )
        .unwrap();

        assert_eq!(live_status_in(&root, now), Some("completed"));

        fs::remove_dir_all(&root).unwrap();
    }
}
