use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use reqwest::header::{HeaderMap, HeaderValue, ACCEPT, AUTHORIZATION, CACHE_CONTROL, PRAGMA};
use reqwest::{redirect::Policy, Url};
use serde::Deserialize;
use serde_json::Value;

use crate::models::{ProviderSnapshot, UsageWindow};

const USAGE_URL: &str = "https://chatgpt.com/backend-api/api/codex/usage";
const LEGACY_USAGE_URL: &str = "https://chatgpt.com/backend-api/wham/usage";
const CREDITS_URL: &str = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits";
const DEEPSEEK_BALANCE_URL: &str = "https://api.deepseek.com/user/balance";
const CURRENT_PROVIDER_QUERY: &str = "SELECT name, provider_type, settings_config \
    FROM providers \
    WHERE app_type = 'codex' AND is_current = 1 \
    ORDER BY id \
    LIMIT 2";
const MAX_RESPONSE_BYTES: u64 = 1024 * 1024;
const MAX_AUTH_BYTES: u64 = 256 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ApiEndpoint {
    ChatGpt,
    DeepSeek,
}

fn allowed_api_endpoint(url: &Url) -> Option<ApiEndpoint> {
    if url.scheme() != "https"
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port_or_known_default() != Some(443)
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return None;
    }
    match (url.host_str(), url.path()) {
        (
            Some("chatgpt.com"),
            "/backend-api/api/codex/usage"
            | "/backend-api/wham/usage"
            | "/backend-api/wham/rate-limit-reset-credits",
        ) => Some(ApiEndpoint::ChatGpt),
        (Some("api.deepseek.com"), "/user/balance") => Some(ApiEndpoint::DeepSeek),
        _ => None,
    }
}

fn checked_api_url(raw: &str, expected: ApiEndpoint) -> Result<Url, &'static str> {
    let url = Url::parse(raw).map_err(|_| "API endpoint is invalid.")?;
    if allowed_api_endpoint(&url) == Some(expected) {
        Ok(url)
    } else {
        Err("API endpoint was rejected by the security policy.")
    }
}

fn redirect_allowed(from: &Url, to: &Url, carries_authorization: bool) -> bool {
    !carries_authorization
        && allowed_api_endpoint(from).is_some()
        && allowed_api_endpoint(from) == allowed_api_endpoint(to)
}

pub(crate) fn authenticated_redirect_policy() -> Policy {
    Policy::custom(|attempt| {
        let allowed = attempt
            .previous()
            .last()
            .is_some_and(|from| redirect_allowed(from, attempt.url(), true));
        if allowed {
            attempt.follow()
        } else {
            attempt.stop()
        }
    })
}

struct Auth {
    access_token: String,
    account_id: Option<String>,
}

fn auth_path() -> Option<PathBuf> {
    std::env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .or_else(|| dirs::home_dir().map(|home| home.join(".codex")))
        .map(|home| home.join("auth.json"))
}

fn pick_string<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a str> {
    keys.iter().find_map(|key| value.get(*key)?.as_str())
}

fn account_id_from_jwt(token: &str) -> Option<String> {
    let payload = token.split('.').nth(1)?;
    let bytes = URL_SAFE_NO_PAD.decode(payload).ok()?;
    let value: Value = serde_json::from_slice(&bytes).ok()?;
    pick_string(
        &value,
        &[
            "https://api.openai.com/auth.chatgpt_account_id",
            "chatgpt_account_id",
        ],
    )
    .map(str::to_owned)
}

fn load_auth() -> Result<Auth, &'static str> {
    let path = auth_path().ok_or("Codex login was not found.")?;
    let metadata = fs::metadata(&path).map_err(|_| "Please sign in to Codex Desktop first.")?;
    if !metadata.is_file() || metadata.len() > MAX_AUTH_BYTES {
        return Err("Codex login data is unavailable.");
    }
    let raw = fs::read_to_string(path).map_err(|_| "Please sign in to Codex Desktop first.")?;
    let value: Value = serde_json::from_str(&raw).map_err(|_| "Codex login format has changed.")?;
    let tokens = value.get("tokens").unwrap_or(&value);
    let access_token = pick_string(tokens, &["access_token", "accessToken"])
        .ok_or("Codex login expired. Please sign in again.")?
        .to_owned();
    let account_id = pick_string(tokens, &["account_id", "accountId"])
        .map(str::to_owned)
        .or_else(|| account_id_from_jwt(&access_token));
    Ok(Auth {
        access_token,
        account_id,
    })
}

fn headers(auth: &Auth) -> Result<HeaderMap, &'static str> {
    let mut result = HeaderMap::new();
    let mut bearer = HeaderValue::from_str(&format!("Bearer {}", auth.access_token))
        .map_err(|_| "Codex login data is invalid.")?;
    bearer.set_sensitive(true);
    result.insert(AUTHORIZATION, bearer);
    result.insert(ACCEPT, HeaderValue::from_static("application/json"));
    result.insert(CACHE_CONTROL, HeaderValue::from_static("no-cache"));
    result.insert(PRAGMA, HeaderValue::from_static("no-cache"));
    result.insert("originator", HeaderValue::from_static("Codex Desktop"));
    result.insert("OAI-Product-Sku", HeaderValue::from_static("CODEX"));
    if let Some(account_id) = &auth.account_id {
        let mut value =
            HeaderValue::from_str(account_id).map_err(|_| "Account identifier is invalid.")?;
        value.set_sensitive(true);
        result.insert("ChatGPT-Account-Id", value);
    }
    Ok(result)
}

fn usage_urls() -> [&'static str; 2] {
    [USAGE_URL, LEGACY_USAGE_URL]
}

fn number_with_key<'a>(value: &'a Value, keys: &[&'a str]) -> Option<(&'a str, f64)> {
    keys.iter()
        .find_map(|key| value.get(*key)?.as_f64().map(|number| (*key, number)))
}

fn integer(value: &Value, keys: &[&str]) -> Option<u64> {
    keys.iter().find_map(|key| {
        let value = value.get(*key)?;
        value
            .as_u64()
            .or_else(|| value.as_i64().and_then(|item| u64::try_from(item).ok()))
    })
}

fn timestamp(value: &Value, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| {
        let item = value.get(*key)?;
        if let Some(text) = item.as_str() {
            return Some(text.to_owned());
        }
        item.as_i64()
            .and_then(|seconds| chrono::DateTime::from_timestamp(seconds, 0))
            .map(|time| time.to_rfc3339())
    })
}

fn collect_reset_credit_expirations(value: &Value) -> Vec<String> {
    fn visit(value: &Value, output: &mut Vec<String>) {
        match value {
            Value::Array(items) => {
                for item in items {
                    visit(item, output);
                }
            }
            Value::Object(map) => {
                if let Some(time) = timestamp(
                    value,
                    &[
                        "expires_at",
                        "expiresAt",
                        "expiration_time",
                        "expirationTime",
                        "expires",
                    ],
                ) {
                    output.push(time);
                }
                for key in [
                    "credits",
                    "reset_credits",
                    "resetCredits",
                    "available",
                    "items",
                    "grants",
                ] {
                    if let Some(child) = map.get(key) {
                        visit(child, output);
                    }
                }
            }
            _ => {}
        }
    }

    let mut expirations = Vec::new();
    visit(value, &mut expirations);
    expirations.sort();
    expirations.dedup();
    expirations
}

fn normalize_reset_credits(
    reset_credits: Option<u64>,
    expirations: Vec<String>,
    now: chrono::DateTime<chrono::Utc>,
) -> (Option<u64>, Vec<String>) {
    let had_expirations = !expirations.is_empty();
    let mut future: Vec<(String, chrono::DateTime<chrono::Utc>)> = expirations
        .into_iter()
        .filter_map(|value| {
            let expiration = chrono::DateTime::parse_from_rfc3339(&value)
                .ok()?
                .with_timezone(&chrono::Utc);
            (expiration > now).then_some((value, expiration))
        })
        .collect();
    future.sort_by_key(|(_, expiration)| *expiration);
    future.dedup_by(|left, right| left.1 == right.1);
    let future: Vec<String> = future.into_iter().map(|(value, _)| value).collect();
    let reset_credits = if had_expirations && future.is_empty() {
        None
    } else {
        reset_credits
    };
    (reset_credits, future)
}

fn scale_ratio_field(key: &str, value: f64) -> bool {
    matches!(
        key,
        "remaining_ratio" | "remainingRatio" | "used_ratio" | "usedRatio" | "utilization"
    ) || (!key.contains("percent") && !key.contains("pct") && value <= 1.0)
}

fn parse_window(value: Option<&Value>) -> Option<UsageWindow> {
    let value = value?;
    let remaining_percent = if let Some((key, remaining)) = number_with_key(
        value,
        &[
            "remaining_percent",
            "remainingPercent",
            "remaining_pct",
            "remainingPct",
            "remaining_ratio",
            "remainingRatio",
            "remaining",
        ],
    ) {
        if scale_ratio_field(key, remaining) {
            remaining * 100.0
        } else {
            remaining
        }
    } else {
        let (key, used) = number_with_key(
            value,
            &[
                "used_percent",
                "usedPercent",
                "used_pct",
                "usedPct",
                "used_ratio",
                "usedRatio",
                "utilization",
                "used",
            ],
        )?;
        let used_percent = if scale_ratio_field(key, used) {
            used * 100.0
        } else {
            used
        };
        100.0 - used_percent
    };
    Some(UsageWindow {
        remaining_percent: remaining_percent.clamp(0.0, 100.0),
        resets_at: timestamp(
            value,
            &[
                "reset_at",
                "resetAt",
                "resets_at",
                "resetsAt",
                "reset_time",
                "resetTime",
            ],
        ),
        window_seconds: integer(
            value,
            &[
                "limit_window_seconds",
                "limitWindowSeconds",
                "window_seconds",
                "windowSeconds",
                "duration_seconds",
                "durationSeconds",
                "period_seconds",
                "periodSeconds",
            ],
        )
        .unwrap_or(0),
    })
}

fn find_window<'a>(
    rate_limit: &'a Value,
    names: &[&str],
    expected_seconds: u64,
) -> Option<&'a Value> {
    for name in names {
        if let Some(value) = rate_limit.get(*name) {
            if parse_window(Some(value)).is_some() {
                return Some(value);
            }
        }
    }

    for key in [
        "windows",
        "limit_windows",
        "limitWindows",
        "limits",
        "buckets",
    ] {
        let Some(items) = rate_limit.get(key).and_then(Value::as_array) else {
            continue;
        };
        for item in items {
            let Some(window) = parse_window(Some(item)) else {
                continue;
            };
            let matches_duration =
                expected_seconds > 0 && window.window_seconds.abs_diff(expected_seconds) <= 60;
            let matches_name = pick_string(item, &["name", "type", "id", "window", "label"])
                .map(|text| {
                    let lower = text.to_ascii_lowercase();
                    names.iter().any(|name| {
                        lower == name.to_ascii_lowercase()
                            || lower.contains(&name.to_ascii_lowercase())
                    })
                })
                .unwrap_or(false);
            if matches_duration || matches_name {
                return Some(item);
            }
        }
    }

    None
}

fn safe_http_failure(status: reqwest::StatusCode) -> (&'static str, &'static str) {
    match status.as_u16() {
        401 | 403 => ("signed_out", "Codex login expired. Please sign in again."),
        429 => (
            "unavailable",
            "Quota service is rate limited. It will retry automatically.",
        ),
        _ => ("unavailable", "Quota service is temporarily unavailable."),
    }
}

async fn limited_json(mut response: reqwest::Response) -> Result<Value, ()> {
    if response
        .content_length()
        .is_some_and(|length| length > MAX_RESPONSE_BYTES)
    {
        return Err(());
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| ())? {
        if bytes.len().saturating_add(chunk.len()) as u64 > MAX_RESPONSE_BYTES {
            return Err(());
        }
        bytes.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&bytes).map_err(|_| ())
}

#[derive(Default, Deserialize)]
struct ProviderAuthConfig {
    #[serde(rename = "OPENAI_API_KEY")]
    api_key: Option<String>,
}

#[derive(Deserialize)]
struct ProviderSettingsConfig {
    api_key: Option<String>,
    #[serde(default)]
    auth: ProviderAuthConfig,
}

#[derive(Deserialize)]
struct ProviderRow {
    name: String,
    provider_type: Option<String>,
    settings_config: String,
}

fn is_valid_api_key(value: &str) -> bool {
    value.starts_with("sk-")
        && (21..=4_096).contains(&value.len())
        && !value.chars().any(char::is_control)
}

fn api_key_from_settings_config(raw: &str) -> Result<String, &'static str> {
    let config: ProviderSettingsConfig =
        serde_json::from_str(raw).map_err(|_| "DeepSeek Provider 配置格式异常")?;
    let api_key = config
        .api_key
        .or(config.auth.api_key)
        .ok_or("DeepSeek Provider 配置中缺少 API Key")?;
    if !is_valid_api_key(&api_key) {
        return Err("DeepSeek Provider API Key 格式异常");
    }
    Ok(api_key)
}

fn current_deepseek_api_key_from_rows(raw: &[u8]) -> Result<String, &'static str> {
    let rows: Vec<ProviderRow> =
        serde_json::from_slice(raw).map_err(|_| "cc-switch Provider 查询结果格式异常")?;
    let [row] = rows.as_slice() else {
        return Err("cc-switch 当前 Codex Provider 不可用");
    };
    let is_deepseek = row.name.eq_ignore_ascii_case("deepseek")
        || row
            .provider_type
            .as_deref()
            .is_some_and(|value| value.eq_ignore_ascii_case("deepseek"));
    if !is_deepseek {
        return Err("cc-switch 当前 Codex Provider 不是 DeepSeek");
    }
    api_key_from_settings_config(&row.settings_config)
}

fn read_current_deepseek_api_key(path: &Path) -> Result<String, &'static str> {
    let output = Command::new("/usr/bin/sqlite3")
        .arg("-readonly")
        .arg("-json")
        .arg(path)
        .arg(CURRENT_PROVIDER_QUERY)
        .output()
        .map_err(|_| "无法只读查询 cc-switch 数据库")?;
    if !output.status.success() || output.stdout.len() as u64 > MAX_AUTH_BYTES {
        return Err("无法只读查询 cc-switch 数据库");
    }
    current_deepseek_api_key_from_rows(&output.stdout)
}

fn parse_amount(value: &Value, key: &str) -> Result<f64, &'static str> {
    let raw = value.get(key).ok_or("DeepSeek 余额字段缺失")?;
    let amount = raw
        .as_str()
        .and_then(|text| text.parse::<f64>().ok())
        .or_else(|| raw.as_f64())
        .ok_or("DeepSeek 余额字段格式异常")?;
    if !amount.is_finite() || amount < 0.0 {
        return Err("DeepSeek 余额字段超出有效范围");
    }
    Ok(amount)
}

fn parse_currency(value: &Value) -> Result<String, &'static str> {
    let currency = value
        .get("currency")
        .and_then(Value::as_str)
        .ok_or("DeepSeek 币种字段缺失")?;
    if currency.len() != 3 || !currency.bytes().all(|byte| byte.is_ascii_alphabetic()) {
        return Err("DeepSeek 币种字段格式异常");
    }
    Ok(currency.to_ascii_uppercase())
}

fn parse_deepseek_balance(body: &Value) -> Result<(f64, String), &'static str> {
    if body.get("is_available").and_then(Value::as_bool) != Some(true) {
        return Err("DeepSeek 余额服务不可用");
    }
    let infos = body
        .get("balance_infos")
        .and_then(Value::as_array)
        .ok_or("DeepSeek 余额数据格式异常")?;
    let primary = infos.first().ok_or("DeepSeek 余额数据为空")?;
    Ok((
        parse_amount(primary, "total_balance")?,
        parse_currency(primary)?,
    ))
}

pub async fn fetch_deepseek_balance(
    client: &reqwest::Client,
) -> Result<ProviderSnapshot, &'static str> {
    let db_path = dirs::home_dir()
        .map(|home| home.join(".cc-switch/cc-switch.db"))
        .ok_or("无法确定 cc-switch 数据库路径")?;
    let api_key = read_current_deepseek_api_key(&db_path)?;

    let mut authorization = HeaderValue::from_str(&format!("Bearer {api_key}"))
        .map_err(|_| "DeepSeek Provider API Key 格式异常")?;
    authorization.set_sensitive(true);
    let balance_url = checked_api_url(DEEPSEEK_BALANCE_URL, ApiEndpoint::DeepSeek)
        .map_err(|_| "DeepSeek 余额地址不符合安全策略")?;

    let response = client
        .get(balance_url)
        .header(AUTHORIZATION, authorization)
        .header(ACCEPT, HeaderValue::from_static("application/json"))
        .send()
        .await
        .map_err(|_| "DeepSeek 余额查询网络错误")?;

    if allowed_api_endpoint(response.url()) != Some(ApiEndpoint::DeepSeek)
        || !response.status().is_success()
    {
        return Err("DeepSeek 余额查询失败");
    }

    let body: Value = limited_json(response)
        .await
        .map_err(|_| "DeepSeek 余额响应格式异常")?;
    let (total, currency) = parse_deepseek_balance(&body)?;

    Ok(ProviderSnapshot {
        display_name: "DeepSeek".into(),
        weekly_window: None,
        reset_credits: None,
        reset_credit_expires_at: vec![],
        status: "ok".into(),
        message: None,
        balance: Some(total),
        currency: Some(currency),
    })
}

pub async fn fetch_snapshot(client: &reqwest::Client) -> ProviderSnapshot {
    let auth = match load_auth() {
        Ok(value) => value,
        Err(message) => return ProviderSnapshot::failure("signed_out", message),
    };
    let request_headers = match headers(&auth) {
        Ok(value) => value,
        Err(message) => return ProviderSnapshot::failure("signed_out", message),
    };

    let usage_urls = usage_urls();
    let primary_url = match checked_api_url(usage_urls[0], ApiEndpoint::ChatGpt) {
        Ok(url) => url,
        Err(message) => return ProviderSnapshot::failure("unavailable", message),
    };
    let legacy_url = match checked_api_url(usage_urls[1], ApiEndpoint::ChatGpt) {
        Ok(url) => url,
        Err(message) => return ProviderSnapshot::failure("unavailable", message),
    };
    let credits_url = match checked_api_url(CREDITS_URL, ApiEndpoint::ChatGpt) {
        Ok(url) => url,
        Err(message) => return ProviderSnapshot::failure("unavailable", message),
    };
    let (usage_result, credits_result) = tokio::join!(
        client
            .get(primary_url)
            .headers(request_headers.clone())
            .send(),
        client
            .get(credits_url)
            .headers(request_headers.clone())
            .send(),
    );

    let usage_response = match usage_result {
        Ok(response)
            if allowed_api_endpoint(response.url()) == Some(ApiEndpoint::ChatGpt)
                && response.status().is_success() =>
        {
            response
        }
        Ok(_) => {
            match client
                .get(legacy_url)
                .headers(request_headers.clone())
                .send()
                .await
            {
                Ok(response)
                    if allowed_api_endpoint(response.url()) == Some(ApiEndpoint::ChatGpt)
                        && response.status().is_success() =>
                {
                    response
                }
                Ok(response) => {
                    let (status, message) = safe_http_failure(response.status());
                    return ProviderSnapshot::failure(status, message);
                }
                Err(_) => {
                    return ProviderSnapshot::failure(
                        "unavailable",
                        "Network unavailable. It will retry automatically.",
                    )
                }
            }
        }
        Err(_) => {
            return ProviderSnapshot::failure(
                "unavailable",
                "Network unavailable. It will retry automatically.",
            )
        }
    };
    let usage: Value = match limited_json(usage_response).await {
        Ok(value) => value,
        Err(_) => {
            return ProviderSnapshot::failure("unavailable", "Quota response format has changed.")
        }
    };
    let rate_limit = usage
        .get("rate_limit")
        .or_else(|| usage.get("rateLimit"))
        .unwrap_or(&usage);
    let short_window = parse_window(find_window(
        rate_limit,
        &[
            "primary_window",
            "primaryWindow",
            "short_window",
            "shortWindow",
            "five_hour_window",
            "fiveHourWindow",
            "5h",
            "primary",
        ],
        18_000,
    ));
    let weekly_window = parse_window(find_window(
        rate_limit,
        &[
            "secondary_window",
            "secondaryWindow",
            "weekly_window",
            "weeklyWindow",
            "week_window",
            "weekWindow",
            "weekly",
            "secondary",
        ],
        604_800,
    ))
    .or_else(|| short_window.clone());
    if weekly_window.is_none() {
        return ProviderSnapshot::failure(
            "unavailable",
            "Quota response is missing the weekly window.",
        );
    }

    let usage_credits = usage
        .get("rate_limit_reset_credits")
        .or_else(|| usage.get("rateLimitResetCredits"));
    let usage_reset_credits = usage_credits.and_then(|value| {
        integer(
            value,
            &[
                "available_count",
                "availableCount",
                "remaining",
                "count",
                "quantity",
            ],
        )
    });
    let usage_reset_credit_expires_at = usage_credits
        .map(collect_reset_credit_expirations)
        .unwrap_or_default();

    let (reset_credits, reset_credit_expires_at) = match credits_result {
        Ok(response)
            if allowed_api_endpoint(response.url()) == Some(ApiEndpoint::ChatGpt)
                && response.status().is_success() =>
        {
            match limited_json(response).await.ok() {
                Some(value) => (
                    integer(
                        &value,
                        &[
                            "available_count",
                            "availableCount",
                            "remaining",
                            "count",
                            "quantity",
                        ],
                    )
                    .or(usage_reset_credits),
                    {
                        let expirations = collect_reset_credit_expirations(&value);
                        if expirations.is_empty() {
                            usage_reset_credit_expires_at
                        } else {
                            expirations
                        }
                    },
                ),
                None => (usage_reset_credits, usage_reset_credit_expires_at),
            }
        }
        _ => (usage_reset_credits, usage_reset_credit_expires_at),
    };
    let (reset_credits, reset_credit_expires_at) =
        normalize_reset_credits(reset_credits, reset_credit_expires_at, chrono::Utc::now());

    ProviderSnapshot {
        display_name: "CODEX".into(),
        weekly_window,
        reset_credits,
        reset_credit_expires_at,
        status: "ok".into(),
        message: None,
        balance: None,
        currency: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn prefers_the_current_codex_usage_endpoint_before_the_legacy_endpoint() {
        assert_eq!(
            usage_urls(),
            [
                "https://chatgpt.com/backend-api/api/codex/usage",
                "https://chatgpt.com/backend-api/wham/usage",
            ]
        );
    }

    #[test]
    fn endpoint_policy_allows_only_exact_https_hosts_and_paths() {
        for allowed in [USAGE_URL, LEGACY_USAGE_URL, CREDITS_URL] {
            assert_eq!(
                allowed_api_endpoint(&Url::parse(allowed).unwrap()),
                Some(ApiEndpoint::ChatGpt)
            );
        }
        assert_eq!(
            allowed_api_endpoint(&Url::parse(DEEPSEEK_BALANCE_URL).unwrap()),
            Some(ApiEndpoint::DeepSeek)
        );
        for rejected in [
            "http://chatgpt.com/backend-api/api/codex/usage",
            "https://evil.chatgpt.com/backend-api/api/codex/usage",
            "https://chatgpt.com/backend-api/api/codex/other",
            "https://chatgpt.com/backend-api/api/codex/usage?next=evil",
            "https://deepseek.com/user/balance",
            "https://api.deepseek.com/user/other",
        ] {
            assert_eq!(allowed_api_endpoint(&Url::parse(rejected).unwrap()), None);
        }
    }

    #[test]
    fn authenticated_redirects_are_rejected_even_within_the_allowlist() {
        let usage = Url::parse(USAGE_URL).unwrap();
        let legacy = Url::parse(LEGACY_USAGE_URL).unwrap();
        let deepseek = Url::parse(DEEPSEEK_BALANCE_URL).unwrap();

        assert!(!redirect_allowed(&usage, &legacy, true));
        assert!(!redirect_allowed(&usage, &deepseek, true));
        assert!(redirect_allowed(&usage, &legacy, false));
        assert!(!redirect_allowed(&usage, &deepseek, false));
    }

    #[test]
    fn reset_credit_normalization_drops_expired_boundaries_and_stale_count() {
        let now = chrono::Utc
            .with_ymd_and_hms(2026, 8, 11, 8, 0, 0)
            .single()
            .unwrap();
        let mixed = normalize_reset_credits(
            Some(2),
            vec![
                "2026-08-11T07:59:59Z".into(),
                "2026-08-11T08:00:00Z".into(),
                "2026-08-11T08:00:01Z".into(),
            ],
            now,
        );
        assert_eq!(mixed.0, Some(2));
        assert_eq!(mixed.1, vec!["2026-08-11T08:00:01Z"]);

        let expired = normalize_reset_credits(
            Some(2),
            vec!["2026-08-11T07:59:59Z".into(), "2026-08-11T08:00:00Z".into()],
            now,
        );
        assert_eq!(expired, (None, vec![]));
        assert_eq!(
            normalize_reset_credits(Some(2), vec![], now),
            (Some(2), vec![])
        );
    }

    #[test]
    fn parses_both_window_shapes() {
        let snake = serde_json::json!({
            "used_percent": 26,
            "reset_at": 1738300000,
            "limit_window_seconds": 18000
        });
        let window = parse_window(Some(&snake)).unwrap();
        assert_eq!(window.remaining_percent, 74.0);
        assert_eq!(window.window_seconds, 18000);
        let camel = serde_json::json!({
            "utilization": 0.4,
            "resetsAt": "2026-07-07T00:00:00Z",
            "windowSeconds": 604800
        });
        assert_eq!(parse_window(Some(&camel)).unwrap().remaining_percent, 60.0);
    }

    #[test]
    fn prefers_explicit_remaining_percent() {
        let value = serde_json::json!({
            "remainingPercent": 73.4,
            "usedPercent": 99,
            "resetTime": "2026-07-07T00:00:00Z",
            "durationSeconds": 18000
        });
        let window = parse_window(Some(&value)).unwrap();
        assert_eq!(window.remaining_percent, 73.4);
        assert_eq!(window.window_seconds, 18000);
    }

    #[test]
    fn treats_fractional_percent_fields_as_ratios() {
        let explicit_remaining = serde_json::json!({"remaining": 0.25, "periodSeconds": 18000});
        assert_eq!(
            parse_window(Some(&explicit_remaining))
                .unwrap()
                .remaining_percent,
            25.0
        );

        let used_ratio = serde_json::json!({"used": 0.25, "periodSeconds": 18000});
        assert_eq!(
            parse_window(Some(&used_ratio)).unwrap().remaining_percent,
            75.0
        );
    }

    #[test]
    fn does_not_scale_explicit_percent_fields() {
        let explicit_remaining =
            serde_json::json!({"remaining_percent": 0.4, "windowSeconds": 18000});
        assert_eq!(
            parse_window(Some(&explicit_remaining))
                .unwrap()
                .remaining_percent,
            0.4
        );

        let explicit_used = serde_json::json!({"used_percent": 0.4, "windowSeconds": 18000});
        assert_eq!(
            parse_window(Some(&explicit_used))
                .unwrap()
                .remaining_percent,
            99.6
        );
    }

    #[test]
    fn finds_window_by_duration_or_name_in_arrays() {
        let rate_limit = serde_json::json!({
            "windows": [
                {"name": "weekly", "remainingPercent": 88, "windowSeconds": 604800},
                {"name": "primary", "remainingPercent": 51, "windowSeconds": 18000}
            ]
        });
        let short = parse_window(find_window(
            &rate_limit,
            &["primary_window", "primary"],
            18_000,
        ))
        .unwrap();
        let weekly = parse_window(find_window(
            &rate_limit,
            &["secondary_window", "weekly"],
            604_800,
        ))
        .unwrap();
        assert_eq!(short.remaining_percent, 51.0);
        assert_eq!(weekly.remaining_percent, 88.0);
    }

    #[test]
    fn reads_only_the_exact_current_deepseek_provider_json_config() {
        assert!(CURRENT_PROVIDER_QUERY.contains("app_type = 'codex' AND is_current = 1"));
        assert!(!CURRENT_PROVIDER_QUERY
            .to_ascii_lowercase()
            .contains(" like "));
        let rows = serde_json::to_vec(&serde_json::json!([{
            "name": "DeepSeek",
            "provider_type": "deepseek",
            "settings_config": "{\"auth\":{\"OPENAI_API_KEY\":\"sk-current-valid-deepseek-key\"}}"
        }]))
        .unwrap();

        assert_eq!(
            current_deepseek_api_key_from_rows(&rows).unwrap(),
            "sk-current-valid-deepseek-key"
        );
    }

    #[test]
    fn rejects_non_deepseek_current_provider_and_malformed_credentials() {
        let rows = serde_json::to_vec(&serde_json::json!([{
            "name": "OpenAI Official",
            "provider_type": "openai",
            "settings_config": "{\"api_key\":\"sk-current-valid-deepseek-key\"}"
        }]))
        .unwrap();
        assert_eq!(
            current_deepseek_api_key_from_rows(&rows),
            Err("cc-switch 当前 Codex Provider 不是 DeepSeek")
        );
        assert_eq!(
            current_deepseek_api_key_from_rows(b"[]"),
            Err("cc-switch 当前 Codex Provider 不可用")
        );
        assert!(api_key_from_settings_config("not-json").is_err());
        assert!(api_key_from_settings_config("{\"api_key\":\"invalid\"}").is_err());
    }

    #[test]
    fn validates_deepseek_balance_amount_and_currency() {
        let valid = serde_json::json!({
            "is_available": true,
            "balance_infos": [{"total_balance": "11.61", "currency": "cny"}]
        });
        assert_eq!(
            parse_deepseek_balance(&valid).unwrap(),
            (11.61, "CNY".into())
        );

        for invalid in [
            serde_json::json!({
                "is_available": true,
                "balance_infos": [{"total_balance": "NaN", "currency": "CNY"}]
            }),
            serde_json::json!({
                "is_available": true,
                "balance_infos": [{"total_balance": "-0.01", "currency": "CNY"}]
            }),
            serde_json::json!({
                "is_available": true,
                "balance_infos": [{"total_balance": "1.00", "currency": "yuan"}]
            }),
        ] {
            assert!(parse_deepseek_balance(&invalid).is_err());
        }
    }
}
