//! Podcasts: shows found through the iTunes Search API
//! (<https://performance-partners.apple.com/search-api>), which needs no key, or added by the
//! address of any RSS feed, and the episodes their feeds list.
//!
//! A feed is untrusted input. It is fetched with a time limit and a size cap, read as XML and
//! nothing else, and every description in it is stripped of its markup to plain text, so no
//! HTML from a feed is ever rendered. [`playback`] plays an episode's enclosure.

pub mod playback;

use std::time::Duration;

use anyhow::{Context as _, Result, bail};
use serde::{Deserialize, Serialize};

use crate::Track;

/// The source episodes play through.
pub const SLUG: &str = "podcast";

/// One show, as its row and page show it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Podcast {
    /// The address of its RSS feed, which is also what tells two shows apart.
    pub feed: String,
    pub title: String,
    #[serde(default)]
    pub author: String,
    /// Plain text: the feed's markup is stripped.
    #[serde(default)]
    pub description: String,
    /// Only an https image: a plain http one would be refused by the platform anyway.
    #[serde(default)]
    pub artwork: Option<String>,
}

/// One episode of a show, with what playing and listing it needs.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Episode {
    /// Made from the feed and the episode's guid, so it stays the same however the feed changes
    /// around it, and says nothing of either.
    pub id: String,
    pub title: String,
    /// The enclosure: the audio file itself.
    pub url: String,
    #[serde(default)]
    pub mime: Option<String>,
    /// How long the episode is, when the feed says.
    #[serde(default)]
    pub duration_secs: Option<u64>,
    /// When it came out, in Unix seconds, when the feed's date reads.
    #[serde(default)]
    pub published: Option<i64>,
    /// Its own image, when it has one apart from the show's.
    #[serde(default)]
    pub artwork: Option<String>,
}

impl Episode {
    /// The episode as a track: its title, the show as the artists, its image or else the show's
    /// as the cover, its length, and its date as when it was added.
    pub fn track(&self, podcast: &Podcast) -> Track {
        Track {
            id: Some(self.id.clone()),
            name: self.title.clone(),
            playable: true,
            artists: podcast.title.clone(),
            artist_refs: Vec::new(),
            album: String::new(),
            album_id: None,
            cover: self.artwork.clone().or_else(|| podcast.artwork.clone()),
            duration: Duration::from_secs(self.duration_secs.unwrap_or(0)),
            added_at: self.published,
            added_by: None,
            playcount: None,
            popularity: 0,
            explicit: false,
            track_number: 0,
            disc_number: 0,
            tags: Vec::new(),
            languages: Vec::new(),
            credits: Vec::new(),
        }
    }
}

/// A show and its episodes, newest first.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Feed {
    pub podcast: Podcast,
    pub episodes: Vec<Episode>,
}

const ITUNES: &str = "http://www.itunes.com/dtds/podcast-1.0.dtd";
/// The most a feed may take. The longest-running shows list thousands of episodes in a few
/// megabytes; anything past this is not a feed worth reading on a phone.
pub const FEED_CAP: usize = 10 * 1024 * 1024;
const SEARCH_CAP: usize = 2 * 1024 * 1024;
const SEARCH: &str = "https://itunes.apple.com/search";

/// Reads the RSS 2.0 feed at `url` from `xml`. An item without an audio enclosure on the web is
/// left out; one whose other fields do not read keeps what does.
pub fn parse_feed(url: &str, xml: &[u8]) -> Result<Feed> {
    let text = String::from_utf8_lossy(xml);
    let document = roxmltree::Document::parse(&text).context("the feed is not XML")?;
    let root = document.root_element();
    if root.tag_name().name() != "rss" {
        bail!("not an RSS feed");
    }
    let channel = child(root, "channel").context("the feed has no channel")?;
    let title = strip_html(&text_of(child(channel, "title")));
    let author = Some(text_of(itunes(channel, "author")))
        .filter(|author| !author.is_empty())
        .or_else(|| {
            let owner = itunes(channel, "owner").and_then(|owner| itunes(owner, "name"));
            Some(text_of(owner)).filter(|name| !name.is_empty())
        })
        .unwrap_or_else(|| editor(&text_of(child(channel, "managingEditor"))));
    let description = Some(text_of(child(channel, "description")))
        .filter(|description| !description.is_empty())
        .unwrap_or_else(|| text_of(itunes(channel, "summary")));
    let artwork = image(channel).or_else(|| {
        web_image(&text_of(
            child(channel, "image").and_then(|image| child(image, "url")),
        ))
    });
    let podcast = Podcast {
        feed: url.to_owned(),
        title,
        author: strip_html(&author),
        description: strip_html(&description),
        artwork,
    };
    let mut episodes: Vec<Episode> = channel
        .children()
        .filter(|node| is(node, None, "item"))
        .filter_map(|item| episode(url, &podcast, item))
        .collect();
    // Newest first; an episode with no date that reads goes last, in the feed's order.
    episodes.sort_by_key(|episode| std::cmp::Reverse(episode.published));
    Ok(Feed { podcast, episodes })
}

fn episode(feed: &str, podcast: &Podcast, item: roxmltree::Node) -> Option<Episode> {
    let enclosure = child(item, "enclosure")?;
    let url = enclosure.attribute("url")?.trim();
    if !web(url) {
        return None;
    }
    let mime = enclosure
        .attribute("type")
        .map(|mime| mime.trim().to_lowercase())
        .filter(|mime| !mime.is_empty());
    if mime
        .as_deref()
        .is_some_and(|mime| mime.starts_with("video/"))
    {
        return None;
    }
    let guid = Some(text_of(child(item, "guid")))
        .filter(|guid| !guid.is_empty())
        .unwrap_or_else(|| url.to_owned());
    let title = Some(strip_html(&text_of(child(item, "title"))))
        .filter(|title| !title.is_empty())
        .unwrap_or_else(|| podcast.title.clone());
    Some(Episode {
        id: episode_id(feed, &guid),
        title,
        url: url.to_owned(),
        mime,
        duration_secs: parse_duration(&text_of(itunes(item, "duration"))),
        published: parse_date(&text_of(child(item, "pubDate"))),
        artwork: image(item),
    })
}

/// A short hash of the feed and the guid, in hex.
fn episode_id(feed: &str, guid: &str) -> String {
    let digest = ring::digest::digest(&ring::digest::SHA256, format!("{feed}\n{guid}").as_bytes());
    digest.as_ref()[..12]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn is(node: &roxmltree::Node, namespace: Option<&str>, name: &str) -> bool {
    node.is_element() && node.tag_name().name() == name && node.tag_name().namespace() == namespace
}

/// The plain RSS child called `name`.
fn child<'a, 'input>(
    node: roxmltree::Node<'a, 'input>,
    name: &str,
) -> Option<roxmltree::Node<'a, 'input>> {
    node.children().find(|child| is(child, None, name))
}

/// The iTunes namespace child called `name`.
fn itunes<'a, 'input>(
    node: roxmltree::Node<'a, 'input>,
    name: &str,
) -> Option<roxmltree::Node<'a, 'input>> {
    node.children().find(|child| is(child, Some(ITUNES), name))
}

/// All the text in `node`, CDATA included, trimmed.
fn text_of(node: Option<roxmltree::Node>) -> String {
    node.map(|node| {
        node.descendants()
            .filter(roxmltree::Node::is_text)
            .filter_map(|text| text.text())
            .collect::<String>()
            .trim()
            .to_owned()
    })
    .unwrap_or_default()
}

/// The `itunes:image` of a channel or an item, when it is on https.
fn image(node: roxmltree::Node) -> Option<String> {
    web_image(itunes(node, "image")?.attribute("href")?)
}

fn web_image(url: &str) -> Option<String> {
    let url = url.trim();
    url.starts_with("https://").then(|| url.to_owned())
}

/// Whether `url` is on the web, which is all a feed or enclosure may point at.
pub fn web(url: &str) -> bool {
    let lower = url.trim_start().to_lowercase();
    (lower.starts_with("https://") || lower.starts_with("http://")) && host(url) != "?"
}

/// The name in an RSS `managingEditor`, which is an address and a name in parentheses.
fn editor(text: &str) -> String {
    match (text.find('('), text.rfind(')')) {
        (Some(open), Some(close)) if open < close => text[open + 1..close].trim().to_owned(),
        _ => text.trim().to_owned(),
    }
}

/// How long an `itunes:duration` says: whole seconds, or `hh:mm:ss` or `mm:ss`.
pub fn parse_duration(text: &str) -> Option<u64> {
    let parts: Vec<&str> = text.trim().split(':').collect();
    if parts.len() > 3 {
        return None;
    }
    let mut seconds: u64 = 0;
    for (index, part) in parts.iter().enumerate() {
        // Only the last part may have a fraction, which is dropped.
        let whole = match index == parts.len() - 1 {
            true => part.split_once('.').map_or(*part, |(whole, _)| whole),
            false => part,
        };
        if whole.is_empty() || !whole.bytes().all(|byte| byte.is_ascii_digit()) {
            return None;
        }
        seconds = seconds.checked_mul(60)?.checked_add(whole.parse().ok()?)?;
    }
    (seconds > 0).then_some(seconds)
}

/// An RSS `pubDate` in Unix seconds. RFC 2822 as feeds really write it: with or without the
/// weekday and the seconds, full month names, US zone names. ISO 8601 is read too, since some
/// feeds use it.
pub fn parse_date(text: &str) -> Option<i64> {
    use time::format_description::well_known::Rfc3339;
    let text = text.trim();
    if let Ok(date) = time::OffsetDateTime::parse(text, &Rfc3339) {
        return Some(date.unix_timestamp());
    }
    let spaced = text.replace(',', " ");
    let mut tokens = spaced.split_whitespace().peekable();
    if tokens
        .peek()
        .is_some_and(|weekday| weekday.chars().all(char::is_alphabetic))
    {
        tokens.next();
    }
    let day: u8 = tokens.next()?.parse().ok()?;
    let month = month(tokens.next()?)?;
    let year: i32 = match tokens.next()?.parse().ok()? {
        year @ 0..50 => 2000 + year,
        year @ 50..100 => 1900 + year,
        year => year,
    };
    let mut clock = tokens.next()?.split(':');
    let hour: u8 = clock.next()?.parse().ok()?;
    let minute: u8 = clock.next()?.parse().ok()?;
    let second: u8 = clock.next().map_or(Some(0), |second| second.parse().ok())?;
    let offset = tokens.next().map_or(Some(0), zone)?;
    let date = time::Date::from_calendar_date(year, month, day).ok()?;
    let at = time::Time::from_hms(hour, minute, second).ok()?;
    let offset = time::UtcOffset::from_whole_seconds(offset).ok()?;
    Some(
        time::PrimitiveDateTime::new(date, at)
            .assume_offset(offset)
            .unix_timestamp(),
    )
}

fn month(name: &str) -> Option<time::Month> {
    const MONTHS: [&str; 12] = [
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
    ];
    let short = name.get(..3)?.to_lowercase();
    let index = MONTHS.iter().position(|month| *month == short)?;
    time::Month::try_from(index as u8 + 1).ok()
}

/// A zone as seconds east of UTC: `+hhmm`, `-hhmm`, or a name RFC 2822 allows. An unknown
/// name counts as UTC rather than losing the date.
fn zone(text: &str) -> Option<i32> {
    let hours = match text.to_uppercase().as_str() {
        "GMT" | "UT" | "UTC" | "Z" => 0,
        "EDT" => -4,
        "EST" | "CDT" => -5,
        "CST" | "MDT" => -6,
        "MST" | "PDT" => -7,
        "PST" => -8,
        zone if zone.chars().all(char::is_alphabetic) => 0,
        _ => {
            let (sign, digits) = match text.as_bytes().first()? {
                b'+' => (1, &text[1..]),
                b'-' => (-1, &text[1..]),
                _ => return None,
            };
            if digits.len() != 4 || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
                return None;
            }
            let hours: i32 = digits[..2].parse().ok()?;
            let minutes: i32 = digits[2..].parse().ok()?;
            return Some(sign * (hours * 3600 + minutes * 60));
        }
    };
    Some(hours * 3600)
}

/// The text of an HTML fragment, with its tags gone, its entities decoded and its paragraphs
/// and line breaks kept as new lines. Scripts and styles go whole.
pub fn strip_html(html: &str) -> String {
    let mut text = String::with_capacity(html.len());
    let mut rest = html;
    while let Some(open) = rest.find('<') {
        text.push_str(&rest[..open]);
        let after = &rest[open + 1..];
        // A `<` that opens no tag, as in "5 < 6", is text.
        if !after
            .chars()
            .next()
            .is_some_and(|next| next.is_ascii_alphabetic() || matches!(next, '/' | '!' | '?'))
        {
            text.push('<');
            rest = after;
            continue;
        }
        if let Some(comment) = after.strip_prefix("!--") {
            rest = comment.find("-->").map_or("", |end| &comment[end + 3..]);
            continue;
        }
        let Some(close) = after.find('>') else {
            rest = "";
            break;
        };
        let name: String = after[..close]
            .trim_start_matches('/')
            .chars()
            .take_while(char::is_ascii_alphanumeric)
            .collect::<String>()
            .to_lowercase();
        let closing = after.starts_with('/');
        rest = &after[close + 1..];
        if !closing && (name == "script" || name == "style") {
            let end = format!("</{name}");
            rest = match rest.to_lowercase().find(&end) {
                Some(at) => rest[at..].find('>').map_or("", |gt| &rest[at + gt + 1..]),
                None => "",
            };
            continue;
        }
        let breaks = name == "br"
            || closing
                && matches!(
                    name.as_str(),
                    "p" | "div"
                        | "li"
                        | "tr"
                        | "h1"
                        | "h2"
                        | "h3"
                        | "h4"
                        | "h5"
                        | "h6"
                        | "blockquote"
                );
        if breaks {
            text.push('\n');
        }
    }
    text.push_str(rest);
    let decoded = decode_entities(&text);
    let mut lines: Vec<String> = Vec::new();
    for line in decoded.lines() {
        let line = line.split_whitespace().collect::<Vec<_>>().join(" ");
        // At most one empty line in a row, and none at the start.
        if line.is_empty() && lines.last().is_none_or(String::is_empty) {
            continue;
        }
        lines.push(line);
    }
    while lines.last().is_some_and(String::is_empty) {
        lines.pop();
    }
    lines.join("\n")
}

/// Decodes the entities HTML text uses most; an unknown one stays as written.
fn decode_entities(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(amp) = rest.find('&') {
        out.push_str(&rest[..amp]);
        let after = &rest[amp + 1..];
        let decoded = after.find(';').filter(|end| *end <= 10).and_then(|end| {
            let name = &after[..end];
            let char = match name {
                "amp" => '&',
                "lt" => '<',
                "gt" => '>',
                "quot" => '"',
                "apos" => '\'',
                "nbsp" => ' ',
                _ => {
                    let code = match name.strip_prefix("#x").or_else(|| name.strip_prefix("#X")) {
                        Some(hex) => u32::from_str_radix(hex, 16).ok()?,
                        None => name.strip_prefix('#')?.parse().ok()?,
                    };
                    char::from_u32(code)?
                }
            };
            Some((char, end))
        });
        match decoded {
            Some((char, end)) => {
                out.push(char);
                rest = &after[end + 1..];
            }
            None => {
                out.push('&');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

#[derive(Deserialize)]
struct Found {
    #[serde(default)]
    results: Vec<WireShow>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WireShow {
    #[serde(default)]
    collection_name: Option<String>,
    #[serde(default)]
    artist_name: Option<String>,
    #[serde(default)]
    feed_url: Option<String>,
    #[serde(default)]
    artwork_url600: Option<String>,
    #[serde(default)]
    artwork_url100: Option<String>,
}

/// The shows in an iTunes Search API answer that have a feed to read.
pub fn search_results(json: &[u8]) -> Result<Vec<Podcast>> {
    let found: Found = serde_json::from_slice(json).context("cannot read the search results")?;
    Ok(found
        .results
        .into_iter()
        .filter_map(|show| {
            let feed = show.feed_url?.trim().to_owned();
            let title = show.collection_name?.trim().to_owned();
            if !web(&feed) || title.is_empty() {
                return None;
            }
            Some(Podcast {
                feed,
                title,
                author: show.artist_name.unwrap_or_default().trim().to_owned(),
                description: String::new(),
                artwork: show
                    .artwork_url600
                    .and_then(|url| web_image(&url))
                    .or_else(|| show.artwork_url100.and_then(|url| web_image(&url))),
            })
        })
        .collect())
}

/// The host of `url`, which is all a log line names: a feed or enclosure address may carry a
/// private token in its path or query.
pub fn host(url: &str) -> &str {
    let Some((_, rest)) = url.trim().split_once("://") else {
        return "?";
    };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    let host = authority.rsplit('@').next().unwrap_or_default();
    let host = host.split(':').next().unwrap_or_default();
    if host.is_empty() { "?" } else { host }
}

/// The iTunes Search API and the feeds it points at, through one client with a time limit.
#[derive(Clone)]
pub struct Directory {
    http: reqwest::Client,
}

impl Default for Directory {
    fn default() -> Self {
        Self::new()
    }
}

impl Directory {
    pub fn new() -> Self {
        Self {
            http: reqwest::Client::builder()
                .user_agent(crate::radio::AGENT)
                .connect_timeout(Duration::from_secs(10))
                .timeout(Duration::from_secs(30))
                .build()
                .unwrap_or_default(),
        }
    }

    /// The shows matching `term`, as Apple ranks them.
    pub async fn search(&self, term: &str) -> Result<Vec<Podcast>> {
        let term = term.trim();
        if term.is_empty() {
            return Ok(Vec::new());
        }
        let response = self
            .http
            .get(SEARCH)
            .query(&[
                ("media", "podcast"),
                ("entity", "podcast"),
                ("term", term),
                ("limit", "40"),
            ])
            .send()
            .await
            .map_err(reqwest::Error::without_url)
            .context("cannot reach the podcast directory")?;
        search_results(&body(response, SEARCH_CAP, "the podcast directory").await?)
    }

    /// Fetches and reads the feed at `url`.
    pub async fn feed(&self, url: &str) -> Result<Feed> {
        if !web(url) {
            bail!("a feed address starts with http:// or https://");
        }
        let host = host(url);
        let response = self
            .http
            .get(url.trim())
            .send()
            .await
            .map_err(reqwest::Error::without_url)
            .with_context(|| format!("cannot reach {host}"))?;
        let xml = body(response, FEED_CAP, host).await?;
        let feed = parse_feed(url.trim(), &xml).with_context(|| format!("{host} sent no feed"))?;
        log::info!("podcast: read {} episodes from {host}", feed.episodes.len());
        Ok(feed)
    }
}

/// The body of `response`, refused once it passes `cap` bytes.
async fn body(mut response: reqwest::Response, cap: usize, from: &str) -> Result<Vec<u8>> {
    let status = response.status();
    if !status.is_success() {
        bail!("{from} answered with status {status}");
    }
    if response
        .content_length()
        .is_some_and(|length| length > cap as u64)
    {
        bail!("{from} sent more than {} MB", cap / 1024 / 1024);
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(reqwest::Error::without_url)?
    {
        if bytes.len() + chunk.len() > cap {
            bail!("{from} sent more than {} MB", cap / 1024 / 1024);
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Shaped like a real show's feed: the iTunes namespace, CDATA descriptions in HTML, mixed
    /// duration and date styles, items out of order, and items a careless feed lists: one with
    /// no enclosure, a video, one with no guid, one whose duration and date do not read.
    const FEED: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:atom="http://www.w3.org/2005/Atom">
  <channel>
    <atom:link href="https://feeds.example.com/show" rel="self" type="application/rss+xml"/>
    <title> The Example Show </title>
    <link>https://example.com</link>
    <language>en-us</language>
    <itunes:author>Example Media</itunes:author>
    <description><![CDATA[<p>Stories about <b>examples</b> &amp; more.</p><p>New episodes every <i>Tuesday</i>.</p>]]></description>
    <itunes:image href="https://cdn.example.com/show-3000.jpg"/>
    <image><url>https://cdn.example.com/show-small.jpg</url><title>The Example Show</title></image>
    <item>
      <title>Episode 1: The beginning</title>
      <guid isPermaLink="false">ep-0001</guid>
      <pubDate>Tue, 07 Oct 2025 08:00:00 GMT</pubDate>
      <enclosure url="https://cdn.example.com/ep1.mp3?token=secret" length="12345678" type="audio/mpeg"/>
      <itunes:duration>00:45:30</itunes:duration>
      <description>First one.</description>
    </item>
    <item>
      <title><![CDATA[Episode 3: Fish &amp; chips]]></title>
      <guid>https://example.com/?p=3</guid>
      <pubDate>Tue, 21 Oct 2025 08:00:00 -0400</pubDate>
      <enclosure url="https://cdn.example.com/ep3.m4a" length="0" type="audio/x-m4a"/>
      <itunes:duration>3723</itunes:duration>
      <itunes:image href="https://cdn.example.com/ep3.jpg"/>
    </item>
    <item>
      <title>Episode 2</title>
      <pubDate>14 Oct 2025 8:00 PDT</pubDate>
      <enclosure url="http://cdn.example.com/ep2.mp3" type="audio/mpeg"/>
      <itunes:duration>62:03</itunes:duration>
      <itunes:image href="http://cdn.example.com/ep2.jpg"/>
    </item>
    <item>
      <title>Bonus: no audio here</title>
      <guid>bonus-text</guid>
      <pubDate>Wed, 22 Oct 2025 08:00:00 GMT</pubDate>
    </item>
    <item>
      <title>Video edition</title>
      <guid>video-1</guid>
      <enclosure url="https://cdn.example.com/ep.mp4" length="1" type="video/mp4"/>
    </item>
    <item>
      <title>  </title>
      <guid>broken-1</guid>
      <pubDate>sometime last week</pubDate>
      <enclosure url="https://cdn.example.com/broken.mp3" length="lots" type="audio/mpeg"/>
      <itunes:duration>about an hour</itunes:duration>
    </item>
    <item>
      <title>Not a web address</title>
      <guid>ftp-1</guid>
      <enclosure url="ftp://cdn.example.com/ep.mp3" type="audio/mpeg"/>
    </item>
  </channel>
</rss>"#;

    fn feed() -> Feed {
        parse_feed("https://feeds.example.com/show", FEED.as_bytes()).unwrap()
    }

    #[test]
    fn a_feed_reads_its_show() {
        let podcast = feed().podcast;
        assert_eq!(podcast.feed, "https://feeds.example.com/show");
        assert_eq!(podcast.title, "The Example Show");
        assert_eq!(podcast.author, "Example Media");
        assert_eq!(
            podcast.description,
            "Stories about examples & more.\nNew episodes every Tuesday."
        );
        assert_eq!(
            podcast.artwork.as_deref(),
            Some("https://cdn.example.com/show-3000.jpg"),
            "itunes:image wins over the small RSS image"
        );
    }

    #[test]
    fn episodes_come_newest_first_and_the_unplayable_are_left_out() {
        let titles: Vec<String> = feed()
            .episodes
            .into_iter()
            .map(|episode| episode.title)
            .collect();
        assert_eq!(
            titles,
            [
                "Episode 3: Fish & chips",
                "Episode 2",
                "Episode 1: The beginning",
                // No date reads, so it goes last; no title, so it borrows the show's.
                "The Example Show",
            ]
        );
    }

    #[test]
    fn an_episode_reads_its_enclosure_duration_date_and_image() {
        let episodes = feed().episodes;
        let third = &episodes[0];
        assert_eq!(third.url, "https://cdn.example.com/ep3.m4a");
        assert_eq!(third.mime.as_deref(), Some("audio/x-m4a"));
        assert_eq!(third.duration_secs, Some(3723));
        assert_eq!(
            third.published,
            Some(1_761_048_000),
            "08:00 at -0400 is 12:00 UTC"
        );
        assert_eq!(
            third.artwork.as_deref(),
            Some("https://cdn.example.com/ep3.jpg")
        );
        let second = &episodes[1];
        assert_eq!(
            second.url, "http://cdn.example.com/ep2.mp3",
            "plain http audio plays"
        );
        assert_eq!(second.duration_secs, Some(3723));
        assert_eq!(second.published, Some(1_760_454_000), "PDT is -0700");
        assert_eq!(second.artwork, None, "a plain http image is left out");
        let first = &episodes[2];
        assert_eq!(first.duration_secs, Some(2730));
        assert_eq!(first.published, Some(1_759_824_000));
    }

    #[test]
    fn a_partial_item_still_plays_with_what_reads() {
        let broken = feed().episodes.pop().unwrap();
        assert_eq!(broken.url, "https://cdn.example.com/broken.mp3");
        assert_eq!(broken.duration_secs, None);
        assert_eq!(broken.published, None);
    }

    #[test]
    fn ids_are_stable_distinct_and_say_nothing_of_the_feed() {
        let first = feed();
        let again = feed();
        let ids: Vec<&str> = first
            .episodes
            .iter()
            .map(|episode| episode.id.as_str())
            .collect();
        let same: Vec<&str> = again
            .episodes
            .iter()
            .map(|episode| episode.id.as_str())
            .collect();
        assert_eq!(ids, same);
        let mut unique = ids.clone();
        unique.sort();
        unique.dedup();
        assert_eq!(unique.len(), ids.len());
        for id in ids {
            assert!(id.chars().all(|c| c.is_ascii_hexdigit()), "{id}");
            assert!(!id.contains("example"));
        }
        // The same guid in another feed is another episode.
        let elsewhere = parse_feed("https://other.example.org/rss", FEED.as_bytes()).unwrap();
        assert_ne!(elsewhere.episodes[0].id, first.episodes[0].id);
    }

    #[test]
    fn an_episode_plays_as_a_track_of_its_show() {
        let feed = feed();
        let track = feed.episodes[1].track(&feed.podcast);
        assert_eq!(track.id.as_deref(), Some(feed.episodes[1].id.as_str()));
        assert_eq!(track.name, "Episode 2");
        assert_eq!(track.artists, "The Example Show");
        assert_eq!(track.album, "", "the show is already the artists");
        assert_eq!(
            track.cover.as_deref(),
            Some("https://cdn.example.com/show-3000.jpg")
        );
        assert_eq!(track.duration, Duration::from_secs(3723));
        assert_eq!(track.added_at, Some(1_760_454_000));
        assert!(track.playable);
        let own = feed.episodes[0].track(&feed.podcast);
        assert_eq!(
            own.cover.as_deref(),
            Some("https://cdn.example.com/ep3.jpg")
        );
    }

    #[test]
    fn what_is_not_an_rss_feed_is_an_error() {
        assert!(parse_feed("https://x", b"<html><body>Not found</body></html>").is_err());
        assert!(parse_feed("https://x", b"<rss><channel><title>cut off").is_err());
        assert!(parse_feed("https://x", b"{\"json\":true}").is_err());
        assert!(parse_feed("https://x", b"").is_err());
    }

    #[test]
    fn a_feed_without_itunes_tags_falls_back_on_plain_rss() {
        let xml = r#"<rss version="2.0"><channel>
            <title>Plain</title>
            <managingEditor>editor@example.com (Ed Itor)</managingEditor>
            <description>Just text &lt;b&gt;escaped&lt;/b&gt;</description>
            <image><url>https://cdn.example.com/plain.png</url></image>
            <item><title>One</title><enclosure url="https://cdn.example.com/1.mp3"/></item>
        </channel></rss>"#;
        let feed = parse_feed("https://plain.example.com/rss", xml.as_bytes()).unwrap();
        assert_eq!(feed.podcast.author, "Ed Itor");
        assert_eq!(feed.podcast.description, "Just text escaped");
        assert_eq!(
            feed.podcast.artwork.as_deref(),
            Some("https://cdn.example.com/plain.png")
        );
        assert_eq!(feed.episodes.len(), 1);
        assert_eq!(feed.episodes[0].mime, None);
    }

    #[test]
    fn durations_read_in_every_style_feeds_use() {
        assert_eq!(parse_duration("3723"), Some(3723));
        assert_eq!(parse_duration(" 3723.6 "), Some(3723));
        assert_eq!(parse_duration("01:02:03"), Some(3723));
        assert_eq!(parse_duration("1:2:3"), Some(3723));
        assert_eq!(parse_duration("62:03"), Some(3723));
        assert_eq!(parse_duration("00:45:30.500"), Some(2730));
        assert_eq!(parse_duration("0"), None, "zero is no length");
        assert_eq!(parse_duration("00:00:00"), None);
        assert_eq!(parse_duration(""), None);
        assert_eq!(parse_duration("about an hour"), None);
        assert_eq!(parse_duration("1:2:3:4"), None);
        assert_eq!(parse_duration("-5"), None);
    }

    #[test]
    fn dates_read_as_feeds_write_them() {
        let noon = Some(1_761_048_000); // 2025-10-21 12:00:00 UTC
        assert_eq!(parse_date("Tue, 21 Oct 2025 12:00:00 +0000"), noon);
        assert_eq!(parse_date("Tue, 21 Oct 2025 12:00:00 GMT"), noon);
        assert_eq!(parse_date("Tue, 21 Oct 2025 12:00:00 UT"), noon);
        assert_eq!(parse_date("21 Oct 2025 12:00:00 Z"), noon);
        assert_eq!(parse_date("Tue, 21 Oct 2025 08:00:00 -0400"), noon);
        assert_eq!(parse_date("Tue, 21 Oct 2025 08:00:00 EDT"), noon);
        assert_eq!(parse_date("Tuesday, 21 October 2025 07:00:00 EST"), noon);
        assert_eq!(
            parse_date("Tue, 21 Oct 2025 12:00 +0000"),
            noon,
            "no seconds"
        );
        assert_eq!(
            parse_date("Tue,21 Oct 2025 12:00:00 +0000"),
            noon,
            "no space"
        );
        assert_eq!(
            parse_date("Tue, 21 Oct 2025 12:00:00"),
            noon,
            "no zone is UTC"
        );
        assert_eq!(
            parse_date("Tue, 21 Oct 25 12:00:00 +0000"),
            noon,
            "two-digit year"
        );
        assert_eq!(parse_date("2025-10-21T12:00:00Z"), noon);
        assert_eq!(parse_date("2025-10-21T14:00:00+02:00"), noon);
        assert_eq!(
            parse_date("Tue, 1 Oct 2025 00:00:00 +0000"),
            Some(1_759_276_800)
        );
        assert_eq!(parse_date(""), None);
        assert_eq!(parse_date("sometime last week"), None);
        assert_eq!(parse_date("Tue, 32 Oct 2025 12:00:00 +0000"), None);
        assert_eq!(parse_date("Tue, 21 Foo 2025 12:00:00 +0000"), None);
    }

    #[test]
    fn html_is_stripped_to_text() {
        assert_eq!(strip_html("plain"), "plain");
        assert_eq!(
            strip_html("<p>One &amp; two</p><p>Three<br/>four</p>"),
            "One & two\nThree\nfour"
        );
        assert_eq!(strip_html("<ul><li>a</li><li>b</li></ul>"), "a\nb");
        assert_eq!(
            strip_html(
                "<script>alert('x')</script><style>p{}</style>Safe <a href=\"javascript:x\">link</a>"
            ),
            "Safe link"
        );
        assert_eq!(
            strip_html("&lt;b&gt; &quot;q&quot; &#39;s&#39; &#x263A; &nbsp;x &unknown; 5 < 6"),
            "<b> \"q\" 's' \u{263A} x &unknown; 5 < 6"
        );
        assert_eq!(
            strip_html("  lots   of\n\n\n\n space  "),
            "lots of\n\nspace"
        );
        assert_eq!(strip_html("<p>unclosed <b"), "unclosed");
    }

    /// Trimmed from a real `itunes.apple.com/search?media=podcast` answer, with a show that has
    /// no feed added, as Apple-only shows come back.
    const SEARCH: &str = r#"{
      "resultCount": 3,
      "results": [
        {"wrapperType":"track","kind":"podcast","collectionId":1200361736,"trackId":1200361736,"artistName":"The New York Times","collectionName":"The Daily","trackName":"The Daily","feedUrl":"https://feeds.simplecast.com/54nAGcIl","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Podcasts/100x100bb.jpg","artworkUrl600":"https://is1-ssl.mzstatic.com/image/thumb/Podcasts/600x600bb.jpg","trackCount":2500,"primaryGenreName":"Daily News"},
        {"wrapperType":"track","kind":"podcast","collectionId":1,"artistName":"Apple Only","collectionName":"No Feed Here"},
        {"wrapperType":"track","kind":"podcast","collectionId":2,"artistName":"","collectionName":"Small Art","feedUrl":"http://example.com/feed.xml","artworkUrl100":"https://example.com/100.jpg"}
      ]
    }"#;

    #[test]
    fn search_results_keep_the_shows_with_a_feed() {
        let found = search_results(SEARCH.as_bytes()).unwrap();
        assert_eq!(
            found,
            [
                Podcast {
                    feed: "https://feeds.simplecast.com/54nAGcIl".to_owned(),
                    title: "The Daily".to_owned(),
                    author: "The New York Times".to_owned(),
                    description: String::new(),
                    artwork: Some(
                        "https://is1-ssl.mzstatic.com/image/thumb/Podcasts/600x600bb.jpg"
                            .to_owned()
                    ),
                },
                Podcast {
                    feed: "http://example.com/feed.xml".to_owned(),
                    title: "Small Art".to_owned(),
                    author: String::new(),
                    description: String::new(),
                    artwork: Some("https://example.com/100.jpg".to_owned()),
                },
            ]
        );
        assert!(search_results(b"<html>").is_err());
    }

    /// Searches the directory for a well-known show, reads its feed, and asks the first episode's
    /// enclosure for its first kilobyte with a range request. Needs the network:
    /// `cargo test -p music podcast -- --ignored --nocapture`.
    #[tokio::test]
    #[ignore]
    async fn live_a_known_show_searches_reads_and_streams() {
        let directory = Directory::new();
        let found = directory.search("Radiolab").await.unwrap();
        let show = found
            .iter()
            .find(|show| show.title.contains("Radiolab"))
            .expect("Radiolab is listed");
        let feed = directory.feed(&show.feed).await.unwrap();
        assert!(!feed.podcast.title.is_empty());
        assert!(feed.episodes.len() > 10, "{} episodes", feed.episodes.len());
        let newest = &feed.episodes[0];
        assert!(newest.published.is_some() && newest.duration_secs.is_some());
        let response = reqwest::Client::new()
            .get(&newest.url)
            .header("Range", "bytes=0-1023")
            .send()
            .await
            .unwrap();
        let status = response.status();
        assert!(status.is_success(), "{status}");
        let length = response.headers().get("content-range").cloned();
        let first = response.bytes().await.unwrap();
        assert!(!first.is_empty());
        println!(
            "{} by {}: {} episodes from {}; newest {:?} ({:?}s), {status} {length:?}, {} bytes",
            feed.podcast.title,
            feed.podcast.author,
            feed.episodes.len(),
            host(&show.feed),
            newest.title,
            newest.duration_secs,
            first.len()
        );
    }

    #[test]
    fn a_log_names_only_the_host() {
        assert_eq!(
            host("https://feeds.example.com/show/rss?token=secret"),
            "feeds.example.com"
        );
        assert_eq!(
            host("http://user:pass@cdn.example.com:8080/a.mp3"),
            "cdn.example.com"
        );
        assert_eq!(host("not a url"), "?");
    }
}
