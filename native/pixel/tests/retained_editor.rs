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
