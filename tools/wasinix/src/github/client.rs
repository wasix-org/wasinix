//! The one GitHub REST client. A rejected call reports GitHub's own error
//! message, not just the status code.

use serde_json::Value;

use crate::support::error::{Error, Result};

const API: &str = "https://api.github.com";

pub fn token() -> Option<String> {
    crate::support::env::github_token()
}

pub struct Client {
    token: Option<String>,
}

impl Client {
    pub fn new(supplied: Option<&str>) -> Client {
        Client {
            token: supplied.map(str::to_string).or_else(token),
        }
    }



    fn send(&self, method: &str, path: &str, body: Option<&Value>) -> Result<Value> {
        let mut request = ureq::request(method, &format!("{API}/{path}"))
            .set("Accept", "application/vnd.github+json")
            .set("X-GitHub-Api-Version", "2022-11-28")
            .set("User-Agent", "wasinix");
        if let Some(token) = &self.token {
            request = request.set("Authorization", &format!("Bearer {token}"));
        }
        let response = match body {
            Some(body) => request.send_json(body.clone()),
            None => request.call(),
        };
        match response {
            Ok(response) => {
                let text = response.into_string().map_err(|source| Error::Io {
                    path: path.into(),
                    source,
                })?;
                if text.is_empty() {
                    Ok(Value::Null)
                } else {
                    serde_json::from_str(&text).map_err(|source| Error::Json {
                        path: path.into(),
                        source,
                    })
                }
            }
            Err(ureq::Error::Status(code, response)) => {
                let body = response.into_string().unwrap_or_default();
                let detail = serde_json::from_str::<Value>(&body)
                    .ok()
                    .and_then(|value| value.get("message").and_then(Value::as_str).map(str::to_string))
                    .unwrap_or_else(|| crate::support::error::tail(&body, 200));
                Err(Error::Failure(format!(
                    "GitHub rejected {method} {path} with {code}: {detail}"
                )))
            }
            Err(error) => Err(Error::Http {
                context: format!("GitHub API {method} {path}"),
                source: Box::new(error),
            }),
        }
    }

    /// Retry transient 5xx: a platform blip during a permission check must
    /// not read as a refusal, and one during a comment update must not fail
    /// a green run. GET and PATCH are idempotent; a retried POST can at
    /// worst duplicate a comment the sticky upsert reconciles next round.
    fn send_retrying(&self, method: &str, path: &str, body: Option<&Value>) -> Result<Value> {
        let mut delay = std::time::Duration::from_secs(2);
        for _ in 0..3 {
            match self.send(method, path, body) {
                Err(error) if error.to_string().contains(" with 50") => {
                    crate::support::ui::warning(format!("retrying: {error}"));
                    std::thread::sleep(delay);
                    delay *= 4;
                }
                result => return result,
            }
        }
        self.send(method, path, body)
    }

    pub fn get(&self, path: &str) -> Result<Value> {
        self.send_retrying("GET", path, None)
    }

    pub(in crate::github) fn post(&self, path: &str, body: &Value) -> Result<Value> {
        self.send_retrying("POST", path, Some(body))
    }

    pub(in crate::github) fn patch(&self, path: &str, body: &Value) -> Result<Value> {
        self.send_retrying("PATCH", path, Some(body))
    }

    /// Every page of a list endpoint, flattened. Callers apply their own
    /// match rule to the complete list, so "first match" means first across
    /// all pages for every caller.
    pub(in crate::github) fn paginate(&self, path: &str) -> Result<Vec<Value>> {
        let mut items = Vec::new();
        for page in 1..=100u32 {
            let separator = if path.contains('?') { '&' } else { '?' };
            let value = self.get(&format!("{path}{separator}per_page=100&page={page}"))?;
            let batch = match value.as_array() {
                Some(batch) => batch.clone(),
                None => {
                    return Err(Error::Failure(format!(
                        "GitHub {path} page {page} is not a list"
                    )))
                }
            };
            let done = batch.len() < 100;
            items.extend(batch);
            if done {
                break;
            }
        }
        Ok(items)
    }
}
