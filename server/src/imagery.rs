//! Raster layers proxied and cached for the app: satellite imagery (EOX Sentinel-2 cloudless 2016,
//! CC BY 4.0) and rain radar (RainViewer).

use std::{
    sync::Arc,
    time::{Duration, Instant},
};

use anyhow::{anyhow, Result};
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::sync::RwLock;

use crate::{
    cache::{Blob, TileCache},
    config::Config,
};

/// Sentinel-2 is 10 m imagery: zoom 14 is its native resolution; the app over-zooms.
pub const SATELLITE_MAX_ZOOM: u32 = 14;
/// RainViewer's public tiles stop here.
pub const RADAR_MAX_ZOOM: u32 = 7;

async fn fetch(http: &reqwest::Client, url: &str) -> Result<Option<Vec<u8>>> {
    let response = http.get(url).send().await?;
    match response.status().as_u16() {
        200 => Ok(Some(response.bytes().await?.to_vec())),
        204 | 404 => Ok(None),
        status => Err(anyhow!("{url} answered {status}")),
    }
}

fn fill(template: &str, z: u32, x: u32, y: u32) -> String {
    template.replace("{z}", &z.to_string()).replace("{x}", &x.to_string()).replace("{y}", &y.to_string())
}

pub struct Satellite {
    http: reqwest::Client,
    config: Arc<Config>,
    pub tiles: Arc<TileCache>,
}

impl Satellite {
    pub fn new(http: reqwest::Client, config: Arc<Config>) -> Self {
        Satellite {
            tiles: Arc::new(TileCache::new("satellite", &config.cache_dir, Duration::from_secs(180 * 86400), 64)),
            http,
            config,
        }
    }

    pub async fn tile(&self, z: u32, x: u32, y: u32) -> Result<Arc<Blob>> {
        if z > SATELLITE_MAX_ZOOM || x >= 1 << z || y >= 1 << z {
            return Err(anyhow!("no such tile {z}/{x}/{y}"));
        }
        let url = fill(&self.config.satellite_url, z, x, y);
        self.tiles.get(&format!("{z}/{x}/{y}.jpg"), || fetch(&self.http, &url)).await
    }
}

#[derive(Deserialize, Clone)]
struct Frame {
    time: i64,
    path: String,
}

#[derive(Deserialize)]
struct Maps {
    host: String,
    radar: RadarFrames,
}

#[derive(Deserialize)]
struct RadarFrames {
    #[serde(default)]
    past: Vec<Frame>,
    #[serde(default)]
    nowcast: Vec<Frame>,
}

struct Frames {
    host: String,
    frames: Vec<Frame>,
    fetched: Instant,
}

pub struct Radar {
    http: reqwest::Client,
    config: Arc<Config>,
    pub tiles: Arc<TileCache>,
    frames: RwLock<Option<Frames>>,
}

impl Radar {
    pub fn new(http: reqwest::Client, config: Arc<Config>) -> Self {
        Radar {
            // A frame's tiles never change; frames older than two hours are no longer offered.
            tiles: Arc::new(TileCache::new("radar", &config.cache_dir, Duration::from_secs(3 * 3600), 32)),
            http,
            config,
            frames: RwLock::new(None),
        }
    }

    async fn frames(&self) -> Result<(String, Vec<Frame>)> {
        if let Some(f) = self.frames.read().await.as_ref() {
            if f.fetched.elapsed() < Duration::from_secs(120) {
                return Ok((f.host.clone(), f.frames.clone()));
            }
        }
        let mut slot = self.frames.write().await;
        if let Some(f) = slot.as_ref() {
            if f.fetched.elapsed() < Duration::from_secs(120) {
                return Ok((f.host.clone(), f.frames.clone()));
            }
        }
        let fetched: Result<Maps> = async {
            Ok(self.http.get(&self.config.radar_url).send().await?.error_for_status()?.json().await?)
        }
        .await;
        match fetched {
            Ok(maps) => {
                let frames: Vec<Frame> = maps.radar.past.into_iter().chain(maps.radar.nowcast).collect();
                *slot = Some(Frames { host: maps.host.clone(), frames: frames.clone(), fetched: Instant::now() });
                Ok((maps.host, frames))
            }
            Err(error) => match slot.as_ref() {
                Some(f) => Ok((f.host.clone(), f.frames.clone())),
                None => Err(error),
            },
        }
    }

    /// Available frames, oldest first, with tile templates on this server.
    pub async fn list(&self, public: &str) -> Result<Value> {
        let (_, frames) = self.frames().await?;
        Ok(json!({
            "maxZoom": RADAR_MAX_ZOOM,
            "attribution": "Radar: RainViewer",
            "frames": frames.iter().map(|f| json!({
                "time": f.time,
                "tiles": format!("{public}/v1/tiles/radar/{}/{{z}}/{{x}}/{{y}}.png", f.time),
            })).collect::<Vec<_>>(),
        }))
    }

    pub async fn tile(&self, time: i64, z: u32, x: u32, y: u32) -> Result<Option<Arc<Blob>>> {
        if z > RADAR_MAX_ZOOM || x >= 1 << z || y >= 1 << z {
            return Ok(None);
        }
        let (host, frames) = self.frames().await?;
        let Some(frame) = frames.into_iter().find(|f| f.time == time) else { return Ok(None) };
        // 256 px, colour scheme 2 (universal blue), smoothed, snow shown.
        let url = format!("{host}{}/256/{z}/{x}/{y}/2/1_1.png", frame.path);
        self.tiles.get(&format!("{time}/{z}/{x}/{y}.png"), || fetch(&self.http, &url)).await.map(Some)
    }
}
