//! A Subsonic request url carries the auth token and salt, so no error may show it.

#[test]
fn a_transport_error_loses_the_url_that_carries_the_token() {
    // The scheme is wrong, so the request fails before it reaches any network.
    let request = reqwest::Client::new()
        .get("ttps://music.example/rest/ping?u=me&t=secret-token&s=secret-salt")
        .send();
    let error = tokio::runtime::Runtime::new().unwrap().block_on(request).unwrap_err();
    let error = music::subsonic::scrub(opensubsonic::Error::Http(error));
    let shown = format!("{:#}", anyhow::Error::new(error).context("cannot reach the subsonic server"));
    assert!(!shown.contains("secret"), "{shown}");
}
