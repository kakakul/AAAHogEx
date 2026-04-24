# Skip Idle Processing Industry Sources Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent FreightNetwork from selecting processing (secondary/tertiary) industries as route sources when their last-month output production is zero.

**Architecture:** Two inline guards in `freightnetwork.nut` — one in `FindSpine` replacing the unconditional production floor with a type-aware check, one in `ScanFeeders` added after the cargo-type match. Primary industry floor behaviour is preserved. Destinations unchanged.

**Tech Stack:** Squirrel, OpenTTD AI API (`AIIndustryType.IsProcessingIndustry`, `AIIndustry.GetLastMonthProduction`, `AIIndustry.GetIndustryType`)

---

### Task 1: Guard idle processing sources in FindSpine and ScanFeeders

**Goal:** Add type-aware production checks so processing industry sources with 0 output are skipped in both `FindSpine` and `ScanFeeders`, with a log line for each skip.

**Files:**
- Modify: `freightnetwork.nut:302-303` (FindSpine production floor)
- Modify: `freightnetwork.nut:169` (ScanFeeders after `if(!produces) continue;`)
- Test: `tests/test_integration.py`

**Acceptance Criteria:**
- [ ] Processing industry sources with 0 output skipped in `FindSpine` (no floor applied)
- [ ] Processing industry sources with 0 output skipped in `ScanFeeders`
- [ ] Primary industry floor of 80 preserved in `FindSpine`
- [ ] Log line emitted when a processing source is skipped
- [ ] No crash; spine still builds on a standard seed

**Verify:** `cd tests && pytest test_integration.py -v` → all existing tests pass, new regression test passes

**Steps:**

- [ ] **Step 1: Write the failing regression test**

Add to `tests/test_integration.py`:

```python
def test_spine_built_no_idle_processing_crash():
    """Spine builds correctly with idle-processing-source guard active."""
    row = run_hognet(network_mode=1, days=365 * 3, seed=42)
    assert not row['error'], f"AI crashed:\n{row['output']}"
    assert 'FreightNetwork.FindSpine: spine built' in row['output'], (
        f"Expected spine to be built\nOutput:\n{row['output']}"
    )
```

- [ ] **Step 2: Run test to confirm it passes on current code (baseline)**

```bash
cd "c:/Program Files (x86)/Steam/steamapps/common/OpenTTD/ai/HogNet/tests"
pytest test_integration.py::test_spine_built_no_idle_processing_crash -v
```

Expected: PASS (spine builds before our change — this is a regression guard).

- [ ] **Step 3: Implement FindSpine guard**

In `freightnetwork.nut`, replace lines 302–303:

```squirrel
						local production = AIIndustry.GetLastMonthProduction(src.id, cargo);
						if(production <= 0) production = 80; // floor for month 0 before any production recorded
```

With:

```squirrel
						local production = AIIndustry.GetLastMonthProduction(src.id, cargo);
						local srcType = AIIndustry.GetIndustryType(src.id);
						if(AIIndustryType.IsProcessingIndustry(srcType)) {
							if(production <= 0) {
								HgLog.Info("FreightNetwork.FindSpine: skipping idle processing source "
									+ AIIndustry.GetName(src.id));
								continue;
							}
						} else {
							if(production <= 0) production = 80; // floor for month 0 before any production recorded
						}
```

- [ ] **Step 4: Implement ScanFeeders guard**

In `freightnetwork.nut`, after line 169 (`if(!produces) continue;`), insert:

```squirrel
			if(AIIndustryType.IsProcessingIndustry(srcType)) {
				if(AIIndustry.GetLastMonthProduction(indId, cargo) <= 0) {
					HgLog.Info("FreightNetwork.ScanFeeders: skipping idle processing source "
						+ AIIndustry.GetName(indId));
					continue;
				}
			}
```

Note: `srcType` is already in scope at line 164 (`local srcType = AIIndustry.GetIndustryType(indId);`).

- [ ] **Step 5: Run full integration test suite**

```bash
cd "c:/Program Files (x86)/Steam/steamapps/common/OpenTTD/ai/HogNet/tests"
pytest test_integration.py -v
```

Expected: all tests pass, no crash.

- [ ] **Step 6: Commit**

```bash
git add freightnetwork.nut tests/test_integration.py
git commit -m "feat: skip idle processing industry sources in FindSpine and ScanFeeders"
```
