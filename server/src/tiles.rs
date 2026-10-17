//! OpenSeaMap seamark tiles with a disk cache. OpenSeaMap is run by volunteers: the cache keeps
//! repeat requests off their servers, and stale tiles are still served if they are down.

use std::{
    path::PathBuf,
    sync::Arc,
    time::{Duration, SystemTime},
};

use anyhow::{anyhow, Result};
use tokio::sync::Semaphore;

use crate::config::Config;

/// Re-fetch tiles older than this.
const FRESH: Duration = Duration::from_secs(14 * 24 * 3600);
pub const MAX_ZOOM: u32 = 18;

pub enum Tile {
    Png(Vec<u8>),
    /// Nothing charted in this tile.
    Empty,
}

pub struct SeamarkTiles {
    http: reqwest::Client,
    config: Arc<Config>,
    /// Be polite upstream: a few requests at a time.
    upstream: Semaphore,
}

impl SeamarkTiles {
    pub fn new(http: reqwest::Client, config: Arc<Config>) -> Self {
        SeamarkTiles { http, config, upstream: Semaphore::new(6) }
    }

    fn path(&self, z: u32, x: u32, y: u32, ext: &str) -> PathBuf {
        self.config.cache_dir.join("seamark").join(z.to_string()).join(x.to_string()).join(format!("{y}.{ext}"))
    }

    pub async fn tile(&self, z: u32, x: u32, y: u32) -> Result<Tile> {
        if z > MAX_ZOOM || x >= 1 << z || y >= 1 << z {
            return Err(anyhow!("no such tile {z}/{x}/{y}"));
        }
        let png = self.path(z, x, y, "png");
        let empty = self.path(z, x, y, "empty");
        if is_fresh(&png).await {
            if let Some(data) = cached(&png).await {
                return Ok(Tile::Png(data));
            }
        }
        if is_fresh(&empty).await {
            return Ok(Tile::Empty);
        }
        match self.download(z, x, y).await {
            Ok(Some(data)) => {
                write(&png, &data).await;
                let _ = tokio::fs::remove_file(&empty).await;
                Ok(Tile::Png(data))
            }
            Ok(None) => {
                write(&empty, b"").await;
                let _ = tokio::fs::remove_file(&png).await;
                Ok(Tile::Empty)
            }
            // Upstream down: a stale tile beats no tile.
            Err(error) => cached(&png).await.map(Tile::Png).ok_or(error),
        }
    }

    async fn download(&self, z: u32, x: u32, y: u32) -> Result<Option<Vec<u8>>> {
        let _permit = self.upstream.acquire().await?;
        let url = self
            .config
            .seamark_url
            .replace("{z}", &z.to_string())
            .replace("{x}", &x.to_string())
            .replace("{y}", &y.to_string());
        let response = self.http.get(&url).send().await?;
        match response.status().as_u16() {
            200 => {
                let data = response.bytes().await?.to_vec();
                // OpenSeaMap sometimes answers an empty tile with a tiny or non-PNG body.
                Ok(if data.starts_with(b"\x89PNG") { Some(data) } else { None })
            }
            204 | 404 => Ok(None),
            status => Err(anyhow!("{url} answered {status}")),
        }
    }
}

async fn cached(path: &PathBuf) -> Option<Vec<u8>> {
    tokio::fs::read(path).await.ok()
}

async fn is_fresh(path: &PathBuf) -> bool {
    let Ok(meta) = tokio::fs::metadata(path).await else { return false };
    let age = meta.modified().ok().and_then(|m| SystemTime::now().duration_since(m).ok());
    age.is_some_and(|age| age < FRESH)
}

/// Write via a temp file so a half-written tile is never served.
async fn write(path: &PathBuf, data: &[u8]) {
    let Some(dir) = path.parent() else { return };
    if tokio::fs::create_dir_all(dir).await.is_err() {
        return;
    }
    let tmp = path.with_extension(format!("tmp{}", std::process::id()));
    if tokio::fs::write(&tmp, data).await.is_ok() {
        let _ = tokio::fs::rename(&tmp, path).await;
    }
}
