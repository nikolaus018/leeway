//! OpenSeaMap seamark tiles. OpenSeaMap is run by volunteers: the shared cache keeps repeat requests
//! off their servers, and stale tiles are still served if they are down.

use std::{sync::Arc, time::Duration};

use anyhow::{anyhow, Result};
use tokio::sync::Semaphore;

use crate::{
    cache::{Blob, TileCache},
    config::Config,
};

pub const MAX_ZOOM: u32 = 18;

pub struct SeamarkTiles {
    http: reqwest::Client,
    config: Arc<Config>,
    pub cache: Arc<TileCache>,
    /// Be polite upstream: a few requests at a time.
    upstream: Semaphore,
}

impl SeamarkTiles {
    pub fn new(http: reqwest::Client, config: Arc<Config>) -> Self {
        SeamarkTiles {
            cache: Arc::new(TileCache::new("seamark", &config.cache_dir, Duration::from_secs(14 * 86400), 64)),
            http,
            config,
            upstream: Semaphore::new(6),
        }
    }

    pub async fn tile(&self, z: u32, x: u32, y: u32) -> Result<Arc<Blob>> {
        if z > MAX_ZOOM || x >= 1 << z || y >= 1 << z {
            return Err(anyhow!("no such tile {z}/{x}/{y}"));
        }
        self.cache.get(&format!("{z}/{x}/{y}.png"), || self.download(z, x, y)).await
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
                Ok(data.starts_with(b"\x89PNG").then_some(data))
            }
            204 | 404 => Ok(None),
            status => Err(anyhow!("{url} answered {status}")),
        }
    }
}
