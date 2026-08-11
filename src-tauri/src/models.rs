#[derive(Debug, Clone)]
pub struct UsageWindow {
    pub remaining_percent: f64,
    pub resets_at: Option<String>,
    pub window_seconds: u64,
}

#[derive(Debug, Clone)]
pub struct ProviderSnapshot {
    pub display_name: String,
    pub weekly_window: Option<UsageWindow>,
    pub reset_credits: Option<u64>,
    pub reset_credit_expires_at: Vec<String>,
    pub status: String,
    pub message: Option<String>,
    pub balance: Option<f64>,
    pub currency: Option<String>,
}

impl ProviderSnapshot {
    pub fn failure(status: &str, message: &str) -> Self {
        Self {
            display_name: "CODEX".into(),
            weekly_window: None,
            reset_credits: None,
            reset_credit_expires_at: vec![],
            status: status.into(),
            message: Some(message.into()),
            balance: None,
            currency: None,
        }
    }
}
