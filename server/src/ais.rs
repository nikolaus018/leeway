//! Live AIS traffic from aisstream.io: one websocket for the configured area, vessels kept in memory.

use std::{
    collections::HashMap,
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use futures_util::{SinkExt, StreamExt};
use serde::Serialize;
use serde_json::{json, Value};
use tokio::sync::RwLock;
use tokio_tungstenite::tungstenite::Message;

use crate::config::Config;

/// Vessels not heard from for this long are dropped.
const FORGET_AFTER: i64 = 3600;

#[derive(Serialize, Clone, Debug, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Vessel {
    pub mmsi: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub call_sign: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destination: Option<String>,
    /// AIS ship type code (30 fishing, 36 sailing, 37 pleasure, 60–69 passenger, 70–79 cargo, 80–89 tanker…).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ship_type: Option<u32>,
    /// Metres.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub length: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub beam: Option<f64>,
    pub lat: f64,
    pub lon: f64,
    /// Knots.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sog: Option<f64>,
    /// Degrees true.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cog: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub heading: Option<f64>,
    /// AIS navigational status (0 under way using engine, 1 at anchor, 5 moored, 8 under way sailing…).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub nav_status: Option<u32>,
    /// Unix seconds of the last position.
    pub updated: i64,
    /// Static data can arrive before the first position.
    #[serde(skip)]
    pub has_position: bool,
    /// Unix seconds of the last message of any kind.
    #[serde(skip)]
    pub seen: i64,
}

#[derive(Default)]
pub struct Ais {
    vessels: RwLock<HashMap<u32, Vessel>>,
    pub enabled: bool,
}

fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs() as i64)
}

impl Ais {
    pub fn start(config: Arc<Config>) -> Arc<Ais> {
        let ais = Arc::new(Ais { enabled: config.ais_key.is_some(), ..Default::default() });
        if let Some(key) = config.ais_key.clone() {
            let worker = ais.clone();
            tokio::spawn(async move { worker.run(&config, &key).await });
            let pruner = ais.clone();
            tokio::spawn(async move {
                loop {
                    tokio::time::sleep(Duration::from_secs(60)).await;
                    let cutoff = now() - FORGET_AFTER;
                    pruner.vessels.write().await.retain(|_, v| v.seen >= cutoff);
                }
            });
        } else {
            tracing::info!("AIS off: set AISSTREAM_API_KEY to receive live vessel positions");
        }
        ais
    }

    async fn run(&self, config: &Config, key: &str) {
        let [south, west, north, east] = config.ais_bbox;
        let subscription = json!({
            "APIKey": key,
            "BoundingBoxes": [[[south, west], [north, east]]],
            "FilterMessageTypes": [
                "PositionReport", "StandardClassBPositionReport", "ExtendedClassBPositionReport",
                "ShipStaticData", "StaticDataReport"
            ],
        })
        .to_string();
        let mut backoff = 2;
        loop {
            match tokio_tungstenite::connect_async(config.ais_url.as_str()).await {
                Ok((mut socket, _)) => {
                    if socket.send(Message::text(subscription.clone())).await.is_ok() {
                        tracing::info!("AIS connected");
                        backoff = 2;
                        while let Some(message) = socket.next().await {
                            let text = match message {
                                Ok(Message::Text(text)) => text.to_string(),
                                Ok(Message::Binary(data)) => String::from_utf8_lossy(&data).into_owned(),
                                Ok(Message::Close(_)) | Err(_) => break,
                                Ok(_) => continue,
                            };
                            if let Ok(value) = serde_json::from_str::<Value>(&text) {
                                if let Some(error) = value.get("error").and_then(Value::as_str) {
                                    tracing::warn!("aisstream: {error}");
                                    continue;
                                }
                                self.ingest(&value).await;
                            }
                        }
                    }
                    tracing::warn!("AIS disconnected; reconnecting");
                }
                Err(error) => tracing::warn!("AIS connect failed: {error}"),
            }
            tokio::time::sleep(Duration::from_secs(backoff)).await;
            backoff = (backoff * 2).min(120);
        }
    }

    pub async fn ingest(&self, value: &Value) {
        let Some(kind) = value.get("MessageType").and_then(Value::as_str) else { return };
        let Some(body) = value.get("Message").and_then(|m| m.get(kind)) else { return };
        let meta = value.get("MetaData");
        let mmsi = meta
            .and_then(|m| m.get("MMSI"))
            .or_else(|| body.get("UserID"))
            .and_then(Value::as_u64)
            .and_then(|m| u32::try_from(m).ok());
        let Some(mmsi) = mmsi else { return };
        let mut vessels = self.vessels.write().await;
        let vessel = vessels.entry(mmsi).or_insert_with(|| Vessel { mmsi, ..Default::default() });
        vessel.seen = now();
        if let Some(name) = meta.and_then(|m| m.get("ShipName")).and_then(text) {
            vessel.name.get_or_insert(name);
        }
        apply(vessel, kind, body);
    }

    /// Vessels with a position inside the box, heard from within `max_age` seconds.
    pub async fn query(&self, west: f64, south: f64, east: f64, north: f64, max_age: i64) -> Vec<Vessel> {
        let cutoff = now() - max_age;
        let vessels = self.vessels.read().await;
        let mut found: Vec<Vessel> = vessels
            .values()
            .filter(|v| v.has_position && v.updated >= cutoff)
            .filter(|v| v.lat >= south && v.lat <= north && v.lon >= west && v.lon <= east)
            .cloned()
            .collect();
        found.sort_by_key(|v| std::cmp::Reverse(v.updated));
        found.truncate(3000);
        found
    }
}

/// AIS pads names with spaces and `@`.
fn text(v: &Value) -> Option<String> {
    let s = v.as_str()?.trim_matches(|c: char| c == '@' || c.is_whitespace()).to_string();
    (!s.is_empty()).then_some(s)
}

fn apply(vessel: &mut Vessel, kind: &str, body: &Value) {
    let num = |key: &str| body.get(key).and_then(Value::as_f64);
    match kind {
        "PositionReport" | "StandardClassBPositionReport" | "ExtendedClassBPositionReport" => {
            let (Some(lat), Some(lon)) = (num("Latitude"), num("Longitude")) else { return };
            // 91/181 mean "not available".
            if lat.abs() > 90.0 || lon.abs() > 180.0 {
                return;
            }
            vessel.lat = lat;
            vessel.lon = lon;
            vessel.sog = num("Sog").filter(|&s| s < 102.2);
            vessel.cog = num("Cog").filter(|&c| c < 360.0);
            vessel.heading = num("TrueHeading").filter(|&h| h < 360.0);
            if let Some(status) = body.get("NavigationalStatus").and_then(Value::as_u64) {
                vessel.nav_status = Some(status as u32);
            }
            vessel.updated = now();
            vessel.has_position = true;
            if kind == "ExtendedClassBPositionReport" {
                static_fields(vessel, body);
            }
        }
        "ShipStaticData" => static_fields(vessel, body),
        "StaticDataReport" => {
            if let Some(a) = body.get("ReportA").filter(|a| a.get("Valid").and_then(Value::as_bool) != Some(false)) {
                if let Some(name) = a.get("Name").and_then(text) {
                    vessel.name = Some(name);
                }
            }
            if let Some(b) = body.get("ReportB").filter(|b| b.get("Valid").and_then(Value::as_bool) != Some(false)) {
                if let Some(t) = b.get("ShipType").and_then(Value::as_u64).filter(|&t| t > 0) {
                    vessel.ship_type = Some(t as u32);
                }
                if let Some(call) = b.get("CallSign").and_then(text) {
                    vessel.call_sign = Some(call);
                }
                dimensions(vessel, b.get("Dimension"));
            }
        }
        _ => {}
    }
}

fn static_fields(vessel: &mut Vessel, body: &Value) {
    if let Some(name) = body.get("Name").and_then(text) {
        vessel.name = Some(name);
    }
    if let Some(call) = body.get("CallSign").and_then(text) {
        vessel.call_sign = Some(call);
    }
    if let Some(destination) = body.get("Destination").and_then(text) {
        vessel.destination = Some(destination);
    }
    if let Some(t) = body.get("Type").and_then(Value::as_u64).filter(|&t| t > 0) {
        vessel.ship_type = Some(t as u32);
    }
    dimensions(vessel, body.get("Dimension"));
}

fn dimensions(vessel: &mut Vessel, dimension: Option<&Value>) {
    let Some(d) = dimension else { return };
    let get = |k: &str| d.get(k).and_then(Value::as_f64).unwrap_or(0.0);
    let (length, beam) = (get("A") + get("B"), get("C") + get("D"));
    if length > 0.0 {
        vessel.length = Some(length);
    }
    if beam > 0.0 {
        vessel.beam = Some(beam);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn merges_position_and_static_data() {
        let ais = Ais { enabled: true, ..Default::default() };
        ais.ingest(&json!({
            "MessageType": "PositionReport",
            "MetaData": {"MMSI": 238123456, "ShipName": "JADROLINIJA   @@"},
            "Message": {"PositionReport": {"Latitude": 45.33, "Longitude": 14.42, "Sog": 12.5, "Cog": 210.0,
                                            "TrueHeading": 511, "NavigationalStatus": 0, "UserID": 238123456}}
        }))
        .await;
        ais.ingest(&json!({
            "MessageType": "ShipStaticData",
            "MetaData": {"MMSI": 238123456},
            "Message": {"ShipStaticData": {"Name": "MARKO POLO", "Type": 60, "Destination": "SPLIT",
                                            "Dimension": {"A": 100, "B": 30, "C": 10, "D": 12}}}
        }))
        .await;
        let found = ais.query(14.0, 45.0, 15.0, 46.0, 600).await;
        assert_eq!(found.len(), 1);
        let v = &found[0];
        assert_eq!(v.name.as_deref(), Some("MARKO POLO"));
        assert_eq!(v.heading, None);
        assert_eq!(v.length, Some(130.0));
        assert_eq!(v.ship_type, Some(60));
        assert!(ais.query(15.0, 45.0, 16.0, 46.0, 600).await.is_empty());
    }
}
