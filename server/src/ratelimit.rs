//! Per-client rate limits (token buckets), so one misbehaving client can't use up the upstream
//! quotas everyone shares. Behind Cloudflare the client is `CF-Connecting-IP`. Map tiles get a far
//! bigger allowance than API calls: a map view loads dozens at once.

use std::{
    collections::HashMap,
    net::{IpAddr, SocketAddr},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use axum::{
    extract::{ConnectInfo, Request, State},
    http::{header, HeaderMap, HeaderValue, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
};

use crate::metrics;

#[derive(Clone, Copy, Debug)]
pub struct Rate {
    /// Requests allowed at once.
    pub burst: f64,
    /// Sustained requests per second.
    pub per_second: f64,
}

pub struct Limiter {
    tiles: Rate,
    api: Rate,
    require_client_header: bool,
    buckets: Mutex<HashMap<(IpAddr, bool), (f64, Instant)>>,
}

impl Limiter {
    pub fn new(tiles: Rate, api: Rate, require_client_header: bool) -> Arc<Self> {
        let limiter = Arc::new(Limiter { tiles, api, require_client_header, buckets: Mutex::new(HashMap::new()) });
        // Forget idle clients.
        let weak = Arc::downgrade(&limiter);
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(300)).await;
                let Some(limiter) = weak.upgrade() else { return };
                if let Ok(mut buckets) = limiter.buckets.lock() {
                    buckets.retain(|_, (_, last)| last.elapsed() < Duration::from_secs(600));
                };
            }
        });
        limiter
    }

    /// Takes one token; `Err(seconds)` until the next one if the bucket is empty.
    fn take(&self, ip: IpAddr, tile: bool) -> Result<(), u64> {
        let rate = if tile { self.tiles } else { self.api };
        let Ok(mut buckets) = self.buckets.lock() else { return Ok(()) };
        let now = Instant::now();
        let (tokens, last) = buckets.entry((ip, tile)).or_insert((rate.burst, now));
        *tokens = (*tokens + now.duration_since(*last).as_secs_f64() * rate.per_second).min(rate.burst);
        *last = now;
        if *tokens >= 1.0 {
            *tokens -= 1.0;
            Ok(())
        } else {
            Err(((1.0 - *tokens) / rate.per_second).ceil().max(1.0) as u64)
        }
    }
}

/// The forwarding headers are only believed from a local proxy (the tunnel); a direct client could
/// otherwise send a fresh address with every request and never run out of tokens.
pub fn client_ip(headers: &HeaderMap, peer: Option<SocketAddr>) -> Option<IpAddr> {
    let header = |name: &str| headers.get(name).and_then(|v| v.to_str().ok());
    let from_proxy = peer.is_none_or(|p| p.ip().is_loopback());
    from_proxy
        .then(|| {
            header("cf-connecting-ip")
                .or_else(|| header("x-forwarded-for").and_then(|v| v.split(',').next()))
                .and_then(|v| v.trim().parse().ok())
        })
        .flatten()
        .or_else(|| peer.map(|p| p.ip()))
}

pub async fn limit(State(limiter): State<Arc<Limiter>>, request: Request, next: Next) -> Response {
    let path = request.uri().path();
    if !path.starts_with("/v1/") {
        return next.run(request).await;
    }
    if limiter.require_client_header && !request.headers().contains_key("x-leeway-client") {
        return (StatusCode::FORBIDDEN, "This server is for the Leeway app.").into_response();
    }
    let tile = path.starts_with("/v1/tiles/") || path.starts_with("/v1/fonts/") || path.starts_with("/v1/charts/files/");
    let peer = request.extensions().get::<ConnectInfo<SocketAddr>>().map(|c| c.0);
    let Some(ip) = client_ip(request.headers(), peer) else { return next.run(request).await };
    match limiter.take(ip, tile) {
        Ok(()) => next.run(request).await,
        Err(wait) => {
            metrics::inc("seadata_rate_limited_total", &[("kind", if tile { "tiles" } else { "api" })]);
            let mut response = (StatusCode::TOO_MANY_REQUESTS, "Too many requests; slow down.").into_response();
            if let Ok(value) = HeaderValue::from_str(&wait.to_string()) {
                response.headers_mut().insert(header::RETRY_AFTER, value);
            }
            response
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn buckets_refill() {
        let limiter = Limiter::new(Rate { burst: 3.0, per_second: 1.0 }, Rate { burst: 2.0, per_second: 100.0 }, false);
        let ip: IpAddr = "10.0.0.1".parse().unwrap();
        assert!((0..3).all(|_| limiter.take(ip, true).is_ok()));
        assert_eq!(limiter.take(ip, true), Err(1));
        // Separate allowance for API calls, and per client.
        assert!(limiter.take(ip, false).is_ok());
        assert!(limiter.take("10.0.0.2".parse().unwrap(), true).is_ok());
    }

    #[test]
    fn prefers_cloudflare_header() {
        let mut headers = HeaderMap::new();
        headers.insert("x-forwarded-for", "1.1.1.1, 2.2.2.2".parse().unwrap());
        assert_eq!(client_ip(&headers, None), Some("1.1.1.1".parse().unwrap()));
        headers.insert("cf-connecting-ip", "3.3.3.3".parse().unwrap());
        assert_eq!(client_ip(&headers, None), Some("3.3.3.3".parse().unwrap()));
    }
}
