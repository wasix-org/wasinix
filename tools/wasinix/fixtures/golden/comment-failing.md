### ❌ Wasinix CI · 1 failure · [run](https://github.com/wasix-org/wasinix/actions/runs/1) · `aaaaaaaaaaaa`

| job | task | failure |
|:--|:--|:--|
| `checks.zlib` | case.core | builder failed with exit code 1 |

1 job blocked behind these failures

<sub>case: Formatting ✅ · Evaluation inputs ✅ · Evaluation ✅ · Core ❌<br><a href="https://github.com/wasix-org/wasinix/actions/runs/1">full pipeline</a></sub>

<details><summary>Details</summary>

<details><summary>Request</summary>

```json
{
  "action": "build",
  "caseId": "case",
  "source": {
    "rev": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "workingTree": false
  },
  "selectors": [
    {
      "kind": "set",
      "name": "core"
    }
  ]
}
```

</details>

**Pipeline**

| task | status | result |
|:--|:--:|:--|
| case: Formatting | ✅ | ok |
| case: Evaluation inputs | ✅ | ok |
| case: Evaluation | ✅ | ok |
| case: Core | ❌ | 1 failed · 39 built |

</details>
