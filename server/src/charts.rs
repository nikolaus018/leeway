//! Offline chart packs (built by `tools/build_region.py`) for the app to download, so charts can be
//! updated or added without an app release.

use std::path::Path;

use serde::{Deserialize, Serialize};

#[derive(Serialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct ChartPack {
    pub id: String,
    pub name: String,
    pub west: f64,
    pub south: f64,
    pub east: f64,
    pub north: f64,
    /// Content hash of the pack's files; the app re-downloads when it changes.
    pub version: String,
    /// Total download size in bytes.
    pub size: u64,
    /// File names, relative to `/v1/charts/`.
    pub files: Vec<String>,
    pub attribution: String,
}

#[derive(Deserialize)]
struct Meta {
    id: String,
    name: String,
    west: f64,
    south: f64,
    east: f64,
    north: f64,
    #[serde(default)]
    attribution: String,
}

/// Every complete pack in `dir`: a `.json` with its `.depth` grid (the `.land` coastline is optional).
pub fn list(dir: &Path) -> Vec<ChartPack> {
    let Ok(entries) = std::fs::read_dir(dir) else { return Vec::new() };
    let mut packs: Vec<ChartPack> = entries
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == "json"))
        .filter_map(|json| {
            let meta: Meta = serde_json::from_slice(&std::fs::read(&json).ok()?).ok()?;
            let stem = json.file_stem()?.to_str()?.to_string();
            let mut files = Vec::new();
            let (mut size, mut hash) = (0u64, FNV_OFFSET);
            for ext in ["json", "depth", "land"] {
                let Ok(data) = std::fs::read(dir.join(format!("{stem}.{ext}"))) else { continue };
                size += data.len() as u64;
                hash = fnv1a(hash, &data);
                files.push(format!("{stem}.{ext}"));
            }
            let version = format!("{hash:016x}");
            files.iter().any(|f| f.ends_with(".depth")).then_some(ChartPack {
                id: meta.id,
                name: meta.name,
                west: meta.west,
                south: meta.south,
                east: meta.east,
                north: meta.north,
                version,
                size,
                files,
                attribution: meta.attribution,
            })
        })
        .collect();
    packs.sort_by(|a, b| a.id.cmp(&b.id));
    packs
}

const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;

/// FNV-1a: stable across builds, unlike `std`'s hasher, so redeploying doesn't trigger downloads.
fn fnv1a(mut hash: u64, data: &[u8]) -> u64 {
    for &byte in data {
        hash ^= byte as u64;
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lists_complete_packs_only() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join("kvarner.json"),
            r#"{"id":"kvarner","name":"Kvarner","west":14,"south":44.5,"east":15,"north":45.5,"seamarks":[]}"#,
        )
        .unwrap();
        std::fs::write(dir.path().join("kvarner.depth"), [0u8; 10]).unwrap();
        std::fs::write(
            dir.path().join("broken.json"),
            r#"{"id":"broken","name":"B","west":0,"south":0,"east":1,"north":1}"#,
        )
        .unwrap();
        let packs = list(dir.path());
        assert_eq!(packs.len(), 1);
        assert_eq!(packs[0].files, vec!["kvarner.json", "kvarner.depth"]);
        assert!(packs[0].size > 10);
    }
}
