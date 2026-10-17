//! Forecasts from Open-Meteo, merged into one series per point: wind from the finest model that
//! covers each hour, waves, swell and currents (including tidal streams) from the marine API,
//! and general weather.
//!
//! Every user shares one cache. Points are snapped to the models' resolution, concurrent requests
//! for the same points share one upstream call, results are kept on disk across restarts, and an
//! hour-old forecast is served at once while a fresh one is fetched in the background.

use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::Duration,
};

use anyhow::{anyhow, Context, Result};
use futures_util::{
    future::{try_join_all, BoxFuture, Shared},
    FutureExt,
};
use moka::future::Cache;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::Semaphore;

use crate::{config::Config, metrics};

/// Wind models, finest first: (name the app shows, Open-Meteo model id).
/// ICON-2I is ItaliaMeteo's 2.2 km Adriatic model and resolves the bura; the global
/// fallback covers every hour the others don't. (ICON-D2 adds nothing where ICON-2I runs, and
/// every model multiplies the cost of a request.)
pub const WIND_MODELS: [(&str, &str); 3] =
    [("icon2I", "italia_meteo_arpae_icon_2i"), ("iconEU", "icon_eu"), ("global", "best_match")];

const FORECAST_DAYS: u32 = 4;
/// Points per upstream request; Open-Meteo takes comma-separated lists.
const CHUNK: usize = 25;
/// The free Open-Meteo API refuses too many concurrent requests from one address.
const UPSTREAM_CONCURRENCY: usize = 2;
pub const MAX_POINTS: usize = 200;
/// Seconds a forecast is current; models update every one to three hours.
const FRESH: i64 = 3600;
/// Older than this, a forecast is fetched again before answering.
const STALE: i64 = 6 * 3600;
/// If Open-Meteo is down, forecasts up to this old are still better than nothing.
const LAST_RESORT: i64 = 24 * 3600;

/// Hourly forecast for one point. Optional series are left out when the source has nothing there
/// (for example marine data on a lake).
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct Series {
    pub lat: f64,
    pub lon: f64,
    /// Unix seconds, hourly.
    pub times: Vec<i64>,
    /// Knots.
    pub wind_speed: Vec<Option<f64>>,
    /// Degrees true the wind blows from.
    pub wind_from: Vec<Option<f64>>,
    pub gust: Vec<Option<f64>>,
    /// Which model supplied the wind each hour (see `WIND_MODELS`).
    pub wind_model: Vec<Option<String>>,
    /// Significant wave height, metres.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub wave_height: Vec<Option<f64>>,
    /// Degrees true the waves come from.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub wave_from: Vec<Option<f64>>,
    /// Seconds.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub wave_period: Vec<Option<f64>>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub swell_height: Vec<Option<f64>>,
    /// Knots.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub current_speed: Vec<Option<f64>>,
    /// Degrees true the stream sets towards.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub current_toward: Vec<Option<f64>>,
    /// °C.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub sea_temp: Vec<Option<f64>>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub air_temp: Vec<Option<f64>>,
    /// hPa at sea level.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub pressure: Vec<Option<f64>>,
    /// mm in the hour.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub precipitation: Vec<Option<f64>>,
    /// Percent.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub cloud_cover: Vec<Option<f64>>,
    /// Metres.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub visibility: Vec<Option<f64>>,
    /// WMO weather code.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub weather_code: Vec<Option<f64>>,
}

/// How much to fetch for a point.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Detail {
    /// Everything, wind from the finest model per hour: for routes and the local forecast.
    Full,
    /// Wind from one model and wave height, for map arrows: multi-model requests cost
    /// Open-Meteo about 1.5 s per point.
    Wind,
}

impl Detail {
    fn name(self) -> &'static str {
        match self {
            Detail::Full => "full",
            Detail::Wind => "wind",
        }
    }
}

/// Grid key: hundredths of a degree.
type Key = (i32, i32);

/// Route and local forecasts snap to 0.02° (about the 2.2 km model grid), so nearby requests share
/// a cache entry; wind-grid nodes are already on round multiples and keep 0.01°.
pub fn key(lat: f64, lon: f64, detail: Detail) -> Key {
    match detail {
        Detail::Full => (((lat / 0.02).round() * 2.0) as i32, ((lon / 0.02).round() * 2.0) as i32),
        Detail::Wind => ((lat * 100.0).round() as i32, (lon * 100.0).round() as i32),
    }
}

fn coordinate(k: Key) -> (f64, f64) {
    (k.0 as f64 / 100.0, k.1 as f64 / 100.0)
}

#[derive(Serialize, Deserialize)]
struct Entry {
    /// Unix seconds.
    fetched: i64,
    series: Arc<Series>,
}

impl Entry {
    fn age(&self) -> i64 {
        crate::now() - self.fetched
    }
}

type Fetched = Arc<HashMap<Key, Arc<Entry>>>;
type Pending = Shared<BoxFuture<'static, Result<Fetched, Arc<String>>>>;

pub struct Forecasts {
    http: reqwest::Client,
    config: Arc<Config>,
    memory: Cache<(Detail, Key), Arc<Entry>>,
    /// Upstream fetches under way, so concurrent requests for a point wait for the same one.
    inflight: Mutex<HashMap<(Detail, Key), Pending>>,
    upstream: Semaphore,
}

impl Forecasts {
    pub fn new(http: reqwest::Client, config: Arc<Config>) -> Self {
        Forecasts {
            http,
            config,
            memory: Cache::builder().max_capacity(200_000).time_to_live(Duration::from_secs(STALE as u64)).build(),
            inflight: Mutex::new(HashMap::new()),
            upstream: Semaphore::new(UPSTREAM_CONCURRENCY),
        }
    }

    /// Series for each point, in order, snapped to the grid for `detail`.
    pub async fn series(self: &Arc<Self>, points: &[(f64, f64)], detail: Detail) -> Result<Vec<Arc<Series>>> {
        let keys: Vec<Key> = points.iter().map(|&(lat, lon)| key(lat, lon, detail)).collect();
        let mut unique = keys.clone();
        unique.sort_unstable();
        unique.dedup();
        let cache = [("cache", if detail == Detail::Full { "forecast" } else { "wind" })];
        metrics::add("seadata_cache_requests_total", &cache, unique.len() as u64);

        let mut found: HashMap<Key, Arc<Series>> = HashMap::new();
        let (mut missing, mut refresh) = (Vec::new(), Vec::new());
        for &k in &unique {
            let entry = match self.memory.get(&(detail, k)).await {
                Some(entry) => Some(entry),
                None => match self.load(detail, k).await.filter(|e| e.age() < STALE) {
                    Some(entry) => {
                        metrics::inc("seadata_cache_disk_hits_total", &cache);
                        self.memory.insert((detail, k), entry.clone()).await;
                        Some(entry)
                    }
                    None => None,
                },
            };
            match entry {
                Some(entry) => {
                    if entry.age() > FRESH {
                        refresh.push(k);
                    }
                    found.insert(k, entry.series.clone());
                }
                None => missing.push(k),
            }
        }
        // Serve the hour-old forecast now; fetch the new one for whoever asks next.
        if !refresh.is_empty() {
            metrics::add("seadata_cache_stale_served_total", &cache, refresh.len() as u64);
            drop(self.start(&refresh, detail));
        }
        if !missing.is_empty() {
            metrics::add("seadata_cache_misses_total", &cache, missing.len() as u64);
            match try_join_all(self.start(&missing, detail)).await {
                Ok(results) => {
                    for fetched in results {
                        for (k, entry) in fetched.iter() {
                            found.insert(*k, entry.series.clone());
                        }
                    }
                }
                Err(error) => {
                    // Open-Meteo down: yesterday's forecast is better than none.
                    for &k in &missing {
                        if let Some(entry) = self.load(detail, k).await.filter(|e| e.age() < LAST_RESORT) {
                            found.insert(k, entry.series.clone());
                        }
                    }
                    if missing.iter().any(|k| !found.contains_key(k)) {
                        return Err(anyhow!("{error}"));
                    }
                }
            }
        }
        keys.iter().map(|k| found.get(k).cloned().ok_or_else(|| anyhow!("no forecast for {k:?}"))).collect()
    }

    /// Fetches `keys` unless they're already being fetched; the futures resolve when they're in.
    fn start(self: &Arc<Self>, keys: &[Key], detail: Detail) -> Vec<Pending> {
        let Ok(mut inflight) = self.inflight.lock() else { return Vec::new() };
        let mut pending: Vec<Pending> = Vec::new();
        let mut todo = Vec::new();
        for &k in keys {
            match inflight.get(&(detail, k)) {
                Some(p) => pending.push(p.clone()),
                None => todo.push(k),
            }
        }
        for chunk in todo.chunks(CHUNK) {
            let (this, chunk_keys) = (self.clone(), chunk.to_vec());
            // Spawned, so it finishes (and lands in the cache) even if the asking client goes away.
            let task = tokio::spawn(async move {
                let result = this.fetch_and_store(&chunk_keys, detail).await;
                if let Ok(mut inflight) = this.inflight.lock() {
                    for k in &chunk_keys {
                        inflight.remove(&(detail, *k));
                    }
                }
                result
            });
            let shared: Pending = async move {
                match task.await {
                    Ok(Ok(fetched)) => Ok(Arc::new(fetched)),
                    Ok(Err(error)) => Err(Arc::new(format!("{error:#}"))),
                    Err(error) => Err(Arc::new(error.to_string())),
                }
            }
            .boxed()
            .shared();
            for &k in chunk {
                inflight.insert((detail, k), shared.clone());
            }
            pending.push(shared);
        }
        pending
    }

    async fn fetch_and_store(&self, keys: &[Key], detail: Detail) -> Result<HashMap<Key, Arc<Entry>>> {
        let series = self.fetch(keys, detail).await?;
        let mut out = HashMap::new();
        for (&k, series) in keys.iter().zip(series) {
            let entry = Arc::new(Entry { fetched: crate::now(), series: Arc::new(series) });
            self.memory.insert((detail, k), entry.clone()).await;
            if let Ok(json) = serde_json::to_vec(entry.as_ref()) {
                crate::cache::write(&self.path(detail, k), &json).await;
            }
            out.insert(k, entry);
        }
        Ok(out)
    }

    fn path(&self, detail: Detail, k: Key) -> PathBuf {
        self.config.cache_dir.join("forecast").join(detail.name()).join(format!("{}_{}.json", k.0, k.1))
    }

    async fn load(&self, detail: Detail, k: Key) -> Option<Arc<Entry>> {
        let data = tokio::fs::read(self.path(detail, k)).await.ok()?;
        serde_json::from_slice::<Entry>(&data).ok().map(Arc::new)
    }

    /// Keeps the coarse grid over `bbox` (south, west, north, east) fresh, so zoomed-out map views
    /// never wait on Open-Meteo. Runs every three hours, when new model runs are out, one chunk at a
    /// time so users' own requests always get an upstream slot.
    pub fn keep_warm(self: Arc<Self>, bbox: [f64; 4]) {
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(60)).await;
            loop {
                let [south, west, north, east] = bbox;
                let nodes = nodes_at(WARM_STEP, west, south, east, north);
                let keys: Vec<Key> = nodes.iter().map(|&(lat, lon)| key(lat, lon, Detail::Wind)).collect();
                let started = std::time::Instant::now();
                let mut failed = None;
                for chunk in keys.chunks(CHUNK) {
                    if let Err(error) = try_join_all(self.start(chunk, Detail::Wind)).await {
                        failed = Some(error);
                        break;
                    }
                }
                match failed {
                    None => tracing::info!("wind grid warm: {} points in {:?}", nodes.len(), started.elapsed()),
                    Some(error) => tracing::warn!("wind grid warm-up failed: {error}"),
                }
                tokio::time::sleep(Duration::from_secs(3 * 3600)).await;
            }
        });
    }

    async fn fetch(&self, keys: &[Key], detail: Detail) -> Result<Vec<Series>> {
        let coords: Vec<(f64, f64)> = keys.iter().map(|&k| coordinate(k)).collect();
        let lats = coords.iter().map(|c| format!("{:.2}", c.0)).collect::<Vec<_>>().join(",");
        let lons = coords.iter().map(|c| format!("{:.2}", c.1)).collect::<Vec<_>>().join(",");
        let models = match detail {
            Detail::Full => WIND_MODELS.iter().map(|m| m.1).collect::<Vec<_>>().join(","),
            Detail::Wind => "best_match".to_string(),
        };

        let wind_query = [
            ("hourly", "wind_speed_10m,wind_direction_10m,wind_gusts_10m"),
            ("wind_speed_unit", "kn"),
            ("models", models.as_str()),
        ];
        let weather_query =
            [("hourly", "temperature_2m,pressure_msl,precipitation,cloud_cover,visibility,weather_code")];
        let marine_query = [(
            "hourly",
            match detail {
                Detail::Full => "wave_height,wave_direction,wave_period,swell_wave_height,ocean_current_velocity,ocean_current_direction,sea_surface_temperature",
                Detail::Wind => "wave_height",
            },
        )];
        let wind = self.get(&self.config.forecast_url, &lats, &lons, &wind_query);
        let weather = async {
            match detail {
                Detail::Full => self.get(&self.config.forecast_url, &lats, &lons, &weather_query).await,
                Detail::Wind => Ok(Value::Array(Vec::new())),
            }
        };
        let marine = self.get(&self.config.marine_url, &lats, &lons, &marine_query);
        let (wind, weather, marine) = tokio::join!(wind, weather, marine);
        let wind = locations(wind.context("wind forecast")?);
        // Waves and general weather are extras: a route still gets timed without them.
        let weather = soft(weather, "weather forecast");
        let marine = soft(marine, "marine forecast");
        if wind.len() != keys.len() {
            return Err(anyhow!("wind forecast returned {} locations for {}", wind.len(), keys.len()));
        }
        Ok(coords
            .iter()
            .enumerate()
            .map(|(i, &(lat, lon))| merge(lat, lon, &wind[i], weather.get(i), marine.get(i)))
            .collect())
    }

    async fn get(&self, base: &str, lats: &str, lons: &str, extra: &[(&str, &str)]) -> Result<Value> {
        let days = FORECAST_DAYS.to_string();
        let mut query: Vec<(&str, &str)> = vec![
            ("latitude", lats),
            ("longitude", lons),
            ("forecast_days", &days),
            ("timeformat", "unixtime"),
            ("cell_selection", "sea"),
        ];
        query.extend_from_slice(extra);
        if let Some(key) = &self.config.open_meteo_key {
            query.push(("apikey", key));
        }
        // Busy or briefly down upstream: back off and try again.
        let mut attempt = 0;
        loop {
            let response = {
                let _permit = self.upstream.acquire().await?;
                metrics::upstream("open-meteo", self.http.get(base).query(&query).timeout(Duration::from_secs(60)).send()).await
            };
            let retry = match response {
                Ok(response) if response.status().is_success() => return Ok(response.json().await?),
                Ok(response) => {
                    let status = response.status();
                    let body = response.text().await.unwrap_or_default();
                    let error = anyhow!("{base} answered {status}: {}", body.chars().take(300).collect::<String>());
                    if status.as_u16() == 429 || status.is_server_error() {
                        error
                    } else {
                        return Err(error);
                    }
                }
                Err(error) if error.is_timeout() || error.is_connect() => error.into(),
                Err(error) => return Err(error.into()),
            };
            attempt += 1;
            if attempt > 3 {
                return Err(retry);
            }
            tokio::time::sleep(Duration::from_millis(1000 << attempt)).await;
        }
    }
}

fn soft(result: Result<Value>, what: &str) -> Vec<Hourly> {
    match result {
        Ok(value) => locations(value),
        Err(error) => {
            tracing::warn!("{what} unavailable: {error:#}");
            Vec::new()
        }
    }
}

/// One location's `hourly` block: time axis, variables, and their units.
#[derive(Default, Debug)]
pub struct Hourly {
    times: Vec<i64>,
    values: HashMap<String, Vec<Option<f64>>>,
    units: HashMap<String, String>,
}

impl Hourly {
    fn get(&self, name: &str, i: usize) -> Option<f64> {
        self.values.get(name).and_then(|v| v.get(i).copied().flatten())
    }
}

/// Open-Meteo answers one location as an object and several as an array.
pub fn locations(value: Value) -> Vec<Hourly> {
    let items = match value {
        Value::Array(items) => items,
        other => vec![other],
    };
    items.iter().map(hourly).collect()
}

fn hourly(location: &Value) -> Hourly {
    let mut out = Hourly::default();
    if let Some(block) = location.get("hourly").and_then(Value::as_object) {
        for (name, values) in block {
            let Some(values) = values.as_array() else { continue };
            if name == "time" {
                out.times = values.iter().filter_map(Value::as_i64).collect();
            } else {
                out.values.insert(name.clone(), values.iter().map(Value::as_f64).collect());
            }
        }
    }
    if let Some(units) = location.get("hourly_units").and_then(Value::as_object) {
        for (name, unit) in units {
            if let Some(unit) = unit.as_str() {
                out.units.insert(name.clone(), unit.to_string());
            }
        }
    }
    out
}

/// Factor that turns a speed in `unit` into knots.
fn to_knots(unit: Option<&str>) -> f64 {
    match unit.unwrap_or("km/h") {
        "kn" | "knots" => 1.0,
        "m/s" => 3600.0 / 1852.0,
        "mph" | "mp/h" => 1609.344 / 1852.0,
        _ => 1.0 / 1.852, // km/h
    }
}

fn round(v: Option<f64>, decimals: i32) -> Option<f64> {
    let k = 10f64.powi(decimals);
    v.filter(|x| x.is_finite()).map(|x| (x * k).round() / k)
}

pub fn merge(lat: f64, lon: f64, wind: &Hourly, weather: Option<&Hourly>, marine: Option<&Hourly>) -> Series {
    let mut s = Series { lat, lon, times: wind.times.clone(), ..Default::default() };
    for i in 0..wind.times.len() {
        // Finest model that has both speed and direction this hour.
        let model = WIND_MODELS.iter().find(|(_, id)| {
            wind.get(&format!("wind_speed_10m_{id}"), i).is_some()
                && wind.get(&format!("wind_direction_10m_{id}"), i).is_some()
        });
        // A single-model request has unsuffixed names.
        let plain = wind.get("wind_speed_10m", i).is_some();
        let (speed, from, gust, label) = match model {
            Some((label, id)) => (
                wind.get(&format!("wind_speed_10m_{id}"), i),
                wind.get(&format!("wind_direction_10m_{id}"), i),
                wind.get(&format!("wind_gusts_10m_{id}"), i),
                Some(label.to_string()),
            ),
            None if plain => (
                wind.get("wind_speed_10m", i),
                wind.get("wind_direction_10m", i),
                wind.get("wind_gusts_10m", i),
                Some("global".to_string()),
            ),
            None => (None, None, None, None),
        };
        s.wind_speed.push(round(speed, 1));
        s.wind_from.push(round(from, 0));
        // Never report gusts below the mean wind (models disagree when mixed).
        s.gust.push(round(gust.map(|g| g.max(speed.unwrap_or(0.0))).or(speed), 1));
        s.wind_model.push(label);
    }

    // Other feeds are lined up by timestamp, so differing ranges can't shift them.
    let align = |source: &Hourly, name: &str, factor: f64, decimals: i32| -> Vec<Option<f64>> {
        if !source.values.contains_key(name) {
            return Vec::new();
        }
        let index: HashMap<i64, usize> = source.times.iter().enumerate().map(|(i, &t)| (t, i)).collect();
        let series: Vec<Option<f64>> = wind
            .times
            .iter()
            .map(|t| round(index.get(t).and_then(|&i| source.get(name, i)).map(|v| v * factor), decimals))
            .collect();
        if series.iter().all(Option::is_none) {
            Vec::new()
        } else {
            series
        }
    };
    if let Some(m) = marine {
        let knots = to_knots(m.units.get("ocean_current_velocity").map(String::as_str));
        s.wave_height = align(m, "wave_height", 1.0, 2);
        s.wave_from = align(m, "wave_direction", 1.0, 0);
        s.wave_period = align(m, "wave_period", 1.0, 1);
        s.swell_height = align(m, "swell_wave_height", 1.0, 2);
        s.current_speed = align(m, "ocean_current_velocity", knots, 2);
        s.current_toward = align(m, "ocean_current_direction", 1.0, 0);
        s.sea_temp = align(m, "sea_surface_temperature", 1.0, 1);
    }
    if let Some(w) = weather {
        s.air_temp = align(w, "temperature_2m", 1.0, 1);
        s.pressure = align(w, "pressure_msl", 1.0, 1);
        s.precipitation = align(w, "precipitation", 1.0, 1);
        s.cloud_cover = align(w, "cloud_cover", 1.0, 0);
        s.visibility = align(w, "visibility", 1.0, 0);
        s.weather_code = align(w, "weather_code", 1.0, 0);
    }
    s
}

// MARK: Wind grid

/// Wind (and waves) on a regular grid over a map view, for drawing arrows.
#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Grid {
    /// Grid spacing, degrees.
    pub step: f64,
    /// Shared time axis for every point (unix seconds, hourly).
    pub times: Vec<i64>,
    pub points: Vec<GridPoint>,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct GridPoint {
    pub lat: f64,
    pub lon: f64,
    pub wind_speed: Vec<Option<f64>>,
    pub wind_from: Vec<Option<f64>>,
    pub gust: Vec<Option<f64>>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub wave_height: Vec<Option<f64>>,
}

pub const MAX_GRID_POINTS: usize = 90;
/// Finer grids than the warm one are fetched on demand, so keep them small.
pub const MAX_ON_DEMAND_POINTS: usize = 30;
/// Spacing of the grid kept warm in the background; coarser grids are subsets of it.
pub const WARM_STEP: f64 = 0.5;

/// Grid nodes covering a box, on multiples of the step so different views share cached points.
pub fn grid_nodes(west: f64, south: f64, east: f64, north: f64) -> (f64, Vec<(f64, f64)>) {
    const STEPS: [f64; 9] = [0.05, 0.1, 0.2, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0];
    let count = |step: f64| {
        let cols = ((east / step).floor() - (west / step).ceil() + 1.0).max(0.0);
        let rows = ((north / step).floor() - (south / step).ceil() + 1.0).max(0.0);
        (cols * rows) as usize
    };
    let fits = |step: f64| count(step) <= if step >= WARM_STEP { MAX_GRID_POINTS } else { MAX_ON_DEMAND_POINTS };
    let step = STEPS.iter().copied().find(|&s| fits(s)).unwrap_or(10.0);
    let mut nodes = nodes_at(step, west, south, east, north);
    nodes.truncate(MAX_GRID_POINTS);
    (step, nodes)
}

fn nodes_at(step: f64, west: f64, south: f64, east: f64, north: f64) -> Vec<(f64, f64)> {
    let mut nodes = Vec::new();
    let (r0, r1) = ((south / step).ceil() as i64, (north / step).floor() as i64);
    let (c0, c1) = ((west / step).ceil() as i64, (east / step).floor() as i64);
    for r in r0..=r1 {
        for c in c0..=c1 {
            let lat = (r as f64 * step * 100.0).round() / 100.0;
            let lon = (c as f64 * step * 100.0).round() / 100.0;
            if lat.abs() <= 85.0 && lon.abs() <= 180.0 {
                nodes.push((lat, lon));
            }
        }
    }
    nodes
}

pub fn grid(step: f64, series: &[Arc<Series>]) -> Grid {
    let times = series.first().map(|s| s.times.clone()).unwrap_or_default();
    let points = series
        .iter()
        .map(|s| {
            let index: HashMap<i64, usize> = s.times.iter().enumerate().map(|(i, &t)| (t, i)).collect();
            let pick = |values: &Vec<Option<f64>>| -> Vec<Option<f64>> {
                if values.is_empty() {
                    return Vec::new();
                }
                times.iter().map(|t| index.get(t).and_then(|&i| values.get(i).copied().flatten())).collect()
            };
            GridPoint {
                lat: s.lat,
                lon: s.lon,
                wind_speed: pick(&s.wind_speed),
                wind_from: pick(&s.wind_from),
                gust: pick(&s.gust),
                wave_height: pick(&s.wave_height),
            }
        })
        .collect();
    Grid { step, times, points }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn picks_finest_model_per_hour_and_converts_currents() {
        let wind = locations(json!([{
            "hourly": {
                "time": [0, 3600, 7200],
                "wind_speed_10m_italia_meteo_arpae_icon_2i": [10.0, null, null],
                "wind_direction_10m_italia_meteo_arpae_icon_2i": [45.0, null, null],
                "wind_gusts_10m_italia_meteo_arpae_icon_2i": [25.0, null, null],
                "wind_speed_10m_icon_eu": [11.0, 12.0, null],
                "wind_direction_10m_icon_eu": [50.0, 60.0, null],
                "wind_gusts_10m_icon_eu": [20.0, 8.0, null],
                "wind_speed_10m_best_match": [9.0, 9.0, 7.0],
                "wind_direction_10m_best_match": [40.0, 40.0, 300.0],
                "wind_gusts_10m_best_match": [15.0, 15.0, 12.0]
            }
        }]));
        let marine = locations(json!({
            "hourly_units": {"ocean_current_velocity": "km/h"},
            "hourly": {
                "time": [3600, 7200],
                "wave_height": [0.5, 0.75],
                "ocean_current_velocity": [1.852, 3.704],
                "ocean_current_direction": [90.0, 180.0]
            }
        }));
        let s = merge(45.0, 14.0, &wind[0], None, marine.first());
        assert_eq!(s.wind_model, vec![Some("icon2I".into()), Some("iconEU".into()), Some("global".into())]);
        assert_eq!(s.wind_speed, vec![Some(10.0), Some(12.0), Some(7.0)]);
        // Gusts never below the mean wind.
        assert_eq!(s.gust, vec![Some(25.0), Some(12.0), Some(12.0)]);
        // Marine lined up by time: no data for hour 0.
        assert_eq!(s.wave_height, vec![None, Some(0.5), Some(0.75)]);
        assert_eq!(s.current_speed, vec![None, Some(1.0), Some(2.0)]);
        assert!(s.air_temp.is_empty());
    }

    #[test]
    fn grid_stays_small_and_snapped() {
        let (step, nodes) = grid_nodes(13.2, 42.2, 19.0, 45.6);
        assert!(nodes.len() <= MAX_GRID_POINTS);
        assert_eq!(step, 0.5);
        assert!(nodes.iter().all(|&(lat, lon)| ((lat / step).round() * step - lat).abs() < 1e-9 && lon >= 13.2));
        let (fine, nodes) = grid_nodes(14.3, 45.0, 14.6, 45.3);
        assert_eq!(fine, 0.1);
        assert!(nodes.len() <= MAX_ON_DEMAND_POINTS);
        assert!(!nodes.is_empty());
    }
}
