# Skip Idle Processing Industry Sources Design

**Goal:** Prevent FreightNetwork from selecting processing (secondary/tertiary) industries as route sources when their current output production is zero.

**Architecture:** Two inline guards added to `FreightNetwork.FindSpine` and `FreightNetwork.ScanFeeders`. Primary industry behaviour (floor of 80) is preserved. Destination selection is unchanged.

**Tech Stack:** Squirrel, OpenTTD AI API (`AIIndustryType.IsProcessingIndustry`, `AIIndustry.GetLastMonthProduction`)

---

## Context

In `FindSpine`, all source industries get a production floor of 80 when `GetLastMonthProduction <= 0`. This is correct for primary industries at game start (no history yet). However, processing industries (factories, steel mills, paper mills, etc.) only produce output when inputs are delivered — a zero reading is a genuine signal that the industry is idle, not a data-gap artifact. Connecting a route to an idle processing source wastes infrastructure and trains.

The same problem exists in `ScanFeeders`, which queues feeder sources by cargo-type match alone with no production check.

## Changes

### 1. `freightnetwork.nut` — `FindSpine` source check (~line 302)

**Before:**
```squirrel
local production = AIIndustry.GetLastMonthProduction(src.id, cargo);
if(production <= 0) production = 80; // floor for month 0 before any production recorded
```

**After:**
```squirrel
local production = AIIndustry.GetLastMonthProduction(src.id, cargo);
local srcType = AIIndustry.GetIndustryType(src.id);
if(AIIndustryType.IsProcessingIndustry(srcType)) {
    if(production <= 0) continue;
} else {
    if(production <= 0) production = 80;
}
```

### 2. `freightnetwork.nut` — `ScanFeeders` feeder source check (~line 169)

Add after `if(!produces) continue;`, before `FreightNetwork.pendingFeeders.push(...)`:

```squirrel
if(AIIndustryType.IsProcessingIndustry(srcType)) {
    if(AIIndustry.GetLastMonthProduction(indId, cargo) <= 0) continue;
}
```

## Behaviour Summary

| Industry type | Production | FindSpine source | ScanFeeders feeder |
|---|---|---|---|
| Primary (raw) | 0 | floor → 80, included | no check (unchanged) |
| Primary (raw) | > 0 | included as-is | included as-is |
| Processing | 0 | skipped (`continue`) | skipped (`continue`) |
| Processing | > 0 | included as-is | included as-is |

Destinations in `FindSpine`: no change — selected by cargo-type match only.

## Acceptance Criteria

- [ ] Processing industry sources with 0 output are never selected in `FindSpine`
- [ ] Processing industry feeders with 0 output are never queued in `ScanFeeders`
- [ ] Primary industry floor of 80 preserved in `FindSpine`
- [ ] Destinations selected by existing logic, unaffected
- [ ] No regression: routes to active processing sources still built normally
