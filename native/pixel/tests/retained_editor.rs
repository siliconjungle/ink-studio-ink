use ink_studio_pixel::{PasteOptions, PasteTransform, PixelEditor};

fn document(x: u32, width: u32) -> serde_json::Value {
    serde_json::json!({
        "format": "ink-studio/pixel-art", "version": 2,
        "width": width, "height": 3, "pixelAspect": [1, 1],
        "palette": {"rust": "#b53129"}, "layers": [{"id": "ink"}],
        "frames": [{"id": "front", "durationMs": 100, "cels": {
            "ink": {"marks": [{"swatch": "rust", "at": [x, 1]}]}
        }}],
        "selections": [{"id": "pin", "frame": "front", "pixels": [[x, 1]]}]
    })
}

#[test]
fn replacement_changes_both_raster_and_saved_selection_and_rejection_preserves_the_editor() {
    let mut editor = PixelEditor::new(&document(2, 5).to_string()).unwrap();
    let swatch = r#"{"type":"swatch","id":"rust"}"#;
    let recall = r#"{"type":"recall","id":"pin"}"#;
    let pick =
        |editor: &mut PixelEditor, query| editor.select(query, None, None, None, "{}").unwrap();
    assert_eq!(pick(&mut editor, swatch).pixels, [[2, 1]]);
    assert_eq!(pick(&mut editor, recall).pixels, [[2, 1]]);

    let mut invalid = document(3, 5);
    invalid["selections"] = serde_json::Value::Null;
    assert_eq!(
        editor.replace_document(&invalid.to_string()).unwrap_err(),
        "Pixel selections must be an array"
    );
    assert_eq!(pick(&mut editor, swatch).pixels, [[2, 1]]);

    editor
        .replace_document(&document(5, 6).to_string())
        .unwrap();
    let after = pick(&mut editor, swatch);
    assert_eq!(after.grid, [6, 3]);
    assert_eq!(after.pixels, [[5, 1]]);
    assert_eq!(pick(&mut editor, recall), after);
}

#[test]
fn paint_updates_a_warm_raster_and_preserves_the_document_on_error() {
    let mut editor = PixelEditor::new(&document(2, 5).to_string()).unwrap();
    let query = r#"{"type":"swatch","id":"rust"}"#;
    let select = |editor: &mut PixelEditor| editor.select(query, None, None, None, "{}").unwrap();
    assert_eq!(select(&mut editor).pixels, [[2, 1]]);
    let report = editor
        .paint(
            r#"{"tool":"eraser","layer":"ink","points":[[2,1]]}"#,
            None,
            None,
        )
        .unwrap();
    assert_eq!(report.runs, [[1, 2, 1]]);
    assert!(select(&mut editor).pixels.is_empty());
    let report = editor
        .paint(
            r#"{"tool":"pencil","layer":"ink","points":[[0,0],[2,0]],
        "swatch":"rust","drawing":{"mirrorX":2}}"#,
            None,
            None,
        )
        .unwrap();
    assert_eq!(report.runs, [[0, 0, 5]]);
    assert_eq!(
        select(&mut editor).pixels,
        [[0, 0], [1, 0], [2, 0], [3, 0], [4, 0]]
    );
    let source = editor.snapshot().unwrap();
    assert!(
        editor
            .paint(
                r#"{"tool":"pencil","layer":"ink","points":[[0,3]],"swatch":"rust"}"#,
                None,
                None
            )
            .is_err()
    );
    assert_eq!(editor.snapshot().unwrap(), source);
    let saved = serde_json::from_str::<serde_json::Value>(&source).unwrap();
    assert_eq!(
        saved["selections"][0]["pixels"],
        serde_json::json!([[2, 1]])
    );
    assert_eq!(
        saved["frames"][0]["cels"]["ink"]["marks"][2]["runs"],
        serde_json::json!([[0, 0, 5]])
    );
    assert_eq!(
        select(&mut PixelEditor::new(&source).unwrap()),
        select(&mut editor)
    );
}

#[test]
fn retained_runs_follow_holds_and_match_the_saved_raster_after_detaching() {
    let mut design = document(1, 8);
    design["palette"]["blue"] = serde_json::json!("#213b71");
    design["frames"][0]["cels"]["ink"]["id"] = serde_json::json!("original");
    design["frames"]
        .as_array_mut()
        .unwrap()
        .push(serde_json::json!({
            "id": "back", "durationMs": 100,
            "cels": { "ink": { "id": "held", "hold": "original", "offset": [1, 1] } }
        }));
    let mut editor = PixelEditor::new(&design.to_string()).unwrap();
    let shape = r#"{"tool":"shape","layer":"ink","swatch":"blue",
        "shape":{"type":"line","from":[2,0],"to":[4,0]}}"#;
    assert_eq!(
        editor.paint(shape, Some("front"), None).unwrap().runs,
        [[0, 2, 3]]
    );
    let selected = |editor: &mut PixelEditor, swatch, frame| {
        editor
            .select(swatch, Some(frame), Some("ink"), None, "{}")
            .unwrap()
            .pixels
    };
    let blue = r#"{"type":"swatch","id":"blue"}"#;
    let rust = r#"{"type":"swatch","id":"rust"}"#;
    assert_eq!(
        selected(&mut editor, blue, "back"),
        [[3, 1], [4, 1], [5, 1]]
    );

    let erase = r#"{"tool":"eraser","points":[[4,1]]}"#;
    assert_eq!(
        editor.paint(erase, None, Some("held")).unwrap().runs,
        [[1, 4, 1]]
    );
    let paint = r#"{"tool":"pencil","layer":"ink","swatch":"rust","points":[[3,0]]}"#;
    assert_eq!(
        editor.paint(paint, Some("front"), None).unwrap().runs,
        [[0, 3, 1]]
    );

    let saved = editor.snapshot().unwrap();
    let mut reloaded = PixelEditor::new(&saved).unwrap();
    assert_eq!(selected(&mut editor, blue, "back"), [[3, 1], [5, 1]]);
    assert_eq!(selected(&mut editor, rust, "back"), [[2, 2]]);
    for (swatch, frame) in [
        (blue, "back"),
        (blue, "front"),
        (rust, "back"),
        (rust, "front"),
    ] {
        assert_eq!(
            selected(&mut editor, swatch, frame),
            selected(&mut reloaded, swatch, frame)
        );
    }
    let saved: serde_json::Value = serde_json::from_str(&saved).unwrap();
    let cel = &saved["frames"][1]["cels"]["ink"];
    assert!(cel.get("hold").is_none());
    assert_eq!(cel["marks"][1]["runs"], serde_json::json!([[0, 2, 3]]));
    assert_eq!(cel["marks"][2]["runs"], serde_json::json!([[0, 3, 1]]));
}
#[test]
fn brush_palette_and_alpha_are_visible_to_capture_and_survive_reload() {
    let mut editor = PixelEditor::new(&document(2, 5).to_string()).unwrap();
    let brush = r##"{"format":"ink-studio/pixel-brush","version":1,"width":1,"height":1,
      "anchor":[0,0],"palette":[{"id":"blue","color":"#213b71"}],"slots":[0],
      "settings":{"angle":0,"size":[1,1],"swatch":{"mode":"original"}}}"##;
    let stamp = |extra: &str| {
        format!(r#"{{"tool":"brush","layer":"ink","brush":{brush},"at":[2,1]{extra}}}"#)
    };
    let capture = r#"{"rect":[2,1,1,1],"layer":"ink"}"#;
    let report = editor.paint(&stamp(""), Some("front"), None).unwrap();
    assert_eq!(report.added_swatches, ["blue"]);
    assert_eq!(
        editor.capture_brush(capture).unwrap().palette[0]
            .id
            .as_deref(),
        Some("blue")
    );
    let hide = stamp(r#","shading":{"mode":"alpha","value":0}"#);
    let restore = stamp(r#","shading":{"mode":"alpha","value":255}"#);
    assert_eq!(
        editor
            .paint(&hide, Some("front"), None)
            .unwrap()
            .pixel_count,
        1
    );
    assert!(editor.capture_brush(capture).is_err());
    let hidden = editor.snapshot().unwrap();
    let mut fresh = PixelEditor::new(&hidden).unwrap();
    assert!(fresh.capture_brush(capture).is_err());
    assert_eq!(
        editor.paint(&restore, Some("front"), None).unwrap().runs,
        [[1, 2, 1]]
    );
    assert_eq!(
        fresh.paint(&restore, Some("front"), None).unwrap().runs,
        [[1, 2, 1]]
    );
    assert_eq!(editor.snapshot().unwrap(), fresh.snapshot().unwrap());
    assert_eq!(
        editor.capture_brush(capture).unwrap().palette[0].color,
        "#213b71"
    );
}
#[test]
fn named_masks_update_in_place_and_drive_exact_color_edits() {
    let mut editor = PixelEditor::new(&document(2, 5).to_string()).unwrap();
    let actual = editor
        .save_selection(
            r#"{"id":"pin","query":{"type":"rectangle","rect":[1,1,3,1]},"layer":"ink"}"#,
            Some("front"),
        )
        .unwrap();
    assert_eq!(actual.runs, [[1, 1, 3]]);
    assert_eq!(actual.pixel_count, 3);

    let command = r#"{"tool":"rgba","layer":"ink","pixels":[
        {"at":[1,1],"rgba":[19,43,71,0],"swatch":"glaze"},
        {"at":[3,1],"rgba":[19,43,71,127],"swatch":"glaze"}]}"#;
    let report = editor.paint(command, Some("front"), None).unwrap();
    assert_eq!(report.added_swatches, ["glaze"]);
    let wrong = r#"{"tool":"rgba","layer":"ink","pixels":[{"at":[1,1],"rgba":[0,0,0,255],"swatch":"glaze"}]}"#;
    let prior = editor.snapshot().unwrap();
    assert_eq!(
        editor.paint(wrong, Some("front"), None).unwrap_err(),
        "RGBA does not match swatch glaze"
    );
    assert_eq!(editor.snapshot().unwrap(), prior);

    let recolor =
        r#"{"tool":"replace-swatch","layer":"ink","selection":"pin","from":"glaze","to":"rust"}"#;
    let replaced = editor.paint(recolor, Some("front"), None).unwrap();
    assert_eq!(replaced.runs, [[1, 1, 1], [1, 3, 1]]);
    let saved = editor.snapshot().unwrap();
    let doc: serde_json::Value = serde_json::from_str(&saved).unwrap();
    assert_eq!(doc["selections"].as_array().unwrap().len(), 1);
    assert_eq!(
        doc["selections"][0]["pixels"],
        serde_json::json!([[1, 1], [2, 1], [3, 1]])
    );
    let query = r#"{"type":"swatch","id":"rust"}"#;
    let pick = |editor: &mut PixelEditor| {
        editor
            .select(query, Some("front"), Some("ink"), None, "{}")
            .unwrap()
            .pixels
    };
    assert_eq!(pick(&mut editor), [[2, 1], [3, 1]]);
    assert_eq!(
        pick(&mut PixelEditor::new(&saved).unwrap()),
        [[2, 1], [3, 1]]
    );
}

#[test]
fn selection_transform_carries_protection_and_paste_preserves_knockout_after_reload() {
    let mut input = document(1, 7);
    input["selections"][0]["pixels"] = serde_json::json!([[1, 1], [2, 1], [3, 1]]);
    input["frames"][0]["cels"]["ink"]["marks"]
        .as_array_mut()
        .unwrap()
        .extend([
            serde_json::json!({"swatch": null, "at": [2, 1]}),
            serde_json::json!({"alpha": 42, "runs": [[1, 1, 1]]}),
        ]);
    input["protectedDetails"] = serde_json::json!([
        {"id": "paint", "kind": "accent", "frame": "front", "pixels": [[1, 1]]}
    ]);
    let mut editor = PixelEditor::new(&input.to_string()).unwrap();
    let copy = r#"{"layer":"ink","selection":"landed"}"#;
    let operation = r#"{"tool":"transform","layer":"ink","selection":"pin","carryProtection":true,
        "transform":{"at":[3,1]},"resultSelection":"landed"}"#;
    let report = editor.paint(operation, Some("front"), None).unwrap();
    let placement = report.transform.unwrap();
    assert_eq!(placement.bounds, [3, 1, 3, 1]);
    assert_eq!(placement.selection_runs.unwrap(), [[1, 3, 3]]);
    assert_eq!(placement.carried_protection[0].pixels, [[3, 1]]);

    let copied = editor.copy_selection(copy).unwrap();
    assert_eq!(copied.slots, [Some(0), Some(-2), Some(-1)]);
    assert_eq!(copied.alpha, [42, 255, 255]);
    let saved = editor.snapshot().unwrap();
    let mut reloaded = PixelEditor::new(&saved).unwrap();
    assert_eq!(
        serde_json::to_value(&copied).unwrap(),
        serde_json::to_value(reloaded.copy_selection(copy).unwrap()).unwrap()
    );
    let wrong = r#"{"tool":"rgba","layer":"ink","pixels":[{"at":[3,1],"rgba":null}]}"#;
    assert_eq!(
        editor.paint(wrong, None, None).unwrap_err(),
        "RGBA edit cannot change this pixel"
    );
    assert_eq!(editor.snapshot().unwrap(), saved);

    let paste = serde_json::json!({"tool": "paste", "layer": "ink", "clipboard": &copied,
        "transform": {"at": [1, 0], "flipX": true}, "resultSelection": "pasted"})
    .to_string();
    let json_report = reloaded.paint(&paste, None, None).unwrap();
    let report = editor
        .paste_clipboard(
            copied,
            PasteOptions {
                layer: Some("ink"),
                result_selection: Some("pasted"),
                transform: PasteTransform {
                    at: Some([1, 0]),
                    flip_x: Some(true),
                    ..PasteTransform::default()
                },
            },
            None,
            None,
        )
        .unwrap();
    assert_eq!(report, json_report);
    assert_eq!(editor.snapshot().unwrap(), reloaded.snapshot().unwrap());
    assert_eq!(report.runs, [[0, 2, 2]]);
    assert_eq!(
        editor
            .copy_selection(r#"{"selection":"pasted","layer":"ink"}"#)
            .unwrap()
            .slots,
        [Some(-1), Some(-2), Some(0)]
    );
    let saved: serde_json::Value = serde_json::from_str(&editor.snapshot().unwrap()).unwrap();
    assert_eq!(
        saved["protectedDetails"][0]["pixels"],
        serde_json::json!([[3, 1]])
    );
}
