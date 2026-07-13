#[derive(Debug, Clone)]
pub struct UsageWindow { pub remaining_percent: f64, pub resets_at: Option<String>, pub window_seconds: u64 }

#[derive(Debug, Clone)]
pub struct ProviderSnapshot { pub provider: String, pub display_name: String, pub plan: Option<String>, pub short_window: Option<UsageWindow>, pub weekly_window: Option<UsageWindow>, pub reset_credits: Option<u64>, pub reset_credit_expires_at: Vec<String>, pub updated_at: String, pub status: String, pub message: Option<String> }

impl ProviderSnapshot { pub fn failure(status: &str, message: &str) -> Self { Self { provider: "codex".into(), display_name: "CODEX".into(), plan: None, short_window: None, weekly_window: None, reset_credits: None, reset_credit_expires_at: vec![], updated_at: chrono::Utc::now().to_rfc3339(), status: status.into(), message: Some(message.into()) } } }
