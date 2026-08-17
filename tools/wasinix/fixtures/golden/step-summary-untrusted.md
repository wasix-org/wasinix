> [!NOTE]
> This result was produced by this pull request's own code and is advisory; it is not an authoritative CI verdict.

### ❌ Wasinix CI · 1 failure · run `https://ci.example/runs/1)|end` · `aaaaaaaaaaaa`

| job | task | failure |
|:--|:--|:--|
| `` checks.zlib`\|<img src=x onerror=alert(1)> `` | case.core | boom \`\`\` |

<sub>case: Formatting ✅ · Evaluation inputs ✅ · Evaluation ✅ · Core ❌<br>full pipeline `https://ci.example/runs/1)|end`</sub>

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
