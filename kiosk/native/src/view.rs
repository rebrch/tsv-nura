//! Turns Home Assistant entity states into plain display data.
//! Formatting mirrors master-control's web/src/lib/conn.svelte.ts and weather.ts.

use crate::config::{Config, Item};
use serde_json::Value;
use std::collections::{BTreeSet, HashMap, HashSet};

pub type Entities = HashMap<String, Value>;

/// Area and helper info from HA's area/device/entity registries.
#[derive(Debug, Default, Clone)]
pub struct Registry {
    /// entity_id -> area name (entity's own area, else its device's area)
    pub area: HashMap<String, String>,
    /// entities created by the group integration (light group helpers)
    pub helpers: HashSet<String>,
    pub area_names: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Hold {
    None = 0,
    /// 1 s hold opens the brightness control
    Dim = 1,
    /// 2 s hold toggles (plugs)
    Toggle = 2,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Tile {
    pub id: String,
    pub name: String,
    pub value: String,
    pub icon: &'static str,
    pub on: bool,
    pub dead: bool,
    pub tap: bool,
    pub hold: Hold,
    /// 0-100, current brightness (0 when off)
    pub brightness: i32,
    /// compact style (individual bulbs on the Lighting page)
    pub small: bool,
    pub cell: Cell,
}

/// Placement in a Lighting section (pixels from the section top; columns of the 4-column grid).
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Cell {
    pub col: i32,
    pub span: i32,
    pub y: i32,
    pub h: i32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Section {
    pub title: String,
    /// each helper on its own full-width row, then the area's bulbs in compact rows of four
    pub tiles: Vec<Tile>,
    /// total height in pixels
    pub height: i32,
}

pub const LIGHT_COLUMNS: i32 = 4;
const HELPER_H: i32 = 72;
const BULB_H: i32 = 55;
const PLUG_H: i32 = 72;
const GAP: i32 = 8;

/// Lay out a section: helpers full width, bulbs packed four per row.
fn pack(tiles: &mut [Tile]) -> i32 {
    let (mut y, mut col, mut row_h) = (0, 0, 0);
    for t in tiles.iter_mut() {
        // Plugs: two per row. Lights: main tiles full width, bulbs four per row.
        let (span, h) = match (t.hold, t.small) {
            (Hold::Toggle, _) => (2, PLUG_H),
            (_, true) => (1, BULB_H),
            (_, false) => (LIGHT_COLUMNS, HELPER_H),
        };
        if row_h > 0 && (col + span > LIGHT_COLUMNS || h != row_h) {
            y += row_h + GAP;
            col = 0;
        }
        t.cell = Cell { col, span, y, h };
        col += span;
        row_h = h;
    }
    if tiles.is_empty() { 0 } else { y + row_h }
}

#[derive(Debug, Clone, Default)]
pub struct Snapshot {
    pub connected: bool,
    pub weather_temp: String,
    pub weather_cond: String,
    pub weather_icon: &'static str,
    pub home_lights: Vec<Tile>,
    pub climate: Vec<Tile>,
    pub light_sections: Vec<Section>,
    pub plug_sections: Vec<Section>,
}

impl Snapshot {
    pub fn find(&self, id: &str) -> Option<&Tile> {
        self.home_lights
            .iter()
            .chain(self.light_sections.iter().flat_map(|s| &s.tiles))
            .chain(self.plug_sections.iter().flat_map(|s| &s.tiles))
            .find(|t| t.id == id)
    }
}

const WHOLE_HOME: &str = "Whole Home";
const OTHER: &str = "Other";

pub fn build(cfg: &Config, ents: &Entities, reg: &Registry, connected: bool) -> Snapshot {
    let (mut weather_temp, mut weather_cond, mut weather_icon) = (String::new(), String::new(), icon("cloud"));
    if let Some(w) = cfg.home.weather.as_ref().and_then(|id| ents.get(id)).filter(|e| !unavailable(Some(e))) {
        let a = &w["attributes"];
        if let Some(t) = a["temperature"].as_f64() {
            weather_temp = format!("{}{}", t.round(), a["temperature_unit"].as_str().unwrap_or("°"));
        }
        let state = w["state"].as_str().unwrap_or_default();
        weather_cond = weather_label(state);
        if let Some(h) = a["humidity"].as_f64() {
            weather_cond.push_str(&format!(" · {}% humidity", trim_num(h, 0)));
        }
        weather_icon = icon(weather_icon_name(state));
    }

    let home_lights = cfg.home.lights.iter().map(|i| light_tile(ents, reg, &i.entity, i.label.as_deref())).collect();
    let climate = cfg.home.climate.iter().map(|i| sensor_tile(ents, i)).collect();
    // Plugs page: grouped by area like the lights, by name within an area.
    let mut plug_areas: HashMap<String, Vec<Tile>> = HashMap::new();
    for item in &cfg.plugs.entities {
        let area = reg.area.get(&item.entity).cloned().unwrap_or_else(|| OTHER.into());
        plug_areas.entry(area).or_default().push(plug_tile(ents, item));
    }
    let mut plug_sections: Vec<Section> = plug_areas
        .into_iter()
        .map(|(title, mut tiles)| {
            tiles.sort_by_key(|t| t.name.to_lowercase());
            let height = pack(&mut tiles);
            Section { title, tiles, height }
        })
        .collect();
    plug_sections.sort_by_key(|s| (s.title == OTHER, s.title.to_lowercase()));

    // Lighting page: every light, grouped by area.
    let mut by_area: HashMap<String, Vec<(bool, Tile)>> = HashMap::new();
    for (id, e) in ents.iter().filter(|(id, _)| id.starts_with("light.")) {
        let helper = reg.helpers.contains(id) || e["attributes"]["entity_id"].is_array();
        let area = light_area(id, e, reg, ents, 0);
        let label = if helper { None } else { cfg.lighting.short_names.get(id).map(String::as_str) };
        let mut t = light_tile(ents, reg, id, label);
        t.small = !helper;
        by_area.entry(area).or_default().push((helper, t));
    }
    let mut light_sections: Vec<Section> = by_area
        .into_iter()
        .map(|(title, mut tiles)| {
            tiles.sort_by(|(ha, a), (hb, b)| hb.cmp(ha).then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase())));
            let mut tiles: Vec<Tile> = tiles.into_iter().map(|(_, t)| t).collect();
            // An area whose only light is a single bulb: that bulb is the area's main light.
            if let [only] = tiles.as_mut_slice() {
                only.small = false;
            }
            let height = pack(&mut tiles);
            Section { title, tiles, height }
        })
        .collect();
    light_sections.sort_by_key(|s| {
        let rank = match s.title.as_str() {
            WHOLE_HOME => 0,
            OTHER => 2,
            _ => 1,
        };
        (rank, s.title.to_lowercase())
    });

    Snapshot { connected, weather_temp, weather_cond, weather_icon, home_lights, climate, light_sections, plug_sections }
}

/// Area for the Lighting page: the entity's own area; for a helper without one, its members'
/// area (or "Whole Home" if they span several); else an area name the light's name starts with.
fn light_area(id: &str, e: &Value, reg: &Registry, ents: &Entities, depth: u8) -> String {
    if let Some(a) = reg.area.get(id) {
        return a.clone();
    }
    // Members may themselves be helpers without an area: resolve them the same way.
    if depth < 4
        && let Some(members) = e["attributes"]["entity_id"].as_array()
    {
        let null = Value::Null;
        let areas: BTreeSet<String> = members
            .iter()
            .filter_map(|m| m.as_str())
            .map(|m| light_area(m, ents.get(m).unwrap_or(&null), reg, ents, depth + 1))
            .filter(|a| a != OTHER)
            .collect();
        match areas.len() {
            0 => {}
            1 if !areas.contains(WHOLE_HOME) => return areas.into_iter().next().unwrap_or_default(),
            _ => return WHOLE_HOME.into(),
        }
    }
    let name = name_of(Some(e), id).to_lowercase();
    reg.area_names
        .iter()
        .filter(|a| name.starts_with(&a.to_lowercase()))
        .max_by_key(|a| a.len())
        .cloned()
        .unwrap_or_else(|| OTHER.into())
}

/// Every entity the display depends on (besides all light.*).
pub fn watched(cfg: &Config) -> HashSet<String> {
    let mut set: HashSet<String> = cfg.home.climate.iter().map(|i| i.entity.clone()).collect();
    for p in &cfg.plugs.entities {
        set.insert(p.entity.clone());
        if let Some(s) = p.entity.strip_prefix("switch.") {
            set.insert(format!("sensor.{s}_power"));
        }
    }
    set.extend(cfg.home.weather.clone());
    set
}

fn light_tile(ents: &Entities, _reg: &Registry, id: &str, label: Option<&str>) -> Tile {
    let e = ents.get(id);
    let on = state(e) == "on";
    let brightness = if on {
        e.and_then(|e| e["attributes"]["brightness"].as_f64()).map(|b| (b / 255.0 * 100.0).round() as i32).unwrap_or(100)
    } else {
        0
    };
    let dimmable = e
        .and_then(|e| e["attributes"]["supported_color_modes"].as_array())
        .is_some_and(|m| m.iter().any(|m| m.as_str().is_some_and(|m| m != "onoff")));
    Tile {
        id: id.into(),
        name: label.map(Into::into).unwrap_or_else(|| name_of(e, id)),
        value: state_text(id, e),
        icon: icon("light"),
        on,
        dead: unavailable(e),
        tap: true,
        hold: if dimmable { Hold::Dim } else { Hold::None },
        brightness,
        small: false,
        cell: Cell::default(),
    }
}

fn plug_tile(ents: &Entities, item: &Item) -> Tile {
    let id = item.entity.as_str();
    let e = ents.get(id);
    let on = state(e) == "on";
    let value = match plug_power(ents, id) {
        Some(p) if on => p,
        _ => state_text(id, e),
    };
    Tile {
        id: id.into(),
        name: item.label.clone().unwrap_or_else(|| name_of(e, id)),
        value,
        icon: icon("plug"),
        on,
        dead: unavailable(e),
        tap: false,
        hold: Hold::Toggle,
        brightness: 0,
        small: false,
        cell: Cell::default(),
    }
}

fn sensor_tile(ents: &Entities, item: &Item) -> Tile {
    let id = item.entity.as_str();
    let e = ents.get(id);
    Tile {
        id: id.into(),
        name: item.label.clone().unwrap_or_else(|| name_of(e, id)),
        value: state_text(id, e),
        icon: icon(icon_name(id, e)),
        on: false,
        dead: unavailable(e),
        tap: false,
        hold: Hold::None,
        brightness: 0,
        small: false,
        cell: Cell::default(),
    }
}

fn domain(id: &str) -> &str {
    id.split('.').next().unwrap_or_default()
}

fn state(e: Option<&Value>) -> &str {
    e.and_then(|e| e["state"].as_str()).unwrap_or_default()
}

pub fn unavailable(e: Option<&Value>) -> bool {
    e.is_none() || matches!(state(e), "unavailable" | "unknown")
}

fn name_of(e: Option<&Value>, id: &str) -> String {
    e.and_then(|e| e["attributes"]["friendly_name"].as_str()).unwrap_or(id).to_string()
}

fn icon_name(id: &str, e: Option<&Value>) -> &'static str {
    match domain(id) {
        "switch" => "plug",
        "light" => "light",
        "fan" => "fan",
        "climate" => "climate",
        "sensor" => match e.and_then(|e| e["attributes"]["device_class"].as_str()) {
            Some("temperature") => "climate",
            Some("humidity") => "humidity",
            _ => "gauge",
        },
        _ => "default",
    }
}

fn cap(s: &str) -> String {
    let mut c = s.chars();
    c.next().map(|f| f.to_uppercase().chain(c).collect()).unwrap_or_default()
}

fn state_text(id: &str, e: Option<&Value>) -> String {
    let Some(ent) = e else { return "—".into() };
    let s = state(e);
    if s == "unavailable" {
        return "Unavailable".into();
    }
    let a = &ent["attributes"];
    match domain(id) {
        "light" if s == "on" => match a["brightness"].as_f64() {
            Some(b) => format!("{}%", (b / 255.0 * 100.0).round()),
            None => "On".into(),
        },
        "fan" if s == "on" => match a["percentage"].as_f64() {
            Some(p) => format!("{}%", trim_num(p, 0)),
            None => "On".into(),
        },
        "climate" => match a["current_temperature"].as_f64() {
            Some(t) => format!("{} · {}°", cap(s), trim_num(t, 1)),
            None => cap(s),
        },
        "sensor" => format_number(s, a["unit_of_measurement"].as_str()),
        _ => cap(s),
    }
}

/// Like JS `toLocaleString({maximumFractionDigits})`: at most `digits` decimals, no trailing zeros.
fn trim_num(n: f64, digits: usize) -> String {
    let s = format!("{n:.digits$}");
    let s = if s.contains('.') { s.trim_end_matches('0').trim_end_matches('.').to_string() } else { s };
    if s == "-0" { "0".into() } else { s }
}

fn format_number(value: &str, unit: Option<&str>) -> String {
    let Ok(n) = value.parse::<f64>() else {
        return match unit {
            Some(u) => format!("{value} {u}"),
            None => cap(value),
        };
    };
    let digits = if unit == Some("W") || n.abs() >= 100.0 { 0 } else { 1 };
    let text = trim_num(n, digits);
    match unit {
        Some(u) if u.starts_with('°') || u == "%" => format!("{text}{u}"),
        Some(u) => format!("{text} {u}"),
        None => text,
    }
}

fn plug_power(ents: &Entities, id: &str) -> Option<String> {
    let p = ents.get(&format!("sensor.{}_power", id.strip_prefix("switch.")?))?;
    (!unavailable(Some(p)))
        .then(|| format_number(p["state"].as_str().unwrap_or_default(), p["attributes"]["unit_of_measurement"].as_str()))
}

fn weather_label(s: &str) -> String {
    match s {
        "clear-night" => "Clear".into(),
        "partlycloudy" => "Partly Cloudy".into(),
        "pouring" => "Heavy Rain".into(),
        "rainy" => "Rain".into(),
        "snowy" => "Snow".into(),
        "snowy-rainy" => "Sleet".into(),
        "lightning-rainy" => "Thunderstorms".into(),
        "windy-variant" => "Windy & Cloudy".into(),
        other => other.split(['-', '_', ' ']).filter(|w| !w.is_empty()).map(cap).collect::<Vec<_>>().join(" "),
    }
}

fn weather_icon_name(s: &str) -> &'static str {
    match s {
        "sunny" => "sun",
        "clear-night" => "moon",
        "partlycloudy" => "sun-cloud",
        "rainy" | "pouring" | "snowy-rainy" | "hail" => "rain",
        "snowy" => "snow",
        "lightning" | "lightning-rainy" => "storm",
        "fog" => "fog",
        "windy" => "wind",
        _ => "cloud",
    }
}

/// SVG path data (24x24, stroked), from master-control's Icon.svelte.
pub fn icon(name: &str) -> &'static str {
    match name {
        "light" => "M9 18h6M10 21h4M12 3a6 6 0 0 0-3.5 10.9c.6.5 1 1.2 1 2V16h5v-.1c0-.8.4-1.5 1-2A6 6 0 0 0 12 3z",
        "plug" => "M9 3v5M15 3v5M6 8h12v3a6 6 0 0 1-12 0zM12 17v4",
        "camera" => "M15 10l5-3v10l-5-3zM3 7h12v10H3z",
        "home" => "M3 11l9-7 9 7M5 9.5V20h5v-6h4v6h5V9.5",
        "fan" => "M12 12c0-3 1-7 4-7s3 4 0 6l-4 1zm0 0c3 0 7 1 7 4s-4 3-6 0l-1-4zm0 0c0 3-1 7-4 7s-3-4 0-6l4-1zm0 0c-3 0-7-1-7-4s4-3 6 0l1 4z",
        "climate" => "M14 14.8V5a2 2 0 0 0-4 0v9.8a4 4 0 1 0 4 0z",
        "humidity" => "M12 3s6 6.5 6 11a6 6 0 0 1-12 0c0-4.5 6-11 6-11z",
        "gauge" => "M4 16a8 8 0 1 1 16 0M12 16l4-5",
        "sun" => "M12 7a5 5 0 1 0 0 10 5 5 0 0 0 0-10zM12 1v2M12 21v2M4.2 4.2l1.4 1.4M18.4 18.4l1.4 1.4M1 12h2M21 12h2M4.2 19.8l1.4-1.4M18.4 5.6l1.4-1.4",
        "moon" => "M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z",
        "sun-cloud" => "M8 3v1.5M3.5 5.5l1 1M2 10h1.5M12.5 5.5l-1 1M5.5 11.5A3.5 3.5 0 0 1 12 8.5M7 21h10a4 4 0 0 0 0-8h-.5A5.5 5.5 0 0 0 6 14a3.5 3.5 0 0 0 1 7z",
        "cloud" => "M7 19h10a5 5 0 0 0 0-10h-.6A6.5 6.5 0 0 0 4 11a4 4 0 0 0 3 8z",
        "rain" => "M7 15h10a4.5 4.5 0 0 0 0-9h-.5A6 6 0 0 0 5 8a3.5 3.5 0 0 0 2 7zM8 18l-1 3M12 18l-1 3M16 18l-1 3",
        "snow" => "M7 14h10a4.5 4.5 0 0 0 0-9h-.5A6 6 0 0 0 5 7a3.5 3.5 0 0 0 2 7zM8 18h.01M12 20h.01M16 18h.01M10 22h.01M14 22h.01",
        "storm" => "M7 15h10a4.5 4.5 0 0 0 0-9h-.5A6 6 0 0 0 5 8a3.5 3.5 0 0 0 2 7zM13 15l-3 4h4l-3 4",
        "fog" => "M4 9h16M2 13h20M5 17h14M8 21h8",
        "wind" => "M3 8h11a3 3 0 1 0-3-3M3 12h16a3 3 0 1 1-3 3M3 16h8",
        _ => "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn numbers_match_web_ui() {
        assert_eq!(format_number("43.5", Some("%")), "43.5%");
        assert_eq!(format_number("70.43", Some("°F")), "70.4°F");
        assert_eq!(format_number("49.0", Some("%")), "49%");
        assert_eq!(format_number("123.6", Some("W")), "124 W");
        assert_eq!(format_number("unknown", None), "Unknown");
    }

    #[test]
    fn packs_helpers_and_bulbs() {
        let t = |small| Tile {
            id: String::new(), name: String::new(), value: String::new(), icon: "", on: false, dead: false,
            tap: true, hold: Hold::None, brightness: 0, small, cell: Cell::default(),
        };
        // helper, then 5 bulbs: [H] / [b b b b] / [b]
        let mut v = vec![t(false), t(true), t(true), t(true), t(true), t(true)];
        let h = pack(&mut v);
        assert_eq!((v[0].cell.y, v[0].cell.span), (0, 4));
        assert_eq!((v[1].cell.y, v[1].cell.col), (HELPER_H + GAP, 0));
        assert_eq!((v[4].cell.y, v[4].cell.col), (HELPER_H + GAP, 3));
        assert_eq!((v[5].cell.y, v[5].cell.col), (HELPER_H + BULB_H + 2 * GAP, 0));
        assert_eq!(h, HELPER_H + 2 * BULB_H + 2 * GAP);
        // bulbs only
        let mut w = vec![t(true), t(true)];
        assert_eq!(pack(&mut w), BULB_H);
    }

    #[test]
    fn helper_area_from_members() {
        let mut reg = Registry::default();
        reg.area.insert("light.a".into(), "Kitchen".into());
        reg.area.insert("light.b".into(), "Kitchen".into());
        reg.area.insert("light.c".into(), "Office".into());
        reg.area_names = vec!["Kitchen".into(), "Office".into(), "Living Room".into()];
        let one = json!({"attributes": {"entity_id": ["light.a", "light.b"]}});
        let many = json!({"attributes": {"entity_id": ["light.a", "light.c"]}});
        let named = json!({"attributes": {"friendly_name": "Living Room Lamp"}});
        let mut ents = Entities::new();
        ents.insert("light.g1".into(), one.clone());
        ents.insert("light.d".into(), json!({"attributes": {"entity_id": ["light.c"]}}));
        let nested = json!({"attributes": {"entity_id": ["light.g1", "light.d"]}});
        assert_eq!(light_area("light.g1", &one, &reg, &ents, 0), "Kitchen");
        assert_eq!(light_area("light.g2", &many, &reg, &ents, 0), WHOLE_HOME);
        assert_eq!(light_area("light.g3", &nested, &reg, &ents, 0), WHOLE_HOME);
        assert_eq!(light_area("light.x", &named, &reg, &ents, 0), "Living Room");
        assert_eq!(light_area("light.y", &json!({}), &reg, &ents, 0), OTHER);
    }
}
