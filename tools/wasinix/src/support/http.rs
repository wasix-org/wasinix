//! Plain HTTP fetches outside the GitHub API, with the shared defaults:
//! Cloudflare intermittently rejects requests with no User-Agent, and a
//! missing timeout turns a stuck mirror into a stuck run.

use std::time::Duration;

use serde_json::Value;

use crate::support::error::{Error, Result};

const USER_AGENT: &str = "wasinix";
const TIMEOUT: Duration = Duration::from_secs(30);

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new().timeout(TIMEOUT).build()
}

pub fn get_json(url: &str) -> Result<Value> {
    let response = agent()
        .get(url)
        .set("User-Agent", USER_AGENT)
        .call()
        .map_err(|error| Error::Http {
            context: format!("GET {url}"),
            source: Box::new(error),
        })?;
    response.into_json().map_err(|source| Error::Io {
        path: url.into(),
        source,
    })
}

pub fn post_json(url: &str, body: &Value) -> Result<Value> {
    let response = agent()
        .post(url)
        .set("User-Agent", USER_AGENT)
        .set("content-type", "application/json")
        .send_json(body.clone())
        .map_err(|error| Error::Http {
            context: format!("POST {url}"),
            source: Box::new(error),
        })?;
    response.into_json().map_err(|source| Error::Io {
        path: url.into(),
        source,
    })
}

pub fn put_json(url: &str, body: &Value, auth: Option<&str>) -> Result<Value> {
    let mut request = agent().put(url).set("User-Agent", USER_AGENT);
    if let Some(token) = auth {
        request = request.set("authorization", token);
    }
    let response = request
        .send_json(body.clone())
        .map_err(|error| Error::Http {
            context: format!("PUT {url}"),
            source: Box::new(error),
        })?;
    response.into_json().map_err(|source| Error::Io {
        path: url.into(),
        source,
    })
}

/// GET where absence is an answer: None on 404, and None on a redirect
/// (an overlay mirror answers for its own content and redirects the rest to
/// its upstream, so a redirect means "not served here"). Never follows one.
pub fn get_text_optional(url: &str) -> Result<Option<String>> {
    let agent = ureq::AgentBuilder::new()
        .timeout(TIMEOUT)
        .redirects(0)
        .build();
    let response = agent.get(url).set("User-Agent", USER_AGENT).call();
    match response {
        Ok(response) => response
            .into_string()
            .map(Some)
            .map_err(|source| Error::Io {
                path: url.into(),
                source,
            }),
        Err(ureq::Error::Status(status, _)) if status == 404 || (300..400).contains(&status) => {
            Ok(None)
        }
        Err(error) => Err(Error::Http {
            context: format!("GET {url}"),
            source: Box::new(error),
        }),
    }
}

pub fn get_text(url: &str) -> Result<String> {
    let response = agent()
        .get(url)
        .set("User-Agent", USER_AGENT)
        .call()
        .map_err(|error| Error::Http {
            context: format!("GET {url}"),
            source: Box::new(error),
        })?;
    response.into_string().map_err(|source| Error::Io {
        path: url.into(),
        source,
    })
}
