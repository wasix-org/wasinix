### ✅ Wasinix diff · green · [run](https://github.com/wasix-org/wasinix/actions/runs/1) · `aaaaaaaaaaaa`

**Comparison** · 1 fixed · 2 rebuilt · 1 version/rel changes · 1 added · 1 removed
**Coverage** · baseline 40/42 selected · 2 omitted by tags (history-tests: 2) · head 40/42 selected · 2 omitted by tags (history-tests: 2)

<details><summary>Fixed (1)</summary>

- `checks.curl`

</details>

<details><summary>Version or rel changed (1)</summary>

- `packages.wasix.eh.zlib: 1.3.1 -> 1.3.2`

</details>

<details><summary>Rebuilt (2)</summary>

- `checks.zlib` at 1.3.2
- `packages.wasix.eh.zlib`

</details>

<details><summary>Added (1)</summary>

- `checks.brotli` at 1.1.0 · selected

</details>

<details><summary>Removed (1)</summary>

- `checks.legacy-tool` at 0.9.1 · selected

</details>

<sub>baseline: Preparing evaluation inputs ✅ · Evaluating jobs ✅ · Core ✅<br>candidate-1: Preparing evaluation inputs ✅ · Evaluating jobs ✅ · Core ✅<br><a href="https://github.com/wasix-org/wasinix/actions/runs/1">full pipeline</a></sub>

<details><summary>Details</summary>

<details><summary>Request</summary>

```json
{
  "blocked": "fail",
  "action": "diff",
  "baseline": "baseline",
  "contentDiff": false,
  "cases": [
    {
      "action": "build",
      "caseId": "baseline",
      "selectors": [
        {
          "kind": "set",
          "name": "core"
        }
      ],
      "source": {
        "rev": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "workingTree": false
      }
    },
    {
      "action": "build",
      "caseId": "candidate-1",
      "selectors": [
        {
          "kind": "set",
          "name": "core"
        }
      ],
      "source": {
        "rev": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "workingTree": false
      }
    }
  ]
}
```

</details>

**Pipeline**

| task | status | result | time |
|:--|:--:|:--|--:|
| baseline: Preparing evaluation inputs | ✅ | ok | 12s |
| baseline: Evaluating jobs | ✅ | ok | 12s |
| candidate-1: Preparing evaluation inputs | ✅ | ok | 12s |
| candidate-1: Evaluating jobs | ✅ | ok | 12s |
| baseline: Core | ✅ | ok | 12s |
| candidate-1: Core | ✅ | ok | 12s |

**Downstream version changes (1)**

- **zlib** [1.3.1 → 1.3.2](https://github.com/madler/zlib/releases/tag/v1.3.2)

</details>
