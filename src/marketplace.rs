//! skills.sh marketplace search.
//!
//! Network I/O lives here; tests cover URL construction and JSON parsing only.

use std::io::Read;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::error::{GinoError, Result};

pub const DEFAULT_MARKETPLACE_URL: &str = "https://skills.sh";
pub const DEFAULT_SEARCH_LIMIT: u32 = 25;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct MarketplaceSkill {
    pub id: String,
    pub name: String,
    pub source: String,
    pub installs: u64,
}

#[derive(Clone, Debug, Deserialize)]
struct SearchResponse {
    #[serde(default)]
    skills: Vec<SearchSkill>,
}

#[derive(Clone, Debug, Deserialize)]
struct SearchSkill {
    #[serde(default)]
    id: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    source: String,
    #[serde(default)]
    installs: u64,
}

/// Parse a skills.sh `/api/search` body: `{skills:[{id,name,installs,source}]}`.
///
/// Unknown fields are ignored so the client stays compatible when the catalog
/// grows extra metadata.
pub fn parse_search_response(bytes: &[u8]) -> Result<Vec<MarketplaceSkill>> {
    let parsed: SearchResponse =
        serde_json::from_slice(bytes).map_err(|source| GinoError::Json {
            path: std::path::PathBuf::from("skills.sh/api/search"),
            source,
        })?;
    Ok(parsed
        .skills
        .into_iter()
        .map(|skill| MarketplaceSkill {
            id: skill.id,
            name: skill.name,
            source: skill.source,
            installs: skill.installs,
        })
        .collect())
}

pub fn search_url(base: &str, query: &str, limit: u32) -> String {
    format!(
        "{}/api/search?q={}&limit={limit}",
        base.trim_end_matches('/'),
        encode_query(query)
    )
}

/// `GET {base}/api/search?q=&limit=25` with an optional HTTP proxy.
pub fn search_skills(
    query: &str,
    base: &str,
    proxy: Option<&str>,
) -> Result<Vec<MarketplaceSkill>> {
    let url = search_url(base, query, DEFAULT_SEARCH_LIMIT);
    let response = agent(proxy)?
        .get(&url)
        .set("User-Agent", concat!("gino/", env!("CARGO_PKG_VERSION")))
        .call()
        .map_err(|error| match error {
            ureq::Error::Status(code, _) => GinoError::InvalidSource {
                input: url.clone(),
                reason: format!("marketplace returned HTTP {code}"),
            },
            other => GinoError::InvalidSource {
                input: url.clone(),
                reason: other.to_string(),
            },
        })?;
    let mut bytes = Vec::new();
    response
        .into_reader()
        .read_to_end(&mut bytes)
        .map_err(|error| GinoError::InvalidSource {
            input: url,
            reason: error.to_string(),
        })?;
    parse_search_response(&bytes)
}

fn agent(proxy: Option<&str>) -> Result<ureq::Agent> {
    let mut builder = ureq::AgentBuilder::new().timeout(Duration::from_secs(30));
    if let Some(proxy) = proxy.filter(|value| !value.is_empty()) {
        let configured = ureq::Proxy::new(proxy).map_err(|error| GinoError::InvalidSource {
            input: proxy.to_owned(),
            reason: error.to_string(),
        })?;
        builder = builder.proxy(configured);
    }
    Ok(builder.build())
}

/// `encodeURIComponent`-compatible encoding used by vercel-labs/skills@1.5.9.
fn encode_query(value: &str) -> String {
    let mut encoded = String::new();
    for byte in value.as_bytes() {
        match *byte {
            b'A'..=b'Z'
            | b'a'..=b'z'
            | b'0'..=b'9'
            | b'-'
            | b'_'
            | b'.'
            | b'~'
            | b'!'
            | b'\''
            | b'('
            | b')'
            | b'*' => encoded.push(*byte as char),
            _ => encoded.push_str(&format!("%{byte:02X}")),
        }
    }
    encoded
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_skills_sh_search_payload() {
        let skills = parse_search_response(
            br#"{"skills":[{"id":"tdd","name":"tdd","source":"mattpocock/skills","installs":100}]}"#,
        )
        .expect("parse");
        assert_eq!(
            skills,
            vec![MarketplaceSkill {
                id: "tdd".to_owned(),
                name: "tdd".to_owned(),
                source: "mattpocock/skills".to_owned(),
                installs: 100,
            }]
        );
        assert_eq!(
            search_url(DEFAULT_MARKETPLACE_URL, "tdd rust", DEFAULT_SEARCH_LIMIT),
            "https://skills.sh/api/search?q=tdd%20rust&limit=25"
        );
        assert_eq!(
            search_url(DEFAULT_MARKETPLACE_URL, "", DEFAULT_SEARCH_LIMIT),
            "https://skills.sh/api/search?q=&limit=25"
        );
    }

    #[test]
    fn parse_ignores_unknown_fields_and_missing_skills_array() {
        let extra = parse_search_response(
            br#"{"skills":[{"id":"tdd","name":"tdd","source":"owner/repo","installs":3,"description":"extra"}],"total":1}"#,
        )
        .expect("parse extra");
        assert_eq!(extra[0].id, "tdd");
        assert_eq!(extra[0].installs, 3);

        let empty = parse_search_response(br#"{}"#).expect("empty object");
        assert!(empty.is_empty());

        assert!(parse_search_response(br#"not-json"#).is_err());
    }

    #[test]
    fn encode_query_matches_encode_uri_component() {
        assert_eq!(encode_query("a/b@c"), "a%2Fb%40c");
        assert_eq!(encode_query("hello world"), "hello%20world");
        assert_eq!(encode_query("ok-_.~!*'()"), "ok-_.~!*'()");
    }
}
