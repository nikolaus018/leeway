//! Offline chart packs (built by `tools/build_region.py`) for the app to download, so charts can be
//! updated or added without an app release.

use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::Mutex,
    time::SystemTime,
};

use serde::{Deserialize, Serialize};

use crate::http::{fnv1a, FNV_OFFSET};

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

/// Pack files, in download order. The `.pmtiles` vector chart is optional (newer packs).
const EXTENSIONS: [&str; 4] = ["json", "depth", "land", "pmtiles"];

/// Content hash of a file, remembered by size and modification time so big packs aren't re-read
/// on every listing.
fn file_hash(path: &Path) -> Option<(u64, u64)> {
    /// Path → (size, modified, hash).
    type Known = HashMap<PathBuf, (u64, SystemTime, u64)>;
    static HASHES: Mutex<Option<Known>> = Mutex::new(None);
    let meta = std::fs::metadata(path).ok()?;
    let (size, modified) = (meta.len(), meta.modified().ok()?);
    if let Ok(mut guard) = HASHES.lock() {
        if let Some(&(s, m, h)) = guard.get_or_insert_with(HashMap::new).get(path) {
            if s == size && m == modified {
                return Some((size, h));
            }
        }
    }
    let hash = fnv1a(FNV_OFFSET, &std::fs::read(path).ok()?);
    if let Ok(mut guard) = HASHES.lock() {
        guard.get_or_insert_with(HashMap::new).insert(path.to_path_buf(), (size, modified, hash));
    }
    Some((size, hash))
}

/// Every complete pack in `dir`: a `.json` with its `.depth` grid (the `.land` coastline and the
/// `.pmtiles` vector chart are optional).
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
            for ext in EXTENSIONS {
                let Some((bytes, file_hash)) = file_hash(&dir.join(format!("{stem}.{ext}"))) else { continue };
                size += bytes;
                hash = fnv1a(hash, &file_hash.to_le_bytes());
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
        std::fs::write(dir.path().join("kvarner.pmtiles"), [1u8; 10]).unwrap();
        std::fs::write(
            dir.path().join("broken.json"),
            r#"{"id":"broken","name":"B","west":0,"south":0,"east":1,"north":1}"#,
        )
        .unwrap();
        let packs = list(dir.path());
        assert_eq!(packs.len(), 1);
        assert_eq!(packs[0].files, vec!["kvarner.json", "kvarner.depth", "kvarner.pmtiles"]);
        assert!(packs[0].size > 20);
        let version = packs[0].version.clone();
        assert_eq!(list(dir.path())[0].version, version, "stable");
        std::fs::write(dir.path().join("kvarner.pmtiles"), [2u8; 11]).unwrap();
        assert_ne!(list(dir.path())[0].version, version, "changes with content");
    }
}
