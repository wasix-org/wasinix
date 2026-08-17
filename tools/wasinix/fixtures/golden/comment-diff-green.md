### ✅ Wasinix CI · green · [run](https://github.com/wasix-org/wasinix/actions/runs/1) · `aaaaaaaaaaaa`

<sub>candidate-1: Formatting ✅ · Evaluation inputs ✅ · Evaluation ✅ · Core ✅ · Compare candidate-1 ✅<br>baseline: Evaluation inputs ✅ · Evaluation ✅ · Core ✅<br><a href="https://github.com/wasix-org/wasinix/actions/runs/1">full pipeline</a></sub>

<details><summary>Details</summary>

**Request**

```json
{
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

**Pipeline**

| task | status | result |
|:--|:--:|:--|
| candidate-1: Formatting | ✅ | ok |
| baseline: Evaluation inputs | ✅ | ok |
| baseline: Evaluation | ✅ | ok |
| candidate-1: Evaluation inputs | ✅ | ok |
| candidate-1: Evaluation | ✅ | ok |
| baseline: Core | ✅ | ok |
| candidate-1: Core | ✅ | ok |
| Compare candidate-1 | ✅ | no regressions |

**Downstream version changes (1)**

- **zlib** 1.3.1 → 1.3.2

**Comparison** · 1 fixed · 2 rebuilt · 1 version/rel changes · 1 added · 1 removed

<details><summary>Fixed (1)</summary>

- `checks.curl`

</details>

<details><summary>Version or rel changed (1)</summary>

- `packagesByProfile.eh.zlib: 1.3.1 -> 1.3.2`

</details>

<details><summary>Rebuilt (2)</summary>

- `checks.zlib` at 1.3.2
- `packagesByProfile.eh.zlib`

</details>

<details><summary>Added (1)</summary>

- `checks.brotli` at 1.1.0

</details>

<details><summary>Removed (1)</summary>

- `checks.legacy-tool` at 0.9.1

</details>

</details>
