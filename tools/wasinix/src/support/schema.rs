//! The document envelope: every top-level document the tool writes or prints
//! is a JSON object opening with `schema` (version) and `kind` (type tag), so
//! files and stdout are self-describing and a version mismatch is a hard
//! error, never a silent default.

use std::path::Path;

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::support::error::{Error, Result, request_error};

pub trait Document: Serialize + DeserializeOwned {
    const KIND: &'static str;
    const SCHEMA: u32;
}

fn envelope<T: Document>(value: &T) -> Result<Value> {
    let mut body = serde_json::to_value(value).map_err(|source| Error::Json {
        path: "<in-memory>".into(),
        source,
    })?;
    let object = body
        .as_object_mut()
        .unwrap_or_else(|| panic!("document kind {} must serialize to an object", T::KIND));
    // The envelope owns these two top-level keys; a document field reusing
    // one would be silently clobbered here and lost on read.
    for reserved in ["schema", "kind"] {
        assert!(
            !object.contains_key(reserved),
            "document kind {} already carries a top-level {reserved:?} field",
            T::KIND
        );
    }
    object.insert("schema".into(), T::SCHEMA.into());
    object.insert("kind".into(), T::KIND.into());
    Ok(body)
}

fn open<T: Document>(mut value: Value, origin: &str) -> Result<T> {
    let object = match value.as_object_mut() {
        Some(object) => object,
        None => return request_error(format!("{origin}: not a document object")),
    };
    match object.remove("kind") {
        Some(Value::String(kind)) if kind == T::KIND => {}
        Some(Value::String(kind)) => {
            return request_error(format!(
                "{origin}: is a {kind} document, expected {}",
                T::KIND
            ));
        }
        _ => {
            return request_error(format!(
                "{origin}: has no document kind, expected {}",
                T::KIND
            ));
        }
    }
    match object.remove("schema") {
        Some(Value::Number(schema)) if schema.as_u64() == Some(u64::from(T::SCHEMA)) => {}
        Some(schema) => {
            return request_error(format!(
                "{origin}: {} document schema {schema} is not the supported {}",
                T::KIND,
                T::SCHEMA
            ));
        }
        None => {
            return request_error(format!(
                "{origin}: {} document carries no schema (expected {})",
                T::KIND,
                T::SCHEMA
            ));
        }
    }
    serde_json::from_value(value).map_err(|source| Error::Json {
        path: origin.into(),
        source,
    })
}

pub fn write<T: Document>(path: &Path, value: &T) -> Result<()> {
    crate::support::json::write(path, &envelope(value)?)
}

pub fn read<T: Document>(path: &Path) -> Result<T> {
    let value: Value = crate::support::json::read(path)?;
    open(value, &path.display().to_string())
}

pub fn from_value<T: Document>(value: Value, origin: &str) -> Result<T> {
    open(value, origin)
}

pub fn to_value<T: Document>(value: &T) -> Result<Value> {
    envelope(value)
}
