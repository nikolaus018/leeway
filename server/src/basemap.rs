//! The worldwide base map: OpenMapTiles-schema vector tiles and label fonts from OpenFreeMap, proxied
//! and cached so every phone shares one copy and the app talks to one server.

use std::{
    sync::Arc,
    time::{Duration, Instant},
};

use anyhow::{anyhow, Context, Result};
use serde_json::{json, Value};
use tokio::sync::RwLock;

use crate::{
    cache::{Blob, TileCache},
    config::Config,
    mvt,
};

/// OpenFreeMap's planet tiles stop at 14; the app over-zooms beyond.
pub const MAX_ZOOM: u32 = 14;

struct Upstream {
    /// Versioned tile URL template, e.g. `https://tiles.openfreemap.org/planet/20261011_080001_pt/{z}/{x}/{y}.pbf`.
    template: String,
    tilejson: Value,
    fetched: Instant,
}

pub struct BaseMap {
    http: reqwest::Client,
    config: Arc<Config>,
    tiles: Arc<TileCache>,
    fonts: Arc<TileCache>,
    upstream: RwLock<Option<Upstream>>,
}

impl BaseMap {
    pub fn new(http: reqwest::Client, config: Arc<Config>) -> Self {
        let day = 86400;
        BaseMap {
            tiles: Arc::new(TileCache::new("base", &config.cache_dir, Duration::from_secs(30 * day), 128)),
            fonts: Arc::new(TileCache::new("fonts", &config.cache_dir, Duration::from_secs(365 * day), 32)),
            http,
            config,
            upstream: RwLock::new(None),
        }
    }

    pub fn caches(&self) -> [&Arc<TileCache>; 2] {
        [&self.tiles, &self.fonts]
    }

    /// The current upstream tile template and TileJSON; OpenFreeMap re-versions weekly.
    async fn upstream(&self) -> Result<(String, Value)> {
        if let Some(u) = self.upstream.read().await.as_ref() {
            if u.fetched.elapsed() < Duration::from_secs(86400) {
                return Ok((u.template.clone(), u.tilejson.clone()));
            }
        }
        let mut slot = self.upstream.write().await;
        if let Some(u) = slot.as_ref() {
            if u.fetched.elapsed() < Duration::from_secs(86400) {
                return Ok((u.template.clone(), u.tilejson.clone()));
            }
        }
        let fetched: Result<Value> = async {
            let response = self.http.get(&self.config.base_tilejson_url).send().await?.error_for_status()?;
            Ok(response.json().await?)
        }
        .await;
        match fetched {
            Ok(tilejson) => {
                let template = tilejson["tiles"][0].as_str().context("base tilejson has no tiles")?.to_string();
                *slot = Some(Upstream { template: template.clone(), tilejson: tilejson.clone(), fetched: Instant::now() });
                Ok((template, tilejson))
            }
            // Keep using the last known version while OpenFreeMap is unreachable.
            Err(error) => match slot.as_mut() {
                Some(u) => {
                    tracing::warn!("base tilejson refresh failed, keeping {}: {error:#}", u.template);
                    // Try again in ten minutes.
                    let now = Instant::now();
                    u.fetched = now.checked_sub(Duration::from_secs(86400 - 600)).unwrap_or(now);
                    Ok((u.template.clone(), u.tilejson.clone()))
                }
                None => Err(error),
            },
        }
    }

    /// TileJSON for the app, pointing at this server.
    pub async fn tilejson(&self, public: &str) -> Result<Value> {
        let (_, upstream) = self.upstream().await?;
        Ok(json!({
            "tilejson": "3.0.0",
            "name": "Leeway base map",
            "attribution": "<a href=\"https://openfreemap.org\">OpenFreeMap</a> <a href=\"https://www.openmaptiles.org/\">© OpenMapTiles</a> Data from <a href=\"https://www.openstreetmap.org/copyright\">OpenStreetMap</a>",
            "tiles": [format!("{public}/v1/tiles/base/{{z}}/{{x}}/{{y}}.pbf")],
            "minzoom": 0,
            "maxzoom": MAX_ZOOM,
            "bounds": [-180, -85.0511, 180, 85.0511],
            "vector_layers": upstream["vector_layers"].clone(),
        }))
    }

    pub async fn tile(&self, z: u32, x: u32, y: u32) -> Result<Arc<Blob>> {
        if z > MAX_ZOOM || x >= 1 << z || y >= 1 << z {
            return Err(anyhow!("no such tile {z}/{x}/{y}"));
        }
        self.tiles
            .get(&format!("{z}/{x}/{y}.pbf"), || async {
                let (template, _) = self.upstream().await?;
                let url = template.replace("{z}", &z.to_string()).replace("{x}", &x.to_string()).replace("{y}", &y.to_string());
                // reqwest undoes the gzip transfer encoding; the tile is stored plain.
                let response = self.http.get(&url).send().await?;
                match response.status().as_u16() {
                    200 => Ok(Some(response.bytes().await?.to_vec())),
                    204 | 404 => Ok(None),
                    status => Err(anyhow!("{url} answered {status}")),
                }
            })
            .await
    }

    /// Which cells of an `n`×`n` grid over tile z/x/y are water according to the base map, or
    /// `None` when the base map has no tile there.
    pub async fn water_mask(&self, z: u32, x: u32, y: u32, n: usize) -> Result<Option<Vec<bool>>> {
        if z > MAX_ZOOM {
            return Ok(None);
        }
        let blob = self.tile(z, x, y).await?;
        if blob.is_empty() {
            return Ok(None);
        }
        let data = blob.data.clone();
        Ok(Some(
            tokio::task::spawn_blocking(move || {
                let (polygons, extent) = mvt::polygons(&data, "water");
                mvt::rasterize(&polygons, extent, n)
            })
            .await?,
        ))
    }

    /// Label glyphs (`fontstack` like "Noto Sans Regular", `range` like "0-255").
    pub async fn glyphs(&self, fontstack: &str, range: &str) -> Result<Arc<Blob>> {
        let valid_stack = !fontstack.is_empty()
            && fontstack.len() < 200
            && fontstack.chars().all(|c| c.is_ascii_alphanumeric() || " ,-_".contains(c));
        let valid_range = range.split_once('-').is_some_and(|(a, b)| {
            a.parse::<u32>().is_ok_and(|a| a % 256 == 0) && b.parse::<u32>().is_ok_and(|b| b < 65536)
        });
        if !valid_stack || !valid_range {
            return Err(anyhow!("bad glyph request"));
        }
        let url = format!(
            "{}/{}/{range}.pbf",
            self.config.fonts_url.trim_end_matches('/'),
            fontstack.replace(' ', "%20").replace(',', "%2C")
        );
        let http = self.http.clone();
        self.fonts
            .get(&format!("{}/{range}.pbf", fontstack.replace([' ', ','], "_")), || async move {
                let response = http.get(&url).send().await?;
                match response.status().as_u16() {
                    200 => Ok(Some(response.bytes().await?.to_vec())),
                    404 => Ok(None),
                    status => Err(anyhow!("{url} answered {status}")),
                }
            })
            .await
    }
}
