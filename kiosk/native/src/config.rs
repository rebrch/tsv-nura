use serde::Deserialize;
use std::path::PathBuf;

#[derive(Debug, Deserialize)]
pub struct Config {
    pub home_assistant: HomeAssistant,
    pub home: Home,
    #[serde(default)]
    pub lighting: Lighting,
    #[serde(default)]
    pub plugs: Plugs,
    #[serde(default)]
    pub ui: Ui,
}

#[derive(Debug, Deserialize)]
pub struct HomeAssistant {
    pub url: String,
    pub token_file: PathBuf,
}

#[derive(Debug, Deserialize, Clone)]
pub struct Item {
    pub entity: String,
    pub label: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct Home {
    pub weather: Option<String>,
    #[serde(default)]
    pub lights: Vec<Item>,
    #[serde(default = "two")]
    pub climate_columns: i32,
    #[serde(default)]
    pub climate: Vec<Item>,
}

#[derive(Debug, Deserialize, Default)]
pub struct Lighting {
    /// light id -> short name for the compact bulb tiles
    #[serde(default)]
    pub short_names: std::collections::HashMap<String, String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct Plugs {
    #[serde(default)]
    pub entities: Vec<Item>,
}

#[derive(Debug, Deserialize)]
pub struct Ui {
    #[serde(default = "ninety")]
    pub idle_return_seconds: u64,
}

impl Default for Ui {
    fn default() -> Self {
        Self { idle_return_seconds: ninety() }
    }
}

fn two() -> i32 {
    2
}
fn ninety() -> u64 {
    90
}

impl Config {
    pub fn load(path: &str) -> anyhow::Result<Self> {
        let text = std::fs::read_to_string(path).map_err(|e| anyhow::anyhow!("reading {path}: {e}"))?;
        Ok(toml::from_str(&text)?)
    }

    /// May the panel toggle this entity? Any light, plus the configured plugs. Everything else
    /// sent from the UI is rejected.
    pub fn may_toggle(&self, id: &str) -> bool {
        id.starts_with("light.") || self.plugs.entities.iter().any(|p| p.entity == id)
    }
}
