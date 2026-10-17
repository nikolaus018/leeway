//! HTTP caching: strong ETags, conditional requests and per-endpoint Cache-Control, so phones and
//! Cloudflare's edge only download what changed.

use axum::{
    body::Body,
    http::{header, HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
};
use bytes::Bytes;
use serde::Serialize;

/// How long a response may be reused: by the app (`max_age`), by shared caches such as Cloudflare
/// (`edge`), and while revalidating in the background (`stale`).
#[derive(Clone, Copy, Debug)]
pub struct Policy {
    pub max_age: u32,
    pub edge: u32,
    pub stale: u32,
    pub immutable: bool,
}

impl Policy {
    pub const fn new(max_age: u32, edge: u32, stale: u32) -> Self {
        Policy { max_age, edge, stale, immutable: false }
    }

    /// Live data (AIS): a few seconds at most.
    pub const LIVE: Policy = Policy::new(5, 5, 10);
    /// Forecasts: models update a few times a day.
    pub const FORECAST: Policy = Policy::new(600, 900, 3600);
    /// Map tiles that change rarely.
    pub const TILE: Policy = Policy::new(7 * 86400, 30 * 86400, 7 * 86400);
    /// Content-addressed files: never change under the same URL.
    pub const IMMUTABLE: Policy = Policy { max_age: 365 * 86400, edge: 365 * 86400, stale: 0, immutable: true };

    pub fn header(&self) -> HeaderValue {
        let mut value = format!("public, max-age={}, s-maxage={}", self.max_age, self.edge);
        if self.stale > 0 {
            value.push_str(&format!(", stale-while-revalidate={}", self.stale));
        }
        if self.immutable {
            value.push_str(", immutable");
        }
        HeaderValue::from_str(&value).unwrap_or(HeaderValue::from_static("no-cache"))
    }
}

pub const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;

/// FNV-1a: stable across builds and machines, unlike `std`'s hasher.
pub fn fnv1a(mut hash: u64, data: &[u8]) -> u64 {
    for &byte in data {
        hash ^= byte as u64;
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

pub fn etag(data: &[u8]) -> String {
    format!("\"{:016x}\"", fnv1a(FNV_OFFSET, data))
}

/// The client already has this version.
pub fn not_modified(headers: &HeaderMap, etag: &str) -> bool {
    headers
        .get_all(header::IF_NONE_MATCH)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(','))
        .map(|v| v.trim().trim_start_matches("W/"))
        .any(|v| v == etag || v == "*")
}

/// A cacheable body: 304 when the client's copy is current, else the bytes with validators.
pub fn bytes(headers: &HeaderMap, data: Bytes, etag: &str, content_type: &'static str, policy: Policy) -> Response {
    let mut response = if not_modified(headers, etag) {
        StatusCode::NOT_MODIFIED.into_response()
    } else {
        let mut response = Response::new(Body::from(data));
        response.headers_mut().insert(header::CONTENT_TYPE, HeaderValue::from_static(content_type));
        response
    };
    let h = response.headers_mut();
    h.insert(header::CACHE_CONTROL, policy.header());
    if let Ok(value) = HeaderValue::from_str(etag) {
        h.insert(header::ETAG, value);
    }
    response
}

pub fn json<T: Serialize>(headers: &HeaderMap, value: &T, policy: Policy) -> Response {
    match serde_json::to_vec(value) {
        Ok(body) => {
            let tag = etag(&body);
            bytes(headers, Bytes::from(body), &tag, "application/json", policy)
        }
        Err(error) => (StatusCode::INTERNAL_SERVER_ERROR, error.to_string()).into_response(),
    }
}

/// Nothing there (an empty tile), cacheable like content.
pub fn empty(policy: Policy) -> Response {
    let mut response = StatusCode::NO_CONTENT.into_response();
    response.headers_mut().insert(header::CACHE_CONTROL, policy.header());
    response
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conditional_requests() {
        let tag = etag(b"hello");
        let mut headers = HeaderMap::new();
        assert_eq!(bytes(&headers, Bytes::from_static(b"hello"), &tag, "text/plain", Policy::TILE).status(), 200);
        headers.insert(header::IF_NONE_MATCH, HeaderValue::from_str(&format!("W/\"x\", {tag}")).unwrap());
        let response = bytes(&headers, Bytes::from_static(b"hello"), &tag, "text/plain", Policy::TILE);
        assert_eq!(response.status(), 304);
        assert_eq!(response.headers()[header::ETAG], tag.as_str());
        assert!(response.headers()[header::CACHE_CONTROL].to_str().unwrap().contains("s-maxage"));
    }
}
