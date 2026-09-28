# BetterBags Category Schemes

A companion add-on for [BetterBags](https://github.com/Cidan/BetterBags) that adds two
things its category system doesn't do out of the box:

1. **Opt-in Weapon / Armor category schemes.** Group weapons and armor into sections the
   way *you* want — without hand-filing every item:
   - **Weapons:** lump every one-handed / two-handed / ranged weapon into a single section
     (**All One-Handed**, **All Two-Handed**, **All Ranged**), *or* give specific weapon
     types their own section (One-Handed Axes, Daggers, Staves…). A specific type wins over
     its lump bucket — so you can lump all 2H together **and** still pull Two-Handed Maces
     into their own section.
   - **Armor:** group by **material** (Cloth / Leather / Mail / Plate) *or* by **slot**
     (Head / Feet / …).
2. **Per-bag removal of BetterBags' default sections, with fall-through.** BetterBags'
   built-in defaults (Trade Goods, Feet, Junk, …) are computed on the fly and can't be
   individually removed — only toggled in bulk. This lets you remove an individual default
   section; its items **fall through to the next appropriate category** instead of
   disappearing, and you can restore it any time.

All settings are **per bag** (Backpack and Bank independently), matching BetterBags' own
per-bag category filters.

## Where the settings live

With a recent BetterBags that includes the `RegisterBagConfig` hook
([PR #1114](https://github.com/Cidan/BetterBags/pull/1114)), the controls appear **natively
inside `/bb` → Backpack and Bank**, under an "Extra Categories" subsection right below the
category filters.

**Without** that hook, the add-on falls back to its own **"Category: Backpack" /
"Category: Bank"** tabs in the BetterBags config — so it works either way.

There's also a `/bbcs` slash command (`weapon off|on`, `armor off|type|slot`,
`remove <Name>`, `restore <Name>`, `restore all`, plus `weapons` / `probe` diagnostics).

## How it works (no BetterBags files modified at runtime)

- Category schemes are registered through BetterBags' public
  `Categories:RegisterCategoryFunction` API. A user's hand-filed item always wins over a
  scheme (BetterBags resolves explicit assignments first), so schemes are purely additive.
- The settings UI uses the `Config:RegisterBagConfig` hook when present; otherwise it builds
  its own tabs. Nothing patches BetterBags' files.

## Install

Drop the `BetterBagsCategorySchemes` folder into `Interface/AddOns/`. Requires BetterBags.

## Notes / status

- Built and tested on **WoW: Forever (Camelot, interface 16001)**.
- The native-placement path depends on the `RegisterBagConfig` hook; until that PR is
  merged upstream you can either use the fallback tabs or apply the small hook yourself.

## License

MIT.
