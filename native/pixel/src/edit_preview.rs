use serde::{Serialize, Serializer};
use serde_json::Value;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PixelEditPreview {
    format: &'static str,
    version: u8,
    pub valid: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cel_links: Option<Value>,
    pub pixel_count: u32,
    pub pixels: Vec<CellChange>,
    sources: [(); 0],
    pub targets: Vec<Value>,
    pub conflicts: Vec<Value>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub guides: Vec<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub diff: Option<ExactPreview>,
}

#[derive(Debug, Serialize)]
pub struct CellChange {
    pub frame: String,
    pub at: [u32; 2],
    #[serde(skip_serializing_if = "Option::is_none")]
    pub layer: Option<String>,
    pub before: Option<Sample>,
    pub after: Option<Sample>,
}

#[derive(Debug, Serialize)]
#[serde(untagged)]
pub enum Sample {
    Composite {
        layer: Option<String>,
        cel: Option<String>,
        swatch: Option<String>,
        color: Option<Color>,
        protected: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        alpha: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        underneath: Option<Location>,
    },
    Raw {
        cel: Option<String>,
        swatch: Option<String>,
        color: Option<Color>,
        alpha: u32,
        knockout: bool,
        clip: u32,
    },
}

#[derive(Debug)]
pub struct Color(pub u32);

impl Serialize for Color {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(&format_args!("#{:06x}", self.0))
    }
}

#[derive(Debug, Serialize)]
pub struct Location {
    pub layer: Option<String>,
    pub cel: Option<String>,
    pub swatch: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct Site {
    pub frame: String,
    pub at: [u32; 2],
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExactPreview {
    pub cells: Vec<CellChange>,
    pub grids: Vec<Value>,
    materials: [(); 0],
    geometry: [(); 0],
    other: [(); 0],
    rendered: [(); 0],
    render_errors: [(); 0],
    pub skipped_hits: Vec<Value>,
    pub protection: Protection,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Protection {
    pub would_change: bool,
    pub details: Vec<Value>,
    geometry: [(); 0],
    pub cells: Vec<Site>,
    rendered_cells: [(); 0],
    pub blocked: Vec<Value>,
}

#[derive(Default)]
pub(crate) struct Preview {
    pub count: u32,
    pub pixels: Vec<CellChange>,
    pub cells: Vec<CellChange>,
    pub protected_cells: Vec<Site>,
    pub details: Vec<Value>,
    pub grids: Vec<Value>,
    pub guides: Vec<Value>,
    pub links: Option<Value>,
    pub receipt: u32,
}

impl Preview {
    pub(crate) fn report(
        self,
        targets: Vec<Value>,
        conflicts: Vec<Value>,
        exact: bool,
    ) -> PixelEditPreview {
        let diff = exact.then(|| {
            let skipped_hits: Vec<_> = conflicts
                .iter()
                .filter(|issue| issue.get("at").is_some())
                .cloned()
                .collect();
            let blocked = skipped_hits
                .iter()
                .filter(|issue| {
                    issue["code"]
                        .as_str()
                        .is_some_and(|code| code.starts_with("protected-"))
                })
                .cloned()
                .collect();
            ExactPreview {
                cells: self.cells,
                grids: self.grids,
                materials: [],
                geometry: [],
                other: [],
                rendered: [],
                render_errors: [],
                skipped_hits,
                protection: Protection {
                    would_change: !self.protected_cells.is_empty() || !self.details.is_empty(),
                    details: self.details,
                    geometry: [],
                    cells: self.protected_cells,
                    rendered_cells: [],
                    blocked,
                },
            }
        });
        PixelEditPreview {
            format: "ink-studio/pixel-edit-preview",
            version: 1,
            valid: conflicts.is_empty(),
            cel_links: self.links,
            pixel_count: self.count,
            pixels: self.pixels,
            sources: [],
            targets,
            conflicts,
            guides: self.guides,
            diff,
        }
    }
}
