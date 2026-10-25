//! Turns the cookies a sign-in webview holds into the header a provider's `SignIn::Secret` takes,
//! the way upstream's `webview` crate does on desktop.

/// One cookie as the host's webview store reports it.
#[derive(Clone, Debug)]
pub struct Cookie {
    pub name: String,
    pub value: String,
    pub domain: String,
}

/// The `Cookie` header for `domain`, once it carries a non-empty `proof` cookie. `None` means the
/// user is not signed in yet, so the host keeps the webview open.
pub fn signed_in_header(cookies: &[Cookie], domain: &str, proof: &[&str]) -> Option<String> {
    let sent: Vec<&Cookie> = cookies
        .iter()
        .filter(|cookie| matches(&cookie.domain, domain))
        .collect();
    // A signed-out page may already set a proof cookie empty, so only a value counts.
    let proven = sent
        .iter()
        .any(|cookie| proof.contains(&cookie.name.as_str()) && !cookie.value.is_empty());
    proven.then(|| {
        sent.iter()
            .map(|cookie| format!("{}={}", cookie.name, cookie.value))
            .collect::<Vec<_>>()
            .join("; ")
    })
}

/// Whether a cookie stored for `stored` is sent to `domain` and its subdomains.
fn matches(stored: &str, domain: &str) -> bool {
    let stored = stored.trim_start_matches('.');
    stored == domain || stored.ends_with(&format!(".{domain}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cookie(name: &str, value: &str, domain: &str) -> Cookie {
        Cookie {
            name: name.to_owned(),
            value: value.to_owned(),
            domain: domain.to_owned(),
        }
    }

    #[test]
    fn header_joins_the_cookies_sent_to_the_domain_and_its_subdomains() {
        let cookies = [
            cookie("arl", "secret", ".deezer.com"),
            cookie("sid", "abc", "www.deezer.com"),
            cookie("other", "x", "example.com"),
            cookie("fake", "y", "notdeezer.com"),
        ];
        assert_eq!(
            signed_in_header(&cookies, "deezer.com", &["arl"]).as_deref(),
            Some("arl=secret; sid=abc")
        );
    }

    #[test]
    fn no_header_until_a_proof_cookie_has_a_value() {
        let signed_out = [
            cookie("arl", "", ".deezer.com"),
            cookie("sid", "abc", ".deezer.com"),
        ];
        assert_eq!(signed_in_header(&signed_out, "deezer.com", &["arl"]), None);
    }

    #[test]
    fn any_one_proof_cookie_is_enough() {
        let cookies = [cookie("__Secure-3PAPISID", "v", ".youtube.com")];
        assert!(
            signed_in_header(&cookies, "youtube.com", &["SAPISID", "__Secure-3PAPISID"]).is_some()
        );
    }

    #[test]
    fn a_proof_cookie_of_another_domain_does_not_count() {
        let cookies = [cookie("arl", "secret", ".example.com")];
        assert_eq!(signed_in_header(&cookies, "deezer.com", &["arl"]), None);
    }
}
