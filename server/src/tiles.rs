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

/// West, south, east, north of tile z/x/y in degrees.
pub fn bounds(z: u32, x: u32, y: u32) -> [f64; 4] {
    let n = (1u64 << z) as f64;
    let lat = |t: f64| (std::f64::consts::PI * (1.0 - 2.0 * t / n)).sinh().atan().to_degrees();
    [x as f64 / n * 360.0 - 180.0, lat(y as f64 + 1.0), (x as f64 + 1.0) / n * 360.0 - 180.0, lat(y as f64)]
}

/// Boxes (`w,s,e,n;w,s,e,n`) the app draws its own seamarks in, from a chart pack.
pub fn parse_skip(spec: &str) -> Vec<[f64; 4]> {
    spec.split(';')
        .filter_map(|b| {
            let v: Vec<f64> = b.split(',').filter_map(|p| p.trim().parse().ok()).collect();
            (v.len() == 4).then(|| [v[0], v[1], v[2], v[3]])
        })
        .take(32)
        .collect()
}

/// The tile lies wholly inside one of the boxes.
pub fn covered(z: u32, x: u32, y: u32, boxes: &[[f64; 4]]) -> bool {
    let [w, s, e, n] = bounds(z, x, y);
    boxes.iter().any(|b| w >= b[0] && s >= b[1] && e <= b[2] && n <= b[3])
}

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skips_tiles_inside_packs() {
        let boxes = parse_skip("13.2,42.2,19.0,45.57;bad");
        assert_eq!(boxes.len(), 1);
        // z10 tile over Kvarner is inside, a z6 tile reaching beyond is not.
        assert!(covered(10, 553, 367, &boxes));
        assert!(!covered(6, 34, 22, &boxes));
        let [w, s, e, n] = bounds(0, 0, 0);
        assert!((w + 180.0).abs() < 1e-9 && (e - 180.0).abs() < 1e-9 && (n - 85.0511).abs() < 1e-3 && s < -85.0);
    }
}
