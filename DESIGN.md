# BetterBagsCategorySchemes — design & spec

> (Formerly EllesmereBetterBagsCategories. Internal design notes; see README.md for usage.)

A **standalone companion addon** (mechanism A) that supplements BetterBags' category
system. It edits **none** of BetterBags' files; it hooks the public plugin API at login
and stores its own state in a SavedVariable. A BetterBags update can only break the API
surface (a code fix), never require a re-apply.

Verified against BetterBags **v0.5.11**, client interface **16001** (Forever / Classic beta).

---

## 1. The problem (root cause, verified in BB source)

Categories like **Trade Goods, Feet, Hands, Cloth, Consumable** are *not stored
categories*. They are **computed on the fly every refresh** in `items:GetCategory`
(`BetterBags/data/items.lua` ~L2187+) from the item's own type/slot, gated only by five
**all-or-nothing global toggles** in `db.categoryFilters[kind]`
(`BetterBags/core/constants.lua:849`):

| Toggle | Produces sections | Default (BACKPACK & BANK) |
|---|---|---|
| `EquipmentLocation` | `_G[itemEquipLoc]` → Head, Shoulder, Chest, Feet, Hands, Waist, Legs, Wrist, Finger, Trinket, Back, Main Hand, Off Hand, Ranged… | **ON** |
| `Type` | `itemType` → Armor, Weapon, Consumable, **Trade Goods**, Quest, Recipe, Container, Miscellaneous… | **ON** |
| `Subtype` | `itemSubType` (concatenated after Type) | OFF |
| `TradeSkill` | `const.TRADESKILL_MAP[subclassID]` for trade goods | OFF |
| `Expansion` | `const.EXPANSION_MAP[expacID]` | OFF |

**Why "remove" resists:** selecting one of these in *Backpack → Categories* routes it to
`ShowDynamicCategoryDetail` (`config/categorypane.lua:1262`), whose "Remove Category"
button calls `categories:DeleteCategory`. That only clears *stored* ephemeral/DB entries —
a computed default has none, so the delete is a **no-op**, and the next `FullRefreshAll`
re-derives it. There is **no per-name off switch** — only the five coarse toggles — and the
pane never shows a "Hide Section" checkbox for these names.

**Which categories suffer:** every computed default (all EquipmentLocation slot names, all
Type names incl. Trade Goods, plus Subtype/TradeSkill/Expansion names when on). Real custom
& search categories are unaffected (working delete/rename/hide).

### Two facts that already work in our favor
1. **Point (3) is guaranteed by the engine.** In `GetCategory`, custom/search assignments
   resolve *before* the computed EquipmentLocation/Type fallback; inside
   `categories:GetCustomCategory` the user's hand-filed per-item assignment
   (`database:GetItemCategoryByItemID`) is checked *first of all*. So a personal category
   already trumps a default regardless of priority number. We must only avoid breaking it —
   and we can't: a registered category function is only consulted *after* that check.
2. **`categories:RegisterCategoryFunction(id, func)`** is the public plugin hook. `func(data)`
   returns a category name (or nil); it runs before the computed defaults; results are cached
   per item. `data.kind`, `data.itemInfo.{itemID,classID,subclassID,itemEquipLoc,itemType,
   itemSubType,expacID}` and `data.containerInfo.quality` are available.

> Note: BB's own `categories:HideCategory(name)` (`shown=false`, honored at
> `items.lua:1217`) *hides items from the bag entirely* — it does NOT fall through. The user
> wants fall-through, so we do **not** use HideCategory for suppression.

---

## 2. What we build

A single registered category function (our **dispatcher**) plus a config panel. The
dispatcher composes two independent layers, evaluated per item, most-specific first:

### Layer A — opt-in baseline schemes (additive re-routing)
Each scheme is an **expandable list of per-subcategory toggles**. A ticked subcategory routes
its matching items into a named section we manage; an unticked one returns nil for those
items (they fall to Layer B / BB-natural). Enabling any scheme automatically displaces BB's
rigid defaults for the claimed items (schemes run before the computed defaults).

- **Weapon Type** — per weapon subclass, named via `C_Item.GetItemSubClassInfo(classID,
  subclassID)` (already locale-correct and hand-aware: "One-Handed Axes", "Two-Handed Axes",
  "Daggers", "Staves", "Guns", "Bows", "Wands"…). This satisfies "1h Axes and 1h Maces as
  separate sections" directly — tick those subclasses.
  - Optional **coarse mode**: collapse to "One-Handed Weapons / Two-Handed Weapons / Ranged"
    (bucketed by `itemEquipLoc`) instead of per-subclass.
- **Armor grouping — single choice (None / By Type / By Slot)**, *mutually exclusive* per the
  user's call (no nesting → avoids "Mail – Feet" clutter):
  - **By Type**: Cloth / Leather / Mail / Plate (classID==Armor; subclassID in
    {Cloth,Leather,Mail,Plate}; excludes `INVTYPE_CLOAK` and non-wearable armor subclasses
    like Shield/Libram/Idol/Totem/Sigil which are handled as their own toggles or left to BB).
  - **By Slot**: Head / Shoulder / Chest / Feet / Hands / … — our own toggleable mirror of
    EquipmentLocation, so individual slots can be kept or dropped (something BB can't do).

Precedence within Layer A: Weapon > Armor (configurable). Within a scheme, the per-subcategory
match is unambiguous (an item has exactly one subclass / one slot), so no intra-scheme
collisions. Each managed section is pre-created at login as an **ephemeral (dynamic)**
category carrying our chosen **priority** and **color**, so (a) `AddItemToCategory` reuses it
with the right priority, and (b) it shows up editable (color/priority/show) in BB's own pane.

### Layer B — suppress a BB default *with fall-through* (the "remove" fix)
State: a per-bag **suppressed set** of BB-natural section names (SavedVar). For an item whose
*natural* section name is suppressed, the dispatcher returns the **next tier's** name instead
of nil (returning nil would let BB recompute the same suppressed name, since the global toggle
is still on).

`ComputeNaturalCategory(data, skipSet)` mirrors BB's fallback order
(`items.lua:2215-2293`) using BB's *own* `const` maps and `database:GetCategoryFilter`:
1. poor quality → `"Junk"`
2. EquipmentLocation (if on & valid `_G[itemEquipLoc]`) → slot name (exclusive, no bisect)
3. else Type [+ " - " Subtype] [+ " - " TradeSkill] [+ " - " Expansion] per toggles
4. else `"Everything"`

When the tier's output name ∈ skipSet, skip that tier and continue. Examples (with default
toggles): suppress **"Feet"** → boots skip equip-loc → land on Type = **"Armor"**; suppress
**"Trade Goods"** → skip Type → **"Everything"** (Subtype off); suppress **"Junk"** → poor
items skip Junk → equip-loc/Type. `"Everything"` may not be suppressed.

"Recover" = remove the name from the suppressed set. The suppressed set only ever contains
BB-natural names (offered from the currently-present computed sections); scheme sections are
controlled by their scheme toggles, not this list.

### Fast path
If no scheme is enabled **and** the suppressed set is empty, the dispatcher returns nil
immediately (near-zero overhead). Otherwise it computes the item's natural name once (cached
by BB) to test suppression.

---

## 3. Applying config changes (release previously-assigned items)

BB caches assignments: `GetCustomCategory` checks `ephemeralCategoryByItemID[itemID]` *before*
re-running functions, so `ReprocessAllItems` alone will NOT release an item already filed into
"One-Handed Axes" when a toggle flips. On **any** config change we therefore:
1. `categories:WipeCategory(ctx, name)` for every section we manage (clears items +
   `ephemeralCategoryByItemID`), then
2. `categories:ReprocessAllItems(ctx)` (wipes `itemsWithNoCategory`, triggers
   `bags/FullRefreshAll`) so every item is re-evaluated against current toggles.

---

## 3b. Placement & settings model (revised)

Settings render **natively inside BetterBags' Backpack and Bank config sections**
(under an "Extra Categories" subsection, just below the category filters), via a new
`config:RegisterBagConfig(fn)` hook added by `_BetterBags-CustomPatches`. Settings are
**per-bag** (each section controls its own bag), matching BetterBags' own per-bag
category filters and avoiding the stale-value wart of showing one shared control in two
panes. DB model: `db.bags[kind] = { weapon={mode,subclasses,priority}, armor={mode,
types,slots,priority} }`; `db.suppressed[kind]`. The dispatcher reads the item's own
`data.kind` config; managed categories are the union of names across both bags.

If the hook API is absent (patch not applied), the addon falls back to two standalone
`Category: Backpack` / `Category: Bank` tabs, so it never hard-breaks.

**Weapon model (revised):** `weapon.mode` is "off"/"on". When on, the picker lists three
synthetic LUMP toggles first — All One-Handed / All Two-Handed / All Ranged
(`all1h`/`all2h`/`allRanged`, classified by equip location) — then per-subtype toggles. A
specific subtype wins over its lump bucket. Obsolete/empty weapon subclasses
(9/11/12/14/17) are hidden. **Schemes are purely additive**: an item with no matching
toggle returns nil and is left to BetterBags (the earlier "scheme owns its class →
fall-through" behavior was dropped as too aggressive); Layer-B suppression still applies.

## 4. Config surface — a BetterBags plugin (superseded by 3b)

Registered via the supported `Config:AddPluginConfig(title, opts)` API (the same mechanism
the Ellesmere Skin addon uses — proven on this client), so it appears inside `/bb` → Plugins
as real toggles/dropdowns, NOT a standalone window or slash-only. `AddPluginConfig` flattens
options via `pairs` (unordered), so we register **three** plugin entries to stay navigable:
- **Ellesmere · Weapons** — grouping dropdown (Off / By weapon type / Coarse 1H-2H-Ranged),
  priority input, per-subclass toggles.
- **Ellesmere · Armor** — grouping dropdown (Off / By material / By slot), priority input,
  material toggles, slot toggles.
- **Ellesmere · Remove Defaults** — a toggle per curated default name (Type/class names +
  equip-slot names + Junk; a stable list from `EBBC:DefaultNameCandidates()`, NOT a live bag
  snapshot which would be empty at login) + a "Restore ALL defaults" button.

The "Plugins" section is created guarded by the shared `config.__ellesmerePluginsSection`
flag so whichever Ellesmere plugin loads first creates it. Registration is guarded by
`config.__ellesmereCategoriesRegistered`.

Slash command `/ebbc` (also `/ellesmerecategories`) mirrors the controls as a convenience.
NOTE: the SlashCmdList key MUST equal the token in `SLASH_<TOKEN>N` — i.e.
`SlashCmdList["EBBC"]` for `SLASH_EBBC1`; a mismatched key silently registers no handler
(the original bug where `/ebbc` did nothing).

---

## 5. SavedVariables — `EllesmereBetterBagsCategoriesDB`
```
{
  weapon = { mode = "off|subclass|coarse", subclasses = { [subclassID]=true }, priority = 5 },
  armor  = { mode = "off|type|slot", types = {Cloth=true,...}, slots = {INVTYPE_FEET=true,...}, priority = 6 },
  suppressed = { [BAG_KIND.BACKPACK] = { ["Trade Goods"]=true }, [BAG_KIND.BANK] = {...} },
}
```

## 6. Guards / degradation
`GetAddon("BetterBags", true)` + `pcall` around every BB call; scheme/enum lookups guarded
(`Enum.ItemWeaponSubclass`, `C_Item.GetItemSubClassInfo`). If the Categories/Config module or
API shifts, the addon no-ops quietly rather than erroring on load.

## 7. Open verification items (require in-game test)
- Confirm ephemeral (dynamic) pre-created categories accept our `priority`/`color` and appear
  editable in the pane.
- Confirm `WipeCategory` + `ReprocessAllItems` fully releases and re-files items on toggle.
- Confirm `ComputeNaturalCategory` output matches BB's actual section names for representative
  items (boots, a trade good, a poor-quality item, a 1H axe).
