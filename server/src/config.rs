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
    /// Sailing area (south, west, north, east): AIS is received and the wind grid kept warm here.
    pub ais_bbox: [f64; 4],
    /// Sent upstream as the User-Agent, as OpenSeaMap and Open-Meteo ask.
    pub user_agent: String,
    /// This server's public address for URLs it hands out (TileJSON, radar frames); taken from the
    /// request's Host header when unset.
    pub public_url: Option<String>,
    /// OpenFreeMap's TileJSON, which names the current versioned tile URL.
    pub base_tilejson_url: String,
    pub fonts_url: String,
    /// Terrarium-encoded elevation tiles (AWS Terrain Tiles) for worldwide depth.
    pub terrain_url: String,
    /// Satellite imagery tiles with `{z}/{x}/{y}`.
    pub satellite_url: String,
    /// RainViewer's frame list.
    pub radar_url: String,
    /// MeteoAlarm Atom feed with `{country}`; empty turns warnings off.
    pub warnings_url: String,
    /// Outline of a MeteoAlarm area (GeoJSON) with `{code}`, the area's EMMA_ID.
    pub warning_areas_url: String,
    /// Photon geocoder; empty searches the chart packs only.
    pub search_url: String,
    /// MapLibre styles served at `/v1/style/`.
    pub styles_dir: PathBuf,
    /// Answer `/v1/` only to requests carrying `X-Leeway-Client`.
    pub require_client_header: bool,
    /// Disk cache cap per tile cache, bytes.
    pub cache_max_bytes: u64,
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
            public_url: var("PUBLIC_URL").map(|u| u.trim_end_matches('/').to_string()),
            base_tilejson_url: var("BASE_TILEJSON_URL").unwrap_or_else(|| "https://tiles.openfreemap.org/planet".into()),
            fonts_url: var("FONTS_URL").unwrap_or_else(|| "https://tiles.openfreemap.org/fonts".into()),
            terrain_url: var("TERRAIN_URL")
                .unwrap_or_else(|| "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png".into()),
            // The 2016 mosaic is the CC BY 4.0 one; later years are non-commercial.
            satellite_url: var("SATELLITE_URL").unwrap_or_else(|| {
                "https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/{z}/{y}/{x}.jpg".into()
            }),
            radar_url: var("RADAR_URL").unwrap_or_else(|| "https://api.rainviewer.com/public/weather-maps.json".into()),
            warnings_url: env::var("WARNINGS_URL")
                .unwrap_or_else(|_| "https://feeds.meteoalarm.org/feeds/meteoalarm-legacy-atom-{country}".into()),
            // MeteoAlarm/EUMETNET geocode outlines (CC0), as published with KDE's public alert server.
            warning_areas_url: env::var("WARNING_AREAS_URL").unwrap_or_else(|_| {
                "https://raw.githubusercontent.com/KDE/foss-public-alert-server/master/foss_public_alert_server/alertHandler/data/EMMA_ID/{code}.geojson".into()
            }),
            search_url: env::var("SEARCH_URL").unwrap_or_else(|_| "https://photon.komoot.io/api".into()),
            styles_dir: var("STYLES_DIR").map(PathBuf::from).unwrap_or_else(default_styles_dir),
            require_client_header: var("REQUIRE_CLIENT_HEADER").is_some_and(|v| v == "1" || v == "true"),
            cache_max_bytes: var("CACHE_MAX_GB").and_then(|v| v.parse::<f64>().ok()).map_or(8 << 30, |gb| (gb * 1e9) as u64),
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

/// `styles/` next to the server when deployed, else the repo's `server/styles`.
fn default_styles_dir() -> PathBuf {
    let local = PathBuf::from("styles");
    if local.is_dir() {
        return local;
    }
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("styles")
}

fn parse_bbox(s: &str) -> Option<[f64; 4]> {
    let v: Vec<f64> = s.split(',').filter_map(|p| p.trim().parse().ok()).collect();
    (v.len() == 4).then(|| [v[0], v[1], v[2], v[3]])
}
