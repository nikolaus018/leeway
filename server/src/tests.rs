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
        .route("/seamark/{z}/{x}/{y}", get(|| async { ([(header::CONTENT_TYPE, "image/png")], b"\x89PNGfake".to_vec()) }))
        .route("/planet", get(|headers: HeaderMap| async move {
            let host = headers[header::HOST].to_str().unwrap().to_string();
            Json(json!({"tiles": [format!("http://{host}/base/{{z}}/{{x}}/{{y}}.pbf")], "vector_layers": [{"id": "water"}]}))
        }))
        .route("/base/{z}/{x}/{y}", get(|| async {
            // Water over the west half of every tile.
            let mut water = mvt::Layer::new("water");
            water.add(&mvt::Geometry::Polygons(vec![vec![vec![(0, 0), (2048, 0), (2048, 4096), (0, 4096)]]]), &[]);
            mvt::encode(&[water])
        }))
        .route("/terrain/{z}/{x}/{y}", get(|| async {
            // 40 m deep everywhere: 32728 = 127·256 + 216.
            let mut png_data = Vec::new();
            {
                let mut encoder = png::Encoder::new(&mut png_data, 256, 256);
                encoder.set_color(png::ColorType::Rgb);
                let mut writer = encoder.write_header().unwrap();
                writer.write_image_data(&[127u8, 216, 0].repeat(256 * 256)).unwrap();
            }
            ([(header::CONTENT_TYPE, "image/png")], png_data)
        }));
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
    config.base_tilejson_url = format!("{upstream}/planet");
    config.terrain_url = format!("{upstream}/terrain/{{z}}/{{x}}/{{y}}.png");
    config.warnings_url = String::new();
    config.search_url = String::new();
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

    // Same points again, nudged within the 0.02° grid: served from cache.
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
    assert_eq!(grid["step"], json!(0.1));
    assert_eq!(grid["times"].as_array().unwrap().len(), 2);
    let points = grid["points"].as_array().unwrap().len();
    assert!((20..=forecast::MAX_ON_DEMAND_POINTS).contains(&points), "{points} points");

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

#[tokio::test]
async fn retries_when_open_meteo_is_busy() {
    let calls = Arc::new(AtomicUsize::new(0));
    let healthy = fake_upstream(Arc::new(AtomicUsize::new(0))).await;
    let counter = calls.clone();
    // Refuses the first wind request like Open-Meteo does under load, then passes through.
    let busy = serve(Router::new().route(
        "/forecast",
        get(move |raw: axum::extract::RawQuery| {
            let first = counter.fetch_add(1, Ordering::SeqCst) == 0;
            let healthy = healthy.clone();
            async move {
                let query = raw.0.unwrap_or_default();
                if first && query.contains("models") {
                    return (StatusCode::TOO_MANY_REQUESTS, r#"{"reason":"Too many concurrent requests"}"#.to_string())
                        .into_response();
                }
                let body = reqwest::get(format!("{healthy}/forecast?{query}")).await.unwrap().text().await.unwrap();
                ([(header::CONTENT_TYPE, "application/json")], body).into_response()
            }
        }),
    ))
    .await;
    let cache = tempfile::tempdir().unwrap();
    let base = server(&busy, cache.path()).await;
    let response = reqwest::get(format!("{base}/v1/forecast?points=45.3,14.4")).await.unwrap();
    assert_eq!(response.status(), 200);
    let body: Value = response.json().await.unwrap();
    assert_eq!(body["points"][0]["windSpeed"], json!([14.0, 8.0]));
    assert!(calls.load(Ordering::SeqCst) >= 3, "wind retried after the 429");
}

#[tokio::test]
async fn many_users_cost_one_upstream_call() {
    let calls = Arc::new(AtomicUsize::new(0));
    let upstream = fake_upstream(calls.clone()).await;
    let cache = tempfile::tempdir().unwrap();
    let base = server(&upstream, cache.path()).await;

    let url = format!("{base}/v1/forecast?points=43.5,16.4");
    let requests = (0..50).map(|_| {
        let url = url.clone();
        tokio::spawn(async move { reqwest::get(&url).await.unwrap().status() })
    });
    for status in futures_util::future::join_all(requests).await {
        assert_eq!(status.unwrap(), 200);
    }
    assert_eq!(calls.load(Ordering::SeqCst), 2, "one wind and one weather call for 50 requests");

    // The client's copy is current: 304, no body.
    let first = reqwest::get(&url).await.unwrap();
    let tag = first.headers()[header::ETAG].to_str().unwrap().to_string();
    assert!(first.headers()[header::CACHE_CONTROL].to_str().unwrap().contains("stale-while-revalidate"));
    let again = reqwest::Client::new().get(&url).header(header::IF_NONE_MATCH, &tag).send().await.unwrap();
    assert_eq!(again.status(), 304);

    // A restarted server answers from disk.
    let restarted = server(&upstream, cache.path()).await;
    let body: Value = reqwest::get(format!("{restarted}/v1/forecast?points=43.5,16.4")).await.unwrap().json().await.unwrap();
    assert_eq!(body["points"][0]["windSpeed"], json!([14.0, 8.0]));
    assert_eq!(calls.load(Ordering::SeqCst), 2);

    let metrics = reqwest::get(format!("{base}/metrics")).await.unwrap().text().await.unwrap();
    assert!(metrics.contains("seadata_cache_misses_total{cache=\"forecast\"}"), "{metrics}");
    assert!(metrics.contains("seadata_requests_total{route=\"/v1/forecast\",status=\"200\"}"), "{metrics}");
}

#[tokio::test]
async fn base_map_and_bathymetry_tiles() {
    let upstream = fake_upstream(Arc::new(AtomicUsize::new(0))).await;
    let cache = tempfile::tempdir().unwrap();
    let base = server(&upstream, cache.path()).await;

    let tilejson: Value = reqwest::get(format!("{base}/v1/tiles/base.json")).await.unwrap().json().await.unwrap();
    assert_eq!(tilejson["tiles"][0], json!(format!("{base}/v1/tiles/base/{{z}}/{{x}}/{{y}}.pbf")));
    assert_eq!(tilejson["vector_layers"][0]["id"], json!("water"));

    let tile = reqwest::get(format!("{base}/v1/tiles/base/5/17/11.pbf")).await.unwrap();
    assert_eq!(tile.status(), 200);
    assert_eq!(tile.headers()[header::CONTENT_TYPE], "application/x-protobuf");
    assert_eq!(mvt::polygons(&tile.bytes().await.unwrap(), "water").0.len(), 1);

    let bathy = reqwest::get(format!("{base}/v1/tiles/bathy/5/17/11.pbf")).await.unwrap();
    assert_eq!(bathy.status(), 200);
    let data = bathy.bytes().await.unwrap();
    let (areas, _) = mvt::polygons(&data, "depare");
    assert!(!areas.is_empty());
    // Clipped to the base map's water (the west half of each tile): depth in the west, none in the
    // middle of the east half. The strip at the east edge meets the next tile's water.
    let covered = mvt::rasterize(&areas, 4096, 16);
    assert!(covered[16 * 8 + 3]);
    assert!(!covered[16 * 8 + 12]);
    assert_eq!(reqwest::get(format!("{base}/v1/tiles/bathy/13/0/0.pbf")).await.unwrap().status(), 404);
}

#[tokio::test]
async fn empty_seamark_tiles_are_transparent_images() {
    let upstream = fake_upstream(Arc::new(AtomicUsize::new(0))).await;
    let cache = tempfile::tempdir().unwrap();
    let base = server(&upstream, cache.path()).await;
    let skipped = reqwest::get(format!("{base}/v1/tiles/seamark/10/553/367.png?skip=13.2,42.2,19.0,45.57")).await.unwrap();
    assert_eq!(skipped.status(), 200);
    let png = skipped.bytes().await.unwrap();
    let mut decoder = png::Decoder::new(std::io::Cursor::new(png.to_vec())).read_info().unwrap();
    let mut buffer = vec![0; decoder.output_buffer_size().unwrap()];
    let info = decoder.next_frame(&mut buffer).unwrap();
    assert_eq!((info.width, info.height), (1, 1));
    assert_eq!(buffer[3], 0, "fully transparent");
}
