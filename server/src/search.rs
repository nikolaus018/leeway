//! Place search: harbours, marinas, anchorages and charted names from the chart packs first (what a
//! sailor looks for), then towns and everything else from Photon (OpenStreetMap), cached.

use std::{path::PathBuf, sync::Arc, time::Duration};

use anyhow::Result;
use moka::future::Cache;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::{RwLock, Semaphore};

use crate::{config::Config, metrics};

#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Place {
    pub name: String,
    /// marina, harbour, anchorage, bay, cape, island, strait, town, village, city, …
    pub kind: String,
    pub lat: f64,
    pub lon: f64,
    /// Town, region, country: whatever tells same-named places apart.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

#[derive(Deserialize)]
struct PackMeta {
    #[serde(default)]
    name: String,
    #[serde(default)]
    seamarks: Vec<PackMark>,
    #[serde(default)]
    names: Vec<PackName>,
}

#[derive(Deserialize)]
struct PackMark {
    t: String,
    n: Option<String>,
    la: f64,
    lo: f64,
    c: Option<String>,
}

#[derive(Deserialize)]
struct PackName {
    t: String,
    n: String,
    la: f64,
    lo: f64,
}

/// Folded name → place, from the chart packs.
type Index = Vec<(String, Place)>;

pub struct Search {
    http: reqwest::Client,
    config: Arc<Config>,
    local: RwLock<Option<(Arc<Index>, std::time::Instant)>>,
    online: Cache<String, Arc<Vec<Place>>>,
    /// Photon is a free community service: one request at a time from us.
    upstream: Semaphore,
}

/// Lowercase without diacritics, so "split" finds "Split" and "cres" finds "Čres".
pub fn fold(s: &str) -> String {
    s.chars()
        .flat_map(char::to_lowercase)
        .map(|c| match c {
            'č' | 'ć' => 'c',
            'š' => 's',
            'ž' => 'z',
            'đ' => 'd',
            'à' | 'á' | 'â' | 'ä' | 'ã' => 'a',
            'è' | 'é' | 'ê' | 'ë' => 'e',
            'ì' | 'í' | 'î' | 'ï' => 'i',
            'ò' | 'ó' | 'ô' | 'ö' | 'õ' => 'o',
            'ù' | 'ú' | 'û' | 'ü' => 'u',
            other => other,
        })
        .collect()
}

impl Search {
    pub fn new(http: reqwest::Client, config: Arc<Config>) -> Self {
        Search {
            http,
            config,
            local: RwLock::new(None),
            online: Cache::builder().max_capacity(20_000).time_to_live(Duration::from_secs(86400)).build(),
            upstream: Semaphore::new(1),
        }
    }

    async fn local_index(&self) -> Arc<Index> {
        {
            if let Some((index, loaded)) = self.local.read().await.as_ref() {
                if loaded.elapsed() < Duration::from_secs(600) {
                    return Arc::clone(index);
                }
            }
        }
        let dir = self.config.charts_dir.clone();
        let index = Arc::new(tokio::task::spawn_blocking(move || index_packs(&dir)).await.unwrap_or_default());
        *self.local.write().await = Some((Arc::clone(&index), std::time::Instant::now()));
        index
    }

    pub async fn find(&self, query: &str, near: Option<(f64, f64)>, limit: usize) -> Result<Vec<Place>> {
        let q = fold(query.trim());
        if q.len() < 2 {
            return Ok(Vec::new());
        }
        let mut candidates: Vec<Place> =
            self.local_index().await.iter().filter(|(key, _)| key.contains(&q)).map(|(_, place)| place.clone()).collect();
        if !self.config.search_url.is_empty() {
            // Bias by area, not exact position, so the cache is shared by everyone nearby.
            let bias = near.map(|(lat, lon)| (lat.round(), lon.round()));
            let key = format!("{q}|{bias:?}");
            let online = self
                .online
                .try_get_with(key, async {
                    let _permit = self.upstream.acquire().await?;
                    self.photon(query.trim(), bias).await.map(Arc::new)
                })
                .await;
            match online {
                Ok(places) => {
                    for place in places.iter() {
                        let duplicate = candidates.iter().any(|c| {
                            fold(&c.name) == fold(&place.name) && (c.lat - place.lat).abs() < 0.01 && (c.lon - place.lon).abs() < 0.01
                        });
                        if !duplicate {
                            candidates.push(place.clone());
                        }
                    }
                }
                Err(error) => tracing::warn!("search upstream: {error:#}"),
            }
        }
        candidates.sort_by(|a, b| rank(&q, a, near).total_cmp(&rank(&q, b, near)));
        candidates.truncate(limit);
        Ok(candidates)
    }

    async fn photon(&self, query: &str, bias: Option<(f64, f64)>) -> Result<Vec<Place>> {
        // Croatia only for now: Photon takes the box as west,south,east,north.
        let [south, west, north, east] = crate::config::CROATIA;
        let mut params = vec![
            ("q", query.to_string()),
            ("limit", "10".into()),
            ("lang", "en".into()),
            ("bbox", format!("{west},{south},{east},{north}")),
        ];
        if let Some((lat, lon)) = bias {
            params.push(("lat", lat.to_string()));
            params.push(("lon", lon.to_string()));
        }
        let value: Value = metrics::upstream("photon", async {
            self.http.get(&self.config.search_url).query(&params).send().await?.error_for_status()?.json().await
        })
        .await?;
        Ok(value["features"]
            .as_array()
            .map(|features| features.iter().filter_map(photon_place).collect())
            .unwrap_or_default())
    }
}

/// Lower is better: how well the name matches, then what kind of place it is, then how far away.
fn rank(q: &str, place: &Place, near: Option<(f64, f64)>) -> f64 {
    let name = fold(&place.name);
    let text = if name == q {
        0.0
    } else if name.split([' ', '-', ',']).any(|word| word.starts_with(q)) {
        1.0
    } else if name.contains(q) {
        2.0
    } else {
        3.0 // Photon's fuzzy matches
    };
    let kind = match place.kind.as_str() {
        "marina" | "harbour" | "anchorage" => 0.0,
        "city" | "town" => 0.1,
        "village" | "bay" | "island" | "strait" => 0.2,
        _ => 0.3,
    };
    // Up to 0.5 for distance: nearby wins among equal matches.
    let distance = near.map_or(0.0, |(lat, lon)| {
        let d = ((place.lat - lat).powi(2) + ((place.lon - lon) * lat.to_radians().cos()).powi(2)).sqrt();
        (d / 10.0).min(0.5)
    });
    text + kind + distance
}

fn photon_place(feature: &Value) -> Option<Place> {
    let p = &feature["properties"];
    let coords = feature["geometry"]["coordinates"].as_array()?;
    let kind = match p["osm_value"].as_str().unwrap_or("") {
        "marina" => "marina",
        "harbour" | "port" => "harbour",
        "bay" => "bay",
        "cape" => "cape",
        "island" | "islet" => "island",
        "strait" => "strait",
        "beach" => "beach",
        "city" => "city",
        "town" => "town",
        "village" | "hamlet" => "village",
        "fuel" => "fuel",
        _ => "place",
    };
    let detail: Vec<&str> = ["city", "county", "country"].iter().filter_map(|k| p[*k].as_str()).collect();
    Some(Place {
        name: p["name"].as_str()?.to_string(),
        kind: kind.into(),
        lat: coords.get(1)?.as_f64()?,
        lon: coords.first()?.as_f64()?,
        detail: (!detail.is_empty()).then(|| detail.join(", ")),
    })
}

/// Named harbours, marinas, anchorages and chart names from every pack in `dir`.
fn index_packs(dir: &PathBuf) -> Vec<(String, Place)> {
    let Ok(entries) = std::fs::read_dir(dir) else { return Vec::new() };
    let mut index = Vec::new();
    for path in entries.flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|e| e == "json")) {
        let Ok(meta) = std::fs::read(&path).map_err(anyhow::Error::from).and_then(|d| Ok(serde_json::from_slice::<PackMeta>(&d)?)) else {
            continue;
        };
        for mark in meta.seamarks {
            let kind = match (mark.t.as_str(), mark.c.as_deref()) {
                ("harbour", Some("marina")) => "marina",
                ("harbour", _) => "harbour",
                ("small_craft_facility", _) => "marina",
                ("anchorage", _) => "anchorage",
                ("mooring", _) => "mooring",
                _ => continue,
            };
            let Some(name) = mark.n else { continue };
            index.push((fold(&name), Place { name, kind: kind.into(), lat: mark.la, lon: mark.lo, detail: Some(meta.name.clone()) }));
        }
        for place in meta.names {
            index.push((fold(&place.n), Place { name: place.n, kind: place.t, lat: place.la, lon: place.lo, detail: Some(meta.name.clone()) }));
        }
    }
    index
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ranks_names_then_kinds() {
        let place = |name: &str, kind: &str| Place { name: name.into(), kind: kind.into(), lat: 45.0, lon: 14.6, detail: None };
        let mut found = [place("Punat Miljanić", "cape"), place("Marina Punat", "marina"), place("Punat", "village")];
        found.sort_by(|a, b| rank("punat", a, None).total_cmp(&rank("punat", b, None)));
        assert_eq!(found.iter().map(|p| p.name.as_str()).collect::<Vec<_>>(), ["Punat", "Marina Punat", "Punat Miljanić"]);
    }

    #[test]
    fn folds_and_indexes_packs() {
        assert_eq!(fold("Čres Šibenik"), "cres sibenik");
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join("p.json"),
            r#"{"name":"Kvarner","seamarks":[{"t":"harbour","c":"marina","n":"Marina Punat","la":45.02,"lo":14.62},
               {"t":"buoy_lateral","n":"Ignored","la":45,"lo":14}],"names":[{"t":"bay","n":"Uvala Soline","la":45.1,"lo":14.6}]}"#,
        )
        .unwrap();
        let index = index_packs(&dir.path().to_path_buf());
        assert_eq!(index.len(), 2);
        assert_eq!(index[0].1.kind, "marina");
        assert_eq!(index[1].0, "uvala soline");
    }
}
