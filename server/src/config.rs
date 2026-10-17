use std::{env, path::PathBuf};

/// Everything the server needs from the environment. Every value has a default, so
/// `cargo run` with no environment at all serves forecasts, tiles and the bundled charts.
#[derive(Clone, Debug)]
pub struct Config {
    pub port: u16,
    /// Chart packs (`<id>.json`, `<id>.depth`, `<id>.land`) served to the app.
    pub charts_dir: PathBuf,
    /// Disk cache for seamark tiles.
    pub cache_dir: PathBuf,
    pub forecast_url: String,
    pub marine_url: String,
    /// Open-Meteo commercial key; the free API is for non-commercial use only.
    pub open_meteo_key: Option<String>,
    pub seamark_url: String,
    /// aisstream.io key; AIS is off without one.
    pub ais_key: Option<String>,
    pub ais_url: String,
    /// Area to receive AIS for: south, west, north, east.
    pub ais_bbox: [f64; 4],
    /// Sent upstream as the User-Agent, as OpenSeaMap and Open-Meteo ask.
    pub user_agent: String,
}

impl Config {
    pub fn from_env() -> Self {
        let var = |key: &str| env::var(key).ok().filter(|v| !v.trim().is_empty());
        let key = var("OPEN_METEO_API_KEY");
        // Paid Open-Meteo plans live on customer-api.* hosts.
        let (forecast, marine) = if key.is_some() {
            ("https://customer-api.open-meteo.com/v1/forecast", "https://customer-marine-api.open-meteo.com/v1/marine")
        } else {
            ("https://api.open-meteo.com/v1/forecast", "https://marine-api.open-meteo.com/v1/marine")
        };
        Config {
            port: var("PORT").and_then(|p| p.parse().ok()).unwrap_or(8790),
            charts_dir: var("CHARTS_DIR").map(PathBuf::from).unwrap_or_else(default_charts_dir),
            cache_dir: var("CACHE_DIR").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("cache")),
            forecast_url: var("OPEN_METEO_FORECAST_URL").unwrap_or_else(|| forecast.into()),
            marine_url: var("OPEN_METEO_MARINE_URL").unwrap_or_else(|| marine.into()),
            open_meteo_key: key,
            seamark_url: var("SEAMARK_TILE_URL")
                .unwrap_or_else(|| "https://tiles.openseamap.org/seamark/{z}/{x}/{y}.png".into()),
            ais_key: var("AISSTREAM_API_KEY"),
            ais_url: var("AISSTREAM_URL").unwrap_or_else(|| "wss://stream.aisstream.io/v0/stream".into()),
            ais_bbox: var("AIS_BBOX").and_then(|s| parse_bbox(&s)).unwrap_or([39.5, 12.0, 46.0, 20.5]),
            user_agent: var("USER_AGENT").unwrap_or_else(|| {
                format!("Leeway-seadata/{} (+https://github.com/nikolaus018/leeway)", env!("CARGO_PKG_VERSION"))
            }),
        }
    }
}

/// `charts/` next to the server when deployed on its own, else the app's bundled charts in this repo.
fn default_charts_dir() -> PathBuf {
    let local = PathBuf::from("charts");
    if local.is_dir() {
        return local;
    }
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../Leeway/Charts")
}

fn parse_bbox(s: &str) -> Option<[f64; 4]> {
    let v: Vec<f64> = s.split(',').filter_map(|p| p.trim().parse().ok()).collect();
    (v.len() == 4).then(|| [v[0], v[1], v[2], v[3]])
}
