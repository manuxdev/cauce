//! Signing in through plex.tv: the app asks for a PIN, the listener approves it on Plex's own
//! page, and the PIN then carries the account's token, which lists the servers it can reach.
//!
//! The PIN's id and code and the account token are credentials: never logged, kept out of every
//! error, and never stored.

use std::time::Duration;

use anyhow::{Context as _, Result, anyhow};
use reqwest::StatusCode;

use crate::plex::client::{failed, headers};
use crate::plex::wire::{self, Account, Resource};

const PLEX_TV: &str = "https://plex.tv";
const RESOURCES: &str = "https://clients.plex.tv/api/v2/resources";
/// How long one request may take, so a hung plex.tv never stalls the waiting.
const TIMEOUT: Duration = Duration::from_secs(15);

/// A PIN waiting to be approved. No `Debug`, so its id and code never land in a log line.
#[derive(Clone)]
pub struct Pin {
    pub id: u64,
    pub code: String,
}

/// Where a PIN stands. No `Debug`, since an approved one carries the account token.
pub enum Check {
    Waiting,
    /// The account token, once the listener approved the PIN.
    Approved(String),
    /// plex.tv no longer knows the PIN, as happens half an hour after it was made.
    Expired,
}

/// A server the account can reach.
#[derive(Clone)]
pub struct Server {
    pub id: String,
    pub name: String,
    pub owned: bool,
    /// The token the server takes from this account, which differs from the account's own on a
    /// server shared with them.
    pub token: String,
    pub addresses: Vec<String>,
}

fn client() -> Result<reqwest::Client> {
    Ok(reqwest::Client::builder().timeout(TIMEOUT).build()?)
}

/// The page where the listener approves `pin`, signing in to Plex first if they must.
pub fn approval_url(client_id: &str, pin: &Pin) -> String {
    let product = crate::escape::component(crate::plex::PRODUCT);
    format!(
        "https://app.plex.tv/auth#?clientID={}&code={}&context%5Bdevice%5D%5Bproduct%5D={product}",
        crate::escape::component(client_id),
        crate::escape::component(&pin.code)
    )
}

/// Asks plex.tv for a strong PIN for this install.
pub async fn create(client_id: &str) -> Result<Pin> {
    let response = client()?
        .post(format!("{PLEX_TV}/api/v2/pins"))
        .headers(headers(client_id, None)?)
        .query(&[("strong", "true")])
        .send()
        .await
        .map_err(|error| failed(error, &[]))
        .context("cannot reach plex.tv")?;
    let status = response.status().as_u16();
    let body = response.bytes().await.map_err(|error| failed(error, &[]))?;
    read_pin(status, &body)
}

/// Where `pin` stands.
pub async fn check(client_id: &str, pin: &Pin) -> Result<Check> {
    let response = client()?
        .get(format!("{PLEX_TV}/api/v2/pins/{}", pin.id))
        .headers(headers(client_id, None)?)
        .query(&[("code", pin.code.as_str())])
        .send()
        .await
        .map_err(|error| failed(error, &[&pin.code]))
        .context("cannot reach plex.tv")?;
    let status = response.status().as_u16();
    let body = response
        .bytes()
        .await
        .map_err(|error| failed(error, &[&pin.code]))?;
    read_check(status, &body)
}

/// The account `token` belongs to.
pub async fn account(client_id: &str, token: &str) -> Result<Account> {
    let response = client()?
        .get(format!("{PLEX_TV}/api/v2/user"))
        .headers(headers(client_id, Some(token))?)
        .send()
        .await
        .map_err(|error| failed(error, &[token]))
        .context("cannot reach plex.tv")?;
    if response.status() == StatusCode::UNAUTHORIZED {
        anyhow::bail!("plex.tv refused the sign-in");
    }
    response
        .error_for_status()
        .map_err(|error| failed(error, &[token]))
        .context("plex.tv refused the sign-in")?
        .json()
        .await
        .map_err(|error| failed(error, &[token]))
        .context("cannot read the plex account")
}

/// Every server the account with `token` can reach, its own first.
pub async fn servers(client_id: &str, token: &str) -> Result<Vec<Server>> {
    let body = client()?
        .get(RESOURCES)
        .headers(headers(client_id, Some(token))?)
        .query(&[("includeHttps", "1"), ("includeRelay", "1")])
        .send()
        .await
        .map_err(|error| failed(error, &[token]))
        .context("cannot reach plex.tv")?
        .error_for_status()
        .map_err(|error| failed(error, &[token]))
        .context("plex.tv refused to list the servers")?
        .bytes()
        .await
        .map_err(|error| failed(error, &[token]))?;
    read_servers(&body)
}

/// Reads `/api/v2/pins`'s answer. The body is never part of an error, since it carries the PIN.
pub(crate) fn read_pin(status: u16, body: &[u8]) -> Result<Pin> {
    if !(200..=299).contains(&status) {
        anyhow::bail!("plex.tv answered {status} to a sign-in code request");
    }
    let pin: wire::Pin =
        serde_json::from_slice(body).map_err(|_| anyhow!("cannot read the plex sign-in code"))?;
    if pin.id == 0 || pin.code.is_empty() {
        anyhow::bail!("plex.tv sent an empty sign-in code");
    }
    Ok(Pin {
        id: pin.id,
        code: pin.code,
    })
}

/// Reads `/api/v2/pins/{id}`'s answer from its status and body. The body is never part of an
/// error, since it carries the PIN and, once approved, the token.
pub(crate) fn read_check(status: u16, body: &[u8]) -> Result<Check> {
    match status {
        404 | 410 => Ok(Check::Expired),
        200..=299 => {
            let pin: wire::Pin = serde_json::from_slice(body)
                .map_err(|_| anyhow!("cannot read the plex sign-in state"))?;
            Ok(match pin.auth_token.filter(|token| !token.is_empty()) {
                Some(token) => Check::Approved(token),
                None => Check::Waiting,
            })
        }
        status => Err(anyhow!("plex.tv answered {status} to a sign-in check")),
    }
}

/// The servers among `/api/v2/resources`, owned ones first. One with no token or no address is
/// left out, since nothing could play from it.
pub(crate) fn read_servers(body: &[u8]) -> Result<Vec<Server>> {
    let resources: Vec<Resource> =
        serde_json::from_slice(body).map_err(|_| anyhow!("cannot read the plex servers"))?;
    let mut servers: Vec<Server> = resources
        .into_iter()
        .filter(Resource::is_server)
        .filter_map(|resource| {
            let addresses = resource.addresses();
            let token = resource
                .access_token
                .clone()
                .filter(|token| !token.is_empty())?;
            (!addresses.is_empty() && !resource.client_identifier.is_empty()).then(|| Server {
                id: resource.client_identifier,
                name: resource.name,
                owned: resource.owned,
                token,
                addresses,
            })
        })
        .collect();
    servers.sort_by_key(|server| !server.owned);
    Ok(servers)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_approval_page_names_the_app_and_carries_the_code() {
        let pin = Pin {
            id: 1,
            code: "ab cd".into(),
        };
        assert_eq!(
            approval_url("client 1", &pin),
            "https://app.plex.tv/auth#?clientID=client%201&code=ab%20cd&context%5Bdevice%5D%5Bproduct%5D=Cauce"
        );
    }

    #[test]
    fn a_new_pin_carries_its_id_and_code() {
        let pin = read_pin(201, br#"{"id":4242,"code":"abcd1234","authToken":null}"#).unwrap();
        assert_eq!((pin.id, pin.code.as_str()), (4242, "abcd1234"));
        assert!(read_pin(201, br#"{"id":0,"code":"abcd"}"#).is_err());
        assert!(read_pin(201, br#"{"id":5,"code":""}"#).is_err());
        let refused = read_pin(429, br#"{"code":"s3cr3t"}"#).err().unwrap();
        assert!(!format!("{refused:#}").contains("s3cr3t"));
    }

    #[test]
    fn a_pin_waits_until_it_carries_a_token() {
        let waiting = read_check(200, br#"{"id":1,"code":"c","authToken":null}"#).unwrap();
        assert!(matches!(waiting, Check::Waiting));
        let blank = read_check(200, br#"{"id":1,"code":"c","authToken":""}"#).unwrap();
        assert!(matches!(blank, Check::Waiting));
        let approved = read_check(200, br#"{"id":1,"code":"c","authToken":"t0k"}"#).unwrap();
        assert!(matches!(approved, Check::Approved(token) if token == "t0k"));
    }

    #[test]
    fn a_pin_plex_forgot_has_expired() {
        assert!(matches!(read_check(404, b"").unwrap(), Check::Expired));
    }

    #[test]
    fn any_other_answer_is_an_error_without_the_body() {
        let error = read_check(500, br#"{"authToken":"s3cr3t"}"#).err().unwrap();
        assert!(!format!("{error:#}").contains("s3cr3t"));
        let error = read_check(200, b"s3cr3t").err().unwrap();
        assert!(!format!("{error:#}").contains("s3cr3t"));
    }

    #[test]
    fn only_servers_with_a_token_and_an_address_are_listed_owned_first() {
        let body = br#"[
            {"name":"Friend","clientIdentifier":"f1","provides":"server","owned":false,"accessToken":"ft",
             "connections":[{"uri":"https://f.plex.direct:32400","local":false,"relay":false}]},
            {"name":"Den","clientIdentifier":"d1","provides":"server","owned":true,"accessToken":"dt",
             "connections":[{"uri":"http://192.168.1.4:32400/","local":true,"relay":false}]},
            {"name":"Tokenless","clientIdentifier":"t1","provides":"server","owned":true,
             "connections":[{"uri":"http://10.0.0.2:32400","local":true,"relay":false}]},
            {"name":"Nowhere","clientIdentifier":"n1","provides":"server","owned":true,"accessToken":"nt","connections":[]},
            {"name":"Phone","clientIdentifier":"p1","provides":"player","owned":true,"accessToken":"pt",
             "connections":[{"uri":"http://10.0.0.3:32500","local":true,"relay":false}]}
        ]"#;
        let servers = read_servers(body).unwrap();
        let names: Vec<&str> = servers.iter().map(|server| server.name.as_str()).collect();
        assert_eq!(names, ["Den", "Friend"]);
        assert_eq!(servers[0].addresses, ["http://192.168.1.4:32400"]);
        assert_eq!(servers[0].token, "dt");
        assert!(read_servers(b"not json").is_err());
    }
}
