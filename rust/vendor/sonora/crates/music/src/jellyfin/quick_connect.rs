//! Quick Connect: signing in to Jellyfin by entering a short code on a device that is already
//! signed in, instead of typing the password. Emby has no such thing.
//!
//! The secret the server hands out is a credential until it is traded for a token: it is never
//! logged, kept out of every error, and never stored.

use std::time::Duration;

use anyhow::{Context as _, Result, anyhow};

use crate::jellyfin::client::{failed, header, header_name};
use crate::jellyfin::wire::QuickConnectResult;
use crate::jellyfin::{Flavor, auth};

/// How long one request may take, so a hung server never stalls the waiting.
const TIMEOUT: Duration = Duration::from_secs(10);

/// A code waiting to be authorized. No `Debug`, so the secret never lands in a log line.
pub struct Code {
    pub secret: String,
    /// What the listener types on the signed-in device.
    pub code: String,
}

/// Where a code stands.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Check {
    Waiting,
    Authorized,
    /// The server no longer knows the code, as happens a few minutes after it was made.
    Expired,
}

fn client() -> Result<reqwest::Client> {
    Ok(reqwest::Client::builder().timeout(TIMEOUT).build()?)
}

/// Whether the server at `server` lets a listener sign in with a code. A server that cannot
/// tell, as an old one or one that is not Jellyfin, does not.
pub async fn enabled(server: &str) -> Result<bool> {
    let server = auth::normalize_server(server)?;
    let response = client()?
        .get(format!("{server}/QuickConnect/Enabled"))
        .send()
        .await
        .map_err(|error| failed(error, ""))
        .context("cannot reach the jellyfin server")?;
    if !response.status().is_success() {
        return Ok(false);
    }
    Ok(response.json::<bool>().await.unwrap_or(false))
}

/// Asks the server for a code for this device.
pub async fn initiate(server: &str) -> Result<Code> {
    initiate_as(server, &auth::device_id(Flavor::Jellyfin)).await
}

pub(crate) async fn initiate_as(server: &str, device_id: &str) -> Result<Code> {
    let server = auth::normalize_server(server)?;
    let response = client()?
        .post(format!("{server}/QuickConnect/Initiate"))
        .header(
            header_name(Flavor::Jellyfin),
            header(&auth::authorization(device_id, None))?,
        )
        .send()
        .await
        .map_err(|error| failed(error, ""))
        .context("cannot reach the jellyfin server")?;
    if response.status() == reqwest::StatusCode::UNAUTHORIZED {
        anyhow::bail!("quick connect is turned off on the jellyfin server");
    }
    let body = response
        .error_for_status()
        .map_err(|error| failed(error, ""))
        .context("the jellyfin server refused a quick connect code")?
        .bytes()
        .await
        .map_err(|error| failed(error, ""))?;
    read_code(&body)
}

/// Where the code with `secret` stands.
pub async fn check(server: &str, secret: &str) -> Result<Check> {
    let server = auth::normalize_server(server)?;
    let response = client()?
        .get(format!("{server}/QuickConnect/Connect"))
        .query(&[("secret", secret)])
        .send()
        .await
        .map_err(|error| failed(error, secret))
        .context("cannot reach the jellyfin server")?;
    let status = response.status().as_u16();
    let body = response
        .bytes()
        .await
        .map_err(|error| failed(error, secret))?;
    read_check(status, &body)
}

/// Reads `/QuickConnect/Initiate`'s answer.
pub(crate) fn read_code(body: &[u8]) -> Result<Code> {
    let answer: QuickConnectResult =
        serde_json::from_slice(body).map_err(|_| anyhow!("cannot read the quick connect code"))?;
    if answer.secret.is_empty() || answer.code.is_empty() {
        anyhow::bail!("the jellyfin server sent an empty quick connect code");
    }
    Ok(Code {
        secret: answer.secret,
        code: answer.code,
    })
}

/// Reads `/QuickConnect/Connect`'s answer from its status and body. The body is never part of
/// an error, since it carries the secret.
pub(crate) fn read_check(status: u16, body: &[u8]) -> Result<Check> {
    match status {
        404 => Ok(Check::Expired),
        200..=299 => {
            let answer: QuickConnectResult = serde_json::from_slice(body)
                .map_err(|_| anyhow!("cannot read the quick connect state"))?;
            Ok(match answer.authenticated {
                true => Check::Authorized,
                false => Check::Waiting,
            })
        }
        status => Err(anyhow!(
            "the jellyfin server answered {status} to a quick connect check"
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_new_code_carries_its_secret_and_the_code_to_type() {
        let body = br#"{"Authenticated":false,"Secret":"s3cr3t","Code":"123456","DeviceId":"d","DeviceName":"android","AppName":"Cauce","AppVersion":"1","DateAdded":"2026-10-27T20:00:00Z"}"#;
        let code = read_code(body).unwrap();
        assert_eq!(code.secret, "s3cr3t");
        assert_eq!(code.code, "123456");
    }

    #[test]
    fn a_new_code_without_a_secret_or_code_is_an_error() {
        assert!(read_code(br#"{"Secret":"","Code":"123456"}"#).is_err());
        assert!(read_code(br#"{"Secret":"s","Code":""}"#).is_err());
        assert!(read_code(b"not json").is_err());
    }

    #[test]
    fn a_code_waits_until_authorized() {
        let waiting = br#"{"Authenticated":false,"Secret":"s","Code":"1"}"#;
        let authorized = br#"{"Authenticated":true,"Secret":"s","Code":"1"}"#;
        assert_eq!(read_check(200, waiting).unwrap(), Check::Waiting);
        assert_eq!(read_check(200, authorized).unwrap(), Check::Authorized);
    }

    #[test]
    fn a_code_the_server_forgot_has_expired() {
        assert_eq!(read_check(404, b"").unwrap(), Check::Expired);
    }

    #[test]
    fn any_other_answer_is_an_error_without_the_body() {
        let error = read_check(500, b"secret s3cr3t").unwrap_err();
        assert!(!format!("{error:#}").contains("s3cr3t"));
        assert!(read_check(200, b"not json").is_err());
    }
}
