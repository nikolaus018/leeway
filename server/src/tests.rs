//! End-to-end: the real router against a fake Open-Meteo and OpenSeaMap on localhost.

use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};

use axum::{extract::Query, routing::get, Json, Router};
use serde_json::{json, Value};

use super::*;

/// Answers like Open-Meteo for however many locations are asked, and counts the calls.
async fn fake_upstream(calls: Arc<AtomicUsize>) -> String {
    let forecast_calls = calls.clone();
    let router = Router::new()
        .route(
            "/forecast",
            get(move |Query(q): Query<std::collections::HashMap<String, String>>| {
                forecast_calls.fetch_add(1, Ordering::SeqCst);
                async move {
                    let n = q["latitude"].split(',').count();
                    let multi = q.contains_key("models");
                    let one = if multi {
                        json!({"hourly": {
                            "time": [1_700_000_000i64, 1_700_003_600i64],
                            "wind_speed_10m_italia_meteo_arpae_icon_2i": [14.0, null],
                            "wind_direction_10m_italia_meteo_arpae_icon_2i": [45.0, null],
                            "wind_gusts_10m_italia_meteo_arpae_icon_2i": [30.0, null],
                            "wind_speed_10m_best_match": [10.0, 8.0],
                            "wind_direction_10m_best_match": [40.0, 320.0],
                            "wind_gusts_10m_best_match": [15.0, 12.0]
                        }})
                    } else {
                        json!({"hourly": {"time": [1_700_000_000i64, 1_700_003_600i64], "temperature_2m": [21.5, 22.0], "pressure_msl": [1012.0, 1011.4]}})
                    };
                    Json(if n == 1 { one } else { Value::Array(vec![one; n]) })
                }
            }),
        )
        .route(
            "/marine",
            get(|Query(q): Query<std::collections::HashMap<String, String>>| async move {
                let n = q["latitude"].split(',').count();
                let one = json!({
                    "hourly_units": {"ocean_current_velocity": "km/h"},
                    "hourly": {"time": [1_700_000_000i64, 1_700_003_600i64], "wave_height": [0.8, 1.1],
                               "ocean_current_velocity": [0.926, 1.852], "ocean_current_direction": [100.0, 120.0]}
                });
                Json(if n == 1 { one } else { Value::Array(vec![one; n]) })
            }),
        )
        .route("/seamark/{z}/{x}/{y}", get(|| async { ([(header::CONTENT_TYPE, "image/png")], b"\x89PNGfake".to_vec()) }));
    serve(router).await
}

async fn serve(router: Router) -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    format!("http://{addr}")
}

async fn server(upstream: &str, cache: &std::path::Path) -> String {
    let mut config = Config::from_env();
    config.forecast_url = format!("{upstream}/forecast");
    config.marine_url = format!("{upstream}/marine");
    config.seamark_url = format!("{upstream}/seamark/{{z}}/{{x}}/{{y}}.png");
    config.cache_dir = cache.to_path_buf();
    config.ais_key = None;
    config.charts_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../Leeway/Charts");
    serve(app(AppState::new(Arc::new(config)).unwrap())).await
}

#[tokio::test]
async fn forecast_merges_sources_and_caches_points() {
    let calls = Arc::new(AtomicUsize::new(0));
    let upstream = fake_upstream(calls.clone()).await;
    let cache = tempfile::tempdir().unwrap();
    let base = server(&upstream, cache.path()).await;

    let url = format!("{base}/v1/forecast?points=45.3245,14.4385;44.5335,14.4660");
    let body: Value = reqwest::get(&url).await.unwrap().json().await.unwrap();
    let points = body["points"].as_array().unwrap();
    assert_eq!(points.len(), 2);
    let p = &points[0];
    assert_eq!(p["lat"], json!(45.32));
    assert_eq!(p["windModel"], json!(["icon2I", "global"]));
    assert_eq!(p["windSpeed"], json!([14.0, 8.0]));
    assert_eq!(p["currentSpeed"], json!([0.5, 1.0]));
    assert_eq!(p["waveHeight"], json!([0.8, 1.1]));
    assert_eq!(p["airTemp"], json!([21.5, 22.0]));
    assert_eq!(calls.load(Ordering::SeqCst), 2, "wind and weather once each");

    // Same points again, nudged within the 0.01° grid: served from cache.
    let again = format!("{base}/v1/forecast?points=45.3221,14.4401");
    let body: Value = reqwest::get(&again).await.unwrap().json().await.unwrap();
    assert_eq!(body["points"][0]["windSpeed"], json!([14.0, 8.0]));
    assert_eq!(calls.load(Ordering::SeqCst), 2);

    let bad = reqwest::get(format!("{base}/v1/forecast?points=95,14")).await.unwrap();
    assert_eq!(bad.status(), 400);
}

#[tokio::test]
async fn wind_grid_tiles_and_charts() {
    let calls = Arc::new(AtomicUsize::new(0));
    let upstream = fake_upstream(calls).await;
    let cache = tempfile::tempdir().unwrap();
    let base = server(&upstream, cache.path()).await;

    let grid: Value = reqwest::get(format!("{base}/v1/wind-grid?west=14.0&south=45.0&east=14.5&north=45.4"))
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(grid["step"], json!(0.05));
    assert_eq!(grid["times"].as_array().unwrap().len(), 2);
    assert!(grid["points"].as_array().unwrap().len() > 50);

    let tile = reqwest::get(format!("{base}/v1/tiles/seamark/10/550/362.png")).await.unwrap();
    assert_eq!(tile.status(), 200);
    assert!(tile.bytes().await.unwrap().starts_with(b"\x89PNG"));
    assert!(cache.path().join("seamark/10/550/362.png").exists());
    assert_eq!(reqwest::get(format!("{base}/v1/tiles/seamark/2/9/0.png")).await.unwrap().status(), 404);

    let charts: Value = reqwest::get(format!("{base}/v1/charts")).await.unwrap().json().await.unwrap();
    let adriatic = &charts["charts"][0];
    assert_eq!(adriatic["id"], json!("adriatic"));
    let file = adriatic["files"][1].as_str().unwrap();
    let download = reqwest::get(format!("{base}/v1/charts/files/{file}")).await.unwrap();
    assert_eq!(download.status(), 200);
    assert_eq!(
        download.bytes().await.unwrap().len() as u64,
        std::fs::metadata(format!("{}/../Leeway/Charts/{file}", env!("CARGO_MANIFEST_DIR"))).unwrap().len()
    );

    let info: Value = reqwest::get(format!("{base}/v1/info")).await.unwrap().json().await.unwrap();
    assert!(!info["features"].as_array().unwrap().contains(&json!("ais")));
    assert_eq!(reqwest::get(format!("{base}/v1/ais?west=13&south=44&east=15&north=46")).await.unwrap().status(), 501);
}
