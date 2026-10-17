//! Sea level at a point (astronomical tide plus surge) from Open-Meteo's marine model, for tide curves.
//! Points are snapped to the model's ~5 km grid so nearby requests share one upstream call.

use std::{sync::Arc, time::Duration};

use anyhow::{anyhow, Result};
use moka::future::Cache;
use serde::Serialize;
use serde_json::Value;

use crate::{config::Config, metrics};

/// Snapping step, degrees.
const STEP: f64 = 0.05;

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct SeaLevel {
    pub lat: f64,
    pub lon: f64,
    pub fetched_at: i64,
    /// Unix seconds, hourly.
    pub times: Vec<i64>,
    /// Metres relative to mean sea level.
    pub height: Vec<Option<f64>>,
}

pub struct SeaLevels {
    http: reqwest::Client,
    config: Arc<Config>,
    cache: Cache<(i32, i32), Arc<SeaLevel>>,
}

impl SeaLevels {
    pub fn new(http: reqwest::Client, config: Arc<Config>) -> Self {
        SeaLevels {
            http,
            config,
            cache: Cache::builder().max_capacity(20_000).time_to_live(Duration::from_secs(3 * 3600)).build(),
        }
    }

    pub async fn at(&self, lat: f64, lon: f64) -> Result<Arc<SeaLevel>> {
        let key = ((lat / STEP).round() as i32, (lon / STEP).round() as i32);
        metrics::inc("seadata_cache_requests_total", &[("cache", "sealevel")]);
        self.cache
            .try_get_with(key, async move {
                metrics::inc("seadata_cache_misses_total", &[("cache", "sealevel")]);
                let (lat, lon) = (key.0 as f64 * STEP, key.1 as f64 * STEP);
                let mut query = vec![
                    ("latitude", format!("{lat:.2}")),
                    ("longitude", format!("{lon:.2}")),
                    ("hourly", "sea_level_height_msl".into()),
                    ("past_days", "1".into()),
                    ("forecast_days", "7".into()),
                    ("timeformat", "unixtime".into()),
                    ("cell_selection", "sea".into()),
                ];
                if let Some(key) = &self.config.open_meteo_key {
                    query.push(("apikey", key.clone()));
                }
                let value: Value = metrics::upstream("sealevel", async {
                    self.http.get(&self.config.marine_url).query(&query).send().await?.error_for_status()?.json().await
                })
                .await?;
                let times: Vec<i64> =
                    value["hourly"]["time"].as_array().map(|a| a.iter().filter_map(Value::as_i64).collect()).unwrap_or_default();
                let height: Vec<Option<f64>> = value["hourly"]["sea_level_height_msl"]
                    .as_array()
                    .map(|a| a.iter().map(|v| v.as_f64().map(|h| (h * 1000.0).round() / 1000.0)).collect())
                    .unwrap_or_default();
                if times.is_empty() || height.iter().all(Option::is_none) {
                    return Err(anyhow!("no sea level data here (inland or outside the model)"));
                }
                Ok(Arc::new(SeaLevel { lat, lon, fetched_at: crate::now(), times, height }))
            })
            .await
            .map_err(|error: Arc<anyhow::Error>| anyhow!("{error:#}"))
    }
}
