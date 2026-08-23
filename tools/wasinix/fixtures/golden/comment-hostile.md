<sub><a href="https://github.com/wasix-org/wasinix/pull/7#issuecomment-9">↳ in reply to this command</a></sub>

### ❌ Wasinix CI · 1 failure · run `https://ci.example/runs/1)|end` · `aaaaaaaaaaaa`

| job | task | failure |
|:--|:--|:--|
| `` checks.zlib`\|<img src=x onerror=alert(1)> `` | case.core | boom \`\`\` · logs `` https://ci.example/logs)\|base/checks.zlib`\|<img src=x onerror=alert(1)>.txt `` |

<sub>case: Formatting ✅ · Preparing evaluation inputs ✅ · Evaluating jobs ✅ · Core ❌<br>full pipeline `https://ci.example/runs/1)|end`</sub>

<details><summary>Details</summary>

<details><summary>Request</summary>

```json
{
  "blocked": "fail",
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

| task | status | result | time |
|:--|:--:|:--|--:|
| case: Formatting | ✅ | ok | 12s |
| case: Preparing evaluation inputs | ✅ | ok | 12s |
| case: Evaluating jobs | ✅ | ok | 12s |
| case: Core | ❌ | 1 failed · 39 built |  |

</details>
