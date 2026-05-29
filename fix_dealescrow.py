import re

path = "contracts/core/DealEscrow.sol"
with open(path, "r") as f:
    lines = f.readlines()

src = "".join(lines)

# ── Fix 1: timer vars → mapping ───────────────────────────────────────────────

# Replace the 7 storage declarations (lines 100-106) with mapping
src = re.sub(
    r'    uint256 public consentWindow;\n'
    r'    uint256 public medicalWindow;\n'
    r'    uint256 public hijackWindow;\n'
    r'    uint256 public disputeWindow;\n'
    r'    uint256 public renegoWindow;\n'
    r'    uint256 public fundingWindow;\n'
    r'    uint256 public mutualCancelWindow;\n',
    '    mapping(uint8 => uint256) public timers;\n'
    '    // 0=consent 1=medical 2=hijack 3=dispute 4=renego 5=funding 6=mutualCancel\n',
    src
)

# Replace initialize assignments (lines 201-207) — use regex to tolerate spacing
src = re.sub(
    r'        consentWindow\s*= 72 hours;\n'
    r'        medicalWindow\s*= 72 hours;\n'
    r'        hijackWindow\s*= 48 hours;\n'
    r'        disputeWindow\s*= 72 hours;\n'
    r'        renegoWindow\s*= 48 hours;\n'
    r'        fundingWindow\s*= 48 hours;\n'
    r'        mutualCancelWindow\s*= 48 hours;\n',
    '        timers[0] = 72 hours;\n'
    '        timers[1] = 72 hours;\n'
    '        timers[2] = 48 hours;\n'
    '        timers[3] = 72 hours;\n'
    '        timers[4] = 48 hours;\n'
    '        timers[5] = 48 hours;\n'
    '        timers[6] = 48 hours;\n',
    src
)

# Replace setTimer body (lines 257-264)
src = re.sub(
    r'        if\s+\(which == 0\) consentWindow\s*= d;\n'
    r'        else if \(which == 1\) medicalWindow\s*= d;\n'
    r'        else if \(which == 2\) hijackWindow\s*= d;\n'
    r'        else if \(which == 3\) disputeWindow\s*= d;\n'
    r'        else if \(which == 4\) renegoWindow\s*= d;\n'
    r'        else if \(which == 5\) fundingWindow\s*= d;\n'
    r'        else if \(which == 6\) mutualCancelWindow = d;\n'
    r'        else revert InvalidAmount\(\);\n',
    '        if (which > 6) revert InvalidAmount();\n'
    '        timers[which] = d;\n',
    src
)

# Replace all remaining usages as standalone identifiers
for old, new in [
    ("consentWindow",      "timers[0]"),
    ("medicalWindow",      "timers[1]"),
    ("hijackWindow",       "timers[2]"),
    ("disputeWindow",      "timers[3]"),
    ("renegoWindow",       "timers[4]"),
    ("fundingWindow",      "timers[5]"),
    ("mutualCancelWindow", "timers[6]"),
]:
    src = re.sub(r'\b' + old + r'\b', new, src)

# ── Fix 2: Remove getInstallmentMeta ─────────────────────────────────────────
src = re.sub(
    r'\n    function getInstallmentMeta\(uint256 dealId\) external view returns \([^)]+\) \{[^}]+\}\n',
    '\n',
    src,
    flags=re.DOTALL
)

# ── Sanity checks ─────────────────────────────────────────────────────────────
for name in ["consentWindow", "medicalWindow", "hijackWindow", "disputeWindow",
             "renegoWindow", "fundingWindow", "mutualCancelWindow"]:
    # consentWindowDuration is a different var — skip it
    hits = [l for l in src.split('\n') if re.search(r'\b' + name + r'\b', l)
            and 'Duration' not in l and '// 0=' not in l]
    assert not hits, f"{name} still present: {hits}"

assert "getInstallmentMeta" not in src, "getInstallmentMeta still present"
assert "timers[0]" in src, "timers mapping not inserted"

with open(path, "w") as f:
    f.write(src)

print("Done. Changes applied successfully.")
