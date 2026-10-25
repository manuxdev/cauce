//! Providers hand out covers sized for a list row. A full-screen player needs the same image far
//! larger, which both image CDNs serve when the size in the url is changed.

/// The edge, in pixels, a full-screen cover is asked for: a phone's width at 3x.
const LARGE: u32 = 1200;

/// `url` asking its CDN for a `LARGE` image. A url from a CDN this does not know is answered as
/// it came.
pub fn large(url: &str) -> String {
    if url.contains("dzcdn.net/images/") {
        return deezer(url).unwrap_or_else(|| url.to_owned());
    }
    if url.contains("googleusercontent.com/") || url.contains("ggpht.com/") {
        return google(url).unwrap_or_else(|| url.to_owned());
    }
    url.to_owned()
}

/// `…/300x300-000000-80-0-0.jpg`: the size leads the file name.
fn deezer(url: &str) -> Option<String> {
    let (folder, file) = url.rsplit_once('/')?;
    let (size, rest) = file.split_once('-')?;
    let (width, height) = size.split_once('x')?;
    let numeric = |part: &str| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit());
    (numeric(width) && numeric(height)).then(|| format!("{folder}/{LARGE}x{LARGE}-{rest}"))
}

/// `…=w120-h120-l90-rj` or `…=s120`: sizes are the `w`, `h` and `s` options after the last `=`.
fn google(url: &str) -> Option<String> {
    let (image, options) = url.rsplit_once('=')?;
    let options: Vec<String> = options
        .split('-')
        .map(|option| match option.split_at_checked(1) {
            Some((kind @ ("w" | "h" | "s"), digits))
                if !digits.is_empty() && digits.bytes().all(|byte| byte.is_ascii_digit()) =>
            {
                format!("{kind}{LARGE}")
            }
            _ => option.to_owned(),
        })
        .collect();
    Some(format!("{image}={}", options.join("-")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deezer_covers_ask_for_the_large_size() {
        assert_eq!(
            large("https://cdn-images.dzcdn.net/images/cover/abc123/300x300-000000-80-0-0.jpg"),
            "https://cdn-images.dzcdn.net/images/cover/abc123/1200x1200-000000-80-0-0.jpg"
        );
    }

    #[test]
    fn google_thumbnails_ask_for_the_large_size() {
        assert_eq!(
            large("https://lh3.googleusercontent.com/xyz=w120-h120-l90-rj"),
            "https://lh3.googleusercontent.com/xyz=w1200-h1200-l90-rj"
        );
        assert_eq!(
            large("https://yt3.ggpht.com/abc=w60-h60-p-l90-rj"),
            "https://yt3.ggpht.com/abc=w1200-h1200-p-l90-rj"
        );
    }

    #[test]
    fn google_thumbnails_with_a_single_size_ask_for_the_large_size() {
        assert_eq!(
            large("https://lh3.googleusercontent.com/xyz=s120"),
            "https://lh3.googleusercontent.com/xyz=s1200"
        );
    }

    #[test]
    fn other_urls_and_paths_are_left_alone() {
        let video = "https://i.ytimg.com/vi/abc/hqdefault.jpg";
        assert_eq!(large(video), video);
        assert_eq!(large("/var/cache/cover.jpg"), "/var/cache/cover.jpg");
    }
}
