mod naming {
    use crate::support::naming::{axis_of, parse, render, resolve_all, split, Domain};

    #[test]
    fn a_near_miss_suggests_the_closest_addresses() {
        let error = resolve("brotly").unwrap_err().to_string();
        assert!(error.contains("nearest:"), "{error}");
        assert!(error.contains("packagesByProfile.brotli"), "{error}");
    }

    fn domain() -> Domain {
        let mut domain = Domain::new("the list");
        for profile in ["eh", "exnrefEh"] {
            for name in ["zlib", "brotli"] {
                let path = vec![
                    "packagesByProfile".into(),
                    profile.to_string(),
                    name.to_string(),
                ];
                let key = path.join(".");
                let axis = axis_of(&path);
                domain.add_path(path, &key, axis, Vec::new());
            }
        }
        domain.add_path(
            vec!["wasmerPackages".into(), "git".into()],
            "gitMinimal",
            None,
            vec!["gitMinimal".into()],
        );
        domain.add_path(
            vec!["wasmerPackages".into(), "python3.14".into()],
            "python3.14",
            None,
            Vec::new(),
        );
        domain.add_path(
            vec!["pythonWheels".into(), "py314".into(), "zlib".into()],
            "wheel-zlib",
            Some(1),
            Vec::new(),
        );
        // The crate-pins/server shape: one target's declared name is the
        // trailing segment of another's address.
        domain.add_path(
            vec!["cargoRegistry".into(), "crates".into()],
            "crate-pins",
            None,
            vec!["cargo-registry".into()],
        );
        domain.add_path(
            vec!["nativePackages".into(), "cargo-registry".into()],
            "registry-server",
            None,
            vec!["cargo-registry-server".into()],
        );
        domain
    }

    fn resolve(spec: &str) -> crate::support::error::Result<Vec<String>> {
        Ok(resolve_all(&domain(), &[spec.to_string()])?
            .into_iter()
            .map(|hit| hit.key)
            .collect())
    }

    #[test]
    fn a_declared_name_outranks_a_structural_suffix() {
        assert_eq!(resolve("cargo-registry").unwrap(), ["crate-pins"]);
        assert_eq!(resolve("cargo-registry-server").unwrap(), ["registry-server"]);
        assert_eq!(
            resolve("nativePackages.cargo-registry").unwrap(),
            ["registry-server"]
        );
    }

    #[test]
    fn an_address_splits_into_segments_and_a_value() {
        let spec = parse("packagesByProfile.eh.zlib@1.2.3").unwrap();
        assert_eq!(spec.segments, ["packagesByProfile", "eh", "zlib"]);
        assert_eq!(spec.value.as_deref(), Some("1.2.3"));
        assert!(parse("packagesByProfile..zlib").is_err());
        assert!(parse("zlib@").is_err());
    }

    #[test]
    fn a_segment_holding_a_dot_is_quoted_the_way_nix_quotes_it() {
        let spec = parse(r#"wasmerPackages."python3.14""#).unwrap();
        assert_eq!(spec.segments, ["wasmerPackages", "python3.14"]);
        assert_eq!(render(&spec.segments), r#"wasmerPackages."python3.14""#);
        assert!(split(r#"a."b"#).is_err());
    }

    #[test]
    fn a_value_may_hold_the_at_sign_the_address_may_not() {
        let spec = parse("libc@github:wasix-org/wasix-libc@abc").unwrap();
        assert_eq!(spec.segments, ["libc"]);
        assert_eq!(
            spec.value.as_deref(),
            Some("github:wasix-org/wasix-libc@abc")
        );
    }

    #[test]
    fn a_full_path_and_any_suffix_of_it_resolve() {
        assert_eq!(
            resolve("packagesByProfile.eh.brotli").unwrap(),
            ["packagesByProfile.eh.brotli"]
        );
        assert_eq!(
            resolve("eh.brotli").unwrap(),
            ["packagesByProfile.eh.brotli"]
        );
    }

    #[test]
    fn dropping_the_variant_segment_means_every_build_of_it() {
        assert_eq!(
            resolve("packagesByProfile.brotli").unwrap(),
            [
                "packagesByProfile.eh.brotli",
                "packagesByProfile.exnrefEh.brotli"
            ]
        );
        assert_eq!(
            resolve("brotli").unwrap(),
            [
                "packagesByProfile.eh.brotli",
                "packagesByProfile.exnrefEh.brotli"
            ]
        );
    }

    #[test]
    fn matches_that_differ_outside_the_variant_are_ambiguous() {
        // packages.*.zlib and pythonWheels.*.zlib are two different things.
        let error = resolve("zlib").unwrap_err().to_string();
        assert!(error.contains("packagesByProfile.zlib"), "{error}");
        assert!(error.contains("pythonWheels.zlib"), "{error}");
        assert_eq!(
            resolve("packagesByProfile.eh.zlib").unwrap(),
            ["packagesByProfile.eh.zlib"]
        );
    }

    #[test]
    fn an_alias_resolves_to_what_the_command_keys_by() {
        assert_eq!(resolve("wasmerPackages.git").unwrap(), ["gitMinimal"]);
        assert_eq!(resolve("gitMinimal").unwrap(), ["gitMinimal"]);
        assert_eq!(resolve("git").unwrap(), ["gitMinimal"]);
    }

    #[test]
    fn a_glob_stays_inside_one_segment() {
        assert_eq!(
            resolve("packagesByProfile.*.zl*").unwrap(),
            [
                "packagesByProfile.eh.zlib",
                "packagesByProfile.exnrefEh.zlib"
            ]
        );
        // Without the variant segment the pattern is one segment short, so it
        // matches the axis-free form rather than spanning the dot.
        assert_eq!(
            resolve("packagesByProfile.br*").unwrap(),
            [
                "packagesByProfile.eh.brotli",
                "packagesByProfile.exnrefEh.brotli"
            ]
        );
        assert!(resolve("zzz*").is_err());
    }

    #[test]
    fn a_flattened_job_name_is_always_an_address() {
        assert_eq!(
            resolve("wasmerPackages.python3.14").unwrap(),
            ["python3.14"]
        );
        assert_eq!(
            resolve(r#"wasmerPackages."python3.14""#).unwrap(),
            ["python3.14"]
        );
    }

    #[test]
    fn repeated_specs_resolve_once() {
        let specs = [
            "eh.brotli".to_string(),
            "packagesByProfile.eh.brotli".to_string(),
        ];
        assert_eq!(resolve_all(&domain(), &specs).unwrap().len(), 1);
    }
}

mod plan {
    use crate::ci::plan::{plan_of, BuildTarget, Phase};
    use crate::ci::types::{
        Build, Case, Diff, Request, RevSource, Selector, SelectorKind, Spot,
    };
    use crate::support::atoms::Rev;

    fn source() -> RevSource {
        RevSource {
            rev: Rev::parse(&"a".repeat(40)).unwrap(),
            patch: None,
            working_tree: false,
        }
    }

    fn build(id: &str, sets: &[&str]) -> Build<RevSource> {
        Build {
            case_id: Some(id.to_string()),
            source: source(),
            selectors: sets
                .iter()
                .map(|name| Selector {
                    kind: SelectorKind::Set,
                    name: name.to_string(),
                })
                .collect(),
            enabled_tags: Vec::new(),
            overrides: Vec::new(),
            from_pr: None,
            on: None,
        }
    }

    fn spot(id: &str, target: &str) -> Spot<RevSource> {
        Spot {
            case_id: Some(id.to_string()),
            source: source(),
            targets: vec![target.to_string()],
            from_source: Vec::new(),
            base: None,
            overrides: Vec::new(),
            from_pr: None,
            on: None,
        }
    }

    fn core_diff() -> Request<RevSource> {
        Request::Diff(Diff {
            baseline: "baseline".into(),
            content_diff: false,
            cases: vec![
                Case::Build(build("baseline", &["core"])),
                Case::Build(build("candidate-1", &["core"])),
            ],
        })
    }

    #[test]
    fn diff_builds_are_advisory_and_candidate_evals_gate() {
        let plan = plan_of(&core_diff(), None, &[]);
        let gate = |id: &str| plan.tasks.iter().find(|t| t.task_id == id).unwrap().gate;
        assert!(!gate("baseline.core"));
        assert!(!gate("candidate-1.core"));
        // Without a candidate evaluation there is nothing to compare; a
        // broken baseline concludes neutral instead, so it never gates.
        assert!(gate("candidate-1.eval"));
        assert!(!gate("baseline.eval"));
        assert!(gate("candidate-1.treefmt"));
        // The baseline is not the submitted tree, so it is never format-checked.
        assert!(!plan.tasks.iter().any(|task| task.task_id == "baseline.treefmt"));
        // The comparison is a fold-time projection, never a task.
        assert!(!plan.tasks.iter().any(|task| task.task_id.starts_with("compare.")));
    }

    #[test]
    fn a_mixed_diff_plans_spot_and_build_as_advisory_cases() {
        let request = Request::Diff(Diff {
            baseline: "baseline".into(),
            content_diff: false,
            cases: vec![
                Case::Build(build("baseline", &["core"])),
                Case::Spot(spot("candidate-1", "exnrefEh.zlib")),
            ],
        });
        let plan = plan_of(&request, None, &[]);
        // A failed spot build still lays out its map and statuses, so a
        // failure both sides share stays the comparison's call.
        assert!(
            !plan
                .tasks
                .iter()
                .find(|task| task.task_id == "candidate-1.spot")
                .unwrap()
                .gate
        );
    }

    #[test]
    fn a_build_request_is_gated_by_its_builds() {
        let plan = plan_of(&Request::Build(build("case", &["core"])), None, &[]);
        assert!(plan.tasks.iter().filter(|t| t.gate).count() == plan.tasks.len());
        assert_eq!(
            plan.tasks
                .iter()
                .find(|task| task.task_id == "case.core")
                .unwrap()
                .phase,
            Phase::Build {
                set: BuildTarget::Core
            }
        );
    }

    #[test]
    fn a_reused_baseline_drops_its_own_work() {
        let plan = plan_of(&core_diff(), None, &["baseline".to_string()]);
        let ids: Vec<&str> = plan.tasks.iter().map(|task| task.task_id.as_str()).collect();
        assert!(!ids.contains(&"baseline.eval-inputs"));
        assert!(!ids.contains(&"baseline.eval"));
        assert!(!ids.contains(&"baseline.core"));
        assert!(ids.contains(&"candidate-1.core"));
    }

    #[test]
    fn build_sections_have_a_stable_order() {
        let plan = plan_of(&Request::Build(build("case", &["all"])), None, &[]);
        let order = |id: &str| plan.tasks.iter().find(|t| t.task_id == id).unwrap().order;
        assert!(order("case.core") < order("case.packages"));
        assert!(order("case.packages") < order("case.python"));
        assert!(order("case.eval-inputs") < order("case.eval"));
        assert!(order("case.eval") < order("case.core"));
    }

    #[test]
    fn every_case_is_evaluated_before_the_build_union() {
        let plan = plan_of(&core_diff(), None, &[]);
        let last_eval = plan
            .tasks
            .iter()
            .filter(|task| task.phase == Phase::Eval)
            .map(|task| task.order)
            .max()
            .unwrap();
        let first_build = plan
            .tasks
            .iter()
            .filter(|task| matches!(task.phase, Phase::Build { .. }))
            .map(|task| task.order)
            .min()
            .unwrap();
        assert!(last_eval < first_build);
    }

    #[test]
    fn phases_spell_camel_case_on_the_wire() {
        let plan = plan_of(&Request::Build(build("case", &["core"])), None, &[]);
        let value = serde_json::to_value(&plan.tasks).unwrap();
        let phases: Vec<&str> = value
            .as_array()
            .unwrap()
            .iter()
            .map(|task| task["phase"].as_str().unwrap())
            .collect();
        assert!(phases.contains(&"evalInputs"), "{phases:?}");
    }

    #[test]
    fn requests_round_trip_through_their_envelope() {
        use crate::support::schema;
        let request = crate::ci::types::ResolvedRequest::Build(build("case", &["core"]));
        let value = schema::to_value(&request).unwrap();
        assert_eq!(value["kind"], "request");
        assert_eq!(value["action"], "build");
        assert!(value.get("overrides").is_none(), "empty lists stay absent");
        let back: crate::ci::types::ResolvedRequest =
            schema::from_value(value, "test").unwrap();
        assert_eq!(back, request);
    }
}

mod evalmap {
    use crate::ci::evalmap::{EvalMap, JobInfo};
    use crate::support::atoms::JobAddr;

    fn map() -> EvalMap {
        let mut map = EvalMap::default();
        for (name, tags) in [
            ("packagesByProfile.eh.zlib", vec![]),
            ("packagesByProfile.exnrefEh.zlib", vec![]),
            ("checks.bench-heavy", vec!["benchmark".to_string()]),
        ] {
            map.jobs.insert(JobAddr(name.into()), format!("/nix/store/{name}.drv"));
            map.info.insert(
                JobAddr(name.into()),
                JobInfo {
                    tags,
                    ..JobInfo::default()
                },
            );
        }
        map.sets
            .insert("packages".into(), vec!["packagesByProfile.eh.zlib".into()]);
        map
    }

    #[test]
    fn an_axis_free_address_selects_every_build() {
        let jobs = map().resolve_jobs(&["packagesByProfile.zlib".into()]).unwrap();
        assert_eq!(
            jobs,
            ["packagesByProfile.eh.zlib", "packagesByProfile.exnrefEh.zlib"]
        );
    }

    #[test]
    fn an_explicitly_selected_gated_job_is_rejected_with_its_tags() {
        let error = map()
            .resolve_enabled_jobs(&["checks.bench-heavy".into()], &[])
            .unwrap_err()
            .to_string();
        assert!(error.contains("benchmark"), "{error}");
        assert!(error.contains("--enable-tag"), "{error}");
        let jobs = map()
            .resolve_enabled_jobs(&["checks.bench-heavy".into()], &["benchmark".into()])
            .unwrap();
        assert_eq!(jobs, ["checks.bench-heavy"]);
    }

    #[test]
    fn tag_omission_is_countable_never_silent() {
        let omitted = map().omitted_by_tags(&[]);
        assert_eq!(omitted["benchmark"], [JobAddr("checks.bench-heavy".into())]);
        assert!(map().omitted_by_tags(&["benchmark".into()]).is_empty());
    }

    #[test]
    fn published_maps_carry_the_envelope() {
        use crate::support::schema::{self, Document};
        assert_eq!(EvalMap::SCHEMA, 1);
        let value = schema::to_value(&map()).unwrap();
        assert_eq!(value["kind"], "evalMap");
        let back: EvalMap = schema::from_value(value, "test").unwrap();
        assert_eq!(back, map());
    }
}

mod authorization {
    use crate::ci::origin::{
        authorize, extract_command, validate, verify, Api, Classifier, CommandKind,
        Origin,
    };
    use crate::support::error::{request_error, Result};
    use crate::support::schema;
    use serde_json::{json, Value};

    struct Fake(Value);

    impl Api for Fake {
        fn get(&self, path: &str) -> Result<Value> {
            let key = if path.contains("/issues/comments/") {
                "comment"
            } else if path.contains("/collaborators/") {
                "permission"
            } else {
                "pull"
            };
            Ok(self.0[key].clone())
        }
    }

    /// Stands in for the clap re-entry the CLI layer provides: recognizes the
    /// verbs and refuses the machine-only flags an untrusted caller may not
    /// pass.
    struct Grammar;

    impl Classifier for Grammar {
        fn classify(&self, command: &str) -> Result<CommandKind> {
            for banned in ["--local", "--dry-run", "--on"] {
                if command.contains(banned) {
                    return request_error(format!("{banned} is not accepted from a comment"));
                }
            }
            match command.split_whitespace().next().unwrap_or_default() {
                "build" | "spot" | "diff" => Ok(CommandKind::Build),
                other => request_error(format!("unknown command {other:?}")),
            }
        }
    }

    fn api(overrides: Value) -> Fake {
        let mut value = json!({
            "comment": {
                "user": {"login": "SomeOne"},
                "issue_url": "https://api.github.com/repos/wasix-org/wasix-libc/issues/7",
                "body": "/wasinix build core",
            },
            "pull": {
                "state": "open",
                "base": {"repo": {"full_name": "wasix-org/wasix-libc"}},
                "head": {"sha": "b".repeat(40)},
            },
            "permission": {"role_name": "write"},
        });
        for (key, patch) in overrides.as_object().unwrap() {
            for (field, item) in patch.as_object().unwrap() {
                value[key][field] = item.clone();
            }
        }
        Fake(value)
    }

    fn origin() -> Origin {
        Origin {
            repository: "wasix-org/wasix-libc".into(),
            pull_request: 7,
            head_sha: "b".repeat(40),
            comment_id: 99,
            actor: "someone".into(),
        }
    }

    fn origin_value() -> Value {
        schema::to_value(&origin()).unwrap()
    }

    /// The document envelope reserves the top-level "kind" and "schema"
    /// keys; a document field serializing to either panics at write. The
    /// authorize document is the one that collided in production.
    #[test]
    fn the_command_document_round_trips_through_its_envelope() {
        let command = crate::ci::origin::Command {
            command: "build checks.zlib".into(),
            kind: "build".into(),
            origin: origin(),
        };
        let value = schema::to_value(&command).unwrap();
        assert_eq!(value["kind"], "ciCommand");
        assert_eq!(value["commandKind"], "build");
        let scratch = crate::support::fs::Scratch::create("wasinix-test").unwrap();
        let path = scratch.path().join("command.json");
        schema::write(&path, &command).unwrap();
        let read: crate::ci::origin::Command = schema::read(&path).unwrap();
        assert_eq!(read, command);
    }

    #[test]
    fn shape_is_checked_before_anything_else() {
        assert!(validate(&origin_value(), Some("wasix-org")).is_ok());
        assert!(validate(&origin_value(), Some("someone-else")).is_err());
        let mut bad = origin_value();
        bad["headSha"] = json!("B".repeat(40));
        assert!(validate(&bad, None).is_err());
        let mut bad = origin_value();
        bad["pullRequest"] = json!(0);
        assert!(validate(&bad, None).is_err());
        let mut bad = origin_value();
        bad["extra"] = json!(1);
        assert!(validate(&bad, None).is_err());
        let mut bad = origin_value();
        bad["schema"] = json!(9);
        assert!(validate(&bad, None).is_err());
    }

    #[test]
    fn a_matching_comment_verifies() {
        assert!(verify(&origin(), "build core", &api(json!({})), &Grammar).is_ok());
    }

    #[test]
    fn a_forged_origin_is_refused() {
        let cases = [
            json!({"comment": {"user": {"login": "someone-else"}}}),
            json!({"comment": {"issue_url": "https://api.github.com/repos/wasix-org/wasix-libc/issues/8"}}),
            json!({"comment": {"body": "hello"}}),
            json!({"permission": {"role_name": "triage"}}),
            json!({"pull": {"head": {"sha": "c".repeat(40)}}}),
        ];
        for case in cases {
            assert!(
                verify(&origin(), "build core", &api(case.clone()), &Grammar).is_err(),
                "expected {case} to be refused"
            );
        }
    }

    #[test]
    fn a_different_dispatched_command_is_refused() {
        assert!(verify(&origin(), "build packages", &api(json!({})), &Grammar).is_err());
    }

    fn event(body: &str) -> Value {
        json!({
            "action": "created",
            "issue": {"number": 7, "pull_request": {"url": "x"}},
            "comment": {"id": 99, "body": body, "user": {"login": "someone"}},
            "repository": {"full_name": "wasix-org/wasix-libc"},
        })
    }

    #[test]
    fn an_authorized_comment_becomes_a_command() {
        let accepted = authorize(
            &event("/wasinix build core"),
            &api(json!({})),
            &Grammar,
            Some("wasix-org"),
        )
        .unwrap();
        assert_eq!(accepted.command, "build core");
        assert_eq!(accepted.kind, "build");
        assert_eq!(accepted.origin.head_sha, "b".repeat(40));
    }

    #[test]
    fn read_permission_cannot_start_a_run() {
        assert!(authorize(
            &event("/wasinix build core"),
            &api(json!({"permission": {"role_name": "triage"}})),
            &Grammar,
            Some("wasix-org"),
        )
        .is_err());
    }

    #[test]
    fn comment_commands_go_through_the_one_parser() {
        for body in [
            "/wasinix build core --local",
            "/wasinix spot eh.zlib --dry-run",
            "/wasinix",
            "build core",
        ] {
            assert!(
                authorize(&event(body), &api(json!({})), &Grammar, Some("wasix-org")).is_err(),
                "expected {body:?} to be rejected"
            );
        }
    }

    #[test]
    fn an_unknown_command_is_refused_before_dispatch() {
        let error = authorize(
            &event("/wasinix update wasmer=7.2.0"),
            &api(json!({})),
            &Grammar,
            Some("wasix-org"),
        )
        .unwrap_err()
        .to_string();
        assert!(error.contains("unknown command"), "{error}");
    }

    #[test]
    fn a_closed_pull_request_is_refused() {
        assert!(authorize(
            &event("/wasinix build core"),
            &api(json!({"pull": {"state": "closed"}})),
            &Grammar,
            Some("wasix-org"),
        )
        .is_err());
    }

    #[test]
    fn directives_are_found_on_any_line_crlf_and_prose_tolerant() {
        let body = "Looks good!\r\n\r\n/wasinix build core\r\n\r\nthanks!";
        assert_eq!(extract_command(body).unwrap(), "build core");
        assert_eq!(
            extract_command("  /WASINIX build core").unwrap(),
            "build core"
        );
        assert!(extract_command("/wasinixbuild core").is_err());
        assert!(extract_command("nothing here").is_err());
        let twice = "/wasinix build core\n/wasinix build packages";
        assert!(extract_command(twice).is_err());
    }


}

mod compare {
    use crate::ci::compare::{compare_loaded, BuildDiff, Comparison, EvalDiff};
    use crate::ci::evalmap::{EvalMap, JobInfo, StatusMap};
    use crate::ci::types::{Build, CaseRef, RevSource, Selector, SelectorKind, Spot};
    use crate::support::atoms::{JobAddr, JobStatus, Rev};

    /// The tests exercise one-candidate comparisons over loaded state, the
    /// same core [`crate::ci::compare::project`] drives.
    fn compare_cases(
        base_case: &Build<RevSource>,
        base_map: &EvalMap,
        base_status: &StatusMap,
        head_case: &Build<RevSource>,
        head_map: &EvalMap,
        head_status: &StatusMap,
    ) -> crate::support::error::Result<(EvalDiff, BuildDiff)> {
        let (eval, builds) = compare_loaded(
            crate::ci::types::CaseRef::Build(base_case),
            base_map,
            crate::ci::types::CaseRef::Build(head_case),
            head_map,
            Some((base_status, head_status)),
        )?;
        Ok((eval, builds.expect("statuses were given")))
    }

    fn source(fill: char) -> RevSource {
        RevSource {
            rev: Rev::parse(&fill.to_string().repeat(40)).unwrap(),
            patch: None,
            working_tree: false,
        }
    }

    fn case(jobs: &[&str]) -> Build<RevSource> {
        Build {
            case_id: Some("case".into()),
            source: source('a'),
            selectors: jobs
                .iter()
                .map(|name| Selector {
                    kind: SelectorKind::Job,
                    name: name.to_string(),
                })
                .collect(),
            enabled_tags: Vec::new(),
            overrides: Vec::new(),
            from_pr: None,
            on: None,
        }
    }

    fn map(jobs: &[(&str, &str)]) -> EvalMap {
        EvalMap {
            jobs: jobs
                .iter()
                .map(|(name, drv)| (JobAddr(name.to_string()), drv.to_string()))
                .collect(),
            ..Default::default()
        }
    }

    fn status(entries: &[(&str, JobStatus)]) -> StatusMap {
        entries
            .iter()
            .map(|(name, value)| (JobAddr(name.to_string()), *value))
            .collect()
    }

    fn addrs(names: &[&str]) -> Vec<JobAddr> {
        names.iter().map(|name| JobAddr(name.to_string())).collect()
    }

    #[test]
    fn build_and_spot_compare_only_their_shared_coverage() {
        let build = case(&[
            "packagesByProfile.exnrefEh.zlib",
            "packagesByProfile.exnrefEh.curl",
        ]);
        let spot = Spot {
            case_id: Some("candidate-1".into()),
            source: source('b'),
            targets: vec!["packagesByProfile.zlib".into()],
            from_source: vec!["toolchain".into()],
            base: Some("a".repeat(40)),
            overrides: Vec::new(),
            from_pr: None,
            on: None,
        };
        let mapping = map(&[
            ("packagesByProfile.exnrefEh.zlib", "/nix/store/zlib.drv"),
            ("packagesByProfile.exnrefEh.curl", "/nix/store/curl.drv"),
        ]);
        let base_status = status(&[
            ("packagesByProfile.exnrefEh.zlib", JobStatus::Success),
            ("packagesByProfile.exnrefEh.curl", JobStatus::Success),
        ]);
        let head_status = status(&[("packagesByProfile.exnrefEh.zlib", JobStatus::Failure)]);
        let (eval, builds) = compare_loaded(
            CaseRef::Build(&build),
            &mapping,
            CaseRef::Spot(&spot),
            &mapping,
            Some((&base_status, &head_status)),
        )
        .unwrap();
        let builds = builds.expect("statuses were given");
        assert_eq!(builds.regressions, addrs(&["packagesByProfile.exnrefEh.zlib"]));
        assert!(eval.removed.is_empty());
        assert_eq!(eval.selected_count, 1);
    }

    #[test]
    fn transitions_are_classified() {
        let names = [
            ("regressed", "/nix/store/a.drv"),
            ("fixed", "/nix/store/b.drv"),
            ("existing", "/nix/store/c.drv"),
        ];
        let (_, builds) = compare_cases(
            &case(&["regressed", "fixed", "existing"]),
            &map(&names),
            &status(&[
                ("regressed", JobStatus::Success),
                ("fixed", JobStatus::Failure),
                ("existing", JobStatus::Failure),
            ]),
            &case(&["regressed", "fixed", "existing"]),
            &map(&names),
            &status(&[
                ("regressed", JobStatus::Failure),
                ("fixed", JobStatus::Success),
                ("existing", JobStatus::Failure),
            ]),
        )
        .unwrap();
        assert_eq!(builds.regressions, addrs(&["regressed"]));
        assert_eq!(builds.fixes, addrs(&["fixed"]));
        assert_eq!(builds.existing_failures, addrs(&["existing"]));
    }

    #[test]
    fn new_and_dropped_jobs_count_as_regressions() {
        let (_, builds) = compare_cases(
            &case(&["kept", "dropped"]),
            &map(&[
                ("kept", "/nix/store/a.drv"),
                ("dropped", "/nix/store/d.drv"),
            ]),
            &status(&[
                ("kept", JobStatus::Success),
                ("dropped", JobStatus::Success),
            ]),
            &case(&["kept", "fresh"]),
            &map(&[("kept", "/nix/store/a.drv"), ("fresh", "/nix/store/f.drv")]),
            &status(&[("kept", JobStatus::Success), ("fresh", JobStatus::Failure)]),
        )
        .unwrap();
        assert!(builds.regressions.is_empty());
        assert_eq!(builds.new_failures, addrs(&["fresh"]));
        assert_eq!(builds.dropped_successes, addrs(&["dropped"]));
        assert_eq!(builds.regression_count(), 2);
    }

    #[test]
    fn a_non_signal_derivation_is_not_reported_as_rebuilt() {
        let mut head = map(&[("job", "/nix/store/moved.drv")]);
        head.info.insert(
            JobAddr("job".into()),
            JobInfo {
                rebuild_signal: false,
                ..Default::default()
            },
        );
        let (eval, _) = compare_cases(
            &case(&["job"]),
            &map(&[("job", "/nix/store/a.drv")]),
            &StatusMap::new(),
            &case(&["job"]),
            &head,
            &StatusMap::new(),
        )
        .unwrap();
        assert!(eval.rebuilt.is_empty());
    }

    #[test]
    fn new_eval_errors_are_regressions() {
        let mut head = EvalMap::default();
        head.errors.insert(JobAddr("job".into()), "broken".into());
        let (eval, builds) = compare_cases(
            &case(&["job"]),
            &map(&[("job", "/nix/store/a.drv")]),
            &StatusMap::new(),
            &case(&["job"]),
            &head,
            &StatusMap::new(),
        )
        .unwrap();
        assert_eq!(eval.new_eval_errors, addrs(&["job"]));
        let comparison = Comparison {
            candidate: "candidate-1".into(),
            base_evaluated: true,
            head_evaluated: true,
            eval: Some(eval),
            builds: Some(builds),
        };
        assert_eq!(comparison.regression_count(), 1);
    }

    #[test]
    fn identities_surface_publication_only_changes() {
        let info = |version: &str, rel: u32| JobInfo {
            version: Some(serde_json::Value::String(version.into())),
            rel: Some(rel),
            ..Default::default()
        };
        let mut base = map(&[("changed", "/nix/store/a.drv")]);
        base.info.insert(JobAddr("changed".into()), info("1.2.3", 1));
        let mut head = map(&[("changed", "/nix/store/a.drv")]);
        head.info.insert(JobAddr("changed".into()), info("1.2.3", 2));
        let (eval, _) = compare_cases(
            &case(&["changed"]),
            &base,
            &StatusMap::new(),
            &case(&["changed"]),
            &head,
            &StatusMap::new(),
        )
        .unwrap();
        assert_eq!(eval.identity_transitions, ["changed: 1.2.3 -> 1.2.3 r2"]);
        assert!(eval.version_updates.is_empty());
        assert!(eval.rebuilt.is_empty());
    }

    #[test]
    fn version_updates_collect_changelogs_across_variants() {
        let info = |version: &str, changelog: Option<&str>| JobInfo {
            subject: Some("zlib".into()),
            version: Some(serde_json::Value::String(version.into())),
            changelog: changelog.map(str::to_string),
            ..Default::default()
        };
        let jobs = [
            "packagesByProfile.default.zlib",
            "packagesByProfile.pic.zlib",
        ];
        let mut base = map(&[
            (jobs[0], "/nix/store/old-default.drv"),
            (jobs[1], "/nix/store/old-pic.drv"),
        ]);
        base.info.insert(JobAddr(jobs[0].into()), info("1.2.13", None));
        base.info.insert(JobAddr(jobs[1].into()), info("1.2.13", None));
        let mut head = map(&[
            (jobs[0], "/nix/store/new-default.drv"),
            (jobs[1], "/nix/store/new-pic.drv"),
        ]);
        head.info.insert(
            JobAddr(jobs[0].into()),
            info("1.3.1", Some("https://example.com/zlib-1.3.1")),
        );
        head.info.insert(
            JobAddr(jobs[1].into()),
            info("1.3.1", Some("https://example.com/zlib-1.3.1")),
        );

        let (eval, _) = compare_cases(
            &case(&jobs),
            &base,
            &StatusMap::new(),
            &case(&jobs),
            &head,
            &StatusMap::new(),
        )
        .unwrap();

        assert_eq!(eval.version_updates.len(), 1);
        let update = &eval.version_updates[0];
        assert_eq!(update.subject, "zlib");
        assert_eq!(update.before, "1.2.13");
        assert_eq!(update.after, "1.3.1");
        assert_eq!(update.changelogs, ["https://example.com/zlib-1.3.1"]);
        assert_eq!(update.jobs, addrs(&jobs));
    }

    #[test]
    fn same_subject_same_move_different_changelogs_stay_two_rows() {
        let info = |changelog: &str| JobInfo {
            subject: Some("protobuf".into()),
            version: Some(serde_json::Value::String("4.0".into())),
            changelog: Some(changelog.into()),
            ..Default::default()
        };
        let old = |_: &str| JobInfo {
            subject: Some("protobuf".into()),
            version: Some(serde_json::Value::String("3.9".into())),
            ..Default::default()
        };
        let jobs = ["packagesByProfile.eh.protobuf", "pythonWheels.py313.protobuf"];
        let mut base = map(&[(jobs[0], "/a.drv"), (jobs[1], "/b.drv")]);
        base.info.insert(JobAddr(jobs[0].into()), old(""));
        base.info.insert(JobAddr(jobs[1].into()), old(""));
        let mut head = map(&[(jobs[0], "/a2.drv"), (jobs[1], "/b2.drv")]);
        head.info
            .insert(JobAddr(jobs[0].into()), info("https://example.com/cpp"));
        head.info
            .insert(JobAddr(jobs[1].into()), info("https://example.com/py"));

        let (eval, _) = compare_cases(
            &case(&jobs),
            &base,
            &StatusMap::new(),
            &case(&jobs),
            &head,
            &StatusMap::new(),
        )
        .unwrap();
        assert_eq!(eval.version_updates.len(), 2);
        let all_changelogs: Vec<&str> = eval
            .version_updates
            .iter()
            .flat_map(|u| u.changelogs.iter().map(String::as_str))
            .collect();
        assert!(all_changelogs.contains(&"https://example.com/cpp"));
        assert!(all_changelogs.contains(&"https://example.com/py"));
        for update in &eval.version_updates {
            assert_eq!(update.changelogs.len(), 1, "no unioned changelog rows");
        }
    }

    #[test]
    fn an_empty_comparison_reports_no_regressions() {
        assert_eq!(Comparison::default().regression_count(), 0);
    }

    /// The projection over a run directory grows with what is on disk: no
    /// head map means no eval half, statuses on both sides bring the build
    /// half, and a finished run computes it regardless so absence reads as
    /// incompleteness instead of a clean pass.
    #[test]
    fn the_projection_tracks_what_the_run_dir_holds() {
        use crate::ci::types::{Case, Diff, Request};
        let scratch = crate::support::fs::Scratch::create("wasinix-test").unwrap();
        let run_dir = scratch.path();
        let request = Request::Diff(Diff {
            baseline: "baseline".into(),
            content_diff: false,
            cases: vec![
                Case::Build(Build {
                    case_id: Some("baseline".into()),
                    ..case(&["job"])
                }),
                Case::Build(Build {
                    case_id: Some("candidate-1".into()),
                    ..case(&["job"])
                }),
            ],
        });
        let write_map = |id: &str, drv: &str| {
            let dir = crate::ci::prepare::case_dir(run_dir, id);
            crate::support::fs::create_dir_all(&crate::ci::prepare::maps_dir(&dir)).unwrap();
            crate::support::schema::write(
                &crate::ci::prepare::eval_map_path(&dir),
                &map(&[("job", drv)]),
            )
            .unwrap();
        };
        let write_status = |id: &str, value: JobStatus| {
            let dir = crate::ci::prepare::case_dir(run_dir, id);
            crate::support::schema::write(
                &crate::ci::prepare::status_path(&dir),
                &crate::ci::compare::JobStatuses {
                    statuses: status(&[("job", value)]),
                },
            )
            .unwrap();
        };

        write_map("baseline", "/nix/store/a.drv");
        let early = crate::ci::compare::project(run_dir, &request, false).unwrap();
        assert_eq!(early.len(), 1);
        assert!(early[0].base_evaluated && !early[0].head_evaluated);
        assert!(early[0].eval.is_none());

        write_map("candidate-1", "/nix/store/b.drv");
        let evaluated = crate::ci::compare::project(run_dir, &request, false).unwrap();
        assert!(evaluated[0].eval.is_some(), "eval half appears with both maps");
        assert!(evaluated[0].builds.is_none(), "no statuses yet");

        write_status("baseline", JobStatus::Success);
        write_status("candidate-1", JobStatus::Failure);
        let built = crate::ci::compare::project(run_dir, &request, false).unwrap();
        let builds = built[0].builds.as_ref().expect("statuses on both sides");
        assert_eq!(builds.regressions, addrs(&["job"]));

        let finished = crate::ci::compare::project(run_dir, &request, true).unwrap();
        assert!(finished[0].builds.is_some());
    }
}

mod route {
    use std::path::PathBuf;
    use std::process::Command;

    use crate::nix::builder::{Builder, Capability};
    use crate::nix::route::{
        EvaluationLimits, Route, DEFAULT_EVAL_MEMORY, DEFAULT_EVAL_TIMEOUT_SECONDS,
        DEFAULT_LOCAL_EVAL_WORKERS, DEFAULT_REMOTE_EVAL_WORKERS,
    };

    pub(super) fn builder() -> Builder {
        Builder {
            name: "test".into(),
            description: None,
            host: "builder@example".into(),
            key: PathBuf::from("/key"),
            daemon_key: "/daemon-key".into(),
            system: "x86_64-linux".into(),
            max_jobs: "4".into(),
            features: "benchmark".into(),
            host_key: "-".into(),
            store_url: Some("ssh-ng://builder@example".into()),
            builders_spec: Some("ssh-ng://builder@example x86_64-linux".into()),
            capabilities: vec![Capability::Builder, Capability::Store],
            capacity: 1,
            max_load: None,
            substituters: Vec::new(),
            trusted_public_keys: Vec::new(),
            route: None,
            eval_workers: None,
            eval_memory: None,
        }
    }

    fn args(command: &Command) -> Vec<String> {
        command
            .get_args()
            .map(|arg| arg.to_string_lossy().into_owned())
            .collect()
    }

    #[test]
    fn lease_slots_exhaust_release_and_reclaim() {
        let scratch = crate::support::fs::Scratch::create("wasinix-test").unwrap();
        let root = scratch.path().join("slots");
        let held = crate::nix::builder::acquire_slots(&root, 1, "test host").unwrap();
        let error = crate::nix::builder::acquire_slots(&root, 1, "test host")
            .unwrap_err()
            .to_string();
        assert!(error.contains("in use"), "{error}");
        drop(held);
        let reacquired = crate::nix::builder::acquire_slots(&root, 1, "test host").unwrap();
        drop(reacquired);

        // A slot whose recorded holder is dead is reclaimed, not respected.
        std::fs::write(root.join("0.json"), "{\"pid\": 4294967294, \"startedAt\": 1}").unwrap();
        let reclaimed = crate::nix::builder::acquire_slots(&root, 1, "test host").unwrap();
        drop(reclaimed);

        // A live pid with the wrong start time is a recycled pid, so the
        // slot is not held: liveness alone must not pin a slot forever.
        std::fs::write(
            root.join("0.json"),
            format!(
                "{{\"pid\": {}, \"startedAt\": 1, \"pidStarted\": 1}}",
                std::process::id()
            ),
        )
        .unwrap();
        crate::nix::builder::acquire_slots(&root, 1, "test host").unwrap();
    }

    #[test]
    fn local_evaluation_defaults_are_bounded() {
        let limits = EvaluationLimits::local().unwrap();
        if crate::support::env::eval_workers().unwrap().is_none() {
            assert_eq!(limits.workers, DEFAULT_LOCAL_EVAL_WORKERS);
        }
        if crate::support::env::eval_memory().unwrap().is_none() {
            assert_eq!(limits.memory, DEFAULT_EVAL_MEMORY);
        }
        if crate::support::env::eval_timeout().unwrap().is_none() {
            assert_eq!(limits.timeout.as_secs(), DEFAULT_EVAL_TIMEOUT_SECONDS);
        }
    }

    #[test]
    fn only_host_routes_get_remote_evaluation_workers() {
        let caller_limits = Route::Builder(builder()).limits().unwrap();
        let host_limits = Route::Host(builder()).limits().unwrap();
        if crate::support::env::eval_workers().unwrap().is_none() {
            assert_eq!(caller_limits.workers, DEFAULT_LOCAL_EVAL_WORKERS);
            assert_eq!(host_limits.workers, DEFAULT_REMOTE_EVAL_WORKERS);
        }
    }

    #[test]
    fn store_evaluation_uses_a_local_eval_store() {
        let route = Route::Store(builder());
        let mut command = Command::new("nix");
        route.configure_nix(&mut command).unwrap();
        assert_eq!(
            args(&command),
            [
                "--store",
                "ssh-ng://builder@example",
                "--eval-store",
                "auto"
            ]
        );
    }

    #[test]
    fn builder_evaluation_disables_local_build_slots() {
        let route = Route::Builder(builder());
        let mut command = Command::new("nix-eval-jobs");
        route.configure_eval_jobs(&mut command).unwrap();
        assert_eq!(
            args(&command),
            [
                "--option",
                "builders",
                "ssh-ng://builder@example x86_64-linux",
                "--option",
                "max-jobs",
                "0",
                "--option",
                "builders-use-substitutes",
                "true"
            ]
        );
    }

    #[test]
    fn a_local_route_pins_builds_to_this_machine() {
        let route = Route::Local(EvaluationLimits::local().unwrap());
        assert_eq!(
            route.build_nix_options(),
            ["--option", "builders", ""]
        );
    }

    #[test]
    fn a_host_route_refuses_caller_side_nix_configuration() {
        let route = Route::Host(builder());
        let mut command = Command::new("nix");
        let error = route.configure_nix(&mut command).unwrap_err().to_string();
        assert!(error.contains("host"), "{error}");
    }
}

mod runs {
    use crate::runs::{observed, supervise, Run, LOG_FILE, RUN_FILE};
    use crate::support::atoms::RunState;
    use crate::support::fs::Scratch;
    use crate::support::schema;
    use crate::support::time::unix_secs;

    fn seed(dir: &std::path::Path, command: &[&str], pid: u32, started_at: u64) {
        schema::write(
            &dir.join(RUN_FILE),
            &Run {
                run_id: "test-run".into(),
                command: command.iter().map(|s| s.to_string()).collect(),
                state: RunState::Starting,
                pid,
                started_at,
                finished_at: None,
                exit_code: None,
            },
        )
        .unwrap();
    }

    #[test]
    fn the_supervisor_records_the_payloads_exit_and_log() {
        let scratch = Scratch::create("wasinix-test").unwrap();
        seed(scratch.path(), &["sh", "-c", "echo tee-me; exit 0"], 0, unix_secs());
        supervise(
            scratch.path(),
            &["sh".into(), "-c".into(), "echo tee-me; exit 0".into()],
        )
        .unwrap();
        let run = observed(scratch.path()).unwrap();
        assert_eq!(run.state, RunState::Complete);
        assert_eq!(run.exit_code, Some(0));
        let log = std::fs::read_to_string(scratch.path().join(LOG_FILE)).unwrap();
        assert!(log.contains("tee-me"), "{log}");
        let events = crate::ci::events::read_all(scratch.path()).unwrap();
        assert!(matches!(events.last(), Some(crate::ci::events::Event::RunFinished { state: RunState::Complete, .. })));
    }

    #[test]
    fn a_failing_payload_records_failed_with_its_code() {
        let scratch = Scratch::create("wasinix-test").unwrap();
        seed(scratch.path(), &["sh", "-c", "exit 7"], 0, unix_secs());
        let error = supervise(scratch.path(), &["sh".into(), "-c".into(), "exit 7".into()])
            .unwrap_err()
            .to_string();
        assert!(error.contains("exit code 7"), "{error}");
        let run = observed(scratch.path()).unwrap();
        assert_eq!(run.state, RunState::Failed);
        assert_eq!(run.exit_code, Some(7));
    }

    #[test]
    fn the_payload_always_receives_the_run_dir() {
        let scratch = Scratch::create("wasinix-test").unwrap();
        seed(scratch.path(), &["sh"], 0, unix_secs());
        let sink = scratch.path().join("args");
        supervise(
            scratch.path(),
            &[
                "sh".into(),
                "-c".into(),
                format!("echo \"$@\" > {}", sink.display()),
                "_".into(),
            ],
        )
        .unwrap();
        let args = std::fs::read_to_string(&sink).unwrap();
        assert!(args.trim().ends_with(&format!("--run-dir {}", scratch.path().display())), "{args}");
    }

    #[test]
    fn a_payload_naming_the_run_dir_gets_no_appended_flag() {
        let scratch = Scratch::create("wasinix-test").unwrap();
        seed(scratch.path(), &["sh"], 0, unix_secs());
        let sink = scratch.path().join("args");
        supervise(
            scratch.path(),
            &[
                "sh".into(),
                "-c".into(),
                format!("echo \"$@\" > {}", sink.display()),
                "_".into(),
                "--run-dir".into(),
                scratch.path().display().to_string(),
            ],
        )
        .unwrap();
        let args = std::fs::read_to_string(&sink).unwrap();
        assert_eq!(args.trim().matches("--run-dir").count(), 1, "{args}");
    }

    #[test]
    fn a_supervisor_that_cannot_start_its_payload_records_the_failure() {
        let scratch = Scratch::create("wasinix-test").unwrap();
        seed(scratch.path(), &["wasinix-no-such-program"], 0, unix_secs());
        supervise(scratch.path(), &["wasinix-no-such-program".into()]).unwrap_err();
        let run = observed(scratch.path()).unwrap();
        assert_eq!(run.state, RunState::Failed);
        let events = crate::ci::events::read_all(scratch.path()).unwrap();
        assert!(matches!(
            events.last(),
            Some(crate::ci::events::Event::RunFinished {
                state: RunState::Failed,
                ..
            })
        ));
    }

    #[test]
    fn a_dead_supervisor_reads_as_lost_and_a_young_start_does_not() {
        let scratch = Scratch::create("wasinix-test").unwrap();
        seed(scratch.path(), &["sh"], 0, unix_secs());
        assert_eq!(observed(scratch.path()).unwrap().state, RunState::Starting);
        seed(scratch.path(), &["sh"], 0, unix_secs() - 120);
        assert_eq!(observed(scratch.path()).unwrap().state, RunState::Lost);
        seed(scratch.path(), &["sh"], 4_000_000, unix_secs());
        assert_eq!(observed(scratch.path()).unwrap().state, RunState::Lost);
        // Our own pid is alive but does not name this run directory in its
        // command line, so it is not mistaken for the supervisor.
        seed(scratch.path(), &["sh"], std::process::id(), unix_secs());
        assert_eq!(observed(scratch.path()).unwrap().state, RunState::Lost);
    }
}

mod events {
    use crate::ci::events::{
        append, fold_snapshot, read_all, read_from, Event, Tracker, FILE,
    };
    use crate::support::atoms::{JobAddr, JobStatus, RunState, TaskStatus};
    use crate::support::fs::Scratch;

    fn job(at: u64, name: &str, status: JobStatus, cached: bool) -> Event {
        Event::JobFinished {
            at,
            job: JobAddr(name.into()),
            status,
            cached,
            duration_seconds: None,
            error: None,
        }
    }

    #[test]
    fn a_stream_round_trips_and_resumes_from_an_offset() {
        let scratch = Scratch::create("wasinix-test").unwrap();
        append(scratch.path(), &Event::RunStarted { at: 1, pid: 42 }).unwrap();
        append(scratch.path(), &job(2, "checks.zlib", JobStatus::Success, true)).unwrap();
        let (events, offset) = read_from(&scratch.path().join(FILE), 0).unwrap();
        assert_eq!(events.len(), 2);
        append(scratch.path(), &job(3, "checks.git", JobStatus::Failure, false)).unwrap();
        let (tail, _) = read_from(&scratch.path().join(FILE), offset).unwrap();
        assert_eq!(tail.len(), 1);
        assert!(matches!(&tail[0], Event::JobFinished { job, .. } if job.as_str() == "checks.git"));
    }

    #[test]
    fn a_torn_tail_line_waits_and_a_torn_middle_line_fails() {
        let scratch = Scratch::create("wasinix-test").unwrap();
        append(scratch.path(), &Event::Heartbeat { at: 1 }).unwrap();
        let path = scratch.path().join(FILE);
        let mut text = std::fs::read_to_string(&path).unwrap();
        text.push_str("{\"schema\":1,\"event\":\"heartbeat\"");
        std::fs::write(&path, &text).unwrap();
        let (events, _) = read_from(&path, 0).unwrap();
        assert_eq!(events.len(), 1, "in-flight tail line is left for later");
        std::fs::write(&path, "{ torn\n{\"schema\":1}\n").unwrap();
        assert!(read_from(&path, 0).is_err());
    }

    #[test]
    fn the_tail_stops_on_run_finished_without_consulting_drained() {
        let scratch = Scratch::create("wasinix-test").unwrap();
        append(scratch.path(), &Event::RunStarted { at: 1, pid: 42 }).unwrap();
        append(scratch.path(), &job(2, "checks.zlib", JobStatus::Success, false)).unwrap();
        append(
            scratch.path(),
            &Event::RunFinished {
                at: 3,
                state: RunState::Complete,
                exit_code: Some(0),
            },
        )
        .unwrap();
        let mut seen = Vec::new();
        crate::ci::events::tail(
            scratch.path(),
            std::time::Duration::from_millis(1),
            |fresh| {
                seen.extend_from_slice(fresh);
                Ok(())
            },
            || panic!("a finished stream never asks whether the run is over"),
        )
        .unwrap();
        assert_eq!(seen.len(), 3);
    }

    #[test]
    fn the_tail_ends_when_drained_and_the_run_is_over() {
        let scratch = Scratch::create("wasinix-test").unwrap();
        append(scratch.path(), &Event::Heartbeat { at: 1 }).unwrap();
        let mut seen = 0;
        crate::ci::events::tail(
            scratch.path(),
            std::time::Duration::from_millis(1),
            |fresh| {
                seen += fresh.len();
                Ok(())
            },
            || Ok(true),
        )
        .unwrap();
        assert_eq!(seen, 1, "the stream drains fully before drained ends it");
    }

    #[test]
    fn build_start_lines_parse_to_their_union_attr() {
        use crate::ci::exec::building_attr;
        assert_eq!(
            building_attr("  building \"head::checks.zlib\""),
            Some("head::checks.zlib")
        );
        assert_eq!(building_attr("  building x"), Some("x"));
        assert_eq!(building_attr("building x"), None);
        assert_eq!(building_attr("  evaluating y"), None);
    }

    #[test]
    fn the_snapshot_is_a_fold_of_the_stream() {
        let events = [
            Event::RunStarted { at: 1, pid: 7 },
            Event::PhaseStarted {
                at: 2,
                task_id: "case.eval".into(),
                label: "eval".into(),
                jobs: None,
            },
            Event::PhaseFinished {
                at: 3,
                task_id: "case.eval".into(),
                status: TaskStatus::Success,
                headline: "5213 jobs".into(),
            },
            Event::PhaseStarted {
                at: 3,
                task_id: "case.core".into(),
                label: "build core".into(),
                jobs: Some(40),
            },
            Event::JobStarted {
                at: 4,
                job: JobAddr("checks.ok".into()),
            },
            Event::JobStarted {
                at: 4,
                job: JobAddr("checks.curl".into()),
            },
            job(4, "checks.ok", JobStatus::Success, true),
            job(5, "checks.zlib", JobStatus::Failure, false),
        ];
        let snapshot = fold_snapshot(&events);
        assert_eq!(snapshot.state, RunState::Running);
        assert_eq!(snapshot.completed_jobs, 2);
        assert_eq!(snapshot.cached_jobs, 1);
        assert_eq!(snapshot.failed_jobs, 1);
        // A started job leaves the building set when it finishes.
        assert_eq!(snapshot.building, [JobAddr("checks.curl".into())]);
        assert_eq!(snapshot.recent_failures, [JobAddr("checks.zlib".into())]);
        assert_eq!(snapshot.phases.len(), 2);
        assert_eq!(snapshot.phases[0].status, TaskStatus::Success);
        assert_eq!(snapshot.phases[1].jobs, Some(40));
        let done = fold_snapshot(
            &events
                .iter()
                .cloned()
                .chain([Event::RunFinished {
                    at: 6,
                    state: RunState::Failed,
                    exit_code: Some(1),
                }])
                .collect::<Vec<_>>(),
        );
        assert_eq!(done.state, RunState::Failed);
        assert_eq!(done.exit_code, Some(1));
    }

    #[test]
    fn the_tracker_persists_stream_and_snapshot_together() {
        let scratch = Scratch::create("wasinix-test").unwrap();
        let mut tracker = Tracker::new(scratch.path()).unwrap();
        tracker.record(Event::RunStarted { at: 1, pid: 9 }).unwrap();
        tracker
            .record(job(2, "checks.zlib", JobStatus::Failure, false))
            .unwrap();
        let snapshot = crate::ci::events::read_snapshot(scratch.path()).unwrap();
        assert_eq!(snapshot.failed_jobs, 1);
        assert_eq!(read_all(scratch.path()).unwrap().len(), 2);
        // A new tracker over the same dir resumes from the recorded stream.
        let resumed = Tracker::new(scratch.path()).unwrap();
        assert_eq!(resumed.snapshot().failed_jobs, 1);
    }
}

mod exec {
    use std::collections::BTreeMap;

    use serde_json::json;

    use crate::ci::events::{read_all, Event, Tracker};
    use crate::ci::exec::{
        blocked_by_case_failure, cached_jobs, fatal, fixed_output_derivations, project_junit,
        record_result, JobState,
    };
    use crate::ci::plan::{BuildTarget, Phase};
    use crate::support::atoms::JobStatus;
    use crate::support::fs::Scratch;

    fn state(drv: &str, status: Option<JobStatus>) -> JobState {
        JobState {
            drv: drv.into(),
            status,
            duration: None,
            error: None,
        }
    }

    #[test]
    fn evaluation_inputs_select_only_fixed_output_derivations() {
        let graph = json!({
            "/nix/store/source.drv": {
                "outputs": {"out": {"hash": "sha256-example"}}
            },
            "/nix/store/package.drv": {
                "outputs": {"out": {"path": "/nix/store/package"}}
            },
            "/nix/store/multi-source.drv": {
                "outputs": {
                    "out": {"path": "/nix/store/multi-source"},
                    "download": {"hash": "sha256-other"}
                }
            }
        });
        assert_eq!(
            fixed_output_derivations(&graph),
            [
                "/nix/store/multi-source.drv^download",
                "/nix/store/source.drv^out"
            ]
        );
    }

    #[test]
    fn only_fatal_failures_hide_analysis_results() {
        assert!(blocked_by_case_failure(Phase::Eval));
        assert!(blocked_by_case_failure(Phase::Build {
            set: BuildTarget::Packages,
        }));
        // A content diff without its case's eval map can only error; a
        // failed build is not fatal, so analysis still runs after one.
        assert!(blocked_by_case_failure(Phase::Content));
        assert!(!blocked_by_case_failure(Phase::Treefmt));
        assert!(fatal(Phase::Eval));
        assert!(!fatal(Phase::Build {
            set: BuildTarget::Packages,
        }));
    }

    #[test]
    fn stream_results_mark_shared_derivations_once() {
        let scratch = Scratch::create("wasinix-test").unwrap();
        let mut tracker = Tracker::new(scratch.path()).unwrap();
        let mut jobs = BTreeMap::new();
        jobs.insert("head::a".to_string(), state("/nix/store/x.drv", None));
        jobs.insert("head::b".to_string(), state("/nix/store/x.drv", None));
        jobs.insert("head::c".to_string(), state("/nix/store/y.drv", None));

        let built =
            json!({"type": "BUILD", "attr": "\"head::a\"", "success": true, "duration": 2.5});
        record_result(&built, &mut jobs, &mut tracker).unwrap();
        assert_eq!(jobs["head::a"].status, Some(JobStatus::Success));
        assert_eq!(
            jobs["head::b"].status,
            Some(JobStatus::Success),
            "a shared derivation finishes every job it builds"
        );
        assert_eq!(jobs["head::c"].status, None);

        let eval_ok = json!({"type": "EVAL", "attr": "\"head::c\"", "success": true});
        record_result(&eval_ok, &mut jobs, &mut tracker).unwrap();
        assert_eq!(jobs["head::c"].status, None, "a clean EVAL says nothing");
        let eval_bad =
            json!({"type": "EVAL", "attr": "\"head::c\"", "success": false, "error": "nope"});
        record_result(&eval_bad, &mut jobs, &mut tracker).unwrap();
        assert_eq!(jobs["head::c"].status, Some(JobStatus::Failure));
        assert_eq!(jobs["head::c"].error.as_deref(), Some("nope"));

        record_result(&built, &mut jobs, &mut tracker).unwrap();
        let finished = read_all(scratch.path())
            .unwrap()
            .into_iter()
            .filter(|event| matches!(event, Event::JobFinished { .. }))
            .count();
        assert_eq!(finished, 3, "a repeated report emits no second event");
    }

    #[test]
    fn junit_projection_backfills_unreported_jobs() {
        let scratch = Scratch::create("wasinix-test").unwrap();
        let source = scratch.path().join("results.xml");
        std::fs::write(
            &source,
            concat!(
                "<testsuites><testsuite name=\"x\" tests=\"3\" failures=\"1\">",
                "<testcase classname=\"Build\" name=\"&quot;head::zlib.build&quot;\" time=\"4\">",
                "<failure type=\"BuildFailure\" message=\"boom\">tail</failure></testcase>",
                "<testcase classname=\"Build\" name=\"&quot;head::other.job&quot;\" time=\"1\"></testcase>",
                "<testcase classname=\"Build\" name=\"&quot;base::zlib.build&quot;\" time=\"2\"></testcase>",
                "</testsuite></testsuites>"
            ),
        )
        .unwrap();
        let mut jobs = BTreeMap::new();
        jobs.insert(
            "head::zlib.build".to_string(),
            state("/nix/store/z.drv", Some(JobStatus::Failure)),
        );
        jobs.insert(
            "head::cached.job".to_string(),
            state("/nix/store/c.drv", Some(JobStatus::Success)),
        );
        jobs.insert(
            "head::missing.job".to_string(),
            state("/nix/store/m.drv", None),
        );
        let selected = [
            "zlib.build".to_string(),
            "cached.job".to_string(),
            "missing.job".to_string(),
        ];
        let destination = scratch.path().join("head.xml");
        project_junit(&source, &destination, "head", &selected, &jobs).unwrap();

        let status = crate::ci::compare::junit_status(&[destination]);
        assert_eq!(status.get("zlib.build"), Some(&JobStatus::Failure));
        assert_eq!(
            status.get("cached.job"),
            Some(&JobStatus::Success),
            "a cached job the union never reported projects as success"
        );
        assert_eq!(
            status.get("missing.job"),
            Some(&JobStatus::Failure),
            "an unreported job projects as failure, never as clean"
        );
        assert!(
            !status.contains_key("other.job"),
            "unselected jobs stay out of the case's results"
        );
    }

    #[test]
    fn cached_jobs_come_from_the_evaluation_cache_status() {
        let scratch = Scratch::create("wasinix-test").unwrap();
        let path = scratch.path().join("eval-jobs.jsonl");
        std::fs::write(
            &path,
            concat!(
                "{\"attrPath\":[\"checks\",\"zlib\"],\"drvPath\":\"/nix/store/a.drv\",\"cacheStatus\":\"cached\"}\n",
                "{\"attrPath\":[\"checks\",\"git\"],\"drvPath\":\"/nix/store/b.drv\",\"cacheStatus\":\"notBuilt\"}\n",
            ),
        )
        .unwrap();
        let cached = cached_jobs(&path).unwrap();
        assert!(cached.contains("checks.zlib"));
        assert!(!cached.contains("checks.git"));
    }

    #[test]
    fn an_evaluation_becomes_a_map_with_first_line_errors() {
        let jobs = crate::nix::evaljobs::parse_file(concat!(
            "{\"attrPath\":[\"packagesByProfile\",\"zlib\"],\"drvPath\":\"/nix/store/z.drv\",\"outputs\":{\"out\":\"/nix/store/z\"}}\n",
            "{\"attrPath\":[\"bad\",\"job\"],\"error\":\"boom\\nmore\"}\n",
        ))
        .unwrap();
        let rev = crate::support::atoms::Rev::parse(&"a".repeat(40)).unwrap();
        let map = crate::ci::evalmap::EvalMap::from_jobs(rev, &jobs);
        assert_eq!(
            map.jobs.get("packagesByProfile.zlib").map(String::as_str),
            Some("/nix/store/z.drv")
        );
        assert_eq!(map.errors.get("bad.job").map(String::as_str), Some("boom"));
        assert_eq!(
            map.outputs["packagesByProfile.zlib"]["out"],
            "/nix/store/z"
        );
    }
}

mod cli {
    use clap::Parser;

    use crate::ci::types::{OverrideKind, Request, SelectorKind};
    use crate::cli::{Cli, CommandTree};

    fn parse(words: &[&str]) -> CommandTree {
        Cli::try_parse_from(std::iter::once("wasinix").chain(words.iter().copied()))
            .unwrap()
            .command
    }

    #[test]
    fn start_refuses_wait_and_follow_together() {
        assert!(Cli::try_parse_from([
            "wasinix", "run", "start", "--wait", "--follow", "--", "true"
        ])
        .is_err());
    }

    #[test]
    fn a_bare_subcommand_payload_is_refused_with_the_verbatim_hint() {
        let error = crate::cli::payload_check("build", false).unwrap_err();
        let message = error.to_string();
        assert!(message.contains("verbatim"));
        assert!(message.contains("wasinix run start -- wasinix build"));
        let other = crate::cli::payload_check("no-such-tool", false)
            .unwrap_err()
            .to_string();
        assert!(other.contains("not on PATH"));
        assert!(!other.contains("wasinix no-such-tool"));
        assert!(crate::cli::payload_check("build", true).is_ok());
    }

    #[test]
    fn build_options_are_typed_and_assemble_a_request() {
        let CommandTree::Build(args) = parse(&[
            "build",
            "core",
            "checks.bash-sh",
            "--at",
            "main",
            "--with",
            "wasmer@7.1.0",
            "--with",
            "wasix-libc@rev:abc123",
            "--enable-tag",
            "slow-tests,expensive-build",
            "--on",
            "ec2:store",
            "--json",
        ]) else {
            panic!("expected build");
        };
        assert!(args.mode.json.wants());
        let request =
            crate::cli::request::build_case(&args.request, args.placement.on.clone(), None)
                .unwrap();
        assert_eq!(request.selectors[0].kind, SelectorKind::Set);
        assert_eq!(request.selectors[1].kind, SelectorKind::Job);
        assert_eq!(request.enabled_tags, ["slow-tests", "expensive-build"]);
        assert_eq!(request.overrides[0].kind, OverrideKind::Release);
        assert_eq!(request.overrides[0].value, "7.1.0");
        assert_eq!(request.overrides[1].kind, OverrideKind::Revision);
        assert_eq!(request.overrides[1].value, "abc123");
        assert_eq!(request.on.as_deref(), Some("ec2:store"));
        assert_eq!(request.source.reference, "main");
    }

    #[test]
    fn the_at_separator_is_the_only_override_grammar() {
        let CommandTree::Build(args) = parse(&["build", "all", "--with", "wasmer=7.1.0"]) else {
            panic!("expected build");
        };
        let error = crate::cli::request::build_case(&args.request, None, None)
            .unwrap_err()
            .to_string();
        assert!(error.contains("TARGET@VERSION"), "{error}");
    }

    #[test]
    fn spot_defaults_to_the_toolchain_source_cut() {
        let CommandTree::Spot(args) = parse(&["spot", "packagesByProfile.zlib"]) else {
            panic!("expected spot");
        };
        let request =
            crate::cli::request::spot_case(&args.request, &args.spot, None, None).unwrap();
        assert_eq!(request.targets, ["packagesByProfile.zlib"]);
        assert_eq!(request.from_source, ["toolchain"]);

        let CommandTree::Spot(args) = parse(&["spot", "packagesByProfile.zlib", "--target-only"]) else {
            panic!("expected spot");
        };
        let request =
            crate::cli::request::spot_case(&args.request, &args.spot, None, None).unwrap();
        assert!(request.from_source.is_empty());

        assert!(Cli::try_parse_from([
            "wasinix",
            "spot",
            "packagesByProfile.zlib",
            "--target-only",
            "--from-source",
            "rust",
        ])
        .is_err());
    }

    #[test]
    fn diff_cases_reenter_the_verb_parsers() {
        let CommandTree::Diff(args) = parse(&[
            "diff",
            "--content-diff",
            "build",
            "all",
            "--at",
            "main",
            "--vs",
            "spot",
            "packagesByProfile.zlib",
        ]) else {
            panic!("expected diff");
        };
        let Request::Diff(diff) = crate::cli::request::diff_request(&args).unwrap() else {
            panic!("expected a diff request");
        };
        assert!(diff.content_diff);
        assert_eq!(diff.baseline, "base");
        assert_eq!(diff.cases[0].case_id(), "base");
        assert_eq!(diff.cases[1].case_id(), "head");
        assert!(matches!(diff.cases[1], crate::ci::types::Case::Spot(_)));

        let CommandTree::Diff(single) = parse(&["diff", "build", "all"]) else {
            panic!("expected diff");
        };
        assert!(crate::cli::request::diff_request(&single).is_err());
    }
}

mod markdown {
    use super::{golden::check_text, scenarios};
    use crate::github::markdown::{check, comment, step_summary, truncate_sections, Links};
    use crate::github::sanitize::{code_span, escape_html, fence, table_cell};
    use crate::support::atoms::Rev;

    fn links() -> Links {
        Links {
            run_url: Some("https://github.com/wasix-org/wasinix/actions/runs/1".into()),
            sha: Some(Rev::parse(&"a".repeat(40)).unwrap()),
            log_base: None,
        }
    }

    /// A link destination hostile to markdown: an unencoded `)` ends the
    /// link early and a `|` breaks any table cell it lands in.
    fn hostile_links() -> Links {
        Links {
            run_url: Some("https://ci.example/runs/1)|end".into()),
            sha: Some(Rev::parse(&"a".repeat(40)).unwrap()),
            log_base: Some("https://ci.example/logs)|base".into()),
        }
    }

    #[test]
    fn hostile_input_matches_its_goldens() {
        let (report, fragments) = scenarios::hostile();
        check_text(
            "comment-hostile.md",
            &comment(&report, &fragments, None, &hostile_links()).into_string(),
        );
        check_text(
            "step-summary-untrusted.md",
            &untrusted_step_summary(&report, &fragments),
        );
        check_text(
            "pr-body-hostile.md",
            &crate::github::changeset::pr_body(&hostile_changes(), true).into_string(),
        );
        check_text(
            "mutation-reply-hostile.md",
            &crate::github::changeset::reply(
                &hostile_changes(),
                "### ✅ Wasinix mutation applied",
                &"a".repeat(40),
            )
            .into_string(),
        );
    }

    #[test]
    fn mutation_comments_classify_as_mutations_and_parse_structurally() {
        use crate::cli::untrusted::{parse, MutationCommand, UntrustedCommand};
        let UntrustedCommand::Mutation(MutationCommand::Update { targets, all }) =
            parse("update wasmer wasix-libc").unwrap()
        else {
            panic!("expected an update mutation");
        };
        assert_eq!(targets, ["wasmer", "wasix-libc"]);
        assert!(!all);
        assert!(matches!(
            parse("update --all").unwrap(),
            UntrustedCommand::Mutation(MutationCommand::Update { all: true, .. })
        ));
        assert!(matches!(
            parse("versions bump numpy@1.26.4 --all-versions").unwrap(),
            UntrustedCommand::Mutation(MutationCommand::Bump { .. })
        ));
        assert!(matches!(
            parse("versions bump --changed").unwrap(),
            UntrustedCommand::Mutation(MutationCommand::Bump { changed: true, .. })
        ));
        assert!(matches!(
            parse("regenerate --force").unwrap(),
            UntrustedCommand::Mutation(MutationCommand::Regenerate)
        ));
        // --force is required at the type level, not checked afterwards.
        assert!(parse("regenerate").is_err());
        use crate::ci::origin::{Classifier, CommandKind};
        assert_eq!(
            crate::cli::untrusted::ClapClassifier
                .classify("update --all")
                .unwrap(),
            CommandKind::Mutation
        );
        assert_eq!(
            crate::cli::untrusted::ClapClassifier
                .classify("build core")
                .unwrap(),
            CommandKind::Build
        );
        // Help replies and is done: routing it through the run machinery
        // manufactures a report-less run every publisher chokes on.
        assert_eq!(
            crate::cli::untrusted::ClapClassifier.classify("help").unwrap(),
            CommandKind::Help
        );
        // clap already prefixes its rendering; the wrapper must not.
        let refusal = crate::cli::untrusted::parse("frobnicate --now")
            .unwrap_err()
            .to_string();
        assert!(refusal.starts_with("unrecognized subcommand"), "{refusal}");
        // Adapter-owned mutation flags do not exist in this grammar.
        for refused in [
            "update wasmer --commit",
            "update wasmer --pr",
            "update wasmer --branch b",
            "update wasmer --repository o/r",
            "versions bump numpy --changed-from main",
            "versions add numpy@1.0",
            "versions import uv.lock",
        ] {
            let error = parse(refused).unwrap_err().to_string();
            assert!(!error.contains("not available"), "{refused}: {error}");
            assert!(parse(refused).is_err(), "{refused} must not parse");
        }
    }

    /// The reply body is fence-proof: a PR-controlled log line cannot close
    /// the fence and render as markup.
    #[test]
    fn the_failure_reply_fences_hostile_detail() {
        let body = crate::github::markdown::failure_reply(
            "log line\n```\n### forged",
            Some("https://ci.example/run"),
        )
        .into_string();
        assert!(body.starts_with("❌ `/wasinix` command failed:"));
        assert!(body.contains("````text\nlog line\n```\n### forged\n````"));
        assert!(body.contains("[Actions run](https://ci.example/run)"));
        let empty = crate::github::markdown::failure_reply("  ", None).into_string();
        assert!(empty.contains("see the Actions run"));
    }

    /// The step summary as published for a fork PR (`untrusted` target),
    /// through the real publish path rather than the renderer alone.
    fn untrusted_step_summary(
        report: &crate::ci::report::Report,
        fragments: &std::collections::BTreeMap<String, crate::ci::report::Fragment>,
    ) -> String {
        let scratch = crate::support::fs::Scratch::create("wasinix-test").unwrap();
        let path = scratch.path().join("summary.md");
        crate::github::publish::step_summary(
            &crate::github::publish::Rendered {
                report: report.clone(),
                fragments: fragments.clone(),
                snapshot: None,
            },
            &crate::github::publish::Target {
                repository: "wasix-org/wasinix".into(),
                pull_request: Some(1),
                head_sha: Some("a".repeat(40)),
                run_url: hostile_links().run_url,
                author: "github-actions[bot]".into(),
                untrusted: true,
                log_base: None,
            },
            &path,
            crate::support::effects::Effects::Apply,
        )
        .unwrap();
        std::fs::read_to_string(&path).unwrap()
    }

    fn hostile_changes() -> crate::update::changeset::ChangeSet {
        use crate::update::changeset::{ChangeSet, Entry, EntryKind};
        ChangeSet {
            entries: vec![
                Entry {
                    kind: EntryKind::Bump,
                    subject: "wasix|libc `rm -rf`".into(),
                    from: Some("1.0|a".into()),
                    to: Some("2.0`b".into()),
                    detail: None,
                    changelog: Some("https://example.invalid/log)|x".into()),
                    files: vec!["pkgs/evil|cell.nix".into()],
                },
                Entry {
                    kind: EntryKind::Notable,
                    subject: "note|subject".into(),
                    from: Some("6.0|x".into()),
                    to: Some("6.1`y".into()),
                    detail: Some("line1\n| forged | row |\n> quote\n### heading".into()),
                    changelog: None,
                    files: Vec::new(),
                },
                Entry {
                    kind: EntryKind::Backfill,
                    subject: "numpy|old".into(),
                    from: None,
                    to: Some("1.26|4".into()),
                    detail: Some("added (cp313|abi)".into()),
                    changelog: None,
                    files: Vec::new(),
                },
            ],
            unchanged: Vec::new(),
            failures: Vec::new(),
            committed: true,
        }
    }

    #[test]
    fn a_lost_run_renders_a_terminal_comment() {
        let run = crate::runs::Run {
            run_id: "1-2-0".into(),
            command: vec!["ci".into(), "run".into()],
            state: crate::support::atoms::RunState::Lost,
            pid: 7,
            started_at: 1_755_000_000,
            finished_at: Some(1_755_003_600),
            exit_code: None,
        };
        let report = crate::ci::report::from_run_state(&run);
        check_text(
            "comment-lost.md",
            &comment(&report, &std::collections::BTreeMap::new(), None, &links()).into_string(),
        );
    }

    #[test]
    fn comment_projections_match_their_goldens() {
        for (name, scenario) in [
            ("comment-green.md", scenarios::green()),
            ("comment-failing.md", scenarios::failing()),
            ("comment-diff-green.md", scenarios::diff_green()),
            ("comment-infra-neutral.md", scenarios::infra_neutral()),
        ] {
            let (report, fragments) = scenario;
            check_text(name, &comment(&report, &fragments, None, &links()).into_string());
        }
        let (report, fragments) = scenarios::diff_in_progress();
        assert_eq!(report.conclusion, None, "a mid-run diff stays open");
        check_text(
            "comment-diff-in-progress.md",
            &comment(&report, &fragments, None, &links()).into_string(),
        );
        let (report, fragments) = scenarios::in_progress();
        let snapshot = crate::ci::events::Snapshot {
            state: crate::support::atoms::RunState::Running,
            exit_code: None,
            started_at: Some(1_755_000_000),
            last_event_at: Some(1_755_003_000),
            completed_jobs: 3106,
            cached_jobs: 0,
            failed_jobs: 0,
            phases: Vec::new(),
            recent_failures: Vec::new(),
            building: Vec::new(),
        };
        check_text(
            "comment-in-progress.md",
            &comment(&report, &fragments, Some(&snapshot), &links()).into_string(),
        );
    }

    #[test]
    fn the_check_run_names_failing_jobs_and_stays_short() {
        let (report, fragments) = scenarios::failing();
        let projected = check(&report, &fragments, &links());
        assert!(projected.title.contains("checks.zlib"), "{}", projected.title);
        assert!(projected.title.len() <= crate::github::markdown::CHECK_TITLE_BUDGET);
        assert!(projected.summary.len() <= crate::github::markdown::CHECK_SUMMARY_BUDGET);
        assert!(
            !projected.summary.contains("<details><summary>Details"),
            "the check summary must not copy the comment"
        );
    }

    #[test]
    fn the_step_summary_carries_what_the_comment_caps() {
        let (report, fragments) = scenarios::failing();
        let text = step_summary(&report, &fragments, &links()).into_string();
        assert!(text.contains("checks.zlib"));
    }

    #[test]
    fn truncation_drops_whole_sections_and_says_so() {
        let text = format!(
            "### heading\n\nbody\n\n<details><summary>A</summary>\n{}\n</details>\n\n<details><summary>B</summary>\nshort\n</details>\n",
            "x".repeat(400)
        );
        let truncated = truncate_sections(text, 200);
        assert!(!truncated.contains("<details"));
        assert!(truncated.contains("2 detail sections moved"), "{truncated}");
        assert!(truncated.contains("### heading"));
    }

    #[test]
    fn hostile_log_text_cannot_escape_its_fence_or_cell() {
        // The forged-marker chain: a log line closing the fence and planting
        // a managed-state marker must stay inert text.
        let hostile = "done\n```\n<!-- wasinix:managed-state -->\n````\n| x |";
        let fenced = fence(hostile, "text");
        let fence_run = fenced.split('\n').next().unwrap();
        assert!(fence_run.starts_with("`````"), "{fence_run}");
        assert!(fenced.matches(fence_run.trim_end_matches("text")).count() >= 2);

        let cell = table_cell(hostile);
        assert!(!cell.contains('\n'));
        assert!(!cell.contains(" | x"), "{cell}");

        assert_eq!(escape_html("<img onerror=x>"), "&lt;img onerror=x&gt;");
        let span = code_span("a`b``c");
        assert!(span.starts_with("``` "), "{span}");

        // Line breaks must not let untrusted text escape a span or an HTML
        // context into block markdown, and a quote must not survive an attr.
        assert!(!code_span("done\n### forged").contains('\n'));
        let escaped = escape_html("a\n\n### forged");
        assert!(!escaped.contains('\n'), "{escaped}");
        assert_eq!(escape_html("it's \"x\""), "it&#39;s &quot;x&quot;");
        // A backslash before a pipe must not escape the escape.
        assert_eq!(table_cell("a\\|b"), "a\\\\\\|b");
    }
}

mod changeset_markdown {
    use crate::github::changeset::pr_body;
    use crate::update::changeset::{ChangeSet, Entry, EntryKind};

    fn sample() -> ChangeSet {
        ChangeSet {
            entries: vec![
                Entry {
                    kind: EntryKind::Bump,
                    subject: "wasix-libc".into(),
                    from: Some("2026-07-03.1".into()),
                    to: Some("2026-08-01.1".into()),
                    detail: None,
                    changelog: Some("https://example.invalid/log".into()),
                    files: vec!["pkgs/toolchain/libc.nix".into()],
                },
                Entry {
                    kind: EntryKind::Retain,
                    subject: "history".into(),
                    from: None,
                    to: None,
                    detail: Some("numpy@1.26.4 retained".into()),
                    changelog: None,
                    files: Vec::new(),
                },
                Entry {
                    kind: EntryKind::Notable,
                    subject: "wasmer".into(),
                    from: Some("6.0".into()),
                    to: Some("6.1".into()),
                    detail: Some("recheck dropped patches".into()),
                    changelog: None,
                    files: Vec::new(),
                },
            ],
            unchanged: Vec::new(),
            failures: Vec::new(),
            committed: true,
        }
    }

    #[test]
    fn the_managed_footer_is_bot_only() {
        let changes = sample();
        assert!(pr_body(&changes, true)
            .into_string()
            .contains("Managed by wasinix"));
        assert!(!pr_body(&changes, false)
            .into_string()
            .contains("Managed by wasinix"));
    }

    #[test]
    fn the_body_carries_the_bump_table_notes_and_details() {
        let body = pr_body(&sample(), false).into_string();
        assert!(body.contains("| wasix-libc | 2026-07-03.1 | 2026-08-01.1 | [changelog]"));
        assert!(body.contains("> [!NOTE]"));
        assert!(body.contains("Retention, prune, and hooks (1)"));
    }

}

mod surfaces {
    use std::cell::RefCell;

    use serde_json::{json, Value};

    use crate::github::surfaces::{CommentApi, Registry, Surface};
    use crate::support::error::Result;

    #[derive(Default)]
    struct Fake {
        comments: RefCell<Vec<Value>>,
        patched: RefCell<Vec<u64>>,
    }

    impl CommentApi for Fake {
        fn paginate(&self, _path: &str) -> Result<Vec<Value>> {
            Ok(self.comments.borrow().clone())
        }

        fn post(&self, _path: &str, body: &Value) -> Result<Value> {
            let id = 100 + self.comments.borrow().len() as u64;
            let comment = json!({
                "id": id,
                "user": {"login": "wasinix-bot"},
                "body": body["body"],
            });
            self.comments.borrow_mut().push(comment.clone());
            Ok(comment)
        }

        fn patch(&self, path: &str, _body: &Value) -> Result<Value> {
            let id: u64 = path.rsplit('/').next().unwrap().parse().unwrap();
            self.patched.borrow_mut().push(id);
            Ok(json!({"id": id}))
        }
    }

    /// A dry run reaches the API layer's edge and stops: nothing is posted,
    /// patched, or even looked up.
    #[test]
    fn a_dry_run_renders_but_never_writes() {
        let fake = Fake::default();
        let mut registry = Registry::new(
            &fake,
            "wasix-org/wasinix",
            7,
            "wasinix-bot",
            crate::support::effects::Effects::DryRun,
        );
        let id = registry
            .upsert(
                &Surface::CiReport,
                &[],
                crate::github::sanitize::Markdown::constant("body"),
            )
            .unwrap();
        assert_eq!(id, None);
        assert!(fake.comments.borrow().is_empty());
        assert!(fake.patched.borrow().is_empty());
    }

    #[test]
    fn a_surface_edits_one_comment_in_place_across_states() {
        let fake = Fake::default();
        let mut registry = Registry::new(
            &fake,
            "wasix-org/wasinix",
            7,
            "wasinix-bot",
            crate::support::effects::Effects::Apply,
        );
        let attrs = [("run", "1755-1".to_string())];
        let first = registry
            .upsert(&Surface::CiReport, &attrs, crate::github::sanitize::Markdown::constant("running"))
            .unwrap();
        let second = registry
            .upsert(&Surface::CiReport, &attrs, crate::github::sanitize::Markdown::constant("final"))
            .unwrap();
        assert_eq!(first, second);
        let first = first.expect("apply upserts return the comment id");
        assert_eq!(fake.comments.borrow().len(), 1);
        assert_eq!(*fake.patched.borrow(), [first]);
        let body = fake.comments.borrow()[0]["body"].as_str().unwrap().to_string();
        assert!(body.starts_with("<!-- wasinix:ci-report run=1755-1 -->\n"), "{body}");
    }

    #[test]
    fn lookup_is_author_checked_and_migrates_the_legacy_marker() {
        let fake = Fake::default();
        fake.comments.borrow_mut().extend([
            // A forged marker from another user is content, not state.
            json!({"id": 1, "user": {"login": "attacker"},
                   "body": "<!-- wasinix:ci-report -->\nforged"}),
            json!({"id": 2, "user": {"login": "wasinix-bot"},
                   "body": "<!-- wasinix-ci-report -->\nold era"}),
        ]);
        let mut registry = Registry::new(
            &fake,
            "wasix-org/wasinix",
            7,
            "wasinix-bot",
            crate::support::effects::Effects::Apply,
        );
        let id = registry
            .upsert(
                &Surface::CiReport,
                &[],
                crate::github::sanitize::Markdown::constant("migrated"),
            )
            .unwrap();
        assert_eq!(id, Some(2), "the legacy-marker comment is adopted, not duplicated");
        assert_eq!(*fake.patched.borrow(), [2]);
    }

    #[test]
    fn replies_are_keyed_and_the_sticky_set_is_closed() {
        // A reply's marker is not adopted as the sticky report.
        let reply = Surface::CiReportReply { comment_id: 42 }
            .marker(&[("sha", "abc".into())]);
        assert!(reply.starts_with("<!-- wasinix:ci-report:42 "));
        assert!(!reply.starts_with("<!-- wasinix:ci-report "));
    }
}

mod render {
    use crate::ci::events::Event;
    use crate::cli::render::LineRenderer;
    use crate::support::atoms::{JobAddr, JobStatus, RunState, TaskStatus};

    #[test]
    fn a_recorded_stream_narrates_with_elapsed_stamps() {
        let events = [
            Event::RunStarted { at: 100, pid: 1 },
            Event::PhaseStarted {
                at: 100,
                task_id: "case.core".into(),
                label: "case: Core".into(),
                jobs: Some(40),
            },
            Event::JobFinished {
                at: 190,
                job: JobAddr("case::checks.zlib".into()),
                status: JobStatus::Failure,
                cached: false,
                duration_seconds: None,
                error: Some("builder failed with exit code 1".into()),
            },
            Event::PhaseFinished {
                at: 250,
                task_id: "case.core".into(),
                status: TaskStatus::Failure,
                headline: "1 of 40 jobs failed".into(),
            },
            Event::RunFinished {
                at: 250,
                state: RunState::Failed,
                exit_code: Some(1),
            },
        ];
        let mut renderer = LineRenderer::with_spinner(false);
        let lines: Vec<String> = events
            .iter()
            .flat_map(|event| renderer.lines_for(event))
            .collect();
        assert_eq!(
            lines,
            [
                "[+0s] case: Core · 40 jobs",
                "[+1m 30s] ✗ case::checks.zlib",
                "  │ builder failed with exit code 1",
                "[+2m 30s] ✗ case.core · 1 of 40 jobs failed",
                "[+2m 30s] failed · 1/40 jobs · 1 failed",
            ]
        );
    }

    #[test]
    fn the_milestone_line_names_the_builds_in_flight() {
        let mut renderer = LineRenderer::with_spinner(false);
        renderer.lines_for(&Event::PhaseStarted {
            at: 100,
            task_id: "build".into(),
            label: "build".into(),
            jobs: Some(100),
        });
        for job in ["checks.curl", "checks.zlib"] {
            renderer.lines_for(&Event::JobStarted {
                at: 100,
                job: JobAddr(job.into()),
            });
        }
        let mut milestone = Vec::new();
        for index in 0..50 {
            milestone = renderer.lines_for(&Event::JobFinished {
                at: 160,
                job: JobAddr(format!("checks.job{index}")),
                status: JobStatus::Success,
                cached: false,
                duration_seconds: None,
                error: None,
            });
        }
        assert_eq!(
            milestone,
            ["[+1m 0s] 50/100 jobs · building checks.curl, checks.zlib"]
        );
        // A heartbeat in a quiet stretch repeats the progress line.
        assert_eq!(
            renderer.lines_for(&Event::Heartbeat { at: 460 }),
            ["[+6m 0s] 50/100 jobs · building checks.curl, checks.zlib"]
        );
    }
}

mod bisect {
    use crate::nix::bisect::{completed, run, Dependency, Options, Outcome};
    use crate::support::fs::Scratch;

    #[test]
    fn the_first_bad_line_is_read_in_every_git_phrasing() {
        let rev = "0123456789abcdef0123456789abcdef01234567";
        assert_eq!(
            completed(&format!("{rev} is the first bad commit\n")),
            Some(rev.to_string())
        );
        assert_eq!(
            completed(&format!("{rev} is the first 'bad' commit\n")),
            Some(rev.to_string())
        );
        assert_eq!(
            completed(&format!("[{rev}] subject\n{rev} is the first bad commit")),
            Some(rev.to_string())
        );
        assert_eq!(completed("Bisecting: 3 revisions left to test"), None);
    }

    fn git(repo: &std::path::Path, args: &[&str]) -> String {
        crate::support::git::git(repo, args).unwrap()
    }

    #[test]
    fn native_git_bisect_selects_the_first_bad_revision() {
        let scratch = Scratch::create("wasinix-bisect").unwrap();
        let source = scratch.path().join("upstream");
        std::fs::create_dir_all(&source).unwrap();
        git(&source, &["init", "--initial-branch=main"]);
        git(&source, &["config", "user.name", "wasinix test"]);
        git(&source, &["config", "user.email", "test@example.invalid"]);
        let mut revisions = Vec::new();
        for index in 0..6 {
            git(&source, &["commit", "--allow-empty", "-m", &format!("commit {index}")]);
            revisions.push(git(&source, &["rev-parse", "HEAD"]));
        }
        let report = run(
            Options {
                dependency: Dependency {
                    target: "example".into(),
                    repository: source.to_string_lossy().to_string(),
                    pinned: revisions[0].clone(),
                },
                good: "pinned".into(),
                bad: revisions[5].clone(),
                first_parent: false,
                command: vec!["build".into(), "example".into()],
                run_dir: scratch.path().join("run"),
            },
            |rev, _| {
                Ok(if revisions[..3].iter().any(|candidate| candidate == rev) {
                    Outcome::Good
                } else {
                    Outcome::Bad
                })
            },
        )
        .unwrap();
        assert_eq!(report.first_bad.as_deref(), Some(revisions[3].as_str()));
    }
}

mod update {
    use std::collections::BTreeMap;

    use crate::update::changeset::{ChangeSet, Entry, EntryKind, FailedStep};
    use crate::update::history::substitute_version;
    use crate::update::retention::retention_crossed;
    use crate::update::select::target_requests;
    use crate::update::targets::{domain, Backend, Target};
    use crate::update::Mode;

    fn flake_target(name: &str) -> Target {
        Target {
            name: name.into(),
            backend: Backend::FlakeInput,
            input: name.into(),
            attr: String::new(),
            version: "a".repeat(40),
            command: Vec::new(),
            command_drv_paths: Vec::new(),
            file: String::new(),
            accepts: vec!["revision".into()],
            source: Some(serde_json::json!({"kind": "github", "owner": "o", "repo": "r"})),
        }
    }

    #[test]
    fn the_at_grammar_selects_and_requests_and_equals_is_dead() {
        let targets = vec![flake_target("wasmer")];
        let domain = domain(&targets);
        let (wanted, requests) = target_requests(
            &targets,
            &domain,
            &[format!("wasmer@rev:{}", "b".repeat(40))],
        )
        .unwrap();
        assert_eq!(wanted, ["wasmer"]);
        assert_eq!(requests["wasmer"].mode, Mode::Revision);

        let error = target_requests(&targets, &domain, &["wasmer=1.0".to_string()])
            .unwrap_err()
            .to_string();
        assert!(error.contains("wasmer@1.0"), "{error}");

        let (wanted, requests) =
            target_requests(&targets, &domain, &["wasmer".to_string()]).unwrap();
        assert_eq!(wanted, ["wasmer"]);
        assert!(requests.is_empty());
    }

    #[test]
    fn version_substitution_only_touches_bounded_matches() {
        assert_eq!(
            substitute_version("url", "https://host:2000/v2/pkg-2.tar.gz", "2", "3").unwrap(),
            "https://host:2000/v3/pkg-3.tar.gz",
            "the port's digits stay; the version spellings move"
        );
        assert_eq!(
            substitute_version("tag", "v2.5.0", "2.5.0", "2.4.0").unwrap(),
            "v2.4.0"
        );
        assert_eq!(
            substitute_version("url", "pkg_1_2_3.zip", "1.2.3", "1.2.2").unwrap(),
            "pkg_1_2_2.zip"
        );
        assert!(substitute_version("url", "pkg.tar.gz", "1.0", "0.9").is_err());
        // Two occurrences sharing a boundary both move.
        assert_eq!(
            substitute_version("url", "https://h/1.2.3/1.2.3.tar.gz", "1.2.3", "1.2.2").unwrap(),
            "https://h/1.2.2/1.2.2.tar.gz"
        );
    }

    #[test]
    fn retention_fires_only_on_series_crossings_of_plain_releases() {
        assert!(retention_crossed("1.9.0", "2.0.0", 1));
        assert!(!retention_crossed("1.8.0", "1.9.0", 1));
        assert!(retention_crossed("1.8.0", "1.9.0", 2));
        assert!(!retention_crossed("5.3p9", "5.4", 1), "non-releases never fire");
        assert!(!retention_crossed("1.9.0", "2.0.0", 0));
    }

    #[test]
    fn the_changeset_speaks_the_repo_commit_voice() {
        let bump = Entry {
            kind: EntryKind::Bump,
            subject: "wasix-libc".into(),
            from: Some("2026-07-03.1".into()),
            to: Some("2026-08-01.1".into()),
            detail: None,
            changelog: Some("https://example.invalid/log".into()),
            files: vec!["pkgs/toolchain/libc.nix".into()],
        };
        assert_eq!(
            ChangeSet::commit_message(&bump),
            "wasix-libc: 2026-07-03.1 -> 2026-08-01.1"
        );
        let sourceless = Entry {
            from: None,
            ..bump.clone()
        };
        assert_eq!(
            ChangeSet::commit_message(&sourceless),
            "wasix-libc: update to 2026-08-01.1"
        );
        let changes = ChangeSet {
            entries: vec![bump],
            unchanged: Vec::new(),
            failures: vec![FailedStep {
                subject: "wasmer".into(),
                message: "upstream tag vanished".into(),
            }],
            committed: false,
        };
        assert_eq!(
            changes.title(),
            "wasix-libc: 2026-07-03.1 -> 2026-08-01.1",
            "a lone bump titles its PR with the commit message"
        );
        let receipt = changes.receipt();
        assert!(receipt[0].contains("2026-07-03.1 → 2026-08-01.1"), "{receipt:?}");
        assert!(receipt.last().unwrap().contains("1 updated · 1 failed · tree modified"));
        let _ = BTreeMap::from([(1, 2)]);
    }

    #[test]
    fn one_pin_is_one_target_however_many_attrs_declare_it() {
        let target = |name: &str, file: &str, command: &[&str]| Target {
            name: name.into(),
            backend: Backend::UpdateScript,
            input: String::new(),
            attr: format!("legacyPackages.x.{name}"),
            version: String::new(),
            command: command.iter().map(|part| part.to_string()).collect(),
            command_drv_paths: Vec::new(),
            file: file.into(),
            accepts: Vec::new(),
            source: None,
        };
        let deduped = crate::update::targets::dedupe(vec![
            // A wrapper and its unwrapped package: same file, same command.
            target("cargo-wasix", "pkgs/cargo-wasix.nix", &["nix-update", "--flake"]),
            target("cargo-wasix-unwrapped", "pkgs/cargo-wasix.nix", &["nix-update", "--flake"]),
            // Grammars share a file but each command names its language.
            target("tree-sitter-c", "pkgs/grammars.nix", &["update-grammars", "c"]),
            target("tree-sitter-go", "pkgs/grammars.nix", &["update-grammars", "go"]),
        ]);
        let names: Vec<&str> = deduped.iter().map(|target| target.name.as_str()).collect();
        assert_eq!(names, ["cargo-wasix", "tree-sitter-c", "tree-sitter-go"]);
    }

    #[test]
    fn declarations_parse_the_flakes_camel_case_keys() {
        let value = serde_json::json!({
            "name": "wasix-libc",
            "version": "2026-07-30.1",
            "attrPath": "toolchain.libc-unwrapped",
            "position": "/nix/store/aaa-source/pkgs/products/wasix-sysroot/libc.nix:22",
            "command": ["/nix/store/bbb-wasix-libc-update/bin/wasix-libc-update"],
            "commandDrvPaths": ["/nix/store/ccc-wasix-libc-update.drv"],
            "accepts": ["release"],
        });
        let target = crate::update::targets::declared_target(
            std::path::Path::new("/repo"),
            "toolchain.libc",
            &value,
        )
        .unwrap();
        assert_eq!(
            target.command_drv_paths,
            vec!["/nix/store/ccc-wasix-libc-update.drv".to_string()],
            "commandDrvPaths must survive deserialization; an empty list makes \
             every store-path command unrealisable in CI"
        );
        assert!(target.attr.ends_with("toolchain.libc-unwrapped"), "{}", target.attr);
        assert_eq!(target.file, "pkgs/products/wasix-sysroot/libc.nix");
    }

    #[test]
    fn the_completion_cache_round_trips_and_narrow_maps_do_not_shrink_it() {
        let scratch = crate::support::fs::Scratch::create("wasinix-test").unwrap();
        let names = crate::support::completions::round_trip_for_tests(
            scratch.path(),
            "selectors",
            &["core", "checks.zlib"],
        );
        assert_eq!(names, ["core", "checks.zlib"]);

        // A spot case's map has no set catalog and offers nothing to record.
        let narrow = crate::ci::evalmap::EvalMap {
            jobs: [(crate::support::atoms::JobAddr("packagesByProfile.zlib".into()), String::new())]
                .into_iter()
                .collect(),
            ..Default::default()
        };
        assert!(narrow.selector_names().is_none());
        let full = crate::ci::evalmap::EvalMap {
            jobs: [(crate::support::atoms::JobAddr("checks.zlib".into()), String::new())]
                .into_iter()
                .collect(),
            sets: [("core".to_string(), vec!["checks.zlib".to_string()])]
                .into_iter()
                .collect(),
            ..Default::default()
        };
        let names = full.selector_names().unwrap();
        assert_eq!(names, ["all", "core", "checks.zlib"]);
    }

    #[test]
    fn script_requests_are_validated_before_a_script_sees_them() {
        use crate::update::request::parse;
        let release = r#"{"schema":1,"mode":"release","target":"wasix-libc","value":"1.2"}"#;
        assert_eq!(parse(release, None).unwrap().value, "1.2");
        assert_eq!(parse(release, Some("wasix-libc")).unwrap().target, "wasix-libc");
        assert!(parse(release, Some("other")).is_err(), "--expect mismatch refuses");
        assert!(parse("{not json", None).is_err());
        assert!(
            parse(r#"{"schema":2,"mode":"release","target":"x","value":"1"}"#, None).is_err(),
            "unknown schema refuses"
        );
        assert!(
            parse(r#"{"schema":1,"mode":"release","target":"x","value":""}"#, None).is_err(),
            "a release request needs a value"
        );
        assert!(
            parse(r#"{"schema":1,"mode":"revision","target":"x","value":"abc"}"#, None).is_err(),
            "a revision request needs a source"
        );
    }
}

mod managed {
    use crate::update::managed::{decode, paused, with_state, State};

    #[test]
    fn state_round_trips_through_the_pr_body() {
        let state = State::new("update wasmer".into(), "a".repeat(40)).unwrap();
        let body = with_state("### Automated pin update\n", &state).unwrap();
        assert_eq!(decode(&body).unwrap(), Some(state.clone()));
        // Recording again replaces the marker instead of stacking a second.
        let updated = State::new("update wasmer".into(), "b".repeat(40)).unwrap();
        let body = with_state(&body, &updated).unwrap();
        assert_eq!(decode(&body).unwrap(), Some(updated));
        assert_eq!(
            body.matches("<!-- wasinix:changeset data=").count(),
            1
        );
    }

    #[test]
    fn a_tampered_record_is_an_error_never_unmanaged() {
        assert!(decode("<!-- wasinix:changeset data=not-base64 -->").is_err());
        assert_eq!(decode("no marker here").unwrap(), None);
    }

    #[test]
    fn pushes_past_the_recorded_head_pause_refreshes() {
        let recorded = State::new("update --all".into(), "a".repeat(40)).unwrap();
        assert!(!paused(&recorded, &"a".repeat(40)));
        assert!(!paused(&recorded, &"A".repeat(40)));
        assert!(paused(&recorded, &"b".repeat(40)));
        let unrecorded = State::new("update --all".into(), String::new()).unwrap();
        assert!(!paused(&unrecorded, &"b".repeat(40)));
    }
}

mod mutation_gates {
    use crate::cli::untrusted::MutationCommand;
    use crate::github::mutation::{resolve, Pull, Resolved};
    use crate::update::managed::State;

    fn pull() -> Pull {
        Pull {
            head_sha: "b".repeat(40),
            head_ref: "auto/update-wasmer".into(),
            head_repository: "wasix-org/wasinix".into(),
            base_sha: "c".repeat(40),
            body: String::new(),
        }
    }

    fn update(targets: &[&str], all: bool) -> MutationCommand {
        MutationCommand::Update {
            targets: targets.iter().map(|t| t.to_string()).collect(),
            all,
        }
    }

    #[test]
    fn recipe_forms_demand_the_managed_record() {
        assert!(resolve(MutationCommand::Regenerate, None, &pull()).is_err());
        assert!(resolve(update(&[], false), None, &pull()).is_err());
    }

    #[test]
    fn a_bare_update_replays_the_recipe_from_the_current_head() {
        let state = State::new("update wasmer".into(), "b".repeat(40)).unwrap();
        let Resolved::Run(resolution) =
            resolve(update(&[], false), Some(state), &pull()).unwrap()
        else {
            panic!("expected a run");
        };
        assert_eq!(resolution.command, update(&["wasmer"], false));
        assert_eq!(resolution.start_sha, "b".repeat(40));
        assert!(!resolution.force);
        assert!(resolution.record_state);
    }

    #[test]
    fn a_bare_update_on_a_moved_branch_pauses() {
        let state = State::new("update wasmer".into(), "a".repeat(40)).unwrap();
        assert!(matches!(
            resolve(update(&[], false), Some(state), &pull()).unwrap(),
            Resolved::Paused(_)
        ));
    }

    #[test]
    fn a_non_update_recipe_refuses_a_bare_update() {
        let state = State::new("versions bump --changed".into(), "b".repeat(40)).unwrap();
        assert!(resolve(update(&[], false), Some(state), &pull()).is_err());
    }

    #[test]
    fn regenerate_replays_from_the_base_with_force() {
        // Even a moved branch regenerates: that is the recovery path.
        let state = State::new("update wasmer".into(), "a".repeat(40)).unwrap();
        let Resolved::Run(resolution) =
            resolve(MutationCommand::Regenerate, Some(state), &pull()).unwrap()
        else {
            panic!("expected a run");
        };
        assert_eq!(resolution.start_sha, "c".repeat(40));
        assert!(resolution.force);
        assert!(resolution.record_state);
    }

    #[test]
    fn explicit_targets_run_as_spelled_without_state() {
        let Resolved::Run(resolution) =
            resolve(update(&["wasmer"], false), None, &pull()).unwrap()
        else {
            panic!("expected a run");
        };
        assert_eq!(resolution.start_sha, "b".repeat(40));
        assert!(!resolution.record_state);
        assert!(resolution.recipe.is_none());
    }
}

mod webc_tree {
    use crate::registries::wasmer::merge_webcs;
    use crate::support::fs::Scratch;

    #[test]
    fn merging_skips_identical_bytes_and_refuses_conflicts() {
        let scratch = Scratch::create("wasinix-test").unwrap();
        let write = |dir: &str, body: &str| {
            let path = scratch.path().join(dir).join("wasix/probe");
            crate::support::fs::create_dir_all(&path).unwrap();
            crate::support::fs::write(&path.join("1.0.webc"), body.as_bytes()).unwrap();
            scratch.path().join(dir)
        };
        let first = write("a", "payload");
        let same = write("b", "payload");
        let conflicting = write("c", "different");
        let tree = scratch.path().join("tree");
        crate::support::fs::create_dir_all(&tree).unwrap();
        merge_webcs(&first, &tree).unwrap();
        merge_webcs(&same, &tree).unwrap();
        let error = merge_webcs(&conflicting, &tree).unwrap_err().to_string();
        assert!(error.contains("conflicting contents"), "{error}");

        // A bare .webc file lands at the tree root under its own name.
        let single = scratch.path().join("single.webc");
        crate::support::fs::write(&single, b"solo").unwrap();
        merge_webcs(&single, &tree).unwrap();
        assert!(tree.join("single.webc").is_file());
        assert!(tree.join("wasix/probe/1.0.webc").is_file());
    }
}

mod cargo_publish {
    use crate::registries::cargo::{classify, index_cksum, index_path, Action};

    /// Cargo's sparse-index layout: 1/, 2/, 3/<first>/, then two two-char
    /// shards, lowercased.
    #[test]
    fn the_index_path_follows_cargos_shard_rule() {
        assert_eq!(index_path("a"), "1/a");
        assert_eq!(index_path("io"), "2/io");
        assert_eq!(index_path("mio"), "3/m/mio");
        assert_eq!(index_path("serde"), "se/rd/serde");
        assert_eq!(index_path("Tokio"), "to/ki/tokio");
    }

    #[test]
    fn index_lines_yield_the_versions_cksum_and_malformed_lines_fail() {
        let index = concat!(
            "{\"name\":\"probe\",\"vers\":\"0.1.0+wasix.1\",\"cksum\":\"aa\"}\n",
            "{\"name\":\"probe\",\"vers\":\"0.2.0+wasix.1\",\"cksum\":\"bb\"}\n",
        );
        assert_eq!(
            index_cksum(index, "0.2.0+wasix.1").unwrap().as_deref(),
            Some("bb")
        );
        assert_eq!(index_cksum(index, "9.9.9").unwrap(), None);
        assert!(index_cksum("{ torn", "0.1.0").is_err());
    }

    /// The three-way decision; a checksum mismatch classifies as a conflict
    /// before the dry-run branch, so a dry run reports it too.
    #[test]
    fn publishing_is_idempotent_by_checksum() {
        assert_eq!(classify(None, "aa"), Action::Publish);
        assert_eq!(classify(Some("aa"), "aa"), Action::Skip);
        assert_eq!(classify(Some("bb"), "aa"), Action::Conflict);
    }
}

mod corpus {
    use clap::Parser;

    use crate::cli::Cli;

    /// Every leaf is either tree-mutating (and flattens MutationMode) or
    /// read-only, explicitly: adding a subcommand fails this test until it
    /// is classified.
    #[test]
    fn every_leaf_is_classified_and_mutating_leaves_carry_mutation_mode() {
        const MUTATING: &[&str] = &[
            "update",
            "versions add",
            "versions import",
            "versions bump",
        ];
        const READONLY: &[&str] = &[
            "build",
            "spot",
            "diff",
            "bisect",
            "run start",
            "run list",
            "run status",
            "run logs",
            "run report",
            "run failures",
            "run watch",
            "run wait",
            "run cancel",
            "run supervise",
            "cargo serve",
            "cargo publish",
            "cargo preview",
            "wasmer serve",
            "wasmer publish",
            "wasmer preview",
            "python serve",
            "python publish",
            "python preview",
            "python count-natives",
            "publish",
            "preview",
            "serve",
            "remote list",
            "remote status",
            "remote doctor",
            "remote field",
            "remote init",
            "ci nix-config",
            "ci run",
            "ci remote",
            "ci observe",
            "ci prepare",
            "ci exec",
            "ci publish",
            "ci origin",
            "ci command",
            // The comment-mutation adapters rewrite a PR branch, but their
            // knobs are the authorized comment and the managed record; the
            // MutationMode flags are structurally absent on purpose.
            "ci mutate",
            "ci mutate-publish",
            "ci reply",
            "completions",
        ];
        fn leaves(command: &clap::Command, prefix: &str, found: &mut Vec<(String, clap::Command)>) {
            for sub in command.get_subcommands() {
                let path = if prefix.is_empty() {
                    sub.get_name().to_string()
                } else {
                    format!("{prefix} {}", sub.get_name())
                };
                if sub.get_subcommands().next().is_none() {
                    found.push((path, sub.clone()));
                } else {
                    leaves(sub, &path, found);
                }
            }
        }
        let mut found = Vec::new();
        leaves(&<Cli as clap::CommandFactory>::command(), "", &mut found);
        assert!(!found.is_empty());
        for (path, command) in &found {
            let mutating = MUTATING.contains(&path.as_str());
            let readonly = READONLY.contains(&path.as_str());
            assert!(
                mutating ^ readonly,
                "{path} must appear in exactly one of MUTATING/READONLY"
            );
            if mutating {
                for flag in ["commit", "pr", "branch", "repository", "base", "fork"] {
                    assert!(
                        command.get_arguments().any(|arg| arg.get_id() == flag),
                        "{path} lacks --{flag}; mutating leaves flatten MutationMode"
                    );
                }
            }
        }
        for expected in MUTATING.iter().chain(READONLY) {
            assert!(
                found.iter().any(|(path, _)| path == expected),
                "{expected} classified but no longer a leaf"
            );
        }
    }

    fn parses(words: &str) {
        let argv = std::iter::once("wasinix").chain(words.split_whitespace());
        if let Err(error) = Cli::try_parse_from(argv) {
            panic!("{words:?} does not parse: {error}");
        }
    }

    /// Every spelling an alias, doc, or self-invocation uses must parse; a
    /// retired spelling must not quietly come back.
    #[test]
    fn the_command_corpus_parses_and_retired_spellings_do_not() {
        for command in [
            "build all",
            "build core checks.bash-sh --at main --on ec2:store --json",
            "build all --inputs-only",
            "spot packagesByProfile.zlib --from-source rust --plan",
            "diff build all --at main --vs build all",
            "diff",
            "diff --content-diff",
            "run start -- wasinix ci run --request r.json",
            "run list --json",
            "run status 123 --json",
            "run logs 123 --follow",
            "run report 123 --json",
            "run failures 123",
            "run watch 123",
            "run wait 123 --timeout 60",
            "run cancel 123",
            "remote list --json",
            "remote status ec2",
            "remote doctor --ifd",
            "remote field store",
            "remote init",
            "ci run --request r.json --run-dir d",
            "ci prepare --request r.json --run-dir d",
            "ci exec --run-dir d --task case.eval",
            "ci command --origin o.json --run-dir d --push-cache",
            "ci reply --pull-request 1 --comment-id 2 --failure err.txt",
            "ci mutate --origin o.json --out-dir mutation",
            "ci mutate-publish --out-dir mutation",
            "ci remote --request r.json --run-dir d --on ec2",
            "ci observe --remote-run-dir /x --run-dir d",
            "ci publish --run-dir d --sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --untrusted --check",
            "build all --push-cache",
            "update wasix-libc",
            "update wasix-libc@2026-08-01.1 wasmer@rev:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "update --all --commit",
            "update list --json",
            "update hooks",
            "versions add numpy@1.26.4",
            "versions add numpy --per-major --since 1.20",
            "versions import uv.lock --dry-run",
            "versions bump gitMinimal --all-versions",
            "versions bump --changed-from origin/main --commit",
            "bisect wasix-libc --good pinned --bad main -- build checks.wasixcc",
            "cargo serve --port 9000 -- cargo check",
            "wasmer publish --dry-run",
            "wasmer preview pr-123 --dry-run",
            "python serve",
            "python publish --dry-run",
            "python publish --registry wasmer.wtf --dry-run",
            "python preview site app-pr-1 --registry wasmer.wtf",
            "cargo serve --mint ./mint",
            "cargo publish --dry-run",
            "wasmer serve bash --out tree --webc ./extra -- sh -c true",
            "serve --mint m --index i --server s --webc w -- sh -c true",
            "cargo serve --server s --mint m",
            "cargo publish mio --registry https://cargo-registry.wasix.org --json",
            "cargo preview cargo-registry-pr9 --base ./base --dry-run",
            "python preview site app-pr-1 --owner wasmer",
            "python count-natives --list",
            "publish --dry-run",
            "completions bash",
        ] {
            parses(command);
        }
        for retired in [
            "build all --trusted-ref main",
            "fetch-inputs all",
            "builder store",
            "registry serve",
            "history add x",
            "bump-rel x",
            "publish-webc --registry wasmer.io",
            "registry pins",
            "publish-index --registry r",
            "preview-diff main",
            "preview-deploy site app",
            "wheel-natives",
            "build all --local",
            "build all --remote ec2",
            "build all --dry-run",
            "build all --with wasmer=7.1.0 --route host",
        ] {
            let argv = std::iter::once("wasinix").chain(retired.split_whitespace());
            assert!(
                Cli::try_parse_from(argv).is_err(),
                "retired spelling parses: {retired:?}"
            );
        }
    }

    /// Every crate source as (relative path, text); the lint tests walk one
    /// listing so no rule can quietly skip a directory.
    fn sources(include_tests: bool) -> Vec<(String, String)> {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut pending = vec![root.clone()];
        let mut found = Vec::new();
        while let Some(dir) = pending.pop() {
            for entry in std::fs::read_dir(&dir).unwrap().flatten() {
                let path = entry.path();
                if path.is_dir() {
                    if !include_tests && path.file_name().is_some_and(|name| name == "tests") {
                        continue;
                    }
                    pending.push(path);
                    continue;
                }
                if path.extension().is_none_or(|ext| ext != "rs") {
                    continue;
                }
                let relative = path.strip_prefix(&root).unwrap().to_string_lossy().to_string();
                found.push((relative, std::fs::read_to_string(&path).unwrap()));
            }
        }
        found
    }

    fn offenders(
        include_tests: bool,
        allowed: &[&str],
        banned: &[&str],
    ) -> Vec<String> {
        let mut offenders = Vec::new();
        for (relative, text) in sources(include_tests) {
            if allowed.contains(&relative.as_str()) {
                continue;
            }
            for (index, line) in text.lines().enumerate() {
                if banned.iter().any(|call| line.contains(call)) {
                    offenders.push(format!("{relative}:{}: {}", index + 1, line.trim()));
                }
            }
        }
        offenders
    }

    /// Results flow through the ui module; a stray print bypasses verbosity,
    /// stream discipline, and the JSON error contract.
    #[test]
    fn printing_happens_only_at_the_presentation_edge() {
        let found = offenders(
            false,
            &["support/ui.rs", "support/json.rs", "cli/render.rs"],
            &["println!", "eprintln!", "print!(", "eprint!("],
        );
        assert!(found.is_empty(), "{}", found.join("\n"));
    }

    /// The environment is read behind support::env's named accessors; a raw
    /// read re-creates the per-site parse drift the accessors exist to end.
    /// Declare a named accessor in support/env.rs instead.
    #[test]
    fn the_environment_is_read_only_through_support_env() {
        // Assembled so the banned token does not appear in this file, which
        // the walk also scans.
        let banned = ["std::", "env"].concat();
        let found = offenders(true, &["support/env.rs"], &[&banned]);
        assert!(found.is_empty(), "{}", found.join("\n"));
    }

    /// nix and its frontends run through support::nix::Invocation, which owns
    /// flake-config classification, placement, logging, and timeouts; a raw
    /// construction re-creates exactly the per-site drift Invocation ended.
    /// The route tests construct carrier Commands for the configure fns, so
    /// the test tree is exempt.
    #[test]
    fn nix_runs_only_through_invocation() {
        let banned: Vec<String> = ["nix\"", "nix-store\"", "nix-eval-jobs\"", "nix-fast-build\"", "nix-prefetch-url\""]
            .iter()
            .map(|name| ["Command::", "new(\"", name].concat())
            .collect();
        let banned: Vec<&str> = banned.iter().map(String::as_str).collect();
        let found = offenders(false, &["support/nix.rs"], &banned);
        assert!(found.is_empty(), "{}", found.join("\n"));
    }

    /// git runs through support::git (repo named on every call, three-way
    /// exits preserved); ssh and scp through the builder (deadlines, logging).
    #[test]
    fn git_and_ssh_run_through_the_shared_runners() {
        let banned: Vec<String> = ["git\"", "ssh\"", "scp\""]
            .iter()
            .map(|name| ["Command::", "new(\"", name].concat())
            .collect();
        let banned: Vec<&str> = banned.iter().map(String::as_str).collect();
        let found = offenders(false, &["support/git.rs", "nix/builder.rs"], &banned);
        assert!(found.is_empty(), "{}", found.join("\n"));
    }

    /// The builder's store() is the one renderer of its ssh store URL, so a
    /// configured store_url override cannot be silently bypassed.
    #[test]
    fn the_ssh_store_url_has_one_renderer() {
        let banned = ["ssh-ng", "://"].concat();
        let found = offenders(false, &["nix/builder.rs"], &[&banned]);
        assert!(found.is_empty(), "{}", found.join("\n"));
    }

    /// Processes are started through support::tools (or a wrapper built on
    /// it),
    /// which logs and carries error context; a raw start is invisible to the
    /// transcript.
    #[test]
    fn processes_start_through_support_tools() {
        let output = [".outp", "ut()"].concat();
        let spawn = [".spa", "wn()"].concat();
        let found = offenders(true, &["support/tools.rs"], &[&output, &spawn]);
        assert!(found.is_empty(), "{}", found.join("\n"));
    }

    /// Run events have one narrator: cli/render's LineRenderer. The other
    /// allowed files emit or fold events; a new file touching event variants
    /// is a new consumer, which renders through the renderer rather than
    /// telling its own story. buildset's own StreamEvent names collide with
    /// these tokens, so it is allowed by name.
    #[test]
    fn run_events_have_one_narrator() {
        let banned = [
            "Event::RunStarted",
            "Event::PhaseStarted",
            "Event::PhaseFinished",
            "Event::JobStarted",
            "Event::JobFinished",
            "Event::Warning",
            "Event::Heartbeat",
            "Event::RunFinished",
        ];
        let found = offenders(
            false,
            &[
                "ci/events.rs",
                "cli/render.rs",
                "ci/exec.rs",
                "runs/mod.rs",
                "github/publish.rs",
                "nix/buildset.rs",
            ],
            &banned,
        );
        assert!(found.is_empty(), "{}", found.join("\n"));
    }

    /// finish_task is the one place a task ends: the only fragment write and
    /// the only PhaseFinished emission, so a result and its ladder close can
    /// never diverge. Counted in exec.rs, banned everywhere else, so a new
    /// emitter in another module cannot slip past the gate.
    #[test]
    fn tasks_finish_through_one_gate() {
        let exec = std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/ci/exec.rs"),
        )
        .unwrap();
        assert_eq!(
            exec.matches("Event::PhaseFinished").count(),
            1,
            "PhaseFinished is emitted only by finish_task"
        );
        assert_eq!(
            exec.matches("fragment.write(").count(),
            1,
            "fragments are written only by finish_task"
        );
        let emit = ["Event::Phase", "Finished"].concat();
        let write = ["Fragment", "::write("].concat();
        let write_method = [".wri", "te(&fragments_dir"].concat();
        // events.rs (snapshot fold) and cli/render.rs read the variant;
        // reading is not emitting.
        let found = offenders(
            false,
            &["ci/exec.rs", "ci/events.rs", "ci/report.rs", "cli/render.rs"],
            &[&emit, &write, &write_method],
        );
        assert!(found.is_empty(), "{}", found.join("\n"));
    }

    /// Display, Debug, and the serde wire spelling are one name per state,
    /// exhaustively: a new variant whose hand-written wire name drifts from
    /// its serde derive fails here, not in a grep session.
    #[test]
    fn run_and_task_states_have_one_spelling_everywhere() {
        use crate::support::atoms::{RunState, TaskStatus};
        for state in [
            RunState::Starting,
            RunState::Running,
            RunState::Complete,
            RunState::Failed,
            RunState::Cancelled,
            RunState::Lost,
            RunState::TimedOut,
        ] {
            assert_eq!(
                serde_json::to_value(state).unwrap(),
                serde_json::json!(state.to_string()),
                "{state} serde spelling drifted from Display"
            );
            assert_eq!(format!("{state:?}"), state.to_string());
        }
        for status in [
            TaskStatus::Pending,
            TaskStatus::Deferred,
            TaskStatus::Success,
            TaskStatus::Failure,
            TaskStatus::Cancelled,
            TaskStatus::Skipped,
            TaskStatus::Neutral,
        ] {
            assert_eq!(
                serde_json::to_value(status).unwrap(),
                serde_json::json!(status.to_string()),
                "{status} serde spelling drifted from Display"
            );
            assert_eq!(format!("{status:?}"), status.to_string());
        }
    }

    /// deny(dead_code) is the wired-or-absent guarantee; a targeted allow
    /// reopens the hole the crate layout closed.
    #[test]
    fn dead_code_stays_denied() {
        let banned = ["allow(dead_", "code"].concat();
        let found = offenders(true, &[], &[&banned]);
        assert!(found.is_empty(), "{}", found.join("\n"));
    }

    /// GitHub writes happen inside github:: (post/patch are visibility-bound
    /// to it); this test also catches dispatch through the CommentApi trait.
    /// support/http.rs is the generic HTTP client for non-GitHub endpoints.
    #[test]
    fn github_writes_happen_only_inside_github() {
        let post = [".po", "st("].concat();
        let patch = [".pat", "ch("].concat();
        let found: Vec<String> = offenders(false, &["support/http.rs"], &[&post, &patch])
            .into_iter()
            .filter(|offender| !offender.starts_with("github/"))
            .collect();
        assert!(found.is_empty(), "{}", found.join("\n"));
    }

    /// The run directory's layout is stated once in ci/prepare.rs; a module
    /// spelling a segment inline re-creates the per-site drift the helpers
    /// ended.
    #[test]
    fn the_run_layout_is_spelled_once() {
        let banned: Vec<String> = ["\"cases\")", "\"maps\")", "\"junit\")", "\"status.json\")", "\"eval-jobs.jsonl\")"]
            .iter()
            .map(|name| ["join(", name].concat())
            .collect();
        let banned: Vec<&str> = banned.iter().map(String::as_str).collect();
        let found = offenders(false, &["ci/prepare.rs"], &banned);
        assert!(found.is_empty(), "{}", found.join("\n"));
    }

    /// The strings that couple the binary to its workflows: the authorize
    /// outputs and kind values ci-command.yml dispatches on, the per-PR
    /// preview app names preview-cleanup.yml deletes, and the artifact name
    /// test-report.yml downloads from build.yml. A drifted spelling would
    /// fail silently (a job that never matches, an app never cleaned), so
    /// the coupling is pinned here instead.
    #[test]
    fn workflow_couplings_match_the_binary() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../.github");
        if !root.is_dir() {
            return;
        }
        let read = |name: &str| {
            std::fs::read_to_string(root.join("workflows").join(name)).unwrap()
        };
        let ci_command = read("ci-command-run.yml");
        for kind in [
            crate::ci::origin::CommandKind::Build,
            crate::ci::origin::CommandKind::Mutation,
        ] {
            assert!(
                ci_command.contains(&format!(
                    "needs.authorize.outputs.kind == '{}'",
                    kind.as_str()
                )),
                "ci-command-run.yml dispatches no job for kind {}",
                kind.as_str()
            );
        }
        // Help is handled inside authorize, not dispatched to a job.
        assert!(
            ci_command.contains(&format!(
                "steps.authorize.outputs.kind == '{}'",
                crate::ci::origin::CommandKind::Help.as_str()
            )),
            "ci-command-run.yml never replies to help"
        );
        for output in ["kind=", "commentId=", "pullRequest=", "headSha="] {
            assert!(
                ci_command.contains(&format!("steps.authorize.outputs.{}", output.trim_end_matches('='))),
                "ci-command-run.yml does not consume authorize output {output}"
            );
        }
        let cleanup = read("preview-cleanup.yml");
        for app in ["python-registry", "cargo-registry"] {
            assert!(
                cleanup.contains(app),
                "preview-cleanup.yml no longer deletes the {app} preview app"
            );
        }
        let build = read("build.yml");
        let report = read("test-report.yml");
        assert!(
            build.contains("name: ci-run") && report.contains("name: ci-run"),
            "the ci-run artifact name drifted between build.yml and test-report.yml"
        );
    }

    /// The cache identity (key, substituter, bucket) lives in support/nix.rs
    /// and, as a test-verified copy, in the setup-nix action Nix needs before
    /// the binary can run; a workflow spelling it again is a 12th paste
    /// waiting to rot.
    #[test]
    fn the_cache_identity_lives_in_the_binary_and_the_setup_action() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../.github");
        // The nix package builds this crate standalone, without the repo
        // around it; the lint still runs on every in-repo cargo test.
        if !root.is_dir() {
            return;
        }
        let action = std::fs::read_to_string(root.join("actions/setup-nix/action.yml")).unwrap();
        let expected: String = crate::support::nix::nix_config()
            .lines()
            .map(|line| format!("          {line}\n"))
            .collect();
        assert!(
            action.contains(&expected),
            "the setup-nix action's nix config drifted from `wasinix ci nix-config`"
        );
        for entry in std::fs::read_dir(root.join("workflows")).unwrap().flatten() {
            let text = std::fs::read_to_string(entry.path()).unwrap();
            for needle in [
                crate::support::nix::CACHE_PUBLIC_KEY,
                crate::support::nix::CACHE_SUBSTITUTER,
                crate::support::nix::CACHE_BUCKET,
            ] {
                assert!(
                    !text.contains(needle),
                    "{}: spells the cache identity; use the setup-nix action",
                    entry.path().display()
                );
            }
        }
    }

    /// Comments are written by the surface registry: sanitized, budgeted,
    /// and bounded by the sticky set. A workflow talking to the comments API
    /// directly bypasses all three. Reactions are not comments, and the
    /// constant-body fallback for a job that dies before the binary runs is
    /// the one enumerated exception.
    #[test]
    fn workflows_do_not_write_comments_directly() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../.github");
        // The nix package builds this crate standalone, without the repo
        // around it; the lint still runs on every in-repo cargo test.
        if !root.is_dir() {
            return;
        }
        let mut pending = vec![root.clone()];
        let mut found = Vec::new();
        while let Some(dir) = pending.pop() {
            for entry in std::fs::read_dir(&dir).unwrap().flatten() {
                let path = entry.path();
                if path.is_dir() {
                    pending.push(path);
                    continue;
                }
                if path.extension().is_none_or(|ext| ext != "yml" && ext != "yaml") {
                    continue;
                }
                let text = std::fs::read_to_string(&path).unwrap();
                let lines: Vec<&str> = text.lines().collect();
                for (index, line) in lines.iter().enumerate() {
                    if !line.contains("/comments")
                        || !(line.contains("gh api") || line.contains("curl"))
                    {
                        continue;
                    }
                    let window = lines[index..(index + 3).min(lines.len())].join("\n");
                    if window.contains("/reactions")
                        || window.contains("failed before it could report")
                        || window.contains("mutation commands only work on")
                    {
                        continue;
                    }
                    found.push(format!(
                        "{}:{}: {}",
                        path.display(),
                        index + 1,
                        line.trim()
                    ));
                }
            }
        }
        assert!(found.is_empty(), "{}", found.join("\n"));
    }
}

mod untrusted {
    use crate::ci::origin::{Classifier, CommandKind};
    use crate::ci::types::Request;
    use crate::cli::untrusted::{parse, split_words, ClapClassifier, UntrustedCommand};

    #[test]
    fn words_split_shell_style_and_unbalanced_quotes_fail() {
        assert_eq!(
            split_words("build core --with 'a b@1'").unwrap(),
            ["build", "core", "--with", "a b@1"]
        );
        assert!(split_words("build 'core").is_err());
        assert!(split_words("build core\\").is_err());
    }

    #[test]
    fn comment_commands_reenter_the_shared_grammar() {
        let UntrustedCommand::Request(Request::Build(build)) =
            parse("build core --enable-tag slow-tests").unwrap()
        else {
            panic!("expected a build request");
        };
        assert_eq!(build.enabled_tags, ["slow-tests"]);
        assert!(matches!(parse("help").unwrap(), UntrustedCommand::Help));
        assert_eq!(
            ClapClassifier.classify("build core").unwrap(),
            CommandKind::Build
        );
    }

    /// Adapter-owned flags do not exist in the untrusted grammar: the parse
    /// itself fails. A "not available" denylist message would mean the
    /// grammar accepted the flag and a filter caught it after the fact.
    #[test]
    fn adapter_owned_flags_are_unrepresentable_from_comments() {
        for command in [
            "build core --run-dir /tmp/x",
            "build core --run-dir=/tmp/x",
            "build core --push-cache",
            "build core --on ec2:host",
            "build core --json",
            "build core --plan",
            "build core --trusted-ref main",
            "build core --inputs-only",
            "spot packagesByProfile.zlib --junit-out out.xml",
            "diff build all --vs build all --on ec2:host",
        ] {
            let error = parse(command).unwrap_err().to_string();
            assert!(error.contains("unexpected argument"), "{command}: {error}");
            assert!(!error.contains("not available"), "{command}: {error}");
        }
    }

    #[test]
    fn a_typo_gets_a_suggestion_not_a_shrug() {
        let error = parse("buld core").unwrap_err().to_string();
        assert!(error.contains("build"), "{error}");
    }
}

mod builder {
    use crate::nix::builder::known_hosts_line;

    #[test]
    fn host_keys_pin_in_known_hosts_form_from_either_encoding() {
        use base64::Engine;
        let line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPZU root@ip-10-240-186-88\n";
        let encoded = base64::engine::general_purpose::STANDARD.encode(line);
        assert_eq!(
            known_hosts_line("example.com", &encoded),
            format!("example.com {}\n", line.trim())
        );
        assert_eq!(
            known_hosts_line("example.com", line.trim()),
            format!("example.com {}\n", line.trim())
        );
    }
}

mod remote_runs {
    use std::time::Duration;

    use crate::nix::route::EvaluationLimits;
    use crate::runs::remote::{launch_script, parse_poll};
    use crate::runs::Run;
    use crate::support::atoms::RunState;
    use crate::support::process::CommandStatus;

    fn run(state: RunState, exit_code: Option<u8>) -> Run {
        Run {
            run_id: "1-2-0".into(),
            command: vec!["ci".into(), "run".into()],
            state,
            pid: 7,
            started_at: 1,
            finished_at: None,
            exit_code,
        }
    }

    #[test]
    fn the_launch_script_quotes_what_it_interpolates() {
        let mut builder = crate::tests::route::builder();
        builder.capacity = 2;
        let script = launch_script(
            &builder,
            "/state/dir with space",
            "a".repeat(40).as_str(),
            "/nix/store/src",
            EvaluationLimits {
                workers: 4,
                memory: 8192,
                timeout: Duration::from_secs(1800),
            },
            &["ci".into(), "run".into(), "--request".into(), "a b".into()],
        );
        assert!(script.contains("'/state/dir with space'/repo.bundle"));
        assert!(script.contains("run start -- \"$bin\" ci run --request 'a b'"));
        assert!(script.contains("WASINIX_EVAL_WORKERS=4"));
        assert!(script.contains("WASINIX_HOST_LEASE_ROOT"));
        assert!(script.contains("WASINIX_HOST_LEASE_CAPACITY=2"));
        assert!(script.contains("WASINIX_RUN_DIR"));
    }

    #[test]
    fn poll_output_splits_into_liveness_record_and_event_bytes() {
        let run_json = serde_json::to_string_pretty(
            &crate::support::schema::to_value(&run(RunState::Running, None)).unwrap(),
        )
        .unwrap();
        let output = format!(
            "alive\n===WASINIX-RUN===\n{run_json}\n===WASINIX-EVENTS===\n{{\"schema\":1,\"event\":\"heartbeat\",\"at\":5}}\n"
        );
        let poll = parse_poll(output.as_bytes()).unwrap();
        assert!(poll.alive);
        assert_eq!(poll.run.unwrap().state, RunState::Running);
        assert!(String::from_utf8_lossy(&poll.events_chunk).contains("heartbeat"));

        let young = parse_poll(b"dead\n===WASINIX-RUN===\n\n===WASINIX-EVENTS===\n").unwrap();
        assert!(!young.alive);
        assert!(young.run.is_none(), "a not-yet-written record is not an error");
        assert!(young.events_chunk.is_empty());
    }

    #[test]
    fn observed_exits_follow_the_recorded_run() {
        let exit = |state: RunState, code: Option<u8>| run(state, code).state.exit(code);
        assert_eq!(exit(RunState::Complete, Some(0)), CommandStatus::SUCCESS);
        assert_eq!(
            exit(RunState::Failed, Some(3)),
            CommandStatus::from_code(3)
        );
        assert_eq!(exit(RunState::Cancelled, None), CommandStatus::FAILURE);
    }
}

mod content {
    use std::collections::BTreeSet;

    use crate::ci::contentdiff::{content_jobs, pairs_of};
    use crate::ci::evalmap::{EvalMap, JobInfo};
    use crate::support::atoms::JobAddr;

    fn map(jobs: &[(&str, &str)]) -> EvalMap {
        let mut map = EvalMap::default();
        for (attr, drv) in jobs {
            map.jobs.insert(JobAddr(attr.to_string()), drv.to_string());
        }
        map
    }

    #[test]
    fn only_moved_content_bearing_jobs_are_compared() {
        let base = map(&[
            ("packagesByProfile.zlib", "/nix/store/a.drv"),
            ("checks.git", "/nix/store/c.drv"),
            ("packagesByProfile.same", "/nix/store/s.drv"),
        ]);
        let mut head = map(&[
            ("packagesByProfile.zlib", "/nix/store/b.drv"),
            ("checks.git", "/nix/store/d.drv"),
            ("packagesByProfile.same", "/nix/store/s.drv"),
            ("packagesByProfile.added", "/nix/store/e.drv"),
        ]);
        head.info.insert(
            JobAddr("checks.git".into()),
            JobInfo {
                content_diff: false,
                ..JobInfo::default()
            },
        );

        let (jobs, excluded) = content_jobs(&base, &head, None);
        assert_eq!(jobs, ["packagesByProfile.zlib"]);
        assert_eq!(excluded, 1, "a moved check without content is counted out");

        let allowed: BTreeSet<String> = ["packagesByProfile.same".to_string()].into();
        let (jobs, _) = content_jobs(&base, &head, Some(&allowed));
        assert!(jobs.is_empty(), "unmoved jobs never enter the comparison");
    }

    #[test]
    fn pairs_cover_shared_outputs_of_jobs_built_on_both_sides() {
        let mut base = map(&[("packagesByProfile.zlib", "/nix/store/a.drv")]);
        let mut head = map(&[("packagesByProfile.zlib", "/nix/store/b.drv")]);
        for (side, out, dev) in [
            (&mut base, "/nix/store/old-out", "/nix/store/old-dev"),
            (&mut head, "/nix/store/new-out", "/nix/store/new-dev"),
        ] {
            side.outputs.insert(
                JobAddr("packagesByProfile.zlib".into()),
                [
                    ("out".to_string(), out.to_string()),
                    ("dev".to_string(), dev.to_string()),
                ]
                .into(),
            );
        }
        head.outputs
            .get_mut("packagesByProfile.zlib")
            .unwrap()
            .insert("doc".to_string(), "/nix/store/new-doc".to_string());

        let jobs = ["packagesByProfile.zlib".to_string()];
        let pairs = pairs_of(&base, &head, &jobs, &BTreeSet::new());
        let outputs: Vec<&str> = pairs.iter().map(|pair| pair.output.as_str()).collect();
        assert_eq!(outputs, ["dev", "out"], "one-sided outputs pair with nothing");

        let failed: BTreeSet<String> = jobs.iter().cloned().collect();
        assert!(
            pairs_of(&base, &head, &jobs, &failed).is_empty(),
            "a failed build has no new output to compare"
        );
    }
}

mod spot {
    use crate::nix::spot::nix_list;

    #[test]
    fn attr_lists_refuse_anything_that_could_escape_the_literal() {
        let listed = nix_list(&["exnrefEh.zlib".into(), "wasix32.curl".into()]).unwrap();
        assert_eq!(listed, "[\"exnrefEh.zlib\" \"wasix32.curl\"]");
        for hostile in ["a\"b", "a\\b", "${x}.zlib"] {
            assert!(nix_list(&[hostile.to_string()]).is_err(), "{hostile}");
        }
    }
}

mod fold {
    use std::collections::BTreeMap;

    use crate::ci::facts::{BuildFacts, Failure, FailureCause};
    use crate::ci::plan::{plan_of, TaskKind};
    use crate::ci::report::{fold, fragments_under, Conclusion, FoldContext, Fragment, FragmentData};
    use crate::ci::types::{Build, Case, Diff, Request, RevSource, Selector, SelectorKind};
    use crate::support::atoms::{JobAddr, Rev, TaskStatus};

    fn build(id: &str) -> Build<RevSource> {
        Build {
            case_id: Some(id.to_string()),
            source: RevSource {
                rev: Rev::parse(&"a".repeat(40)).unwrap(),
                patch: None,
                working_tree: false,
            },
            selectors: vec![Selector {
                kind: SelectorKind::Set,
                name: "core".into(),
            }],
            enabled_tags: Vec::new(),
            overrides: Vec::new(),
            from_pr: None,
            on: None,
        }
    }

    fn diff_request() -> Request<RevSource> {
        Request::Diff(Diff {
            baseline: "baseline".into(),
            content_diff: false,
            cases: vec![
                Case::Build(build("baseline")),
                Case::Build(build("candidate-1")),
            ],
        })
    }

    fn fragment(task_id: &str, kind: TaskKind, status: TaskStatus, headline: &str) -> Fragment {
        Fragment::new(task_id, task_id, kind, status, headline)
    }

    #[test]
    fn a_green_build_concludes_success() {
        let plan = plan_of(&Request::Build(build("case")), None, &[]);
        let fragments: BTreeMap<String, Fragment> = plan
            .tasks
            .iter()
            .map(|task| {
                (
                    task.task_id.clone(),
                    fragment(&task.task_id, task.kind, TaskStatus::Success, "ok"),
                )
            })
            .collect();
        let report = fold(&plan, &fragments, FoldContext::default());
        assert_eq!(report.conclusion, Some(Conclusion::Success));
        assert!(report.complete);
        assert_eq!(report.title, "CI passed");
    }

    #[test]
    fn a_failed_gate_concludes_failure_and_skips_its_downstream() {
        let plan = plan_of(&Request::Build(build("case")), None, &[]);
        let mut fragments = BTreeMap::new();
        fragments.insert(
            "case.treefmt".to_string(),
            fragment("case.treefmt", TaskKind::Validation, TaskStatus::Success, "ok"),
        );
        fragments.insert(
            "case.eval-inputs".to_string(),
            fragment(
                "case.eval-inputs",
                TaskKind::Eval,
                TaskStatus::Failure,
                "could not evaluate",
            ),
        );
        let report = fold(&plan, &fragments, FoldContext::default());
        assert_eq!(report.conclusion, Some(Conclusion::Failure));
        assert!(report.complete, "a required failure closes the run");
        let eval = report
            .tasks
            .iter()
            .find(|task| task.task_id == "case.eval")
            .unwrap();
        assert_eq!(eval.status, TaskStatus::Skipped);
    }

    #[test]
    fn a_base_side_failure_concludes_neutral() {
        let plan = plan_of(&diff_request(), None, &[]);
        let mut fragments = BTreeMap::new();
        for task in &plan.tasks {
            let status = if task.case == "baseline" && task.kind == TaskKind::Eval {
                TaskStatus::Failure
            } else if task.case == "baseline" {
                continue;
            } else {
                TaskStatus::Success
            };
            fragments.insert(
                task.task_id.clone(),
                fragment(&task.task_id, task.kind, status, "x"),
            );
        }
        let report = fold(
            &plan,
            &fragments,
            FoldContext {
                baseline_case: Some("baseline".into()),
                finished: true,
                comparisons: vec![crate::ci::compare::Comparison {
                    candidate: "candidate-1".into(),
                    base_evaluated: false,
                    head_evaluated: true,
                    eval: None,
                    builds: None,
                }],
                ..FoldContext::default()
            },
        );
        assert_eq!(report.conclusion, Some(Conclusion::Neutral), "{}", report.title);
        assert!(report.title.contains("could not compare"), "{}", report.title);
    }

    fn all_green(plan: &crate::ci::plan::Plan) -> BTreeMap<String, Fragment> {
        plan.tasks
            .iter()
            .map(|task| {
                (
                    task.task_id.clone(),
                    fragment(&task.task_id, task.kind, TaskStatus::Success, "ok"),
                )
            })
            .collect()
    }

    fn projected(
        eval: Option<crate::ci::compare::EvalDiff>,
        builds: Option<crate::ci::compare::BuildDiff>,
    ) -> crate::ci::compare::Comparison {
        crate::ci::compare::Comparison {
            candidate: "candidate-1".into(),
            base_evaluated: true,
            head_evaluated: true,
            eval,
            builds,
        }
    }

    #[test]
    fn a_diff_stays_open_until_its_process_finishes() {
        let plan = plan_of(&diff_request(), None, &[]);
        // Every task reported green, builds included; only the eval half of
        // the comparison exists. Gate accounting alone would conclude here.
        let report = fold(
            &plan,
            &all_green(&plan),
            FoldContext {
                baseline_case: Some("baseline".into()),
                finished: false,
                comparisons: vec![projected(
                    Some(crate::ci::compare::EvalDiff::default()),
                    None,
                )],
                ..FoldContext::default()
            },
        );
        assert_eq!(report.conclusion, None, "{}", report.title);
        assert!(!report.complete);
    }

    #[test]
    fn regressions_in_the_projection_conclude_failure() {
        let plan = plan_of(&diff_request(), None, &[]);
        let report = fold(
            &plan,
            &all_green(&plan),
            FoldContext {
                baseline_case: Some("baseline".into()),
                finished: true,
                comparisons: vec![projected(
                    Some(crate::ci::compare::EvalDiff::default()),
                    Some(crate::ci::compare::BuildDiff {
                        regressions: vec![crate::support::atoms::JobAddr("checks.zlib".into())],
                        ..crate::ci::compare::BuildDiff::default()
                    }),
                )],
                ..FoldContext::default()
            },
        );
        assert_eq!(report.conclusion, Some(Conclusion::Failure));
        assert!(report.title.contains("1 regressions"), "{}", report.title);
    }

    #[test]
    fn a_clean_finished_diff_concludes_success() {
        let plan = plan_of(&diff_request(), None, &[]);
        let report = fold(
            &plan,
            &all_green(&plan),
            FoldContext {
                baseline_case: Some("baseline".into()),
                finished: true,
                comparisons: vec![projected(
                    Some(crate::ci::compare::EvalDiff::default()),
                    Some(crate::ci::compare::BuildDiff::default()),
                )],
                ..FoldContext::default()
            },
        );
        assert_eq!(report.conclusion, Some(Conclusion::Success), "{}", report.title);
    }

    #[test]
    fn an_uncompared_candidate_with_an_evaluated_base_concludes_failure() {
        let plan = plan_of(&diff_request(), None, &[]);
        let report = fold(
            &plan,
            &all_green(&plan),
            FoldContext {
                baseline_case: Some("baseline".into()),
                finished: true,
                comparisons: vec![crate::ci::compare::Comparison {
                    candidate: "candidate-1".into(),
                    base_evaluated: true,
                    head_evaluated: false,
                    eval: None,
                    builds: None,
                }],
                ..FoldContext::default()
            },
        );
        assert_eq!(report.conclusion, Some(Conclusion::Failure), "{}", report.title);
        assert!(report.title.contains("could not compare"), "{}", report.title);
    }

    #[test]
    fn a_finished_run_resolves_pending_gates_instead_of_holding_open() {
        let plan = plan_of(&Request::Build(build("case")), None, &[]);
        let report = fold(
            &plan,
            &BTreeMap::new(),
            FoldContext {
                finished: true,
                ..FoldContext::default()
            },
        );
        assert!(report.complete);
        assert_eq!(report.conclusion, Some(Conclusion::Failure));
        assert!(report
            .tasks
            .iter()
            .all(|task| task.status == TaskStatus::Cancelled));
    }

    #[test]
    fn failures_flow_from_typed_build_fragments() {
        let plan = plan_of(&Request::Build(build("case")), None, &[]);
        let mut fragments: BTreeMap<String, Fragment> = plan
            .tasks
            .iter()
            .map(|task| {
                (
                    task.task_id.clone(),
                    fragment(&task.task_id, task.kind, TaskStatus::Success, "ok"),
                )
            })
            .collect();
        let facts = BuildFacts {
            complete: true,
            failures: vec![Failure {
                job: JobAddr("checks.zlib".into()),
                cause: FailureCause::Direct,
                class: Some("Build".into()),
                message: Some("exit 1".into()),
                jobs: Vec::new(),
                position: None,
                log: None,
            }],
            ..BuildFacts::default()
        };
        fragments.insert(
            "case.core".to_string(),
            fragment("case.core", TaskKind::Build, TaskStatus::Failure, "1 failed")
                .with_data(FragmentData::Build(facts)),
        );
        let report = fold(&plan, &fragments, FoldContext::default());
        assert_eq!(report.failures["case.core"][0].job.as_str(), "checks.zlib");
    }

    #[test]
    fn a_failure_position_becomes_a_repo_relative_annotation() {
        let plan = plan_of(&Request::Build(build("case")), None, &[]);
        let mut fragments: BTreeMap<String, Fragment> = plan
            .tasks
            .iter()
            .map(|task| {
                (
                    task.task_id.clone(),
                    fragment(&task.task_id, task.kind, TaskStatus::Success, "ok"),
                )
            })
            .collect();
        let facts = BuildFacts {
            complete: true,
            failures: vec![Failure {
                job: JobAddr("checks.zlib".into()),
                cause: FailureCause::Direct,
                class: Some("Build".into()),
                message: Some("exit 1".into()),
                jobs: Vec::new(),
                position: Some("/nix/store/abc123-source/pkgs/zlib.nix:12".into()),
                log: None,
            }],
            ..BuildFacts::default()
        };
        fragments.insert(
            "case.core".to_string(),
            fragment("case.core", TaskKind::Build, TaskStatus::Failure, "1 failed")
                .with_data(FragmentData::Build(facts)),
        );
        let report = fold(&plan, &fragments, FoldContext::default());
        assert_eq!(report.annotations.len(), 1);
        assert_eq!(report.annotations[0].path, "pkgs/zlib.nix");
        assert_eq!(report.annotations[0].line, 12);
        assert_eq!(report.annotations[0].title, "checks.zlib");
    }

    #[test]
    fn a_corrupt_fragment_fails_the_fold_loudly() {
        let scratch = crate::support::fs::Scratch::create("wasinix-test").unwrap();
        let good = fragment("case.core", TaskKind::Build, TaskStatus::Success, "ok");
        good.write(&scratch.path().join("a.json")).unwrap();
        std::fs::write(scratch.path().join("b.json"), "{ torn").unwrap();
        let error = fragments_under(scratch.path()).unwrap_err().to_string();
        assert!(error.contains("b.json"), "{error}");
        std::fs::remove_file(scratch.path().join("b.json")).unwrap();
        assert_eq!(fragments_under(scratch.path()).unwrap().len(), 1);
    }
}

mod scenarios {
    //! The report scenarios both golden families render: one construction,
    //! two projections.

    use std::collections::BTreeMap;

    use crate::ci::facts::{BuildFacts, Failure, FailureCause, LogRef};
    use crate::ci::plan::{plan_of, TaskKind};
    use crate::ci::report::{fold, FoldContext, Fragment, FragmentData, Report};
    use crate::ci::types::{Build, Case, Diff, Request, RevSource, Selector, SelectorKind};
    use crate::support::atoms::{Bytes, DurationSecs, JobAddr, Rev, TaskStatus};

    pub type Fragments = BTreeMap<String, Fragment>;

    fn build(id: &str) -> Build<RevSource> {
        Build {
            case_id: Some(id.to_string()),
            source: RevSource {
                rev: Rev::parse(&"a".repeat(40)).unwrap(),
                patch: None,
                working_tree: false,
            },
            selectors: vec![Selector {
                kind: SelectorKind::Set,
                name: "core".into(),
            }],
            enabled_tags: Vec::new(),
            overrides: Vec::new(),
            from_pr: None,
            on: None,
        }
    }

    fn green_fragments(plan: &crate::ci::plan::Plan) -> Fragments {
        plan.tasks
            .iter()
            .map(|task| {
                let mut fragment = Fragment::new(
                    &task.task_id,
                    &task.label,
                    task.kind,
                    TaskStatus::Success,
                    "ok",
                );
                fragment.elapsed_seconds = Some(DurationSecs(12.0));
                (task.task_id.clone(), fragment)
            })
            .collect()
    }

    pub fn green() -> (Report, Fragments) {
        let request = Request::Build(build("case"));
        let plan = plan_of(&request, Some("golden"), &[]);
        let fragments = green_fragments(&plan);
        let report = fold(
            &plan,
            &fragments,
            FoldContext {
                started_at: Some(1_755_000_000),
                finished_at: Some(1_755_003_600),
                request: Some(request),
                ..FoldContext::default()
            },
        );
        (report, fragments)
    }

    pub fn failing() -> (Report, Fragments) {
        let request = Request::Build(build("case"));
        let plan = plan_of(&request, Some("golden"), &[]);
        let mut fragments = green_fragments(&plan);
        let facts = BuildFacts {
            complete: true,
            failures: vec![
                Failure {
                    job: JobAddr("checks.zlib".into()),
                    cause: FailureCause::Direct,
                    class: Some("Build".into()),
                    message: Some("builder failed with exit code 1".into()),
                    jobs: Vec::new(),
                    position: Some("pkgs/overlay/packages/zlib.nix:12".into()),
                    log: Some(LogRef {
                        path: "00112233445566778899.log.gz".into(),
                        bytes: Bytes(20_000),
                        archived_bytes: Bytes(20_000),
                        truncated: false,
                    }),
                },
                // A victim of the zlib failure: counted, never rowed.
                Failure {
                    job: JobAddr("checks.curl".into()),
                    cause: FailureCause::Transitive,
                    class: Some("Build".into()),
                    message: Some("build did not complete".into()),
                    jobs: Vec::new(),
                    position: None,
                    log: None,
                },
            ],
            counts: BTreeMap::from([("Build".to_string(), (40usize, 2usize))]),
            ..BuildFacts::default()
        };
        fragments.insert(
            "case.core".into(),
            Fragment::new(
                "case.core",
                "case: Core",
                TaskKind::Build,
                TaskStatus::Failure,
                "1 failed · 39 built",
            )
            .with_data(FragmentData::Build(facts)),
        );
        let report = fold(
            &plan,
            &fragments,
            FoldContext {
                started_at: Some(1_755_000_000),
                finished_at: Some(1_755_003_600),
                request: Some(request),
                ..FoldContext::default()
            },
        );
        (report, fragments)
    }

    pub fn infra_neutral() -> (Report, Fragments) {
        let request = Request::Diff(Diff {
            baseline: "baseline".into(),
            content_diff: false,
            cases: vec![
                Case::Build(build("baseline")),
                Case::Build(build("candidate-1")),
            ],
        });
        let plan = plan_of(&request, Some("golden"), &[]);
        let mut fragments = BTreeMap::new();
        for task in &plan.tasks {
            let status = if task.case == "baseline" && task.kind == TaskKind::Eval {
                TaskStatus::Failure
            } else if task.case == "baseline" {
                continue;
            } else {
                TaskStatus::Success
            };
            fragments.insert(
                task.task_id.clone(),
                Fragment::new(&task.task_id, &task.label, task.kind, status, "x"),
            );
        }
        let report = fold(
            &plan,
            &fragments,
            FoldContext {
                baseline_case: Some("baseline".into()),
                finished: true,
                comparisons: vec![crate::ci::compare::Comparison {
                    candidate: "candidate-1".into(),
                    base_evaluated: false,
                    head_evaluated: true,
                    eval: None,
                    builds: None,
                }],
                request: Some(request),
                ..FoldContext::default()
            },
        );
        (report, fragments)
    }

    /// A green diff whose comparison carries every non-failure story: fixes,
    /// rebuilds, version moves, added and removed jobs.
    pub fn diff_green() -> (Report, Fragments) {
        use crate::ci::compare::{BuildDiff, Comparison, EvalDiff, VersionUpdate};
        let request = Request::Diff(Diff {
            baseline: "baseline".into(),
            content_diff: false,
            cases: vec![
                Case::Build(build("baseline")),
                Case::Build(build("candidate-1")),
            ],
        });
        let plan = plan_of(&request, Some("golden"), &[]);
        let fragments = green_fragments(&plan);
        let comparison = Comparison {
            candidate: "candidate-1".into(),
            base_evaluated: true,
            head_evaluated: true,
            eval: Some(EvalDiff {
                rebuilt: vec![
                    JobAddr("checks.zlib".into()),
                    JobAddr("packagesByProfile.eh.zlib".into()),
                ],
                identity_transitions: vec!["packagesByProfile.eh.zlib: 1.3.1 -> 1.3.2".into()],
                version_updates: vec![VersionUpdate {
                    subject: "zlib".into(),
                    before: "1.3.1".into(),
                    after: "1.3.2".into(),
                    changelogs: Vec::new(),
                    jobs: vec![JobAddr("packagesByProfile.eh.zlib".into())],
                }],
                added: vec![JobAddr("checks.brotli".into())],
                removed: vec![JobAddr("checks.legacy-tool".into())],
                identities: BTreeMap::from([
                    (JobAddr("checks.brotli".into()), "1.1.0".to_string()),
                    (JobAddr("checks.legacy-tool".into()), "0.9.1".to_string()),
                    (JobAddr("checks.zlib".into()), "1.3.2".to_string()),
                ]),
                selected_count: 40,
                ..EvalDiff::default()
            }),
            builds: Some(BuildDiff {
                fixes: vec![JobAddr("checks.curl".into())],
                ..BuildDiff::default()
            }),
        };
        let report = fold(
            &plan,
            &fragments,
            FoldContext {
                baseline_case: Some("baseline".into()),
                finished: true,
                started_at: Some(1_755_000_000),
                finished_at: Some(1_755_003_600),
                comparisons: vec![comparison],
                request: Some(request),
            },
        );
        (report, fragments)
    }

    /// A diff mid-run: both evals landed, builds still going, so only the
    /// eval half of the comparison exists. The comment must already tell the
    /// added/removed/version story.
    pub fn diff_in_progress() -> (Report, Fragments) {
        use crate::ci::compare::{Comparison, EvalDiff};
        let request = Request::Diff(Diff {
            baseline: "baseline".into(),
            content_diff: false,
            cases: vec![
                Case::Build(build("baseline")),
                Case::Build(build("candidate-1")),
            ],
        });
        let plan = plan_of(&request, Some("golden"), &[]);
        let mut fragments = BTreeMap::new();
        for task in &plan.tasks {
            if matches!(task.kind, TaskKind::Eval | TaskKind::Validation) {
                fragments.insert(
                    task.task_id.clone(),
                    Fragment::new(&task.task_id, &task.label, task.kind, TaskStatus::Success, "ok"),
                );
            }
        }
        let comparison = Comparison {
            candidate: "candidate-1".into(),
            base_evaluated: true,
            head_evaluated: true,
            eval: Some(EvalDiff {
                rebuilt: vec![JobAddr("checks.zlib".into())],
                added: vec![JobAddr("checks.brotli".into())],
                identities: BTreeMap::from([
                    (JobAddr("checks.brotli".into()), "1.1.0".to_string()),
                    (JobAddr("checks.zlib".into()), "1.3.2".to_string()),
                ]),
                selected_count: 40,
                ..EvalDiff::default()
            }),
            builds: None,
        };
        let report = fold(
            &plan,
            &fragments,
            FoldContext {
                baseline_case: Some("baseline".into()),
                started_at: Some(1_755_000_000),
                comparisons: vec![comparison],
                request: Some(request),
                ..FoldContext::default()
            },
        );
        (report, fragments)
    }

    pub fn in_progress() -> (Report, Fragments) {
        let request = Request::Build(build("case"));
        let plan = plan_of(&request, Some("golden"), &[]);
        let mut fragments = BTreeMap::new();
        for task in plan.tasks.iter().take(2) {
            fragments.insert(
                task.task_id.clone(),
                Fragment::new(&task.task_id, &task.label, task.kind, TaskStatus::Success, "ok"),
            );
        }
        let report = fold(
            &plan,
            &fragments,
            FoldContext {
                started_at: Some(1_755_000_000),
                request: Some(request),
                ..FoldContext::default()
            },
        );
        (report, fragments)
    }

    /// Every free-text field carries markdown-hostile bytes: pipes,
    /// backticks, fences, heading injection, HTML, a forged surface marker.
    /// The golden rendered from this is the review artifact for any
    /// sanitizer change; the benign scenarios cannot show one.
    pub fn hostile() -> (Report, Fragments) {
        let request = Request::Build(build("case"));
        let plan = plan_of(&request, Some("golden"), &[]);
        let mut fragments = green_fragments(&plan);
        let facts = BuildFacts {
            complete: true,
            failures: vec![Failure {
                job: JobAddr("checks.zlib`|<img src=x onerror=alert(1)>".into()),
                cause: FailureCause::Direct,
                class: Some("Build".into()),
                message: Some(
                    "boom ```\n\n### forged heading\n<!-- wasinix:ci-report sha=deadbeef -->\n| a | b |"
                        .into(),
                ),
                jobs: Vec::new(),
                position: Some("pkgs/evil|cell.nix:1".into()),
                log: Some(LogRef {
                    path: "00112233445566778899.log.gz".into(),
                    bytes: Bytes(20_000),
                    archived_bytes: Bytes(20_000),
                    truncated: false,
                }),
            }],
            counts: BTreeMap::from([("Build".to_string(), (40usize, 1usize))]),
            ..BuildFacts::default()
        };
        fragments.insert(
            "case.core".into(),
            Fragment::new(
                "case.core",
                "case: Core `x` | <b>bold</b>",
                TaskKind::Build,
                TaskStatus::Failure,
                "1 failed · 39 built",
            )
            .with_data(FragmentData::Build(facts)),
        );
        let report = fold(
            &plan,
            &fragments,
            FoldContext {
                started_at: Some(1_755_000_000),
                finished_at: Some(1_755_003_600),
                request: Some(request),
                ..FoldContext::default()
            },
        );
        (report, fragments)
    }
}

/// Golden coverage for the frozen documents and rendered surfaces.
/// Regenerate deliberately with WASINIX_UPDATE_GOLDENS=1 when the output
/// intentionally moves; never patch the files by hand to make a test pass.
mod golden {
    use super::scenarios;

    fn golden_dir() -> std::path::PathBuf {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures/golden")
    }

    pub(super) fn check_text(name: &str, rendered: &str) {
        let path = golden_dir().join(name);
        if crate::support::env::update_goldens() {
            std::fs::create_dir_all(golden_dir()).unwrap();
            std::fs::write(&path, rendered).unwrap();
            return;
        }
        let expected = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("{}: {e}; author with WASINIX_UPDATE_GOLDENS=1", path.display()));
        assert_eq!(rendered, expected, "{} drifted from its golden", name);
    }

    fn check(name: &str, report: &crate::ci::report::Report) {
        let value = crate::support::schema::to_value(report).unwrap();
        let mut rendered =
            serde_json::to_string_pretty(&serde_json::to_value(&value).unwrap()).unwrap();
        rendered.push('\n');
        check_text(name, &rendered);
    }

    #[test]
    fn report_green() {
        check("report-green.json", &scenarios::green().0);
    }

    #[test]
    fn report_failing() {
        check("report-failing.json", &scenarios::failing().0);
    }

    #[test]
    fn report_infra_neutral() {
        check("report-infra-neutral.json", &scenarios::infra_neutral().0);
    }

    #[test]
    fn report_in_progress() {
        check("report-in-progress.json", &scenarios::in_progress().0);
    }
}

mod wire_format {
    /// Every key in every golden document is camelCase; a snake_case key is
    /// a struct that forgot its rename_all.
    #[test]
    fn no_snake_keys_reach_the_wire() {
        fn walk(value: &serde_json::Value, path: &str, offenders: &mut Vec<String>) {
            match value {
                serde_json::Value::Object(map) => {
                    for (key, inner) in map {
                        // Job addresses and store paths are data, not field
                        // names, once nested under a map-valued field.
                        if key.contains('_') && !key.contains('.') && !key.contains('/') {
                            offenders.push(format!("{path}.{key}"));
                        }
                        walk(inner, &format!("{path}.{key}"), offenders);
                    }
                }
                serde_json::Value::Array(items) => {
                    for item in items {
                        walk(item, path, offenders);
                    }
                }
                _ => {}
            }
        }
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures/golden");
        let mut offenders = Vec::new();
        for entry in std::fs::read_dir(&dir).unwrap().flatten() {
            let path = entry.path();
            if path.extension().is_some_and(|ext| ext == "json") {
                let value: serde_json::Value =
                    serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
                walk(&value, path.file_name().unwrap().to_str().unwrap(), &mut offenders);
            }
        }
        assert!(offenders.is_empty(), "snake keys on the wire: {offenders:?}");
    }
}

mod facts {
    use std::collections::BTreeMap;
    use std::path::PathBuf;

    use crate::ci::facts::{self, junit, logs, Failure, FailureCause, TestOutcome};
    use crate::support::atoms::JobAddr;
    use crate::support::fs::Scratch;

    fn junit_file(dir: &std::path::Path, name: &str, body: &str) -> PathBuf {
        let path = dir.join(name);
        std::fs::write(&path, format!("<testsuite>{body}</testsuite>")).unwrap();
        path
    }

    fn case(attr: &str, class: &str, seconds: f64, failure: Option<&str>) -> String {
        let inner = failure
            .map(|log| format!("<failure message=\"failed\">{log}</failure>"))
            .unwrap_or_default();
        format!("<testcase name=\"&quot;{attr}&quot;\" classname=\"{class}\" time=\"{seconds}\">{inner}</testcase>")
    }

    #[test]
    fn junit_parsing_unquotes_attrs_and_reads_failures() {
        let scratch = Scratch::create("wasinix-test").unwrap();
        let path = junit_file(
            scratch.path(),
            "core.xml",
            &format!(
                "{}{}",
                case("checks.zlib", "Build", 65.2, Some("the log tail")),
                case("checks.ok", "Build", 1.0, None)
            ),
        );
        let cases = junit::parse_junits(&[path], false).unwrap();
        assert_eq!(cases.len(), 2);
        assert_eq!(cases[0].attr, "checks.zlib");
        assert_eq!(cases[0].message.as_deref(), Some("failed"));
        assert_eq!(cases[0].log.as_deref(), Some("the log tail"));
        assert!(cases[1].message.is_none());
    }

    #[test]
    fn a_missing_junit_is_incomplete_never_clean() {
        let scratch = Scratch::create("wasinix-test").unwrap();
        let facts = facts::ingest(
            &[scratch.path().join("absent.xml")],
            None,
            &BTreeMap::new(),
            std::time::SystemTime::now(),
            &scratch.path().join("logs"),
        )
        .unwrap();
        assert!(!facts.complete);
        assert!(facts.failures.is_empty());
    }

    #[test]
    fn junit_writing_escapes_attribute_values() {
        let mut written = junit::Case::new("job".into(), "Build".into());
        written.message = Some("broke \"quoted\" & <tagged>".into());
        let xml = junit::write_junit(&[written]);
        assert!(xml.contains("&quot;quoted&quot;"), "{xml}");
        assert!(xml.contains("&amp;"), "{xml}");
        let scratch = Scratch::create("wasinix-test").unwrap();
        let path = scratch.path().join("t.xml");
        std::fs::write(&path, &xml).unwrap();
        let parsed = junit::parse_junits(&[path], false).unwrap();
        assert_eq!(
            parsed[0].message.as_deref(),
            Some("broke \"quoted\" & <tagged>")
        );
    }

    #[test]
    fn a_backfilled_failure_round_trips_without_growing_a_log() {
        let mut written = junit::Case::new("job".into(), "Build".into());
        written.message = Some("build did not complete".into());
        let xml = junit::write_junit(&[written]);
        let scratch = Scratch::create("wasinix-test").unwrap();
        let path = scratch.path().join("t.xml");
        std::fs::write(&path, &xml).unwrap();
        let parsed = junit::parse_junits(&[path], false).unwrap();
        // A message echoed into the body would read back as a build log and
        // defeat the transitive classification of jobs that never ran.
        assert_eq!(parsed[0].log.as_deref().unwrap_or(""), "");
    }

    #[test]
    fn expectations_shape_test_outcomes() {
        use crate::ci::evalmap::{ExpectedOutcome, TestExpectation};
        let mut case = junit::Case::new("checks.icu".into(), "Build".into());
        case.expectation = Some(TestExpectation {
            outcome: ExpectedOutcome::Xfail,
            reason: "no data archive".into(),
        });
        assert_eq!(junit::test_outcome(&case), TestOutcome::Xfail);
        case.message = Some("failed".into());
        assert_eq!(junit::test_outcome(&case), TestOutcome::Fail);
        case.message = None;
        case.transitive = true;
        assert_eq!(junit::test_outcome(&case), TestOutcome::Skipped);
    }

    #[test]
    fn archived_logs_bind_into_their_failures() {
        let scratch = Scratch::create("wasinix-test").unwrap();
        let logs_dir = scratch.path().join("logs");
        let root = logs::RootCause {
            drv: "/nix/store/abc-openssl-3.0.drv".into(),
            name: "openssl-3.0".into(),
            log: "configure: error: no".into(),
            jobs: vec!["checks.zlib".into()],
        };
        let mut failures = vec![Failure {
            job: JobAddr("openssl-3.0".into()),
            cause: FailureCause::Dependency,
            class: None,
            message: None,
            jobs: vec![JobAddr("checks.zlib".into())],
            position: None,
            log: None,
        }];
        let manifest = logs::archive(
            &logs_dir,
            &[],
            &[root],
            &BTreeMap::new(),
            &mut failures,
        )
        .unwrap();
        assert_eq!(manifest.logs.len(), 1);
        let log_ref = failures[0].log.as_ref().expect("log bound to failure");
        let tail = logs::read_archived(&logs_dir, log_ref, 4096).unwrap();
        assert_eq!(tail, "configure: error: no");
        // The manifest on disk round-trips through the same struct.
        let read: logs::LogManifest =
            crate::support::schema::read(&logs_dir.join("manifest.json")).unwrap();
        assert_eq!(read, manifest);
    }
}

mod process {
    use std::process::Command;

    use crate::support::process::CommandStatus;

    #[test]
    fn preserves_a_subprocess_exit_code() {
        let status = Command::new("sh").args(["-c", "exit 17"]).status().unwrap();
        assert_eq!(CommandStatus::from_exit(status).code(), 17);
    }

    #[cfg(unix)]
    #[test]
    fn a_signal_is_failure() {
        let status = Command::new("sh")
            .args(["-c", "kill -TERM $$"])
            .status()
            .unwrap();
        assert_eq!(CommandStatus::from_exit(status), CommandStatus::FAILURE);
    }
}

mod tools {
    use std::process::Command;
    use std::time::Duration;

    use crate::support::tools::{checked_text, rendered, timed_command};

    #[test]
    fn timed_commands_get_a_term_and_kill_deadline() {
        let command = timed_command("nix-eval-jobs", Duration::from_secs(1800));
        assert_eq!(
            rendered(&command),
            "timeout --foreground --signal=TERM --kill-after=30 1800 nix-eval-jobs"
        );
    }

    #[test]
    fn a_failing_tool_reports_its_context_and_diagnostics() {
        let mut command = Command::new("sh");
        command.args(["-c", "echo the-detail >&2; exit 1"]);
        let error = checked_text(&mut command, "probing").unwrap_err().to_string();
        assert!(error.contains("probing"), "{error}");
        assert!(error.contains("the-detail"), "{error}");
    }

    #[test]
    fn a_tool_reporting_on_stdout_is_still_heard() {
        let mut command = Command::new("sh");
        command.args(["-c", "echo stdout-detail; exit 1"]);
        let error = checked_text(&mut command, "probing").unwrap_err().to_string();
        assert!(error.contains("stdout-detail"), "{error}");
    }
}

mod format {
    use crate::support::format::{bytes, duration, short_rev};

    #[test]
    fn durations_have_one_spelling_per_magnitude() {
        assert_eq!(duration(12.0), "12s");
        assert_eq!(duration(92.0), "1m 32s");
        assert_eq!(duration(7212.0), "2h 0m");
    }

    #[test]
    fn short_revs_never_panic_on_short_input() {
        assert_eq!(short_rev("d2d8fa99c1b0aabbccdd00112233445566778899"), "d2d8fa99c1b0");
        assert_eq!(short_rev("abc"), "abc");
        assert_eq!(short_rev(""), "");
    }

    #[test]
    fn byte_counts_use_binary_units() {
        assert_eq!(bytes(512), "512 B");
        assert_eq!(bytes(9_957_000), "9.5 MiB");
    }
}

mod schema {
    use serde::{Deserialize, Serialize};

    use crate::support::schema::{self, Document};

    #[derive(Debug, PartialEq, Serialize, Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Probe {
        job_count: u32,
    }

    impl Document for Probe {
        const KIND: &'static str = "probe";
        const SCHEMA: u32 = 1;
    }

    #[test]
    fn documents_round_trip_through_their_envelope() {
        let value = schema::to_value(&Probe { job_count: 3 }).unwrap();
        assert_eq!(value["schema"], 1);
        assert_eq!(value["kind"], "probe");
        assert_eq!(value["jobCount"], 3);
        let back: Probe = schema::from_value(value, "test").unwrap();
        assert_eq!(back, Probe { job_count: 3 });
    }

    #[test]
    fn a_missing_or_wrong_schema_is_a_hard_error() {
        let mut value = schema::to_value(&Probe { job_count: 3 }).unwrap();
        value["schema"] = 2.into();
        assert!(schema::from_value::<Probe>(value.clone(), "test").is_err());
        value.as_object_mut().unwrap().remove("schema");
        assert!(schema::from_value::<Probe>(value.clone(), "test").is_err());
        value["schema"] = 1.into();
        value["kind"] = "other".into();
        assert!(schema::from_value::<Probe>(value, "test").is_err());
    }
}

mod atoms {
    use crate::support::atoms::{Rev, RunState};

    #[test]
    fn revisions_are_full_on_the_wire_and_short_on_display() {
        let rev = Rev::parse("D2D8FA99C1B0AABBCCDD00112233445566778899").unwrap();
        assert_eq!(rev.full(), "d2d8fa99c1b0aabbccdd00112233445566778899");
        assert_eq!(rev.to_string(), "d2d8fa99c1b0");
        assert!(Rev::parse("HEAD").is_err());
    }

    #[test]
    fn run_states_spell_camel_case_on_the_wire() {
        assert_eq!(
            serde_json::to_string(&RunState::TimedOut).unwrap(),
            "\"timedOut\""
        );
        assert!(RunState::Lost.is_final());
        assert!(!RunState::Running.is_final());
    }
}

mod fs {
    use crate::support::fs;

    #[test]
    fn atomic_writes_land_whole_and_errors_carry_the_path() {
        let scratch = fs::Scratch::create("wasinix-test").unwrap();
        let path = scratch.path().join("state.json");
        fs::write_atomic(&path, b"{}\n").unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), "{}\n");
        let missing = scratch.path().join("absent");
        let error = fs::read_to_string(&missing).unwrap_err().to_string();
        assert!(error.contains("absent"), "{error}");
    }

    #[test]
    fn tail_reads_only_the_end_of_a_file() {
        let scratch = fs::Scratch::create("wasinix-test").unwrap();
        let path = scratch.path().join("log");
        fs::write(&path, "front middle end".as_bytes()).unwrap();
        assert_eq!(fs::tail(&path, 3).unwrap(), "end");
    }
}

mod shell {
    use crate::support::shell::quote;

    #[test]
    fn quoting_survives_embedded_quotes() {
        assert_eq!(quote("plain-word_1.0"), "plain-word_1.0");
        assert_eq!(quote("has space"), "'has space'");
        assert_eq!(quote("it's"), r"'it'\''s'");
    }
}

mod table {
    use crate::support::table::render;

    #[test]
    fn columns_align_with_a_two_space_gutter() {
        let out = render(
            Some(&["id", "state"]),
            &[
                vec!["1755-1".into(), "running".into()],
                vec!["9".into(), "complete".into()],
            ],
        );
        assert_eq!(out, "id      state\n1755-1  running\n9       complete\n");
    }
}


mod buildset {
    use crate::nix::buildset::{dry_run_plan, realise_building_drv};
    use crate::nix::evaljobs;

    #[test]
    fn eval_jobs_lines_parse_typed_and_fail_loud() {
        let job = evaljobs::parse_line(
            r#"{"attrPath":["checks","zlib"],"drvPath":"/nix/store/z.drv","neededBuilds":["/nix/store/d.drv"],"cacheStatus":"notBuilt","meta":{"position":"pkgs/z.nix:1"}}"#,
        )
        .unwrap();
        assert_eq!(job.name(), "checks.zlib");
        assert_eq!(job.needed_builds, ["/nix/store/d.drv"]);
        assert_eq!(job.meta.position.as_deref(), Some("pkgs/z.nix:1"));
        assert!(evaljobs::parse_file("{ torn").is_err());
    }

    #[test]
    fn the_eval_error_excerpt_starts_at_the_root_cause() {
        let trace = "warning: unknown setting\n\
            error: worker error: error:\n\
            \x20      … while calling 'throwIf'\n\
            \x20        163|     in\n\
            \x20      error: attribute 'passthru.wasmer.name' already defined at pkgs/p.nix:24:13\n\
            \x20      at pkgs/p.nix:268:15:";
        let excerpt = evaljobs::error_excerpt(trace);
        assert!(excerpt
            .starts_with("error: attribute 'passthru.wasmer.name' already defined"));
        assert!(!excerpt.contains("worker error"));
        assert_eq!(
            evaljobs::error_excerpt("plain failure\nwith no error line"),
            "plain failure\nwith no error line"
        );
    }

    #[test]
    fn the_dry_run_plan_partitions_in_every_phrasing() {
        let plural = "these 2 derivations will be built:\n  /nix/store/a.drv\n  /nix/store/b.drv\nthese 3 paths will be fetched (1.0 MiB download, 2.0 MiB unpacked):\n  /nix/store/c\n  /nix/store/d\n  /nix/store/e\n";
        let plan = dry_run_plan(plural).unwrap();
        assert_eq!(
            plan.to_build.iter().collect::<Vec<_>>(),
            ["/nix/store/a.drv", "/nix/store/b.drv"]
        );
        assert_eq!(
            plan.fetched.iter().collect::<Vec<_>>(),
            ["/nix/store/c", "/nix/store/d", "/nix/store/e"],
            "the fetch set separates substitutable from locally valid"
        );
        let singular = "this derivation will be built:\n  /nix/store/only.drv\n";
        assert_eq!(dry_run_plan(singular).unwrap().to_build.len(), 1);
        assert!(dry_run_plan("").unwrap().to_build.is_empty());
        // A phrasing the parser does not know must not read as fully cached.
        assert!(dry_run_plan("cannot price /nix/store/x.drv").is_err());
    }

    /// Real-nix integration: run with `cargo test -- --ignored` on a
    /// machine with a nix daemon; the crate's sandboxed check has none.
    #[test]
    #[ignore = "needs a nix daemon"]
    fn the_driver_builds_reports_and_marks_cached_on_rerun() {
        use crate::nix::buildset::{build_union, StreamEvent, UnionCase, UnionRequest};
        use crate::nix::route::{EvaluationLimits, Route};
        let scratch = crate::support::fs::Scratch::create("wasinix-driver").unwrap();
        let instantiate = |expr: &str| -> (String, String) {
            let drv = crate::support::nix::Invocation::tool("nix-instantiate")
                .args(["--expr", expr])
                .checked_text("instantiate")
                .unwrap();
            let out = crate::support::nix::Invocation::tool("nix-store")
                .args(["--query", "--outputs"])
                .operand(drv.trim())
                .checked_text("outputs")
                .unwrap();
            (drv.trim().to_string(), out.trim().to_string())
        };
        let nonce = std::process::id();
        let (ok_drv, ok_out) = instantiate(&format!(
            r#"derivation {{ name = "wasinix-driver-ok-{nonce}"; system = builtins.currentSystem; builder = "/bin/sh"; args = ["-c" "echo ok > $out"]; }}"#
        ));
        let (bad_drv, bad_out) = instantiate(&format!(
            r#"derivation {{ name = "wasinix-driver-bad-{nonce}"; system = builtins.currentSystem; builder = "/bin/sh"; args = ["-c" "echo doom >&2; exit 1"]; }}"#
        ));
        let jobs_file = scratch.path().join("jobs.jsonl");
        std::fs::write(
            &jobs_file,
            format!(
                "{}
{}
",
                serde_json::json!({"attrPath": ["ok"], "drvPath": ok_drv, "outputs": {"out": ok_out}}),
                serde_json::json!({"attrPath": ["bad"], "drvPath": bad_drv, "outputs": {"out": bad_out}}),
            ),
        )
        .unwrap();
        let route = Route::Local(EvaluationLimits {
            workers: 1,
            memory: 2048,
            timeout: std::time::Duration::from_secs(600),
        });
        let run = |dir: &str| {
            let mut results = Vec::new();
            let status = build_union(
                UnionRequest {
                    cases: vec![UnionCase {
                        id: "case".into(),
                        jobs_file: jobs_file.clone(),
                        jobs: vec!["ok".into(), "bad".into()],
                    }],
                    work_dir: &scratch.path().join(dir),
                    result_file: scratch.path().join(dir).join("results.xml"),
                    route: &route,
                    max_jobs: 2,
                    hard_timeout: None,
                    push: false,
                },
                &mut |event| {
                    if let StreamEvent::Result(value) = event {
                        results.push(value);
                    }
                    Ok(())
                },
            )
            .unwrap();
            (status, results)
        };

        let (status, results) = run("first");
        assert!(!status.is_success());
        let find = |results: &[serde_json::Value], attr: &str| -> serde_json::Value {
            results
                .iter()
                .find(|value| value["attr"] == format!("case::{attr}"))
                .unwrap()
                .clone()
        };
        assert_eq!(find(&results, "ok")["success"], true);
        let bad = find(&results, "bad");
        assert_eq!(bad["success"], false);
        assert!(bad["error"].as_str().unwrap().contains("doom"), "{bad}");
        let junit = std::fs::read_to_string(scratch.path().join("first/results.xml")).unwrap();
        assert!(junit.contains("case::ok"), "{junit}");

        // The rerun finds the built output valid and reports it cached; the
        // failure builds again and fails again.
        let (status, results) = run("second");
        assert!(!status.is_success());
        assert_eq!(find(&results, "ok")["cached"], true);
        assert_eq!(find(&results, "bad")["success"], false);
    }

    #[test]
    fn realise_progress_lines_name_their_derivation() {
        assert_eq!(
            realise_building_drv("building '/nix/store/abc-zlib.drv'..."),
            Some("/nix/store/abc-zlib.drv")
        );
        assert_eq!(realise_building_drv("copying path '/nix/store/x'"), None);
        assert_eq!(realise_building_drv("building trees"), None);
    }
}

mod git_support {
    use crate::support::git::{commit, Stage, git, is_ancestor, resolve_rev};
    use crate::support::fs::Scratch;

    fn repo() -> (Scratch, std::path::PathBuf) {
        let scratch = Scratch::create("wasinix-test").unwrap();
        let repo = scratch.path().join("repo");
        std::fs::create_dir(&repo).unwrap();
        for args in [
            vec!["init", "-q"],
            vec!["config", "user.name", "Test"],
            vec!["config", "user.email", "test@example.com"],
        ] {
            assert!(std::process::Command::new("git")
                .arg("-C")
                .arg(&repo)
                .args(&args)
                .status()
                .unwrap()
                .success());
        }
        std::fs::write(repo.join("file"), "one\n").unwrap();
        git(&repo, &["add", "-A"]).unwrap();
        git(&repo, &["commit", "-q", "-m", "initial"]).unwrap();
        (scratch, repo)
    }

    #[test]
    fn commit_stages_only_the_named_paths() {
        let (_scratch, repo) = repo();
        std::fs::write(repo.join("rels.json"), "after\n").unwrap();
        std::fs::write(repo.join("other"), "after\n").unwrap();
        assert!(commit(&repo, Stage::Paths(&["rels.json"]), "rels only", None).unwrap());
        assert_eq!(git(&repo, &["log", "-1", "--format=%s"]).unwrap(), "rels only");
        assert_eq!(git(&repo, &["status", "--short"]).unwrap(), "?? other");
    }

    #[test]
    fn ancestry_answers_or_errors_but_never_guesses() {
        let (_scratch, repo) = repo();
        let first = resolve_rev(&repo, "HEAD").unwrap();
        std::fs::write(repo.join("file"), "two\n").unwrap();
        git(&repo, &["commit", "-aqm", "second"]).unwrap();
        assert!(is_ancestor(&repo, first.full(), "HEAD").unwrap());
        assert!(!is_ancestor(&repo, "HEAD", first.full()).unwrap());
        assert!(is_ancestor(&repo, "not-a-rev", "HEAD").is_err());
    }
}

mod workspace {
    use crate::ci::types::{Build, CaseRef, RevSource, Selector, SelectorKind};
    use crate::ci::workspace::{
        reproduced_worktree, working_patch, write_materialization, PATCH_FILE,
    };
    use crate::support::fs::Scratch;
    use crate::support::git::{git, resolve_rev};

    fn repo() -> (Scratch, std::path::PathBuf) {
        let scratch = Scratch::create("wasinix-test").unwrap();
        let repo = scratch.path().join("repo");
        std::fs::create_dir(&repo).unwrap();
        for args in [
            vec!["init", "-q"],
            vec!["config", "user.name", "Test"],
            vec!["config", "user.email", "test@example.com"],
        ] {
            assert!(std::process::Command::new("git")
                .arg("-C")
                .arg(&repo)
                .args(&args)
                .status()
                .unwrap()
                .success());
        }
        std::fs::write(repo.join("pin"), "old\n").unwrap();
        git(&repo, &["add", "-A"]).unwrap();
        git(&repo, &["commit", "-q", "-m", "initial"]).unwrap();
        (scratch, repo)
    }

    #[test]
    fn a_working_tree_patch_ignores_untracked_files() {
        let (_scratch, repo) = repo();
        std::fs::write(repo.join("pin"), "new\n").unwrap();
        std::fs::write(repo.join("stray"), "x\n").unwrap();
        let patch = working_patch(&repo).unwrap();
        assert!(patch.contains("pin"), "{patch}");
        assert!(!patch.contains("stray"), "{patch}");
    }

    #[test]
    fn a_case_reproduces_only_against_its_recorded_patch() {
        let (_scratch, repo) = repo();
        let rev = resolve_rev(&repo, "HEAD").unwrap();
        // Uncommitted edit becomes the materialization patch.
        std::fs::write(repo.join("pin"), "new\n").unwrap();
        let case = Build::<RevSource> {
            case_id: Some("case".into()),
            source: RevSource {
                rev: rev.clone(),
                patch: None,
                working_tree: true,
            },
            selectors: vec![Selector {
                kind: SelectorKind::Set,
                name: "core".into(),
            }],
            enabled_tags: Vec::new(),
            overrides: Vec::new(),
            from_pr: None,
            on: None,
        };
        let out = _scratch.path().join("prepared");
        let manifest = write_materialization(
            &repo,
            CaseRef::Build(&case),
            &serde_json::to_value(&case).unwrap(),
            &out,
        )
        .unwrap();
        assert!(!manifest.patch_hash.is_empty());

        let mut pinned = case.source.clone();
        pinned.patch = Some(manifest.patch_hash.clone());
        let reproduced =
            reproduced_worktree(&repo, &pinned, &out.join(PATCH_FILE)).unwrap();
        assert_eq!(
            std::fs::read_to_string(reproduced.path().join("pin")).unwrap(),
            "new\n"
        );
        drop(reproduced);

        pinned.patch = Some("0".repeat(64));
        let error = match reproduced_worktree(&repo, &pinned, &out.join(PATCH_FILE)) {
            Ok(_) => panic!("a wrong patch hash must refuse to reproduce"),
            Err(error) => error.to_string(),
        };
        assert!(error.contains("patch hash"), "{error}");
    }

    #[test]
    fn sibling_worktrees_survive_each_other() {
        let (_scratch, repo) = repo();
        let rev = resolve_rev(&repo, "HEAD").unwrap();
        let source = RevSource {
            rev,
            patch: None,
            working_tree: false,
        };
        let missing = _scratch.path().join("no-patch");
        let first = reproduced_worktree(&repo, &source, &missing).unwrap();
        let second = reproduced_worktree(&repo, &source, &missing).unwrap();
        drop(first);
        assert!(second.path().join("pin").exists());
    }
}

mod baseline {
    use crate::ci::baseline::{covers, expected_jobs, missing_status, publish_document};
    use crate::ci::evalmap::{EvalMap, StatusMap};
    use crate::ci::types::{Build, RevSource, Selector, SelectorKind};
    use crate::support::atoms::{JobAddr, JobStatus, Rev};

    fn case(jobs: &[&str]) -> Build<RevSource> {
        Build {
            case_id: Some("baseline".into()),
            source: RevSource {
                rev: Rev::parse(&"a".repeat(40)).unwrap(),
                patch: None,
                working_tree: false,
            },
            selectors: jobs
                .iter()
                .map(|name| Selector {
                    kind: SelectorKind::Job,
                    name: name.to_string(),
                })
                .collect(),
            enabled_tags: Vec::new(),
            overrides: Vec::new(),
            from_pr: None,
            on: None,
        }
    }

    fn map(jobs: &[&str]) -> EvalMap {
        EvalMap {
            jobs: jobs
                .iter()
                .map(|name| (JobAddr(name.to_string()), format!("/nix/store/{name}.drv")))
                .collect(),
            ..Default::default()
        }
    }

    #[test]
    fn a_baseline_requires_status_for_every_selected_evaluable_job() {
        let selected = case(&["one", "two"]);
        let mapping = map(&["one", "two"]);
        let partial: StatusMap = [(JobAddr("one".into()), JobStatus::Success)].into();
        assert_eq!(
            missing_status(&selected, &mapping, &partial).unwrap(),
            ["two"]
        );

        let complete: StatusMap = [
            (JobAddr("one".into()), JobStatus::Success),
            (JobAddr("two".into()), JobStatus::Failure),
        ]
        .into();
        let coverage: Vec<JobAddr> = expected_jobs(&selected, &mapping)
            .unwrap()
            .into_iter()
            .map(JobAddr)
            .collect();
        let document = publish_document(&mapping, &complete, &coverage, &Default::default());
        assert!(covers(&selected, &document));
        assert!(!covers(&case(&["one", "two", "three"]), &document));
    }
}

mod prepare {
    use crate::ci::prepare::{load, prepare_all, request_path};
    use crate::ci::types::{Build, Request, RevSource, Selector, SelectorKind};
    use crate::support::fs::Scratch;
    use crate::support::git::{git, resolve_rev};

    fn repo() -> (Scratch, std::path::PathBuf) {
        let scratch = Scratch::create("wasinix-test").unwrap();
        let repo = scratch.path().join("repo");
        std::fs::create_dir(&repo).unwrap();
        for args in [
            vec!["init", "-q", "-b", "main"],
            vec!["config", "user.name", "Test"],
            vec!["config", "user.email", "test@example.com"],
        ] {
            assert!(std::process::Command::new("git")
                .arg("-C")
                .arg(&repo)
                .args(&args)
                .status()
                .unwrap()
                .success());
        }
        std::fs::write(repo.join("file"), "one\n").unwrap();
        git(&repo, &["add", "-A"]).unwrap();
        git(&repo, &["commit", "-q", "-m", "initial"]).unwrap();
        (scratch, repo)
    }

    #[test]
    fn a_prepared_run_loads_back_with_its_tree_and_plan() {
        let (scratch, repo) = repo();
        let request = Request::Build(Build::<RevSource> {
            case_id: Some("case".into()),
            source: RevSource {
                rev: resolve_rev(&repo, "HEAD").unwrap(),
                patch: None,
                working_tree: false,
            },
            selectors: vec![Selector {
                kind: SelectorKind::Set,
                name: "core".into(),
            }],
            enabled_tags: Vec::new(),
            overrides: Vec::new(),
            from_pr: None,
            on: None,
        });
        let run_dir = scratch.path().join("run");
        let prepared = prepare_all(&repo, &request, &run_dir).unwrap();
        assert!(prepared.plan().tasks.iter().any(|t| t.task_id == "case.core"));

        let loaded = load(&run_dir).unwrap();
        assert_eq!(loaded.plan().tasks.len(), prepared.plan().tasks.len());
        // The recorded case carries its materialization digest.
        let value: serde_json::Value =
            crate::support::json::read(&request_path(&run_dir)).unwrap();
        assert!(value["source"]["patch"].is_string());
        // A clean case's recorded tree is the commit's own tree, so any
        // commit with identical content shares its published baseline.
        let manifest: crate::ci::workspace::Materialization = crate::support::schema::read(
            &run_dir.join("cases/case/prepared/materialization.json"),
        )
        .unwrap();
        assert_eq!(manifest.tree, git(&repo, &["rev-parse", "HEAD^{tree}"]).unwrap());

        // A second prepare into the same directory refuses.
        assert!(prepare_all(&repo, &request, &run_dir).is_err());
    }

    #[test]
    fn a_case_with_a_published_tree_adopts_its_evaluation() {
        use crate::ci::evalmap::EvalMap;
        use crate::support::atoms::{JobAddr, JobStatus};
        let (scratch, repo) = repo();
        // The working tree, not a plain rev: reuse keys on the materialized
        // tree, so a clean checkout matches what a commit's run published.
        let request = Request::Build(Build::<RevSource> {
            case_id: Some("case".into()),
            source: RevSource {
                rev: resolve_rev(&repo, "HEAD").unwrap(),
                patch: None,
                working_tree: true,
            },
            selectors: vec![Selector {
                kind: SelectorKind::Set,
                name: "core".into(),
            }],
            enabled_tags: Vec::new(),
            overrides: Vec::new(),
            from_pr: None,
            on: None,
        });
        let tree = git(&repo, &["rev-parse", "HEAD^{tree}"]).unwrap();
        let maps = scratch.path().join("maps");
        crate::support::fs::create_dir_all(&maps).unwrap();
        let published = EvalMap {
            rev: Some(resolve_rev(&repo, "HEAD").unwrap()),
            jobs: [(JobAddr("checks.zlib".into()), "/nix/store/z.drv".into())]
                .into_iter()
                .collect(),
            sets: [("core".to_string(), vec!["checks.zlib".to_string()])]
                .into_iter()
                .collect(),
            status: Some(
                [(JobAddr("checks.zlib".into()), JobStatus::Success)]
                    .into_iter()
                    .collect(),
            ),
            coverage: vec![JobAddr("checks.zlib".into())],
            ..EvalMap::default()
        };
        crate::support::schema::write(&maps.join(format!("{tree}.json")), &published).unwrap();

        let run_dir = scratch.path().join("run");
        let template = format!("{}/{{tree}}.json", maps.display());
        let loaded =
            crate::ci::prepare::prepare_all_with(&repo, &request, &run_dir, &template).unwrap();
        assert_eq!(loaded.preparation.reused, ["case"]);
        assert!(
            !loaded
                .plan()
                .tasks
                .iter()
                .any(|task| task.task_id == "case.core" || task.task_id == "case.eval"),
            "an adopted case plans no evaluation or builds"
        );
        let case = crate::ci::prepare::case_dir(&run_dir, "case");
        assert!(crate::ci::prepare::eval_map_path(&case).exists());
        assert!(crate::ci::prepare::status_path(&case).exists());

        // A red map is not adopted for a case under test: a re-run retries
        // instead of inheriting a flake forever.
        let mut red = published.clone();
        red.status = Some(
            [(JobAddr("checks.zlib".into()), JobStatus::Failure)]
                .into_iter()
                .collect(),
        );
        crate::support::schema::write(&maps.join(format!("{tree}.json")), &red).unwrap();
        let retry = scratch.path().join("run-retry");
        let loaded =
            crate::ci::prepare::prepare_all_with(&repo, &request, &retry, &template).unwrap();
        assert!(loaded.preparation.reused.is_empty());

        // A tree nobody published prepares the full plan.
        std::fs::remove_file(maps.join(format!("{tree}.json"))).unwrap();
        let cold = scratch.path().join("run-cold");
        let loaded =
            crate::ci::prepare::prepare_all_with(&repo, &request, &cold, &template).unwrap();
        assert!(loaded.preparation.reused.is_empty());
        assert!(loaded
            .plan()
            .tasks
            .iter()
            .any(|task| task.task_id == "case.core"));
    }

    #[test]
    fn a_running_run_loads_as_a_concluded_nothing_report() {
        use crate::ci::events::Event;
        use crate::support::atoms::{RunState, TaskStatus};
        let (scratch, repo) = repo();
        let request = Request::Build(Build::<RevSource> {
            case_id: Some("case".into()),
            source: RevSource {
                rev: resolve_rev(&repo, "HEAD").unwrap(),
                patch: None,
                working_tree: false,
            },
            selectors: vec![Selector {
                kind: SelectorKind::Set,
                name: "core".into(),
            }],
            enabled_tags: Vec::new(),
            overrides: Vec::new(),
            from_pr: None,
            on: None,
        });
        let run_dir = scratch.path().join("run");

        // Before the plan is recorded there is nothing to say.
        assert!(crate::github::publish::load_running(&run_dir, &[])
            .unwrap()
            .is_none());

        prepare_all(&repo, &request, &run_dir).unwrap();
        let events = [Event::RunStarted { at: 1, pid: 7 }];
        let rendered = crate::github::publish::load_running(&run_dir, &events)
            .unwrap()
            .expect("a prepared run renders");
        assert_eq!(rendered.report.conclusion, None);
        assert!(!rendered.report.complete);
        assert!(rendered
            .report
            .tasks
            .iter()
            .any(|task| task.task_id == "case.core" && task.status == TaskStatus::Pending));
        assert_eq!(rendered.snapshot.unwrap().state, RunState::Running);
    }

    #[test]
    fn a_bare_diff_bases_on_the_main_merge_base() {
        let (_scratch, repo) = repo();
        let base = git(&repo, &["rev-parse", "HEAD"]).unwrap();
        git(&repo, &["checkout", "-q", "-b", "feature"]).unwrap();
        std::fs::write(repo.join("file"), "two\n").unwrap();
        git(&repo, &["add", "-A"]).unwrap();
        git(&repo, &["commit", "-q", "-m", "feature"]).unwrap();
        assert_eq!(crate::cli::request::pr_base(&repo).unwrap(), base);
    }

    #[test]
    fn a_dirty_working_tree_materializes_under_its_own_tree_id() {
        let (scratch, repo) = repo();
        std::fs::write(repo.join("file"), "two\n").unwrap();
        let request = Request::Build(Build::<RevSource> {
            case_id: Some("case".into()),
            source: RevSource {
                rev: resolve_rev(&repo, "HEAD").unwrap(),
                patch: None,
                working_tree: true,
            },
            selectors: vec![Selector {
                kind: SelectorKind::Set,
                name: "core".into(),
            }],
            enabled_tags: Vec::new(),
            overrides: Vec::new(),
            from_pr: None,
            on: None,
        });
        let run_dir = scratch.path().join("run");
        prepare_all(&repo, &request, &run_dir).unwrap();
        let manifest: crate::ci::workspace::Materialization = crate::support::schema::read(
            &run_dir.join("cases/case/prepared/materialization.json"),
        )
        .unwrap();
        // The uncommitted edit is part of the materialized tree, so the
        // recorded key differs from the commit's and a baseline published
        // under it can never be mistaken for the commit's.
        assert_ne!(manifest.tree, git(&repo, &["rev-parse", "HEAD^{tree}"]).unwrap());
    }
}
