//! Worldwide depth areas and contours as vector tiles, so the chart looks the same everywhere, not
//! only inside the detailed chart packs. Elevation comes from the AWS Terrain Tiles (Terrarium
//! encoding, bathymetry from GEBCO/ETOPO and others); water is clipped to the base map's coastline
//! so the coarse elevation never paints depth onto land.
//!
//! Layers match the chart packs: `depare` polygons with `min`/`max` metres and `depcnt` lines with
//! `depth`, so one style draws both.

use std::sync::Arc;

use anyhow::{anyhow, Context, Result};
use contour::ContourBuilder;
use futures_util::future::join_all;

use crate::{
    basemap::BaseMap,
    cache::{Blob, TileCache},
    config::Config,
    mvt,
};

pub const MAX_ZOOM: u32 = 12;
/// Depth band limits in metres; the last band is open-ended.
pub const BANDS: [f64; 12] = [0.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 200.0, 500.0, 1000.0, 2000.0, 12000.0];
pub const CONTOURS: [f64; 10] = [2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 200.0, 500.0, 1000.0, 2000.0];
/// Elevation tiles are 256 px square.
const N: usize = 256;
/// Below any depth, so land never falls into a band.
const LAND: f64 = -2.0;

pub struct Bathy {
    http: reqwest::Client,
    config: Arc<Config>,
    terrain: Arc<TileCache>,
    tiles: Arc<TileCache>,
    base: Arc<BaseMap>,
}

/// Elevation in metres, row-major, row 0 north.
type Elevation = Vec<f32>;

impl Bathy {
    pub fn new(http: reqwest::Client, config: Arc<Config>, base: Arc<BaseMap>) -> Self {
        let year = std::time::Duration::from_secs(365 * 86400);
        Bathy {
            terrain: Arc::new(TileCache::new("terrain", &config.cache_dir, year, 64)),
            tiles: Arc::new(TileCache::new("bathy", &config.cache_dir, year, 64)),
            http,
            config,
            base,
        }
    }

    pub fn caches(&self) -> [&Arc<TileCache>; 2] {
        [&self.terrain, &self.tiles]
    }

    pub async fn tile(&self, z: u32, x: u32, y: u32) -> Result<Arc<Blob>> {
        if z > MAX_ZOOM || x >= 1 << z || y >= 1 << z {
            return Err(anyhow!("no such tile {z}/{x}/{y}"));
        }
        // The version in the key lets a change in how tiles are built replace old ones.
        self.tiles.get(&format!("v1/{z}/{x}/{y}.pbf"), || self.render(z, x, y)).await
    }

    async fn render(&self, z: u32, x: u32, y: u32) -> Result<Option<Vec<u8>>> {
        let n = 1i64 << z;
        // The tile and its eight neighbours, so edges line up with the tiles next door.
        let neighbours = (-1i64..=1).flat_map(|dy| (-1i64..=1).map(move |dx| (dx, dy))).map(|(dx, dy)| {
            let ty = y as i64 + dy;
            let tx = (x as i64 + dx).rem_euclid(n);
            async move {
                if ty < 0 || ty >= n {
                    return None;
                }
                self.elevation(z, tx as u32, ty as u32).await.ok().flatten()
            }
        });
        let grids: Vec<Option<Elevation>> = join_all(neighbours).await;
        if grids[4].is_none() {
            return Err(anyhow!("no elevation for {z}/{x}/{y}"));
        }
        // The base map's water for all nine, so both tiles at a seam see the same coastline.
        let masks = (-1i64..=1).flat_map(|dy| (-1i64..=1).map(move |dx| (dx, dy))).map(|(dx, dy)| {
            let ty = y as i64 + dy;
            let tx = (x as i64 + dx).rem_euclid(n);
            async move {
                if ty < 0 || ty >= n {
                    return None;
                }
                self.base.water_mask(z, tx as u32, ty as u32, N).await.ok().flatten()
            }
        });
        let masks: Vec<Option<Vec<bool>>> = join_all(masks).await;
        tokio::task::spawn_blocking(move || build(&grids, &masks)).await?
    }

    async fn elevation(&self, z: u32, x: u32, y: u32) -> Result<Option<Elevation>> {
        let url = self
            .config
            .terrain_url
            .replace("{z}", &z.to_string())
            .replace("{x}", &x.to_string())
            .replace("{y}", &y.to_string());
        let http = self.http.clone();
        let blob = self
            .terrain
            .get(&format!("{z}/{x}/{y}.png"), || async move {
                let response = http.get(&url).send().await?;
                match response.status().as_u16() {
                    200 => Ok(Some(response.bytes().await?.to_vec())),
                    403 | 404 => Ok(None),
                    status => Err(anyhow!("{url} answered {status}")),
                }
            })
            .await?;
        if blob.is_empty() {
            return Ok(None);
        }
        decode_terrarium(&blob.data).map(Some)
    }
}

/// Terrarium: elevation = R·256 + G + B/256 − 32768.
pub fn decode_terrarium(png_data: &[u8]) -> Result<Elevation> {
    let mut decoder = png::Decoder::new(std::io::Cursor::new(png_data));
    decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut reader = decoder.read_info().context("terrain png")?;
    let mut buffer = vec![0; reader.output_buffer_size().ok_or_else(|| anyhow!("terrain png too large"))?];
    let info = reader.next_frame(&mut buffer).context("terrain png")?;
    let channels = info.color_type.samples();
    if info.width as usize != N || info.height as usize != N || channels < 3 {
        return Err(anyhow!("unexpected terrain tile {}×{} with {channels} channels", info.width, info.height));
    }
    Ok((0..N * N)
        .map(|i| {
            let p = &buffer[i * channels..];
            p[0] as f32 * 256.0 + p[1] as f32 + p[2] as f32 / 256.0 - 32768.0
        })
        .collect())
}

/// Depth (positive) or `LAND` at pixel (`px`, `py`) of the centre tile; −1 and N reach into neighbours.
/// `masks` are the base map's water per tile, where known.
fn depth_at(grids: &[Option<Elevation>], masks: &[Option<Vec<bool>>], px: i64, py: i64) -> f64 {
    let n = N as i64;
    let (gx, lx) = if px < 0 { (0, px + n) } else if px >= n { (2, px - n) } else { (1, px) };
    let (gy, ly) = if py < 0 { (0, py + n) } else if py >= n { (2, py - n) } else { (1, py) };
    let index = (gy * 3 + gx) as usize;
    let (index, lx, ly) = match &grids[index] {
        Some(_) => (index, lx, ly),
        // Off the edge of the world or missing: repeat the centre tile's edge.
        None => (4, px.clamp(0, n - 1), py.clamp(0, n - 1)),
    };
    let grid = grids[index].as_ref().expect("centre tile");
    let elevation = grid[(ly * n + lx) as usize] as f64;
    match masks.get(index).and_then(Option::as_ref) {
        Some(mask) if mask[(ly * n + lx) as usize] => (-elevation).max(0.0),
        Some(_) => LAND,
        None if elevation < 0.0 => -elevation,
        None => LAND,
    }
}

/// The vector tile for the centre of a 3×3 block of elevation tiles, or `None` if it's all land.
fn build(grids: &[Option<Elevation>], masks: &[Option<Vec<bool>>]) -> Result<Option<Vec<u8>>> {
    // Values at pixel corners (0…N), averaged from the four pixels around each corner, so both tiles
    // at a seam compute the same edge.
    let size = N + 1;
    let mut values = vec![LAND; size * size];
    let mut any_water = false;
    for j in 0..size {
        for i in 0..size {
            let (i, j) = (i as i64, j as i64);
            let sum = depth_at(grids, masks, i - 1, j - 1)
                + depth_at(grids, masks, i, j - 1)
                + depth_at(grids, masks, i - 1, j)
                + depth_at(grids, masks, i, j);
            let v = sum / 4.0;
            any_water |= v >= 0.0;
            values[j as usize * size + i as usize] = v;
        }
    }
    if !any_water {
        return Ok(None);
    }

    let scale = mvt::EXTENT as f64 / N as f64;
    // The crate puts value i at i + 0.5; shift so corner i lands on i·scale.
    let builder = ContourBuilder::new(size, size, true)
        .x_step(scale)
        .y_step(scale)
        .x_origin(-scale / 2.0)
        .y_origin(-scale / 2.0);
    let mut areas = mvt::Layer::new("depare");
    for band in builder.isobands(&values, &BANDS).map_err(|e| anyhow!("isobands: {e:?}"))? {
        let polygons: Vec<mvt::Polygon> = band
            .geometry()
            .0
            .iter()
            .map(|polygon| {
                std::iter::once(polygon.exterior())
                    .chain(polygon.interiors())
                    .map(|ring| simplify(&ring.0.iter().map(|c| (c.x, c.y)).collect::<Vec<_>>(), 8.0))
                    .collect()
            })
            .collect();
        areas.add(&mvt::Geometry::Polygons(polygons), &[("min", band.min_v()), ("max", band.max_v())]);
    }
    let mut contours = mvt::Layer::new("depcnt");
    for line in builder.lines(&values, &CONTOURS).map_err(|e| anyhow!("contours: {e:?}"))? {
        let lines: Vec<mvt::Ring> = line
            .geometry()
            .0
            .iter()
            .map(|l| simplify(&l.0.iter().map(|c| (c.x, c.y)).collect::<Vec<_>>(), 6.0))
            .filter(|l| l.len() >= 2)
            .collect();
        contours.add(&mvt::Geometry::Lines(lines), &[("depth", line.threshold())]);
    }
    Ok(Some(mvt::encode(&[areas, contours])))
}

/// Douglas–Peucker, rounded to tile units.
fn simplify(points: &[(f64, f64)], tolerance: f64) -> Vec<(i32, i32)> {
    if points.len() < 3 {
        return points.iter().map(|p| (p.0.round() as i32, p.1.round() as i32)).collect();
    }
    let mut keep = vec![false; points.len()];
    keep[0] = true;
    keep[points.len() - 1] = true;
    let mut stack = vec![(0, points.len() - 1)];
    while let Some((a, b)) = stack.pop() {
        let (pa, pb) = (points[a], points[b]);
        let (dx, dy) = (pb.0 - pa.0, pb.1 - pa.1);
        let length = (dx * dx + dy * dy).sqrt();
        let mut worst = (0.0, a);
        for (i, p) in points.iter().enumerate().take(b).skip(a + 1) {
            let d = if length == 0.0 {
                ((p.0 - pa.0).powi(2) + (p.1 - pa.1).powi(2)).sqrt()
            } else {
                ((p.0 - pa.0) * dy - (p.1 - pa.1) * dx).abs() / length
            };
            if d > worst.0 {
                worst = (d, i);
            }
        }
        if worst.0 > tolerance {
            keep[worst.1] = true;
            stack.push((a, worst.1));
            stack.push((worst.1, b));
        }
    }
    points.iter().zip(keep).filter(|(_, k)| *k).map(|(p, _)| (p.0.round() as i32, p.1.round() as i32)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A sloping seabed: land in the west, 0 m at x = 64, 3000 m deep in the east.
    fn slope() -> Elevation {
        (0..N * N).map(|i| (64.0 - (i % N) as f32) * 15.0).collect()
    }

    /// The tile alone, its edges repeated outwards.
    fn alone(centre: Elevation) -> Vec<Option<Elevation>> {
        (0..9).map(|i| (i == 4).then(|| centre.clone())).collect()
    }

    #[test]
    fn builds_bands_and_contours() {
        let tile = build(&alone(slope()), &[]).unwrap().expect("there is water");
        let (areas, extent) = mvt::polygons(&tile, "depare");
        assert_eq!(extent, 4096);
        assert!(areas.len() >= 8, "{} bands", areas.len());
        // Land stays out: nothing west of the shoreline at x ≈ 64 px = 1024 units.
        let westmost = areas.iter().flatten().flatten().map(|p| p.0).min().unwrap();
        assert!((990..1060).contains(&westmost), "westmost {westmost}");

        assert!(build(&alone(vec![10.0; N * N]), &[]).unwrap().is_none());
        assert!(mvt::polygons(&tile, "depcnt").0.is_empty(), "contours are lines, not polygons");
    }

    #[test]
    fn coastline_mask_keeps_depth_off_land() {
        // The base map says the east half is land after all.
        let mask: Vec<bool> = (0..N * N).map(|i| i % N < 128).collect();
        let masks: Vec<Option<Vec<bool>>> = (0..9).map(|i| (i == 4).then(|| mask.clone())).collect();
        let tile = build(&alone(slope()), &masks).unwrap().unwrap();
        let (areas, extent) = mvt::polygons(&tile, "depare");
        let eastmost = areas.iter().flatten().flatten().map(|p| p.0).max().unwrap();
        assert!(eastmost <= 128 * 16 + 24, "eastmost {eastmost}");
        let covered = mvt::rasterize(&areas, extent, 8);
        assert!(covered[8 * 4 + 2] && !covered[8 * 4 + 6]);
    }

    #[test]
    fn decodes_terrarium() {
        let mut png_data = Vec::new();
        {
            let mut encoder = png::Encoder::new(&mut png_data, N as u32, N as u32);
            encoder.set_color(png::ColorType::Rgb);
            let mut writer = encoder.write_header().unwrap();
            // 127·256 + 246 + 0 − 32768 = −10 m everywhere.
            writer.write_image_data(&[127, 246, 0].repeat(N * N)).unwrap();
        }
        let elevation = decode_terrarium(&png_data).unwrap();
        assert_eq!(elevation.len(), N * N);
        assert!((elevation[0] + 10.0).abs() < 1e-3);
    }
}

