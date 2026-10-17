//! Prometheus-style counters for `/metrics`: requests per route, cache hits and misses, upstream calls
//! and their latency. Small and dependency-free; labels are fixed strings chosen in code.

use std::{
    collections::BTreeMap,
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};

use axum::{
    extract::{MatchedPath, Request},
    middleware::Next,
    response::Response,
};

#[derive(Default)]
struct Registry {
    counters: BTreeMap<String, u64>,
    /// name{labels} → (sum of seconds, count)
    timings: BTreeMap<String, (f64, u64)>,
}

fn registry() -> &'static Mutex<Registry> {
    static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();
    REGISTRY.get_or_init(Default::default)
}

fn series(name: &str, labels: &[(&str, &str)]) -> String {
    if labels.is_empty() {
        return name.to_string();
    }
    let inner: Vec<String> =
        labels.iter().map(|(k, v)| format!("{k}=\"{}\"", v.replace('\\', "\\\\").replace('"', "\\\""))).collect();
    format!("{name}{{{}}}", inner.join(","))
}

pub fn inc(name: &str, labels: &[(&str, &str)]) {
    add(name, labels, 1);
}

pub fn add(name: &str, labels: &[(&str, &str)], n: u64) {
    if let Ok(mut r) = registry().lock() {
        *r.counters.entry(series(name, labels)).or_default() += n;
    }
}

pub fn observe(name: &str, labels: &[(&str, &str)], elapsed: Duration) {
    if let Ok(mut r) = registry().lock() {
        let entry = r.timings.entry(series(name, labels)).or_default();
        entry.0 += elapsed.as_secs_f64();
        entry.1 += 1;
    }
}

/// Times an upstream call and counts its outcome.
pub async fn upstream<T, E>(source: &str, call: impl std::future::Future<Output = Result<T, E>>) -> Result<T, E> {
    let started = Instant::now();
    let result = call.await;
    observe("seadata_upstream_seconds", &[("source", source)], started.elapsed());
    inc("seadata_upstream_requests_total", &[("source", source), ("ok", if result.is_ok() { "true" } else { "false" })]);
    result
}

pub fn render() -> String {
    let Ok(r) = registry().lock() else { return String::new() };
    let mut out = String::new();
    for (name, value) in &r.counters {
        out.push_str(&format!("{name} {value}\n"));
    }
    for (name, (sum, count)) in &r.timings {
        let (base, labels) = name.split_once('{').map_or((name.as_str(), String::new()), |(b, l)| (b, format!("{{{l}")));
        out.push_str(&format!("{base}_sum{labels} {sum:.6}\n{base}_count{labels} {count}\n"));
    }
    out
}

/// Counts requests by route pattern (not raw path, so tile coordinates don't explode the series).
pub async fn track(request: Request, next: Next) -> Response {
    let route = request
        .extensions()
        .get::<MatchedPath>()
        .map(|p| p.as_str().to_string())
        .unwrap_or_else(|| if request.uri().path().starts_with("/v1/charts/files") { "/v1/charts/files".into() } else { "other".into() });
    let started = Instant::now();
    let response = next.run(request).await;
    let status = response.status().as_u16().to_string();
    inc("seadata_requests_total", &[("route", &route), ("status", &status)]);
    observe("seadata_request_seconds", &[("route", &route)], started.elapsed());
    response
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_counters_and_timings() {
        inc("test_total", &[("cache", "x")]);
        inc("test_total", &[("cache", "x")]);
        observe("test_seconds", &[("source", "y")], Duration::from_millis(500));
        let text = render();
        assert!(text.contains("test_total{cache=\"x\"} 2"));
        assert!(text.contains("test_seconds_count{source=\"y\"} 1"));
    }
}
