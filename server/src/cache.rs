//! A shared cache for anything fetched or rendered by key (map tiles, glyphs, elevation): hot entries
//! in memory, everything on disk, one upstream request per key however many users ask at once, and
//! stale copies served when the upstream is down. The disk is kept under a size cap, oldest first.

use std::{
    future::Future,
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, SystemTime},
};

use anyhow::{anyhow, Result};
use bytes::Bytes;
use moka::future::Cache;

use crate::{http, metrics};

/// A cached body; empty means "nothing here" (an empty tile), which is cached too.
#[derive(Debug)]
pub struct Blob {
    pub data: Bytes,
    pub etag: String,
}

impl Blob {
    fn new(data: Vec<u8>) -> Self {
        let etag = http::etag(&data);
        Blob { data: Bytes::from(data), etag }
    }

    pub fn is_empty(&self) -> bool {
        self.data.is_empty()
    }
}

pub struct TileCache {
    name: &'static str,
    dir: PathBuf,
    fresh: Duration,
    memory: Cache<String, Arc<Blob>>,
}

impl TileCache {
    /// `fresh`: how long a stored copy is used before asking upstream again. `memory_mb`: hot set size.
    pub fn new(name: &'static str, root: &Path, fresh: Duration, memory_mb: u64) -> Self {
        TileCache {
            name,
            dir: root.join(name),
            fresh,
            memory: Cache::builder()
                .weigher(|key: &String, blob: &Arc<Blob>| (key.len() + blob.data.len() + 64).try_into().unwrap_or(u32::MAX))
                .max_capacity(memory_mb * 1024 * 1024)
                .time_to_live(fresh.min(Duration::from_secs(3600)))
                .build(),
        }
    }

    /// The blob for `key` (a relative path such as `12/2201/1456.pbf`), from memory, disk, or `fetch`.
    /// `fetch` returns `None` for "nothing here". Concurrent callers for one key share one fetch.
    pub async fn get<F, Fut>(&self, key: &str, fetch: F) -> Result<Arc<Blob>>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<Option<Vec<u8>>>>,
    {
        metrics::inc("seadata_cache_requests_total", &[("cache", self.name)]);
        let path = self.dir.join(key);
        self.memory
            .try_get_with(key.to_string(), async move {
                if let Some(blob) = self.read(&path, true).await {
                    metrics::inc("seadata_cache_disk_hits_total", &[("cache", self.name)]);
                    return Ok(Arc::new(blob));
                }
                metrics::inc("seadata_cache_misses_total", &[("cache", self.name)]);
                match metrics::upstream(self.name, fetch()).await {
                    Ok(data) => {
                        let data = data.unwrap_or_default();
                        write(&path, &data).await;
                        Ok(Arc::new(Blob::new(data)))
                    }
                    // Upstream down: a stale copy beats nothing.
                    Err(error) => match self.read(&path, false).await {
                        Some(blob) => {
                            metrics::inc("seadata_cache_stale_served_total", &[("cache", self.name)]);
                            Ok(Arc::new(blob))
                        }
                        None => Err(error),
                    },
                }
            })
            .await
            .map_err(|error: Arc<anyhow::Error>| anyhow!("{}: {error:#}", self.name))
    }

    async fn read(&self, path: &Path, fresh_only: bool) -> Option<Blob> {
        let meta = tokio::fs::metadata(path).await.ok()?;
        if fresh_only {
            let age = meta.modified().ok().and_then(|m| SystemTime::now().duration_since(m).ok())?;
            if age > self.fresh {
                return None;
            }
        }
        tokio::fs::read(path).await.ok().map(Blob::new)
    }

    /// Deletes the oldest files whenever the cache grows past `max_bytes`.
    pub fn keep_under(self: &Arc<Self>, max_bytes: u64) {
        let dir = self.dir.clone();
        let name = self.name;
        tokio::spawn(async move {
            loop {
                let dir = dir.clone();
                let removed = tokio::task::spawn_blocking(move || evict(&dir, max_bytes)).await.unwrap_or(0);
                if removed > 0 {
                    tracing::info!("{name} cache: evicted {removed} old files");
                    metrics::add("seadata_cache_evicted_total", &[("cache", name)], removed as u64);
                }
                tokio::time::sleep(Duration::from_secs(1800)).await;
            }
        });
    }
}

/// Write via a temp file so a half-written file is never served.
pub async fn write(path: &Path, data: &[u8]) {
    let Some(dir) = path.parent() else { return };
    if tokio::fs::create_dir_all(dir).await.is_err() {
        return;
    }
    let tmp = path.with_extension(format!("tmp{}", std::process::id()));
    if tokio::fs::write(&tmp, data).await.is_ok() {
        let _ = tokio::fs::rename(&tmp, path).await;
    }
}

/// Removes the oldest files until the tree is at 90 % of `max_bytes`; returns how many went.
fn evict(dir: &Path, max_bytes: u64) -> usize {
    let mut files: Vec<(SystemTime, u64, PathBuf)> = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&d) else { continue };
        for entry in entries.flatten() {
            let Ok(meta) = entry.metadata() else { continue };
            if meta.is_dir() {
                stack.push(entry.path());
            } else {
                files.push((meta.modified().unwrap_or(SystemTime::UNIX_EPOCH), meta.len(), entry.path()));
            }
        }
    }
    let mut total: u64 = files.iter().map(|f| f.1).sum();
    if total <= max_bytes {
        return 0;
    }
    files.sort_by_key(|f| f.0);
    let target = max_bytes / 10 * 9;
    let mut removed = 0;
    for (_, size, path) in files {
        if total <= target {
            break;
        }
        if std::fs::remove_file(&path).is_ok() {
            total = total.saturating_sub(size);
            removed += 1;
        }
    }
    removed
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    #[tokio::test]
    async fn coalesces_caches_and_serves_stale() {
        let root = tempfile::tempdir().unwrap();
        let cache = Arc::new(TileCache::new("test", root.path(), Duration::from_secs(3600), 1));
        let calls = Arc::new(AtomicUsize::new(0));
        let fetch = |calls: Arc<AtomicUsize>| async move {
            calls.fetch_add(1, Ordering::SeqCst);
            tokio::time::sleep(Duration::from_millis(50)).await;
            Ok(Some(b"tile".to_vec()))
        };
        let gets = (0..20).map(|_| {
            let (cache, calls) = (cache.clone(), calls.clone());
            tokio::spawn(async move { cache.get("1/2/3.pbf", || fetch(calls)).await.unwrap() })
        });
        for blob in futures_util::future::join_all(gets).await {
            assert_eq!(&blob.unwrap().data[..], b"tile");
        }
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert!(root.path().join("test/1/2/3.pbf").exists());

        // Expired on disk and upstream down: the stale copy is served.
        let stale = TileCache::new("test", root.path(), Duration::ZERO, 1);
        let blob = stale.get("1/2/3.pbf", || async { Err(anyhow!("down")) }).await.unwrap();
        assert_eq!(&blob.data[..], b"tile");
        assert!(stale.get("9/9/9.pbf", || async { Err(anyhow!("down")) }).await.is_err());
    }

    #[test]
    fn evicts_oldest_first() {
        let root = tempfile::tempdir().unwrap();
        for i in 0..10 {
            std::fs::write(root.path().join(format!("{i}")), [0u8; 100]).unwrap();
            let t = SystemTime::now() - Duration::from_secs(100 - i);
            std::fs::File::options().write(true).open(root.path().join(format!("{i}"))).unwrap().set_modified(t).unwrap();
        }
        assert_eq!(evict(root.path(), 500), 6);
        assert!(!root.path().join("0").exists());
        assert!(root.path().join("9").exists());
    }
}
