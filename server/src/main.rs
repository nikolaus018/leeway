//! seadata: the Leeway app's data server. It pulls every external source the app uses (Open-Meteo
//! wind, weather, waves and currents; OpenSeaMap seamark tiles; aisstream.io AIS) and serves it in
//! one compact shape, with caching, plus the offline chart packs.

mod ais;
mod charts;
mod config;
mod forecast;
mod tiles;

use std::{net::SocketAddr, sync::Arc, time::Duration};

use axum::{
    extract::{Path, Query, State},
    http::{header, HeaderValue, StatusCode},
    response::{Html, IntoResponse, Response},
    routing::get,
    Json, Router,
};
use serde::Deserialize;
use serde_json::json;
use tower_http::{compression::CompressionLayer, cors::CorsLayer, services::ServeDir, trace::TraceLayer};

use crate::{ais::Ais, config::Config, forecast::Forecasts, tiles::SeamarkTiles};

#[derive(Clone)]
struct AppState {
    config: Arc<Config>,
    forecasts: Arc<Forecasts>,
    tiles: Arc<SeamarkTiles>,
    ais: Arc<Ais>,
    started: std::time::Instant,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "seadata=info,tower_http=warn".into()),
        )
        .init();
    let config = Arc::new(Config::from_env());
    let state = AppState::new(config.clone())?;
    tracing::info!(
        "charts from {}, {} pack(s); tile cache in {}",
        config.charts_dir.display(),
        charts::list(&config.charts_dir).len(),
        config.cache_dir.display()
    );
    let addr = SocketAddr::from(([0, 0, 0, 0], config.port));
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!("seadata listening on http://{addr}");
    axum::serve(listener, app(state)).with_graceful_shutdown(shutdown()).await?;
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
        Ok(AppState {
            forecasts: Arc::new(Forecasts::new(http.clone(), config.clone())),
            tiles: Arc::new(SeamarkTiles::new(http, config.clone())),
            ais: Ais::start(config.clone()),
            config,
            started: std::time::Instant::now(),
        })
    }
}

fn app(state: AppState) -> Router {
    let charts = ServeDir::new(&state.config.charts_dir);
    Router::new()
        .route("/", get(index))
        .route("/health", get(health))
        .route("/v1/info", get(info))
        .route("/v1/forecast", get(forecast))
        .route("/v1/wind-grid", get(wind_grid))
        .route("/v1/tiles/seamark/{z}/{x}/{y}", get(seamark_tile))
        .route("/v1/charts", get(chart_list))
        .nest_service("/v1/charts/files", charts)
        .route("/v1/ais", get(ais_vessels))
        .layer(CompressionLayer::new())
        .layer(CorsLayer::permissive())
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

// MARK: Errors

struct ApiError(StatusCode, String);

impl ApiError {
    fn bad(message: impl Into<String>) -> Self {
        ApiError(StatusCode::BAD_REQUEST, message.into())
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

fn cached<T: IntoResponse>(seconds: u32, body: T) -> Response {
    let mut response = body.into_response();
    if let Ok(value) = HeaderValue::from_str(&format!("public, max-age={seconds}")) {
        response.headers_mut().insert(header::CACHE_CONTROL, value);
    }
    response
}

// MARK: Handlers

async fn index() -> Html<&'static str> {
    Html(include_str!("index.html"))
}

async fn health(State(state): State<AppState>) -> Json<serde_json::Value> {
    Json(json!({ "ok": true, "uptimeSeconds": state.started.elapsed().as_secs() }))
}

async fn info(State(state): State<AppState>) -> Json<serde_json::Value> {
    let mut features = vec!["forecast", "windGrid", "seamarkTiles", "charts"];
    if state.ais.enabled {
        features.push("ais");
    }
    Json(json!({
        "name": "seadata",
        "version": env!("CARGO_PKG_VERSION"),
        "features": features,
        "windModels": forecast::WIND_MODELS.iter().map(|m| m.0).collect::<Vec<_>>(),
        "attribution": [
            "Weather, waves and currents: Open-Meteo.com (CC BY 4.0), models by ItaliaMeteo-ARPAE, DWD, ECMWF, NOAA, Météo-France and others",
            "Seamarks: OpenSeaMap (CC BY-SA 2.0)",
            "Charts: EMODnet Bathymetry (CC BY 4.0), © OpenStreetMap contributors (ODbL)",
            "AIS: aisstream.io",
        ],
    }))
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

async fn forecast(State(state): State<AppState>, Query(q): Query<ForecastQuery>) -> Result<Response, ApiError> {
    let points = parse_points(&q.points)?;
    let series = state.forecasts.series(&points).await?;
    Ok(cached(
        600,
        Json(json!({
            "fetchedAt": chrono_now(),
            "points": series.iter().map(|s| s.as_ref()).collect::<Vec<_>>(),
        })),
    ))
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

async fn wind_grid(State(state): State<AppState>, Query(q): Query<BoxQuery>) -> Result<Response, ApiError> {
    q.validate()?;
    let (step, nodes) = forecast::grid_nodes(q.west, q.south, q.east, q.north);
    if nodes.is_empty() {
        return Ok(cached(600, Json(forecast::grid(step, &[]))));
    }
    let series = state.forecasts.series(&nodes).await?;
    Ok(cached(600, Json(forecast::grid(step, &series))))
}

async fn seamark_tile(
    State(state): State<AppState>,
    Path((z, x, y)): Path<(u32, u32, String)>,
) -> Result<Response, ApiError> {
    let y: u32 = y.trim_end_matches(".png").parse().map_err(|_| ApiError::bad("bad tile"))?;
    if z > tiles::MAX_ZOOM || x >= 1 << z || y >= 1 << z {
        return Err(ApiError(StatusCode::NOT_FOUND, "no such tile".into()));
    }
    Ok(match state.tiles.tile(z, x, y).await? {
        tiles::Tile::Png(data) => cached(7 * 24 * 3600, ([(header::CONTENT_TYPE, "image/png")], data)),
        tiles::Tile::Empty => cached(7 * 24 * 3600, StatusCode::NO_CONTENT),
    })
}

async fn chart_list(State(state): State<AppState>) -> Response {
    let dir = state.config.charts_dir.clone();
    let packs = tokio::task::spawn_blocking(move || charts::list(&dir)).await.unwrap_or_default();
    cached(300, Json(json!({ "charts": packs })))
}

async fn ais_vessels(State(state): State<AppState>, Query(q): Query<BoxQuery>) -> Result<Response, ApiError> {
    q.validate()?;
    if !state.ais.enabled {
        return Err(ApiError(StatusCode::NOT_IMPLEMENTED, "AIS is not configured on this server".into()));
    }
    let max_age = q.max_age.unwrap_or(1800).clamp(60, 3600);
    let vessels = state.ais.query(q.west, q.south, q.east, q.north, max_age).await;
    Ok(cached(10, Json(json!({ "fetchedAt": chrono_now(), "vessels": vessels }))))
}

fn chrono_now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs() as i64)
}

#[cfg(test)]
mod tests;
