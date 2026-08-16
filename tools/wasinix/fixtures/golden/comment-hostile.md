### ❌ Wasinix CI · 1 failure · run `https://ci.example/runs/1)|end` · `aaaaaaaaaaaa`

| job | task | failure |
|:--|:--|:--|
| `` checks.zlib`\|<img src=x onerror=alert(1)> `` | case.core | boom \`\`\` · logs `` https://ci.example/logs)\|base/checks.zlib`\|<img src=x onerror=alert(1)>.txt `` |

<sub>case: Formatting ✅ · Evaluation inputs ✅ · Evaluation ✅ · Core ❌<br>full pipeline `https://ci.example/runs/1)|end`</sub>

<details><summary>Details</summary>

**Request**

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

**Pipeline**

| task | status | result |
|:--|:--:|:--|
| case: Formatting | ✅ | ok |
| case: Evaluation inputs | ✅ | ok |
| case: Evaluation | ✅ | ok |
| case: Core | ❌ | 1 failed · 39 built |

</details>
