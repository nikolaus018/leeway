//! Official weather warnings from MeteoAlarm (the national weather services' CAP feeds), refreshed in
//! the background so app requests never wait on them. English texts come from each CAP message.
//! The feeds name areas by EMMA_ID code only; their outlines (MeteoAlarm/EUMETNET, CC0) are fetched
//! once per code and cached, so warnings are matched to the map by area, and the app can draw them.

use std::{collections::HashMap, sync::Arc, time::Duration};

use anyhow::Result;
use serde::Serialize;
use tokio::sync::RwLock;

use crate::{config::Config, metrics};

/// MeteoAlarm feed slug, ISO code, and the country's rough bounding box (west, south, east, north),
/// for the seas Leeway sails in.
const COUNTRIES: &[(&str, &str, [f64; 4])] = &[
    ("croatia", "HR", [13.4, 42.3, 19.5, 46.6]),
    ("slovenia", "SI", [13.3, 45.4, 16.7, 46.9]),
    ("bosnia-herzegovina", "BA", [15.7, 42.5, 19.7, 45.3]),
    ("montenegro", "ME", [18.4, 41.8, 20.4, 43.6]),
    ("italy", "IT", [6.6, 35.4, 18.6, 47.1]),
    ("greece", "GR", [19.3, 34.7, 29.7, 41.8]),
    ("malta", "MT", [14.1, 35.7, 14.6, 36.1]),
    ("cyprus", "CY", [32.2, 34.5, 34.7, 35.8]),
    ("france", "FR", [-5.2, 41.3, 9.6, 51.1]),
    ("spain", "ES", [-9.4, 35.9, 4.4, 43.8]),
    ("portugal", "PT", [-9.6, 36.9, -6.1, 42.2]),
];

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Warning {
    pub id: String,
    pub country: String,
    pub area_name: String,
    pub event: String,
    /// Minor, Moderate, Severe, Extreme.
    pub severity: String,
    pub urgency: String,
    pub certainty: String,
    /// yellow, orange, red (MeteoAlarm awareness level).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub level: Option<String>,
    /// Wind, Thunderstorm, Coastal event, Fog, Rain, …
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    pub onset: String,
    pub expires: String,
    pub headline: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub instruction: Option<String>,
    /// The area's outline(s), lon/lat, simplified; absent when unknown.
    pub polygon: Option<Vec<Vec<[f64; 2]>>>,
    #[serde(skip)]
    cap_url: Option<String>,
    /// MeteoAlarm EMMA_ID of the area.
    #[serde(skip)]
    code: Option<String>,
    /// west, south, east, north of the area, when its outline is known.
    #[serde(skip)]
    bbox: Option<[f64; 4]>,
}

/// An area outline: rings and their bounding box.
#[derive(Clone, Debug)]
struct Area {
    rings: Vec<Vec<[f64; 2]>>,
    bbox: [f64; 4],
}

#[derive(Default)]
pub struct Warnings {
    /// Country code → current warnings.
    current: RwLock<HashMap<String, Vec<Warning>>>,
    /// CAP details already fetched, by warning id: (level, kind, description, instruction).
    details: RwLock<HashMap<String, Details>>,
    /// Outlines by EMMA_ID (`None`: looked up, none published).
    areas: RwLock<HashMap<String, Option<Area>>>,
    cache_dir: Option<std::path::PathBuf>,
    area_url: String,
}

#[derive(Clone, Default)]
struct Details {
    level: Option<String>,
    kind: Option<String>,
    description: Option<String>,
    instruction: Option<String>,
}

impl Warnings {
    pub fn start(http: reqwest::Client, config: Arc<Config>) -> Arc<Self> {
        let warnings = Arc::new(Warnings {
            cache_dir: Some(config.cache_dir.join("warning-areas")),
            area_url: config.warning_areas_url.clone(),
            ..Default::default()
        });
        if config.warnings_url.is_empty() {
            return warnings;
        }
        let worker = warnings.clone();
        tokio::spawn(async move {
            loop {
                for (slug, code, _) in COUNTRIES {
                    let url = config.warnings_url.replace("{country}", slug);
                    match worker.refresh(&http, &url, code).await {
                        Ok(n) => tracing::debug!("warnings {code}: {n}"),
                        Err(error) => tracing::warn!("warnings {code}: {error:#}"),
                    }
                }
                tokio::time::sleep(Duration::from_secs(15 * 60)).await;
            }
        });
        warnings
    }

    async fn refresh(&self, http: &reqwest::Client, url: &str, code: &str) -> Result<usize> {
        let feed = metrics::upstream("meteoalarm", async { http.get(url).send().await?.error_for_status()?.text().await }).await?;
        let now = chrono_like_now();
        let mut found: Vec<Warning> = parse_feed(&feed, code).into_iter().filter(|w| w.expires.as_str() > now.as_str()).collect();
        // English description and the awareness type from the CAP message, fetched once per warning.
        for warning in &mut found {
            let known = self.details.read().await.get(&warning.id).cloned();
            let details = match known {
                Some(d) => d,
                None => {
                    let Some(cap_url) = warning.cap_url.clone() else { continue };
                    let fetched = async { http.get(&cap_url).send().await?.error_for_status()?.text().await }.await;
                    let Ok(cap) = fetched else { continue };
                    let d = parse_cap(&cap);
                    self.details.write().await.insert(warning.id.clone(), d.clone());
                    d
                }
            };
            warning.level = details.level;
            warning.kind = details.kind;
            warning.description = details.description;
            warning.instruction = details.instruction;
            if let Some(code) = warning.code.clone() {
                if let Some(area) = self.area(http, &code).await {
                    warning.bbox = Some(area.bbox);
                    warning.polygon = Some(area.rings);
                }
            }
        }
        let n = found.len();
        let ids: Vec<String> = found.iter().map(|w| w.id.clone()).collect();
        self.current.write().await.insert(code.to_string(), found);
        // Forget details of warnings no longer in any feed, once in a while.
        let mut details = self.details.write().await;
        if details.len() > 5000 {
            details.retain(|id, _| ids.contains(id));
        }
        Ok(n)
    }

    /// The outline of an EMMA_ID area, from memory, disk, or the published geometry.
    async fn area(&self, http: &reqwest::Client, code: &str) -> Option<Area> {
        if let Some(known) = self.areas.read().await.get(code) {
            return known.clone();
        }
        if code.is_empty() || !code.chars().all(|c| c.is_ascii_alphanumeric()) || self.area_url.is_empty() {
            return None;
        }
        let file = self.cache_dir.as_ref().map(|d| d.join(format!("{code}.geojson")));
        let mut data = match &file {
            Some(f) => tokio::fs::read(f).await.ok(),
            None => None,
        };
        if data.is_none() {
            let url = self.area_url.replace("{code}", code);
            if let Ok(response) = http.get(&url).send().await {
                match response.status().as_u16() {
                    200 => data = response.bytes().await.ok().map(|b| b.to_vec()),
                    404 => data = Some(Vec::new()),
                    _ => return None, // try again next refresh
                }
                if let (Some(f), Some(d)) = (&file, &data) {
                    crate::cache::write(f, d).await;
                }
            }
        }
        let area = data.and_then(|d| parse_area(&d));
        self.areas.write().await.insert(code.to_string(), area.clone());
        area
    }

    /// Current warnings whose area overlaps the box (or, with no outline, whose country does),
    /// most severe first.
    pub async fn in_box(&self, west: f64, south: f64, east: f64, north: f64) -> Vec<Warning> {
        let current = self.current.read().await;
        let overlaps = |b: &[f64; 4]| b[0] < east && b[2] > west && b[1] < north && b[3] > south;
        let mut found: Vec<Warning> = COUNTRIES
            .iter()
            .filter(|(_, _, b)| overlaps(b))
            .flat_map(|(_, code, _)| current.get(*code).cloned().unwrap_or_default())
            .filter(|w| w.bbox.as_ref().is_none_or(overlaps))
            .collect();
        let rank = |s: &str| match s {
            "Extreme" => 0,
            "Severe" => 1,
            "Moderate" => 2,
            _ => 3,
        };
        found.sort_by(|a, b| rank(&a.severity).cmp(&rank(&b.severity)).then(a.onset.cmp(&b.onset)));
        found
    }

    #[cfg(test)]
    pub async fn insert(&self, code: &str, warnings: Vec<Warning>) {
        self.current.write().await.insert(code.into(), warnings);
    }
}

/// UTC now as an RFC 3339 string; CAP times compare correctly as strings once normalised to UTC.
fn chrono_like_now() -> String {
    rfc3339(crate::now())
}

pub fn rfc3339(unix: i64) -> String {
    // Civil-from-days (Howard Hinnant), enough for formatting UTC timestamps without a date crate.
    let days = unix.div_euclid(86400);
    let secs = unix.rem_euclid(86400);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}+00:00", secs / 3600, secs / 60 % 60, secs % 60)
}

/// "2026-10-17T04:00:00+02:00" → the same instant as "…+00:00", so string comparison works.
fn to_utc(time: &str) -> String {
    let parse = || -> Option<i64> {
        let (date, rest) = time.split_once('T')?;
        let mut d = date.split('-').map(|p| p.parse::<i64>().ok());
        let (y, m, day) = (d.next()??, d.next()??, d.next()??);
        let (clock, offset_sign, offset) = match rest.rfind(['+', '-']) {
            Some(i) if i >= 8 => (&rest[..i], if &rest[i..i + 1] == "-" { -1 } else { 1 }, &rest[i + 1..]),
            _ => (rest.trim_end_matches('Z'), 1, "00:00"),
        };
        let mut c = clock.split(':').map(|p| p.split('.').next().unwrap_or("0").parse::<i64>().ok());
        let (hh, mm, ss) = (c.next()??, c.next()??, c.next().flatten().unwrap_or(0));
        let mut o = offset.split(':').map(|p| p.parse::<i64>().ok());
        let (oh, om) = (o.next().flatten().unwrap_or(0), o.next().flatten().unwrap_or(0));
        // Days from civil (Howard Hinnant).
        let y2 = if m <= 2 { y - 1 } else { y };
        let era = y2.div_euclid(400);
        let yoe = y2 - era * 400;
        let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + day - 1;
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        let days = era * 146_097 + doe - 719_468;
        Some(days * 86400 + hh * 3600 + mm * 60 + ss - offset_sign * (oh * 3600 + om * 60))
    };
    parse().map(rfc3339).unwrap_or_else(|| time.to_string())
}

/// Text of the first `<tag>…</tag>` in `xml`, entities decoded.
fn tag(xml: &str, name: &str) -> Option<String> {
    let open = format!("<{name}>");
    let start = xml.find(&open)? + open.len();
    let end = xml[start..].find(&format!("</{name}>"))? + start;
    let text = unescape(xml[start..end].trim());
    (!text.is_empty()).then_some(text)
}

fn unescape(s: &str) -> String {
    s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'").replace("&amp;", "&")
}

/// The EMMA_ID geocode of an Atom entry.
fn emma_id(entry: &str) -> Option<String> {
    entry.split("<cap:geocode>").skip(1).find_map(|g| {
        (tag(g, "valueName").as_deref() == Some("EMMA_ID")).then(|| tag(g, "value")).flatten()
    })
}

/// Rings of a GeoJSON Feature (Polygon or MultiPolygon), outer rings only, thinned to about 150
/// points each, with their bounding box.
fn parse_area(data: &[u8]) -> Option<Area> {
    let value: serde_json::Value = serde_json::from_slice(data).ok()?;
    let geometry = value.get("geometry").unwrap_or(&value);
    let polygons: Vec<&serde_json::Value> = match geometry.get("type")?.as_str()? {
        "Polygon" => vec![geometry.get("coordinates")?],
        "MultiPolygon" => geometry.get("coordinates")?.as_array()?.iter().collect(),
        _ => return None,
    };
    let mut rings = Vec::new();
    let mut bbox = [f64::MAX, f64::MAX, f64::MIN, f64::MIN];
    for polygon in polygons {
        let Some(outer) = polygon.as_array().and_then(|p| p.first()).and_then(|r| r.as_array()) else { continue };
        let points: Vec<[f64; 2]> = outer
            .iter()
            .filter_map(|p| Some([p.get(0)?.as_f64()?, p.get(1)?.as_f64()?]))
            .collect();
        if points.len() < 3 {
            continue;
        }
        let step = points.len().div_ceil(150).max(1);
        let thinned: Vec<[f64; 2]> = points.iter().step_by(step).chain(points.last()).copied().collect();
        for p in &points {
            bbox = [bbox[0].min(p[0]), bbox[1].min(p[1]), bbox[2].max(p[0]), bbox[3].max(p[1])];
        }
        rings.push(thinned);
    }
    (!rings.is_empty()).then_some(Area { rings, bbox })
}

/// The CAP link of an Atom entry.
fn cap_link(entry: &str) -> Option<String> {
    entry.split("<link").find(|l| l.contains("application/cap+xml")).and_then(|l| {
        let start = l.find("href=\"")? + 6;
        let end = l[start..].find('"')? + start;
        Some(unescape(&l[start..end]))
    })
}

pub fn parse_feed(feed: &str, code: &str) -> Vec<Warning> {
    feed.split("<entry>")
        .skip(1)
        .filter_map(|entry| {
            let entry = entry.split("</entry>").next()?;
            if tag(entry, "cap:message_type").as_deref() == Some("Cancel") || tag(entry, "cap:status").as_deref() != Some("Actual") {
                return None;
            }
            Some(Warning {
                id: tag(entry, "cap:identifier")?,
                country: code.to_string(),
                area_name: tag(entry, "cap:areaDesc").unwrap_or_default(),
                event: tag(entry, "cap:event").unwrap_or_default(),
                severity: tag(entry, "cap:severity").unwrap_or_default(),
                urgency: tag(entry, "cap:urgency").unwrap_or_default(),
                certainty: tag(entry, "cap:certainty").unwrap_or_default(),
                level: None,
                kind: None,
                onset: to_utc(&tag(entry, "cap:onset").or_else(|| tag(entry, "cap:effective")).unwrap_or_default()),
                expires: to_utc(&tag(entry, "cap:expires")?),
                headline: tag(entry, "title").unwrap_or_default(),
                description: None,
                instruction: None,
                polygon: None,
                cap_url: cap_link(entry),
                code: emma_id(entry),
                bbox: None,
            })
        })
        .collect()
}

/// The English `<info>` block of a CAP message (else the first), and its awareness parameters.
fn parse_cap(cap: &str) -> Details {
    let infos: Vec<&str> = cap.split("<info>").skip(1).collect();
    let info = infos
        .iter()
        .find(|i| tag(i, "language").is_some_and(|l| l.starts_with("en")))
        .or(infos.first())
        .copied()
        .unwrap_or("");
    let parameter = |name: &str| -> Option<String> {
        info.split("<parameter>").skip(1).find(|p| tag(p, "valueName").as_deref() == Some(name)).and_then(|p| tag(p, "value"))
    };
    // "2; yellow; Moderate" and "1; Wind".
    Details {
        level: parameter("awareness_level").and_then(|v| v.split(';').nth(1).map(|s| s.trim().to_string())),
        kind: parameter("awareness_type").and_then(|v| v.split(';').nth(1).map(|s| s.trim().to_string())),
        description: tag(info, "description"),
        instruction: tag(info, "instruction"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FEED: &str = r#"<feed><entry>
        <cap:geocode><valueName>EMMA_ID</valueName><value>HR805</value></cap:geocode>
        <cap:areaDesc>Middle Dalmatia region</cap:areaDesc>
        <cap:event>Yellow wind warning</cap:event>
        <cap:expires>2099-10-17T04:00:00+02:00</cap:expires>
        <cap:onset>2099-10-17T00:01:01+02:00</cap:onset>
        <cap:certainty>Likely</cap:certainty><cap:severity>Moderate</cap:severity><cap:urgency>Future</cap:urgency>
        <cap:message_type>Alert</cap:message_type><cap:status>Actual</cap:status>
        <cap:identifier>2.49.HR805</cap:identifier>
        <link type="application/cap+xml" href="https://example.org/cap/1?a=1&amp;b=2"/>
        <title>Yellow Wind Warning issued for Croatia - Middle Dalmatia region</title>
      </entry><entry><cap:identifier>x</cap:identifier><cap:status>Test</cap:status></entry></feed>"#;

    #[test]
    fn parses_feed_and_cap() {
        let found = parse_feed(FEED, "HR");
        assert_eq!(found.len(), 1);
        let w = &found[0];
        assert_eq!(w.area_name, "Middle Dalmatia region");
        assert_eq!(w.expires, "2099-10-17T02:00:00+00:00");
        assert_eq!(w.onset, "2099-10-16T22:01:01+00:00");
        assert_eq!(w.cap_url.as_deref(), Some("https://example.org/cap/1?a=1&b=2"));
        assert_eq!(w.code.as_deref(), Some("HR805"));
        let area = parse_area(br#"{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[15.0,43.0],[17.0,43.0],[17.0,44.0],[15.0,43.0]]]}}"#).unwrap();
        assert_eq!(area.bbox, [15.0, 43.0, 17.0, 44.0]);

        let cap = r#"<alert><info><language>hr-HR</language><description>Bura</description></info>
            <info><language>en-GB</language><description>Locally fresh wind.</description>
            <parameter><valueName>awareness_level</valueName><value>2; yellow; Moderate</value></parameter>
            <parameter><valueName>awareness_type</valueName><value>1; Wind</value></parameter></info></alert>"#;
        let d = parse_cap(cap);
        assert_eq!(d.description.as_deref(), Some("Locally fresh wind."));
        assert_eq!(d.level.as_deref(), Some("yellow"));
        assert_eq!(d.kind.as_deref(), Some("Wind"));
    }

    #[test]
    fn formats_utc() {
        assert_eq!(rfc3339(0), "1970-01-01T00:00:00+00:00");
        assert_eq!(rfc3339(1_792_235_724), "2026-10-17T11:15:24+00:00");
        assert_eq!(to_utc("2026-10-17T11:15:24Z"), "2026-10-17T11:15:24+00:00");
    }

    #[tokio::test]
    async fn filters_by_area_then_country() {
        let warnings = Warnings::default();
        let mut found = parse_feed(FEED, "HR");
        warnings.insert("HR", found.clone()).await;
        // No outline: matched by country.
        assert_eq!(warnings.in_box(14.0, 44.0, 15.0, 45.0).await.len(), 1);
        assert!(warnings.in_box(-20.0, 10.0, -10.0, 20.0).await.is_empty());
        // With an outline in Middle Dalmatia, Istria is clear of it.
        found[0].bbox = Some([15.5, 43.0, 17.3, 44.0]);
        warnings.insert("HR", found).await;
        assert!(warnings.in_box(13.5, 44.8, 14.3, 45.5).await.is_empty());
        assert_eq!(warnings.in_box(16.0, 43.2, 16.6, 43.6).await.len(), 1);
    }
}
