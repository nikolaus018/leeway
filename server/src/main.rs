//! seadata: the Leeway app's data server. It pulls every external source the app uses (the base map,
//! worldwide depth, Open-Meteo wind, weather, waves, currents and sea level; OpenSeaMap seamarks;
//! satellite imagery; rain radar; MeteoAlarm warnings; place search; aisstream.io AIS) and serves it
//! in one compact shape from a cache that every user shares, plus the offline chart packs.

mod ais;
mod basemap;
mod bathy;
mod cache;
mod charts;
mod config;
mod forecast;
mod http;
mod imagery;
mod metrics;
mod mvt;
mod ratelimit;
mod sealevel;
mod search;
mod tiles;
mod warnings;

use std::{net::SocketAddr, sync::Arc, time::Duration};

use axum::{
    extract::{Path, Query, Request, State},
    http::{header, HeaderMap, StatusCode},
    middleware::{self, Next},
    response::{Html, IntoResponse, Response},
    routing::get,
    Json, Router,
};
use serde::Deserialize;
use serde_json::json;
use tower_http::{compression::CompressionLayer, cors::CorsLayer, services::ServeDir, trace::TraceLayer};

use crate::{
    ais::Ais,
    basemap::BaseMap,
    bathy::Bathy,
    cache::{Blob, TileCache},
    config::Config,
    forecast::Forecasts,
    http::Policy,
    imagery::{Radar, Satellite},
    ratelimit::{Limiter, Rate},
    sealevel::SeaLevels,
    search::Search,
    tiles::SeamarkTiles,
    warnings::Warnings,
};

#[derive(Clone)]
struct AppState {
    config: Arc<Config>,
    forecasts: Arc<Forecasts>,
    seamarks: Arc<SeamarkTiles>,
    base: Arc<BaseMap>,
    bathy: Arc<Bathy>,
    satellite: Arc<Satellite>,
    radar: Arc<Radar>,
    sealevels: Arc<SeaLevels>,
    warnings: Arc<Warnings>,
    search: Arc<Search>,
    ais: Arc<Ais>,
    limiter: Arc<Limiter>,
    started: std::time::Instant,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| "seadata=info,tower_http=warn".into());
    if std::env::var("LOG_FORMAT").is_ok_and(|f| f == "json") {
        tracing_subscriber::fmt().json().with_env_filter(filter).init();
    } else {
        tracing_subscriber::fmt().with_env_filter(filter).init();
    }
    let config = Arc::new(Config::from_env());
    let state = AppState::new(config.clone())?;
    // The AIS area is also the sailing area: keep its wind grid ready for zoomed-out maps.
    state.forecasts.clone().keep_warm(config.ais_bbox);
    state.keep_caches_small();
    tracing::info!(
        "charts from {}, {} pack(s); cache in {}",
        config.charts_dir.display(),
        charts::list(&config.charts_dir).len(),
        config.cache_dir.display()
    );
    let addr = SocketAddr::from(([0, 0, 0, 0], config.port));
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!("seadata listening on http://{addr}");
    axum::serve(listener, app(state).into_make_service_with_connect_info::<SocketAddr>())
        .with_graceful_shutdown(shutdown())
        .await?;
    Ok(())
}

async fn shutdown() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let term = async {
        if let Ok(mut s) = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            s.recv().await;
        }
    };
    #[cfg(not(unix))]
    let term = std::future::pending::<()>();
    tokio::select! { _ = ctrl_c => {}, _ = term => {} }
}

impl AppState {
    fn new(config: Arc<Config>) -> anyhow::Result<Self> {
        let http = reqwest::Client::builder()
            .user_agent(config.user_agent.clone())
            .timeout(Duration::from_secs(25))
            .connect_timeout(Duration::from_secs(8))
            .build()?;
        let base = Arc::new(BaseMap::new(http.clone(), config.clone()));
        Ok(AppState {
            forecasts: Arc::new(Forecasts::new(http.clone(), config.clone())),
            seamarks: Arc::new(SeamarkTiles::new(http.clone(), config.clone())),
            bathy: Arc::new(Bathy::new(http.clone(), config.clone(), base.clone())),
            base,
            satellite: Arc::new(Satellite::new(http.clone(), config.clone())),
            radar: Arc::new(Radar::new(http.clone(), config.clone())),
            sealevels: Arc::new(SeaLevels::new(http.clone(), config.clone())),
            warnings: Warnings::start(http.clone(), config.clone()),
            search: Arc::new(Search::new(http, config.clone())),
            ais: Ais::start(config.clone()),
            limiter: Limiter::new(
                Rate { burst: 600.0, per_second: 60.0 },
                Rate { burst: 60.0, per_second: 2.0 },
                config.require_client_header,
            ),
            config,
            started: std::time::Instant::now(),
        })
    }

    /// Splits the disk budget between the tile caches, biggest share to the base map.
    fn keep_caches_small(&self) {
        let budget = self.config.cache_max_bytes;
        let [base, fonts] = self.base.caches();
        let [terrain, bathy] = self.bathy.caches();
        let shares: [(&Arc<TileCache>, u64); 7] = [
            (base, 35),
            (bathy, 15),
            (terrain, 15),
            (&self.satellite.tiles, 20),
            (&self.seamarks.cache, 10),
            (&self.radar.tiles, 4),
            (fonts, 1),
        ];
        for (cache, percent) in shares {
            cache.keep_under(budget / 100 * percent);
        }
    }

    /// This server's address as the client sees it, for URLs in responses.
    fn public_url(&self, headers: &HeaderMap) -> String {
        if let Some(url) = &self.config.public_url {
            return url.clone();
        }
        let get = |name: header::HeaderName| headers.get(name).and_then(|v| v.to_str().ok());
        let host = headers
            .get("x-forwarded-host")
            .and_then(|v| v.to_str().ok())
            .or_else(|| get(header::HOST))
            .unwrap_or("localhost");
        let proto = headers.get("x-forwarded-proto").and_then(|v| v.to_str().ok()).unwrap_or(
            if host.starts_with("localhost") || host.starts_with("127.") || host.starts_with("192.168.") { "http" } else { "https" },
        );
        format!("{proto}://{host}")
    }
}

fn app(state: AppState) -> Router {
    let charts = Router::new()
        .nest_service("/v1/charts/files", ServeDir::new(&state.config.charts_dir))
        .layer(middleware::from_fn(chart_file_caching));
    Router::new()
        .route("/", get(index))
        .route("/health", get(health))
        .route("/metrics", get(metrics_text))
        .route("/v1/info", get(info))
        .route("/v1/forecast", get(forecast))
        .route("/v1/wind-grid", get(wind_grid))
        .route("/v1/sealevel", get(sea_level))
        .route("/v1/warnings", get(weather_warnings))
        .route("/v1/search", get(search_places))
        .route("/v1/radar", get(radar_frames))
        .route("/v1/ais", get(ais_vessels))
        .route("/v1/charts", get(chart_list))
        .route("/v1/tiles/seamark/{z}/{x}/{y}", get(seamark_tile))
        .route("/v1/tiles/base.json", get(base_tilejson))
        .route("/v1/tiles/base/{z}/{x}/{y}", get(base_tile))
        .route("/v1/tiles/bathy/{z}/{x}/{y}", get(bathy_tile))
        .route("/v1/tiles/satellite/{z}/{x}/{y}", get(satellite_tile))
        .route("/v1/tiles/radar/{time}/{z}/{x}/{y}", get(radar_tile))
        .route("/v1/fonts/{fontstack}/{range}", get(glyphs))
        .nest_service("/v1/style", ServeDir::new(&state.config.styles_dir))
        .route_layer(middleware::from_fn(metrics::track))
        .merge(charts)
        .layer(middleware::from_fn_with_state(state.limiter.clone(), ratelimit::limit))
        .layer(CompressionLayer::new())
        .layer(CorsLayer::permissive())
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

/// Chart files asked for with `?v=<version>` never change under that URL.
async fn chart_file_caching(request: Request, next: Next) -> Response {
    let versioned = request.uri().query().is_some_and(|q| q.split('&').any(|p| p.starts_with("v=")));
    let mut response = next.run(request).await;
    let policy = if versioned { Policy::IMMUTABLE } else { Policy::new(300, 300, 3600) };
    response.headers_mut().insert(header::CACHE_CONTROL, policy.header());
    response
}

pub fn now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs() as i64)
}

// MARK: Errors

struct ApiError(StatusCode, String);

impl ApiError {
    fn bad(message: impl Into<String>) -> Self {
        ApiError(StatusCode::BAD_REQUEST, message.into())
    }

    fn not_found() -> Self {
        ApiError(StatusCode::NOT_FOUND, "no such tile".into())
    }
}

impl From<anyhow::Error> for ApiError {
    fn from(error: anyhow::Error) -> Self {
        tracing::warn!("upstream: {error:#}");
        ApiError(StatusCode::BAD_GATEWAY, format!("{error:#}"))
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.0, Json(json!({ "error": self.1 }))).into_response()
    }
}

// MARK: Handlers

async fn index() -> Html<&'static str> {
    Html(include_str!("index.html"))
}

async fn health(State(state): State<AppState>) -> Json<serde_json::Value> {
    Json(json!({ "ok": true, "uptimeSeconds": state.started.elapsed().as_secs() }))
}

async fn metrics_text() -> Response {
    ([(header::CONTENT_TYPE, "text/plain; version=0.0.4")], metrics::render()).into_response()
}

async fn info(State(state): State<AppState>, headers: HeaderMap) -> Response {
    let mut features =
        vec!["forecast", "windGrid", "seamarkTiles", "charts", "baseMap", "bathymetry", "satellite", "radar", "seaLevel", "warnings", "search"];
    if state.ais.enabled {
        features.push("ais");
    }
    http::json(
        &headers,
        &json!({
            "name": "seadata",
            "version": env!("CARGO_PKG_VERSION"),
            "features": features,
            "windModels": forecast::WIND_MODELS.iter().map(|m| m.0).collect::<Vec<_>>(),
            "attribution": [
                "Base map: OpenFreeMap, © OpenMapTiles, © OpenStreetMap contributors (ODbL)",
                "Worldwide depth: AWS Terrain Tiles (GEBCO, ETOPO1, NOAA and others)",
                "Weather, waves, currents and sea level: Open-Meteo.com (CC BY 4.0), models by ItaliaMeteo-ARPAE, DWD, ECMWF, NOAA, Météo-France and others",
                "Seamarks: OpenSeaMap (CC BY-SA 2.0)",
                "Charts: EMODnet Bathymetry (CC BY 4.0), © OpenStreetMap contributors (ODbL)",
                "Satellite: Sentinel-2 cloudless 2016 by EOX IT Services GmbH (contains modified Copernicus Sentinel data 2016, CC BY 4.0)",
                "Rain radar: RainViewer",
                "Warnings: MeteoAlarm and the national weather services (CC BY 4.0)",
                "Search: Photon by komoot, © OpenStreetMap contributors",
                "AIS: aisstream.io",
            ],
        }),
        Policy::new(300, 300, 3600),
    )
}

#[derive(Deserialize)]
struct ForecastQuery {
    /// `lat,lon;lat,lon;…`
    points: String,
}

fn parse_points(spec: &str) -> Result<Vec<(f64, f64)>, ApiError> {
    let points: Vec<(f64, f64)> = spec
        .split(';')
        .filter(|p| !p.trim().is_empty())
        .map(|pair| {
            let mut parts = pair.split(',').map(|v| v.trim().parse::<f64>());
            match (parts.next(), parts.next(), parts.next()) {
                (Some(Ok(lat)), Some(Ok(lon)), None) if lat.abs() <= 90.0 && lon.abs() <= 180.0 => Ok((lat, lon)),
                _ => Err(ApiError::bad(format!("bad point '{pair}', expected lat,lon"))),
            }
        })
        .collect::<Result<_, _>>()?;
    if points.is_empty() || points.len() > forecast::MAX_POINTS {
        return Err(ApiError::bad(format!("give 1 to {} points", forecast::MAX_POINTS)));
    }
    Ok(points)
}

async fn forecast(State(state): State<AppState>, headers: HeaderMap, Query(q): Query<ForecastQuery>) -> Result<Response, ApiError> {
    let points = parse_points(&q.points)?;
    let series = state.forecasts.series(&points, forecast::Detail::Full).await?;
    let body = json!({
        "fetchedAt": now(),
        "points": series.iter().map(|s| s.as_ref()).collect::<Vec<_>>(),
    });
    // The ETag covers the forecast only, not the time it was asked for.
    let tag = http::etag(&serde_json::to_vec(&body["points"]).unwrap_or_default());
    let data = serde_json::to_vec(&body).map_err(|e| anyhow::anyhow!(e))?;
    Ok(http::bytes(&headers, data.into(), &tag, "application/json", Policy::FORECAST))
}

#[derive(Deserialize)]
struct BoxQuery {
    west: f64,
    south: f64,
    east: f64,
    north: f64,
    /// AIS only: seconds since the last position report.
    #[serde(rename = "maxAge")]
    max_age: Option<i64>,
}

impl BoxQuery {
    fn validate(&self) -> Result<(), ApiError> {
        let ok = self.west < self.east
            && self.south < self.north
            && self.south >= -90.0
            && self.north <= 90.0
            && self.west >= -180.0
            && self.east <= 180.0;
        if ok {
            Ok(())
        } else {
            Err(ApiError::bad("bad box: need west < east and south < north, in degrees"))
        }
    }
}

async fn wind_grid(State(state): State<AppState>, headers: HeaderMap, Query(q): Query<BoxQuery>) -> Result<Response, ApiError> {
    q.validate()?;
    let (step, nodes) = forecast::grid_nodes(q.west, q.south, q.east, q.north);
    if nodes.is_empty() {
        return Ok(http::json(&headers, &forecast::grid(step, &[]), Policy::FORECAST));
    }
    let series = state.forecasts.series(&nodes, forecast::Detail::Wind).await?;
    Ok(http::json(&headers, &forecast::grid(step, &series), Policy::FORECAST))
}

#[derive(Deserialize)]
struct PointQuery {
    lat: f64,
    lon: f64,
}

async fn sea_level(State(state): State<AppState>, headers: HeaderMap, Query(q): Query<PointQuery>) -> Result<Response, ApiError> {
    if q.lat.abs() > 90.0 || q.lon.abs() > 180.0 {
        return Err(ApiError::bad("bad position"));
    }
    let level = state.sealevels.at(q.lat, q.lon).await.map_err(|e| ApiError(StatusCode::NOT_FOUND, format!("{e:#}")))?;
    Ok(http::json(&headers, level.as_ref(), Policy::FORECAST))
}

async fn weather_warnings(State(state): State<AppState>, headers: HeaderMap, Query(q): Query<BoxQuery>) -> Result<Response, ApiError> {
    q.validate()?;
    let found = state.warnings.in_box(q.west, q.south, q.east, q.north).await;
    Ok(http::json(&headers, &json!({ "fetchedAt": now(), "warnings": found }), Policy::new(300, 300, 600)))
}

#[derive(Deserialize)]
struct SearchQuery {
    q: String,
    lat: Option<f64>,
    lon: Option<f64>,
    limit: Option<usize>,
}

async fn search_places(State(state): State<AppState>, headers: HeaderMap, Query(q): Query<SearchQuery>) -> Result<Response, ApiError> {
    if q.q.len() > 100 {
        return Err(ApiError::bad("query too long"));
    }
    let near = q.lat.zip(q.lon).filter(|(lat, lon)| lat.abs() <= 90.0 && lon.abs() <= 180.0);
    let results = state.search.find(&q.q, near, q.limit.unwrap_or(10).clamp(1, 25)).await?;
    Ok(http::json(&headers, &json!({ "results": results }), Policy::new(3600, 86400, 86400)))
}

async fn radar_frames(State(state): State<AppState>, headers: HeaderMap) -> Result<Response, ApiError> {
    let public = state.public_url(&headers);
    let frames = state.radar.list(&public).await?;
    Ok(http::json(&headers, &frames, Policy::new(60, 60, 120)))
}

async fn ais_vessels(State(state): State<AppState>, headers: HeaderMap, Query(q): Query<BoxQuery>) -> Result<Response, ApiError> {
    q.validate()?;
    if !state.ais.enabled {
        return Err(ApiError(StatusCode::NOT_IMPLEMENTED, "AIS is not configured on this server".into()));
    }
    let max_age = q.max_age.unwrap_or(1800).clamp(60, 3600);
    let vessels = state.ais.query(q.west, q.south, q.east, q.north, max_age).await;
    Ok(http::json(&headers, &json!({ "fetchedAt": now(), "vessels": vessels }), Policy::LIVE))
}

async fn chart_list(State(state): State<AppState>, headers: HeaderMap) -> Response {
    let dir = state.config.charts_dir.clone();
    let packs = tokio::task::spawn_blocking(move || charts::list(&dir)).await.unwrap_or_default();
    http::json(&headers, &json!({ "charts": packs }), Policy::new(300, 300, 3600))
}

// MARK: Tiles

/// `z`, `x` and `y` from a tile path whose last part carries an extension (`123.png`).
fn tile_path(z: u32, x: u32, y: &str, ext: &str) -> Result<(u32, u32, u32), ApiError> {
    let y: u32 = y.strip_suffix(ext).unwrap_or(y).parse().map_err(|_| ApiError::bad("bad tile"))?;
    if z > 22 || x >= 1 << z || y >= 1 << z {
        return Err(ApiError::not_found());
    }
    Ok((z, x, y))
}

/// A 1×1 transparent PNG.
const TRANSPARENT_PNG: &[u8] = &[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01,
    0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0B, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x63, 0x60, 0x00, 0x02, 0x00, 0x00, 0x05, 0x00, 0x01, 0x7A, 0x5E, 0xAB, 0x3F, 0x00, 0x00, 0x00, 0x00,
    0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

fn transparent(headers: &HeaderMap) -> Response {
    http::bytes(headers, bytes::Bytes::from_static(TRANSPARENT_PNG), "\"transparent\"", "image/png", Policy::TILE)
}

fn tile_response(headers: &HeaderMap, blob: &Blob, content_type: &'static str, policy: Policy) -> Response {
    if blob.is_empty() {
        return http::empty(policy);
    }
    http::bytes(headers, blob.data.clone(), &blob.etag, content_type, policy)
}

#[derive(Deserialize)]
struct SkipQuery {
    /// Chart pack boxes the app draws its own seamarks in: `w,s,e,n;…`.
    skip: Option<String>,
}

async fn seamark_tile(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((z, x, y)): Path<(u32, u32, String)>,
    Query(q): Query<SkipQuery>,
) -> Result<Response, ApiError> {
    let (z, x, y) = tile_path(z, x, &y, ".png")?;
    if z > tiles::MAX_ZOOM {
        return Err(ApiError::not_found());
    }
    // Empty tiles are a transparent image, not "204 No Content": map engines keep showing a
    // stretched parent tile where a child has no content.
    if q.skip.as_deref().is_some_and(|spec| tiles::covered(z, x, y, &tiles::parse_skip(spec))) {
        return Ok(transparent(&headers));
    }
    let blob = state.seamarks.tile(z, x, y).await?;
    if blob.is_empty() {
        return Ok(transparent(&headers));
    }
    Ok(tile_response(&headers, &blob, "image/png", Policy::TILE))
}

async fn base_tilejson(State(state): State<AppState>, headers: HeaderMap) -> Result<Response, ApiError> {
    let public = state.public_url(&headers);
    Ok(http::json(&headers, &state.base.tilejson(&public).await?, Policy::new(3600, 3600, 86400)))
}

async fn base_tile(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((z, x, y)): Path<(u32, u32, String)>,
) -> Result<Response, ApiError> {
    let (z, x, y) = tile_path(z, x, &y, ".pbf")?;
    if z > basemap::MAX_ZOOM {
        return Err(ApiError::not_found());
    }
    let blob = state.base.tile(z, x, y).await?;
    Ok(tile_response(&headers, &blob, "application/x-protobuf", Policy::TILE))
}

async fn bathy_tile(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((z, x, y)): Path<(u32, u32, String)>,
) -> Result<Response, ApiError> {
    let (z, x, y) = tile_path(z, x, &y, ".pbf")?;
    if z > bathy::MAX_ZOOM {
        return Err(ApiError::not_found());
    }
    let blob = state.bathy.tile(z, x, y).await?;
    Ok(tile_response(&headers, &blob, "application/x-protobuf", Policy::TILE))
}

async fn satellite_tile(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((z, x, y)): Path<(u32, u32, String)>,
) -> Result<Response, ApiError> {
    let (z, x, y) = tile_path(z, x, &y, ".jpg")?;
    if z > imagery::SATELLITE_MAX_ZOOM {
        return Err(ApiError::not_found());
    }
    let blob = state.satellite.tile(z, x, y).await?;
    Ok(tile_response(&headers, &blob, "image/jpeg", Policy::TILE))
}

async fn radar_tile(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((time, z, x, y)): Path<(i64, u32, u32, String)>,
) -> Result<Response, ApiError> {
    let (z, x, y) = tile_path(z, x, &y, ".png")?;
    match state.radar.tile(time, z, x, y).await? {
        // A frame never changes; it just stops being offered.
        Some(blob) => Ok(tile_response(&headers, &blob, "image/png", Policy::new(3600, 3600, 0))),
        None => Err(ApiError::not_found()),
    }
}

async fn glyphs(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((fontstack, range)): Path<(String, String)>,
) -> Result<Response, ApiError> {
    let range = range.strip_suffix(".pbf").unwrap_or(&range);
    let blob = state.base.glyphs(&fontstack, range).await.map_err(|e| ApiError::bad(format!("{e:#}")))?;
    Ok(tile_response(&headers, &blob, "application/x-protobuf", Policy::IMMUTABLE))
}

#[cfg(test)]
mod tests;
