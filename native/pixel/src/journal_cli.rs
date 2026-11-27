use ink_studio_pixel::{PixelCommandEditor, PixelEditError, PixelPreviewOptions};
use serde::{Deserialize, Serialize};
use serde_json::{
    Value,
    value::{RawValue, to_raw_value},
};
use std::{
    ffi::OsString,
    io::{self, Write},
};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Request<'a> {
    document: &'a RawValue,
    history_limit: Option<u32>,
    #[serde(borrow)]
    steps: Vec<Step<'a>>,
}

#[derive(Deserialize)]
struct Step<'a> {
    op: &'a str,
    label: Option<&'a str>,
    patch: Option<&'a RawValue>,
    receipt: Option<&'a RawValue>,
    options: Option<&'a RawValue>,
    command: Option<&'a RawValue>,
}

#[derive(Serialize)]
#[serde(untagged)]
enum Reply {
    Ok {
        value: Box<RawValue>,
    },
    Rejected {
        error: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        receipt: Option<Box<Value>>,
    },
}

fn raw(value: String) -> Result<Box<RawValue>, PixelEditError> {
    RawValue::from_string(value).map_err(|error| error.to_string().into())
}

fn encoded(value: impl Serialize) -> Result<Box<RawValue>, PixelEditError> {
    to_raw_value(&value).map_err(|error| error.to_string().into())
}

fn preview_options(raw: Option<&RawValue>) -> Result<PixelPreviewOptions, PixelEditError> {
    PixelPreviewOptions::from_json(raw.map_or("{}", RawValue::get))
}

fn execute(
    editor: &mut PixelCommandEditor,
    step: Step<'_>,
) -> Result<Box<RawValue>, PixelEditError> {
    match step.op {
        "begin" => encoded(editor.begin(step.label.unwrap_or(""))?),
        "commit" => encoded(editor.commit()?),
        "cancel" => encoded(editor.cancel()?),
        "undo" => encoded(editor.undo()?),
        "redo" => encoded(editor.redo()?),
        "history" => encoded(editor.history()?),
        "revision" => encoded(editor.revision()?),
        "receipts" => encoded(editor.receipts()?),
        "preview" => raw(editor.preview()?),
        "execute" => raw(editor.execute(step.command.map_or("null", RawValue::get))?),
        "snapshot" => raw(editor.snapshot()?),
        "apply" => raw(editor.apply(step.patch.map_or("null", RawValue::get))?),
        "replay" => raw(editor.replay(step.receipt.map_or("null", RawValue::get))?),
        "copy" => encoded(editor.copy_selection(step.options.map_or("{}", RawValue::get))?),
        "preview-edit" => encoded(editor.preview_edit(
            step.patch.map_or("null", RawValue::get),
            preview_options(step.options)?,
        )?),
        "preview-changes" => encoded(editor.preview_changes(preview_options(step.options)?)?),
        "preview-patch" => {
            #[derive(Serialize)]
            struct Preview<'a> {
                document: Box<RawValue>,
                receipt: &'a Value,
            }
            let staged = editor.preview_patch(step.patch.map_or("null", RawValue::get))?;
            encoded(Preview {
                document: raw(staged.document)?,
                receipt: &staged.receipt,
            })
        }
        _ => Err(format!("Unknown pixel journal step {}", step.op).into()),
    }
}

pub fn run(path: OsString) -> Result<(), String> {
    let input = std::fs::read_to_string(path).map_err(|error| error.to_string())?;
    let request: Request = serde_json::from_str(&input).map_err(|error| error.to_string())?;
    let mut editor =
        PixelCommandEditor::new(request.document.get(), request.history_limit.unwrap_or(100))?;
    let mut stdout = io::BufWriter::new(io::stdout().lock());
    for step in request.steps {
        let reply = match execute(&mut editor, step) {
            Ok(value) => Reply::Ok { value },
            Err(mut error) => Reply::Rejected {
                error: error.to_string(),
                receipt: error.receipt.take(),
            },
        };
        serde_json::to_writer(&mut stdout, &reply).map_err(|error| error.to_string())?;
        stdout.write_all(b"\n").map_err(|error| error.to_string())?;
    }
    stdout.flush().map_err(|error| error.to_string())
}

pub fn run_command(path: OsString) -> Result<(), String> {
    #[derive(Deserialize)]
    struct Command<'a> {
        #[serde(borrow)]
        document: &'a RawValue,
        #[serde(borrow)]
        command: &'a RawValue,
    }
    #[derive(Deserialize)]
    struct Status {
        valid: Option<bool>,
    }
    let input = std::fs::read_to_string(path).map_err(|error| error.to_string())?;
    let request: Command<'_> = serde_json::from_str(&input).map_err(|error| error.to_string())?;
    let mut editor = PixelCommandEditor::new(request.document.get(), 100)?;
    let run = editor.execute(request.command.get());
    match run {
        Ok(reply) => {
            println!("{reply}");
            if serde_json::from_str::<Status>(&reply)
                .is_ok_and(|status| status.valid == Some(false))
            {
                std::process::exit(2);
            }
            Ok(())
        }
        Err(error) => {
            if let Some(receipt) = error.receipt.as_ref() {
                println!("{receipt}");
                std::process::exit(2);
            }
            Err(error.to_string())
        }
    }
}
