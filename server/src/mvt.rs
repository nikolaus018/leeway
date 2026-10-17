//! Mapbox Vector Tile (v2) encoding, plus just enough decoding to read polygons back (the base map's
//! water, for clipping bathymetry to the coastline). Hand-written protobuf: the format is small.

use std::collections::HashMap;

pub const EXTENT: u32 = 4096;

/// A ring of tile coordinates.
pub type Ring = Vec<(i32, i32)>;
/// An exterior ring followed by its holes.
pub type Polygon = Vec<Ring>;

pub enum Geometry {
    /// Polygons in tile coordinates, each its exterior ring followed by its holes; any winding
    /// (fixed on encode).
    Polygons(Vec<Polygon>),
    Lines(Vec<Ring>),
}

pub struct Layer {
    name: String,
    keys: Vec<String>,
    key_index: HashMap<String, u32>,
    values: Vec<f64>,
    value_index: HashMap<u64, u32>,
    features: Vec<Vec<u8>>,
}

impl Layer {
    pub fn new(name: &str) -> Self {
        Layer {
            name: name.into(),
            keys: Vec::new(),
            key_index: HashMap::new(),
            values: Vec::new(),
            value_index: HashMap::new(),
            features: Vec::new(),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.features.is_empty()
    }

    /// Adds a feature with numeric properties; degenerate geometry is skipped.
    pub fn add(&mut self, geometry: &Geometry, properties: &[(&str, f64)]) {
        let (kind, commands) = match geometry {
            Geometry::Polygons(polygons) => (3, polygon_commands(polygons)),
            Geometry::Lines(lines) => (2, line_commands(lines)),
        };
        if commands.is_empty() {
            return;
        }
        let mut tags = Vec::with_capacity(properties.len() * 2);
        for &(key, value) in properties {
            let k = match self.key_index.get(key) {
                Some(&k) => k,
                None => {
                    let k = self.keys.len() as u32;
                    self.keys.push(key.into());
                    self.key_index.insert(key.into(), k);
                    k
                }
            };
            let v = match self.value_index.get(&value.to_bits()) {
                Some(&v) => v,
                None => {
                    let v = self.values.len() as u32;
                    self.values.push(value);
                    self.value_index.insert(value.to_bits(), v);
                    v
                }
            };
            tags.extend([k, v]);
        }
        let mut feature = Vec::new();
        packed(&mut feature, 2, &tags);
        varint_field(&mut feature, 3, kind);
        packed(&mut feature, 4, &commands);
        self.features.push(feature);
    }

    fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        varint_field(&mut out, 15, 2);
        bytes_field(&mut out, 1, self.name.as_bytes());
        for feature in &self.features {
            bytes_field(&mut out, 2, feature);
        }
        for key in &self.keys {
            bytes_field(&mut out, 3, key.as_bytes());
        }
        for value in &self.values {
            let mut v = Vec::with_capacity(9);
            key(&mut v, 3, 1);
            v.extend_from_slice(&value.to_le_bytes());
            bytes_field(&mut out, 4, &v);
        }
        varint_field(&mut out, 5, EXTENT as u64);
        out
    }
}

/// The tile's bytes; layers without features are left out.
pub fn encode(layers: &[Layer]) -> Vec<u8> {
    let mut out = Vec::new();
    for layer in layers.iter().filter(|l| !l.is_empty()) {
        bytes_field(&mut out, 3, &layer.encode());
    }
    out
}

fn command(id: u32, count: u32) -> u32 {
    (id & 7) | (count << 3)
}

fn zigzag(v: i32) -> u32 {
    ((v << 1) ^ (v >> 31)) as u32
}

fn unzigzag(v: u32) -> i32 {
    ((v >> 1) as i32) ^ -((v & 1) as i32)
}

/// Twice the signed area, y pointing down (positive = clockwise on screen).
fn area2(ring: &[(i32, i32)]) -> i64 {
    let n = ring.len();
    (0..n)
        .map(|i| {
            let (a, b) = (ring[i], ring[(i + 1) % n]);
            a.0 as i64 * b.1 as i64 - b.0 as i64 * a.1 as i64
        })
        .sum()
}

/// Consecutive duplicates and the closing point removed.
fn clean(ring: &[(i32, i32)]) -> Vec<(i32, i32)> {
    let mut out: Vec<(i32, i32)> = Vec::with_capacity(ring.len());
    for &p in ring {
        if out.last() != Some(&p) {
            out.push(p);
        }
    }
    while out.len() > 1 && out.first() == out.last() {
        out.pop();
    }
    out
}

fn polygon_commands(polygons: &[Polygon]) -> Vec<u32> {
    // MVT wants exterior rings clockwise (y down) and holes anticlockwise.
    let mut out = Vec::new();
    let mut cursor = (0, 0);
    for polygon in polygons {
        for (i, ring) in polygon.iter().enumerate() {
            let mut ring = clean(ring);
            if ring.len() < 3 || area2(&ring) == 0 {
                if i == 0 {
                    break; // no exterior, so its holes mean nothing
                }
                continue;
            }
            if (area2(&ring) > 0) != (i == 0) {
                ring.reverse();
            }
            out.push(command(1, 1));
            out.extend([zigzag(ring[0].0 - cursor.0), zigzag(ring[0].1 - cursor.1)]);
            cursor = ring[0];
            out.push(command(2, (ring.len() - 1) as u32));
            for &p in &ring[1..] {
                out.extend([zigzag(p.0 - cursor.0), zigzag(p.1 - cursor.1)]);
                cursor = p;
            }
            out.push(command(7, 1));
        }
    }
    out
}

fn line_commands(lines: &[Ring]) -> Vec<u32> {
    let mut out = Vec::new();
    let mut cursor = (0, 0);
    for line in lines {
        let mut points: Vec<(i32, i32)> = Vec::with_capacity(line.len());
        for &p in line {
            if points.last() != Some(&p) {
                points.push(p);
            }
        }
        if points.len() < 2 {
            continue;
        }
        out.push(command(1, 1));
        out.extend([zigzag(points[0].0 - cursor.0), zigzag(points[0].1 - cursor.1)]);
        cursor = points[0];
        out.push(command(2, (points.len() - 1) as u32));
        for &p in &points[1..] {
            out.extend([zigzag(p.0 - cursor.0), zigzag(p.1 - cursor.1)]);
            cursor = p;
        }
    }
    out
}

// MARK: Protobuf

fn varint(out: &mut Vec<u8>, mut v: u64) {
    while v >= 0x80 {
        out.push((v as u8) | 0x80);
        v >>= 7;
    }
    out.push(v as u8);
}

fn key(out: &mut Vec<u8>, field: u32, wire: u32) {
    varint(out, ((field << 3) | wire) as u64);
}

fn varint_field(out: &mut Vec<u8>, field: u32, v: u64) {
    key(out, field, 0);
    varint(out, v);
}

fn bytes_field(out: &mut Vec<u8>, field: u32, data: &[u8]) {
    key(out, field, 2);
    varint(out, data.len() as u64);
    out.extend_from_slice(data);
}

fn packed(out: &mut Vec<u8>, field: u32, values: &[u32]) {
    if values.is_empty() {
        return;
    }
    let mut body = Vec::with_capacity(values.len() * 2);
    for &v in values {
        varint(&mut body, v as u64);
    }
    bytes_field(out, field, &body);
}

struct Reader<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn varint(&mut self) -> Option<u64> {
        let mut v = 0u64;
        for shift in (0..64).step_by(7) {
            let byte = *self.data.get(self.pos)?;
            self.pos += 1;
            v |= ((byte & 0x7f) as u64) << shift;
            if byte < 0x80 {
                return Some(v);
            }
        }
        None
    }

    /// (field, wire type, payload for length-delimited, value for varints)
    fn next(&mut self) -> Option<(u32, &'a [u8], u64)> {
        if self.pos >= self.data.len() {
            return None;
        }
        let k = self.varint()?;
        let (field, wire) = ((k >> 3) as u32, (k & 7) as u32);
        match wire {
            0 => Some((field, &[], self.varint()?)),
            1 => {
                self.pos += 8;
                Some((field, &[], 0))
            }
            2 => {
                let len = self.varint()? as usize;
                let start = self.pos;
                self.pos = start.checked_add(len).filter(|&e| e <= self.data.len())?;
                Some((field, &self.data[start..self.pos], 0))
            }
            5 => {
                self.pos += 4;
                Some((field, &[], 0))
            }
            _ => None,
        }
    }
}

/// Polygons of one layer, as rings in that layer's extent, and the extent.
pub fn polygons(tile: &[u8], layer_name: &str) -> (Vec<Polygon>, u32) {
    let mut found = Vec::new();
    let mut extent = EXTENT;
    let mut tile_reader = Reader { data: tile, pos: 0 };
    while let Some((field, layer, _)) = tile_reader.next() {
        if field != 3 {
            continue;
        }
        let mut name = "";
        let mut features: Vec<&[u8]> = Vec::new();
        let mut r = Reader { data: layer, pos: 0 };
        while let Some((f, payload, value)) = r.next() {
            match f {
                1 => name = std::str::from_utf8(payload).unwrap_or(""),
                2 => features.push(payload),
                5 => extent = value as u32,
                _ => {}
            }
        }
        if name != layer_name {
            continue;
        }
        for feature in features {
            let mut kind = 0;
            let mut geometry: Vec<u32> = Vec::new();
            let mut r = Reader { data: feature, pos: 0 };
            while let Some((f, payload, value)) = r.next() {
                match f {
                    3 => kind = value,
                    4 => {
                        let mut g = Reader { data: payload, pos: 0 };
                        while let Some(v) = g.varint() {
                            geometry.push(v as u32);
                        }
                    }
                    _ => {}
                }
            }
            if kind == 3 {
                found.push(decode_rings(&geometry));
            }
        }
    }
    (found, extent)
}

fn decode_rings(commands: &[u32]) -> Polygon {
    let mut rings = Vec::new();
    let mut ring: Vec<(i32, i32)> = Vec::new();
    let (mut x, mut y) = (0i32, 0i32);
    let mut i = 0;
    while i < commands.len() {
        let (id, count) = (commands[i] & 7, commands[i] >> 3);
        i += 1;
        match id {
            1 | 2 => {
                for _ in 0..count {
                    if i + 1 >= commands.len() {
                        return rings;
                    }
                    x += unzigzag(commands[i]);
                    y += unzigzag(commands[i + 1]);
                    i += 2;
                    if id == 1 && !ring.is_empty() {
                        rings.push(std::mem::take(&mut ring));
                    }
                    ring.push((x, y));
                }
            }
            7 => {
                if !ring.is_empty() {
                    rings.push(std::mem::take(&mut ring));
                }
            }
            _ => return rings,
        }
    }
    if !ring.is_empty() {
        rings.push(ring);
    }
    rings
}

/// Even-odd fill of polygons into an `n`×`n` mask sampled at cell centres.
pub fn rasterize(polygons: &[Polygon], extent: u32, n: usize) -> Vec<bool> {
    let mut mask = vec![false; n * n];
    let scale = extent as f64 / n as f64;
    for rings in polygons {
        let mut inside = vec![false; n * n];
        for row in 0..n {
            let y = (row as f64 + 0.5) * scale;
            let mut crossings: Vec<f64> = Vec::new();
            for ring in rings {
                let m = ring.len();
                for i in 0..m {
                    let (a, b) = (ring[i], ring[(i + 1) % m]);
                    let (ay, by) = (a.1 as f64, b.1 as f64);
                    if (ay > y) != (by > y) {
                        crossings.push(a.0 as f64 + (y - ay) / (by - ay) * (b.0 as f64 - a.0 as f64));
                    }
                }
            }
            crossings.sort_by(|a, b| a.total_cmp(b));
            for pair in crossings.chunks(2) {
                let [x0, x1] = pair else { continue };
                let c0 = ((x0 / scale) - 0.5).ceil().max(0.0) as usize;
                let c1 = ((x1 / scale) - 0.5).floor().min(n as f64 - 1.0);
                if c1 < 0.0 {
                    continue;
                }
                for c in c0..=(c1 as usize) {
                    inside[row * n + c] ^= true;
                }
            }
        }
        for (m, i) in mask.iter_mut().zip(inside) {
            *m |= i;
        }
    }
    mask
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_polygons_and_rasterizes() {
        let square = vec![(0, 0), (2048, 0), (2048, 2048), (0, 2048)];
        let hole = vec![(512, 512), (1024, 512), (1024, 1024), (512, 1024)];
        let mut water = Layer::new("water");
        water.add(&Geometry::Polygons(vec![vec![square, hole]]), &[("min", 2.0)]);
        let mut other = Layer::new("depcnt");
        other.add(&Geometry::Lines(vec![vec![(0, 0), (100, 100)]]), &[("depth", 5.0)]);
        let tile = encode(&[water, other, Layer::new("empty")]);

        let (polys, extent) = polygons(&tile, "water");
        assert_eq!(extent, 4096);
        assert_eq!(polys.len(), 1);
        assert_eq!(polys[0].len(), 2);
        assert!(area2(&polys[0][0]) > 0, "exterior clockwise");
        assert!(area2(&polys[0][1]) < 0, "hole anticlockwise");

        let mask = rasterize(&polys, extent, 8);
        assert!(mask[0], "top-left inside");
        assert!(!mask[8 + 1], "cell (1, 1) sits in the hole");
        assert!(mask[2 * 8 + 1], "cell (2, 1) is below it");
        assert!(!mask[7], "right half outside");
        assert!(!mask[7 * 8], "bottom half outside");
    }
}
