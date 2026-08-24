//! Reading and writing the build result junit files.

use std::path::PathBuf;

use quick_xml::events::Event;

use crate::ci::evalmap::{ExpectedOutcome, TestExpectation};

/// One junit testcase, enriched by classification: whether its failure was its
/// own or inherited, and what the job's declared expectation was.
#[derive(Debug, Clone)]
pub struct Case {
    pub attr: String,
    pub class: String,
    pub duration: f64,
    /// The derivation behind the job, so aggregation can count a build once
    /// however many job addresses share it.
    pub drv: Option<String>,
    pub message: Option<String>,
    pub log: Option<String>,
    pub transitive: bool,
    pub expectation: Option<TestExpectation>,
    pub is_test: bool,
    pub test_name: Option<String>,
    pub test_family: Option<String>,
    pub position: Option<String>,
}

impl Case {
    pub fn new(attr: String, class: String) -> Case {
        Case {
            attr,
            class,
            duration: 0.0,
            drv: None,
            message: None,
            log: None,
            transitive: false,
            expectation: None,
            is_test: false,
            test_name: None,
            test_family: None,
            position: None,
        }
    }
}

/// Parse every junit the task produced. `None` means none of them existed,
/// which is a cancelled or crashed build rather than a clean one.
pub fn parse_junits(paths: &[PathBuf], warn_missing: bool) -> Option<Vec<Case>> {
    let mut cases = Vec::new();
    let mut found = false;
    for path in paths {
        let text = match std::fs::read_to_string(path) {
            Ok(text) => text,
            Err(error) => {
                if warn_missing {
                    crate::support::ui::warning(format!("no junit results ({error})"));
                }
                continue;
            }
        };
        found = true;
        let mut reader = quick_xml::Reader::from_str(&text);
        let mut buffer = Vec::new();
        let mut current: Option<Case> = None;
        let mut in_failure = false;
        while let Ok(event) = reader.read_event_into(&mut buffer) {
            match event {
                Event::Start(element) | Event::Empty(element) => match element.name().as_ref() {
                    b"testcase" => {
                        if let Some(case) = current.take() {
                            cases.push(case);
                        }
                        let attribute = |name: &[u8]| {
                            element
                                .attributes()
                                .flatten()
                                .find(|attr| attr.key.as_ref() == name)
                                .and_then(|attr| attr.unescape_value().ok())
                                .map(|value| value.to_string())
                                .unwrap_or_default()
                        };
                        let mut case = Case::new(
                            crate::nix::evaljobs::attr_name(&attribute(b"name")),
                            attribute(b"classname"),
                        );
                        case.duration = attribute(b"time")
                            .parse::<f64>()
                            .ok()
                            .filter(|seconds| seconds.is_finite() && *seconds >= 0.0)
                            .unwrap_or(0.0);
                        case.drv = Some(attribute(b"drv")).filter(|drv| !drv.is_empty());
                        current = Some(case);
                    }
                    b"failure" => {
                        if let Some(case) = current.as_mut() {
                            let message = element
                                .attributes()
                                .flatten()
                                .find(|attr| attr.key.as_ref() == b"message")
                                .and_then(|attr| attr.unescape_value().ok())
                                .map(|value| value.to_string())
                                .unwrap_or_default();
                            case.message = Some(message);
                            case.log = Some(String::new());
                            in_failure = true;
                        }
                    }
                    _ => {}
                },
                Event::Text(text) if in_failure => {
                    if let Some(case) = current.as_mut() {
                        if let Ok(value) = text.unescape() {
                            case.log = Some(value.to_string());
                        }
                    }
                }
                Event::End(element) => match element.name().as_ref() {
                    b"failure" => in_failure = false,
                    b"testcase" => {
                        if let Some(case) = current.take() {
                            cases.push(case);
                        }
                    }
                    _ => {}
                },
                Event::Eof => break,
                _ => {}
            }
            buffer.clear();
        }
        if let Some(case) = current.take() {
            cases.push(case);
        }
    }
    found.then_some(cases)
}

fn xml(value: &str) -> String {
    let value: String = value
        .chars()
        .filter(|character| matches!(*character, '\t' | '\n' | '\r') || *character >= '\u{20}')
        .collect();
    quick_xml::escape::escape(&value).into_owned()
}

/// Render cases back to one junit document, attribute values escaped.
pub fn write_junit(cases: &[Case]) -> String {
    let tests = cases.len();
    let failures = cases.iter().filter(|case| case.message.is_some()).count();
    let mut body = String::new();
    for case in cases {
        let drv = case
            .drv
            .as_deref()
            .map(|drv| format!(" drv=\"{}\"", xml(drv)))
            .unwrap_or_default();
        body += &format!(
            "<testcase classname=\"{}\" name=\"{}\" time=\"{}\"{drv}>",
            xml(&case.class),
            xml(&case.attr),
            case.duration
        );
        if let Some(message) = &case.message {
            // The body is the build log alone: echoing the message there
            // makes a job that never ran look like it produced output, which
            // defeats the transitive classification downstream.
            body += &format!(
                "<failure type=\"BuildFailure\" message=\"{}\">{}</failure>",
                xml(message),
                xml(case.log.as_deref().unwrap_or_default())
            );
        }
        body += "</testcase>";
    }
    format!(
        "<testsuites><testsuite name=\"wasinix\" tests=\"{tests}\" failures=\"{failures}\">{body}</testsuite></testsuites>"
    )
}

pub fn test_outcome(case: &Case) -> super::TestOutcome {
    use super::TestOutcome;
    if case.transitive {
        TestOutcome::Skipped
    } else if case.message.is_some() {
        if case
            .log
            .as_deref()
            .is_some_and(|log| log.contains("XPASS:"))
        {
            TestOutcome::Xpass
        } else {
            TestOutcome::Fail
        }
    } else {
        match case.expectation.as_ref().map(|value| value.outcome) {
            Some(ExpectedOutcome::Xfail) => TestOutcome::Xfail,
            Some(ExpectedOutcome::Broken) => TestOutcome::Broken,
            None => TestOutcome::Pass,
        }
    }
}
