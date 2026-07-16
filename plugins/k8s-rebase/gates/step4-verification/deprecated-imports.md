Scan all non-vendor .go files for deprecated import paths and
symbols. For each pattern, run the specified grep and report
hits with file:line.

1. "k8s.io/klog" without "/v2" — deprecated since k8s 1.19
   grep -rn '"k8s.io/klog"' --include='*.go' . | grep -v vendor | grep -v '/v2'

2. "io/ioutil" — deprecated since Go 1.16
   grep -rn '"io/ioutil"' --include='*.go' . | grep -v vendor

3. "golang.org/x/exp/maps", "golang.org/x/exp/slices", "golang.org/x/exp/constraints" — promoted to stdlib
   grep -rn '"golang.org/x/exp/\(maps\|slices\|constraints\)' --include='*.go' . | grep -v vendor

4. "k8s.io/utils/pointer" — deprecated, use "k8s.io/utils/ptr"
   grep -rn '"k8s.io/utils/pointer"' --include='*.go' . | grep -v vendor

5. reflect.Ptr — deprecated constant, use reflect.Pointer
   grep -rn 'reflect\.Ptr\b' --include='*.go' . | grep -v vendor

6. "github.com/golang/protobuf" — deprecated
   grep -rn '"github.com/golang/protobuf' --include='*.go' . | grep -v vendor

7. FieldsV1.Raw or FieldsV1{Raw: — use typed FieldsV1 access
   grep -rn 'FieldsV1\.Raw\|FieldsV1{Raw:' --include='*.go' . | grep -v vendor

Report count per pattern. Zero means clean.

Rules: you are read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line
for each hit.

After your analysis, write your report. The repo path is the
first line of your prompt — use it as an absolute path:

```bash
REPO="<the repo path from the first line of your prompt>"
mkdir -p "$REPO/.rebase-tmp/gates"
cat > "$REPO/.rebase-tmp/gates/step4-deprecated-imports.report" << 'REPORT'
VERDICT: <PASS or FAIL>
ISSUES: <total issue count>
SUMMARY: <one-line description of what you checked and found>
DETAILS:
<one finding per line, with file:line references>
REPORT
```
