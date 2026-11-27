use ink_studio_pixel::PixelEditor;

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
