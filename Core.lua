--[[
	BetterBags — Category Schemes (Core)

	A standalone companion addon that supplements BetterBags' category engine. It
	edits none of BetterBags' files; it hooks the public plugin API at login.

	It does two things (see DESIGN.md for the full rationale):

	  (1) Lets you "remove" a rigid BetterBags default (Trade Goods, Feet, Hands, …)
	      with FALL-THROUGH: the items drop to the next appropriate category instead
	      of vanishing, and the default can be recovered at any time. BetterBags
	      itself only offers all-or-nothing global toggles and its own HideCategory
	      would hide the items from the bag entirely — this does neither.

	  (2) Adds opt-in baseline category "schemes" via RegisterCategoryFunction:
	      Weapon Type (per weapon subclass, or a coarse 1H/2H/Ranged split) and an
	      Armor grouping that is EITHER by material type (Cloth/Leather/Mail/Plate)
	      OR by slot (Head/Feet/…) — mutually exclusive, no nesting.

	Point (3) from the request — "a personal category should trump the default" — is
	already guaranteed by the BetterBags engine: a hand-filed per-item assignment is
	checked before any registered category function, and custom/search categories are
	resolved before the computed EquipmentLocation/Type defaults. We only compose on
	top of that; we never override an explicit user assignment.
]]

local addonName = ... ---@type string

local BB = LibStub("AceAddon-3.0"):GetAddon("BetterBags", true)
if not BB then return end -- BetterBags absent/too old; bail quietly.

local categories = BB:GetModule("Categories", true)
local const      = BB:GetModule("Constants", true)
local database   = BB:GetModule("Database", true)
local events     = BB:GetModule("Events", true)
local ctxModule  = BB:GetModule("Context", true)
local L          = BB:GetModule("Localization", true)
if not (categories and const and database and events and ctxModule) then return end

-- The shared namespace table, exposed for Config.lua and the slash command.
---@class BetterBagsCategorySchemes
local EBBC = {}
_G.BetterBagsCategorySchemes = EBBC
EBBC.BB = BB
EBBC.categories = categories
EBBC.const = const
EBBC.database = database

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------
local BACKPACK = const.BAG_KIND.BACKPACK
local BANK     = const.BAG_KIND.BANK

-- BetterBags localizes these three fallback names; mirror it when the module is
-- present, else use the enUS literal (this client is enUS).
local function Loc(key)
	if L and L.G then
		local ok, v = pcall(L.G, L, key)
		if ok and v then return v end
	end
	return key
end
local NAME_JUNK       = Loc("Junk")
local NAME_EVERYTHING = Loc("Everything")
local NAME_UNKNOWN    = Loc("Unknown")

local function NewCtx(name)
	return ctxModule:New(name or "EBBC")
end

--------------------------------------------------------------------------------
-- SavedVariables + defaults
--------------------------------------------------------------------------------
-- Default scheme priority mirrors BetterBags' own default (10): our broad schemes
-- do NOT stomp a user's more specific search category on a tie (BetterBags breaks
-- priority ties in favour of the user's search category). Lower this in config to
-- make a scheme win.
local DEFAULT_PRIORITY = 10

-- Weapon subclasses to hide from the picker: obsolete/empty on this client (verified
-- via /bbcs weapons against the Forever/Classic mapping — these carry no real items,
-- so offering them only misleads). IDs: 9 Warglaives, 11 One-Handed Exotics,
-- 12 Two-Handed Exotics, 14 Miscellaneous, 17 Spears.
local WEAPON_SUBCLASS_DENY = { [9] = true, [11] = true, [12] = true, [14] = true, [17] = true }

-- Settings are PER BAG (Backpack vs Bank), matching BetterBags' own per-bag
-- category filters. db.bags[kind] = { weapon = {...}, armor = {...} }.
local function InitDB()
	-- One-time migration from the addon's former name (EllesmereBetterBagsCategories),
	-- so existing users keep their settings. The old SavedVar is declared in the .toc
	-- only for this handoff and can be dropped later.
	local db = _G.BetterBagsCategorySchemesDB
	if not db and _G.EllesmereBetterBagsCategoriesDB then
		db = _G.EllesmereBetterBagsCategoriesDB
	end
	db = db or {}
	db.bags = db.bags or {}

	-- Migrate a pre-per-bag global config (db.weapon / db.armor) into both bags.
	if not db.bags[BACKPACK] and (db.weapon or db.armor) then
		for _, k in ipairs({ BACKPACK, BANK }) do
			local bc = {
				weapon = { mode = (db.weapon and db.weapon.mode) or "off", subclasses = {},
					priority = (db.weapon and db.weapon.priority) or DEFAULT_PRIORITY },
				armor = { mode = (db.armor and db.armor.mode) or "off", types = {}, slots = {},
					priority = (db.armor and db.armor.priority) or DEFAULT_PRIORITY },
			}
			if db.weapon and db.weapon.subclasses then for id in pairs(db.weapon.subclasses) do bc.weapon.subclasses[id] = true end end
			if db.armor and db.armor.types then for key in pairs(db.armor.types) do bc.armor.types[key] = true end end
			if db.armor and db.armor.slots then for n in pairs(db.armor.slots) do bc.armor.slots[n] = true end end
			db.bags[k] = bc
		end
		db.weapon, db.armor = nil, nil
	end

	-- Fill defaults + normalize the weapon model for each bag.
	for _, k in ipairs({ BACKPACK, BANK }) do
		local bc = db.bags[k] or {}
		bc.weapon = bc.weapon or {}
		bc.weapon.subclasses = bc.weapon.subclasses or {}   -- [subclassID]=true (granular, per-type)
		bc.weapon.priority = bc.weapon.priority or DEFAULT_PRIORITY

		-- Weapon model: mode is "off" | "on". When on, the picker offers the synthetic
		-- lump buckets all1h / all2h / allRanged PLUS per-subtype toggles (a specific
		-- subtype wins over its lump bucket). Migrate the older "subclass"/"coarse"
		-- modes, and the obsolete "Exotics" subclasses (11=1H, 12=2H) which users read
		-- as "All 1H"/"All 2H" — turn those into the real lump toggles.
		local wm = bc.weapon.mode
		if wm == "coarse" then
			bc.weapon.mode = "on"
			bc.weapon.all1h, bc.weapon.all2h, bc.weapon.allRanged = true, true, true
		elseif wm == "subclass" then
			bc.weapon.mode = "on"
		elseif wm ~= "on" then
			bc.weapon.mode = "off"
		end
		if bc.weapon.subclasses[11] then bc.weapon.all1h = true end
		if bc.weapon.subclasses[12] then bc.weapon.all2h = true end
		for id in pairs(WEAPON_SUBCLASS_DENY) do bc.weapon.subclasses[id] = nil end
		bc.weapon.all1h     = bc.weapon.all1h or false
		bc.weapon.all2h     = bc.weapon.all2h or false
		bc.weapon.allRanged = bc.weapon.allRanged or false

		bc.armor = bc.armor or {}
		bc.armor.mode = bc.armor.mode or "off"              -- "off" | "type" | "slot"
		bc.armor.types = bc.armor.types or {}               -- ["Cloth"|"Leather"|"Mail"|"Plate"]=true
		bc.armor.slots = bc.armor.slots or {}               -- [displayName]=true
		bc.armor.priority = bc.armor.priority or DEFAULT_PRIORITY
		db.bags[k] = bc
	end

	db.suppressed = db.suppressed or {}                 -- [kind] = { [naturalName]=true }
	db.suppressed[BACKPACK] = db.suppressed[BACKPACK] or {}
	db.suppressed[BANK]     = db.suppressed[BANK] or {}

	_G.BetterBagsCategorySchemesDB = db
	EBBC.db = db
	return db
end

-- Per-bag config accessor.
---@param kind BagKind
function EBBC:Bag(kind)
	return self.db and self.db.bags and self.db.bags[kind]
end

-- Enum shorthands, guarded (all present on this client, but degrade safely).
local ItemClass        = Enum and Enum.ItemClass
local ArmorSubclass    = Enum and Enum.ItemArmorSubclass
local CLASS_WEAPON     = ItemClass and ItemClass.Weapon
local CLASS_ARMOR      = ItemClass and ItemClass.Armor
local CLASS_TRADEGOODS = ItemClass and ItemClass.Tradegoods

-- Classify a weapon into a hand bucket by equip location, for the "All 1H / 2H /
-- Ranged" lump toggles. Staves/polearms/fishing poles are INVTYPE_2HWEAPON → 2h;
-- wands/bows/guns/crossbows/thrown → ranged; the rest → 1h.
local ONE_H_LOCS  = { INVTYPE_WEAPON = true, INVTYPE_WEAPONMAINHAND = true, INVTYPE_WEAPONOFFHAND = true }
local TWO_H_LOCS  = { INVTYPE_2HWEAPON = true }
local RANGED_LOCS = { INVTYPE_RANGED = true, INVTYPE_RANGEDRIGHT = true, INVTYPE_THROWN = true }
local function WeaponHand(loc)
	if TWO_H_LOCS[loc] then return "2h"
	elseif RANGED_LOCS[loc] then return "ranged"
	elseif ONE_H_LOCS[loc] then return "1h" end
	return nil
end

--------------------------------------------------------------------------------
-- The weapon-subclass and armor-slot catalogues (for config UI + name lookups).
--------------------------------------------------------------------------------
-- Weapon subclasses that actually exist on this client, discovered at runtime.
---@return { id: number, name: string }[]
function EBBC:WeaponSubclasses()
	if self._weaponSubclasses then return self._weaponSubclasses end
	local list = {}
	if CLASS_WEAPON and C_Item and C_Item.GetItemSubClassInfo then
		for id = 0, 20 do
			local ok, name = pcall(C_Item.GetItemSubClassInfo, CLASS_WEAPON, id)
			if ok and name and name ~= "" and not name:find("OBSOLETE") and not WEAPON_SUBCLASS_DENY[id] then
				table.insert(list, { id = id, name = name })
			end
		end
	end
	self._weaponSubclasses = list
	return list
end

-- The armor material types we group (wearable class armor only).
function EBBC:ArmorTypeKeys()
	-- key -> subclass enum value
	if self._armorTypeKeys then return self._armorTypeKeys end
	local t = {}
	if ArmorSubclass then
		t = {
			{ key = "Cloth",   sub = ArmorSubclass.Cloth },
			{ key = "Leather", sub = ArmorSubclass.Leather },
			{ key = "Mail",    sub = ArmorSubclass.Mail },
			{ key = "Plate",   sub = ArmorSubclass.Plate },
		}
	end
	self._armorTypeKeys = t
	return t
end

-- Armor equipment-slot display names (coalesced across tokens that share a name,
-- e.g. INVTYPE_ROBE and INVTYPE_CHEST both display "Chest"). Keyed by the display
-- string so an item's live itemEquipLoc → _G[loc] maps straight onto the toggle.
local SLOT_TOKENS = {
	"INVTYPE_HEAD", "INVTYPE_NECK", "INVTYPE_SHOULDER", "INVTYPE_BODY",
	"INVTYPE_CHEST", "INVTYPE_ROBE", "INVTYPE_WAIST", "INVTYPE_LEGS",
	"INVTYPE_FEET", "INVTYPE_WRIST", "INVTYPE_HAND", "INVTYPE_FINGER",
	"INVTYPE_TRINKET", "INVTYPE_CLOAK", "INVTYPE_HOLDABLE", "INVTYPE_SHIELD",
	"INVTYPE_TABARD",
}
function EBBC:ArmorSlotNames()
	if self._armorSlotNames then return self._armorSlotNames end
	local seen, list = {}, {}
	for _, tok in ipairs(SLOT_TOKENS) do
		local n = _G[tok]
		if n and n ~= "" and not seen[n] then
			seen[n] = true
			table.insert(list, n)
		end
	end
	self._armorSlotNames = list
	return list
end

-- A stable, curated list of BetterBags "natural" default section names the user
-- may want to remove: every item-class (Type) name, every equipment-location slot
-- name, and Junk. Used to build the "Remove defaults" toggles at login (a live bag
-- snapshot would be empty this early, before the bags first draw).
local ALL_EQUIP_TOKENS = {
	"INVTYPE_HEAD", "INVTYPE_NECK", "INVTYPE_SHOULDER", "INVTYPE_BODY",
	"INVTYPE_CHEST", "INVTYPE_ROBE", "INVTYPE_WAIST", "INVTYPE_LEGS",
	"INVTYPE_FEET", "INVTYPE_WRIST", "INVTYPE_HAND", "INVTYPE_FINGER",
	"INVTYPE_TRINKET", "INVTYPE_CLOAK", "INVTYPE_HOLDABLE", "INVTYPE_SHIELD",
	"INVTYPE_TABARD", "INVTYPE_WEAPON", "INVTYPE_2HWEAPON",
	"INVTYPE_WEAPONMAINHAND", "INVTYPE_WEAPONOFFHAND", "INVTYPE_RANGED",
	"INVTYPE_RANGEDRIGHT", "INVTYPE_THROWN", "INVTYPE_RELIC",
}
---@return string[]
function EBBC:DefaultNameCandidates()
	if self._defaultNames then return self._defaultNames end
	local seen, list = {}, {}
	local function add(n) if n and n ~= "" and not seen[n] then seen[n] = true; list[#list + 1] = n end end
	if ItemClass and C_Item and C_Item.GetItemClassInfo then
		for _, v in pairs(ItemClass) do
			if type(v) == "number" then
				local ok, n = pcall(C_Item.GetItemClassInfo, v)
				if ok then add(n) end
			end
		end
	end
	for _, tok in ipairs(ALL_EQUIP_TOKENS) do add(_G[tok]) end
	add(NAME_JUNK)
	table.sort(list)
	self._defaultNames = list
	return list
end

--------------------------------------------------------------------------------
-- ComputeNaturalCategory — a faithful mirror of BetterBags' fallback tiers
-- (BetterBags/data/items.lua GetCategory, the portion after custom/search), used
-- for suppression fall-through. `skip` is a set of section names to skip; when a
-- tier's output is skipped we advance to the next tier. Reads BetterBags' OWN
-- constants and per-bag filter toggles so it tracks the user's real settings.
--------------------------------------------------------------------------------
---@param data ItemData
---@param skip? table<string, boolean>
---@return string
function EBBC:ComputeNaturalCategory(data, skip)
	local info = data and data.itemInfo
	if not info then return NAME_EVERYTHING end
	local kind = data.kind
	skip = skip or {}
	local function ok(n) return n and n ~= "" and not skip[n] end

	-- Tier 0: poor quality → Junk (BetterBags checks this before equip location).
	local quality = data.containerInfo and data.containerInfo.quality
	if quality ~= nil and const.ITEM_QUALITY and quality == const.ITEM_QUALITY.Poor then
		if ok(NAME_JUNK) then return NAME_JUNK end
	end

	-- Tier 1: equipment location (exclusive — BetterBags does not bisect it).
	if database:GetCategoryFilter(kind, "EquipmentLocation")
		and info.itemEquipLoc
		and info.itemEquipLoc ~= "INVTYPE_NON_EQUIP_IGNORE"
		and info.itemEquipLoc ~= ""
		and _G[info.itemEquipLoc]
		and _G[info.itemEquipLoc] ~= ""
	then
		local n = _G[info.itemEquipLoc]
		if ok(n) then return n end
	end

	-- Tier 2: Type [ + Subtype ] [ + TradeSkill ] [ + Expansion ].
	local category = ""
	local isTradegoods = CLASS_TRADEGOODS and info.classID == CLASS_TRADEGOODS
	local tradeSkillOn = database:GetCategoryFilter(kind, "TradeSkill")

	if database:GetCategoryFilter(kind, "Type")
		and not (isTradegoods and tradeSkillOn)
		and info.itemType then
		category = info.itemType
	end
	if database:GetCategoryFilter(kind, "Subtype")
		and not (isTradegoods and tradeSkillOn)
		and info.itemSubType then
		if category ~= "" then category = category .. " - " end
		category = category .. info.itemSubType
	end
	if isTradegoods and tradeSkillOn and const.TRADESKILL_MAP then
		local ts = const.TRADESKILL_MAP[info.subclassID]
		if ts then
			if category ~= "" then category = category .. " - " end
			category = category .. ts
		end
	end
	if database:GetCategoryFilter(kind, "Expansion") then
		if not info.expacID or not (const.EXPANSION_MAP and const.EXPANSION_MAP[info.expacID]) then
			return NAME_UNKNOWN
		end
		if category ~= "" then category = category .. " - " end
		category = category .. const.EXPANSION_MAP[info.expacID]
	end

	if category ~= "" and ok(category) then return category end

	-- Tier 3: everything else.
	return NAME_EVERYTHING
end

--------------------------------------------------------------------------------
-- Layer A — schemes. Purely ADDITIVE: an item we don't have a toggle for returns
-- nil and is left to BetterBags (it is NOT force-rerouted). Suppression (Layer B)
-- still applies afterward in Dispatch.
--------------------------------------------------------------------------------
-- Weapons. When on, precedence is: a specific per-subtype toggle (e.g. "Two-Handed
-- Maces") wins over the lump bucket ("Two-Handed Weapons"); an unticked weapon → nil.
---@param data ItemData
---@return string|nil
function EBBC:WeaponCategory(data)
	local bc = self:Bag(data.kind)
	local w = bc and bc.weapon
	if not w or w.mode ~= "on" then return nil end
	local info = data.itemInfo
	if not (CLASS_WEAPON and info.classID == CLASS_WEAPON) then return nil end

	-- Most specific: a per-subtype toggle gives the weapon its own section.
	if w.subclasses[info.subclassID] and C_Item and C_Item.GetItemSubClassInfo then
		local name = C_Item.GetItemSubClassInfo(info.classID, info.subclassID)
		if name and name ~= "" then return name end
	end

	-- Lump buckets: all one-handed / two-handed / ranged into a single section.
	local hand = WeaponHand(info.itemEquipLoc)
	if hand == "2h" and w.all2h then return "Two-Handed Weapons" end
	if hand == "ranged" and w.allRanged then return "Ranged Weapons" end
	if hand == "1h" and w.all1h then return "One-Handed Weapons" end

	return nil
end

-- Armor. Material mode groups Cloth/Leather/Mail/Plate; slot mode gives per-slot
-- sections. Unticked armor → nil (left to BetterBags).
---@param data ItemData
---@return string|nil
function EBBC:ArmorCategory(data)
	local bc = self:Bag(data.kind)
	local a = bc and bc.armor
	if not a or a.mode == "off" then return nil end
	local info = data.itemInfo
	if not (CLASS_ARMOR and info.classID == CLASS_ARMOR) then return nil end

	if a.mode == "type" then
		-- Only wearable material armor; cloaks are Cloth-subclass but not "cloth armor".
		if info.itemEquipLoc == "INVTYPE_CLOAK" then return nil end
		for _, e in ipairs(self:ArmorTypeKeys()) do
			if info.subclassID == e.sub then
				if a.types[e.key] then
					local base = (C_Item and C_Item.GetItemSubClassInfo
						and C_Item.GetItemSubClassInfo(info.classID, e.sub)) or e.key
					return base .. " Armor"
				end
				return nil
			end
		end
		return nil -- shields / misc armor left to BetterBags
	end

	if a.mode == "slot" then
		local loc = info.itemEquipLoc
		if not loc or loc == "" or loc == "INVTYPE_NON_EQUIP_IGNORE" then return nil end
		local n = _G[loc]
		if not n or n == "" then return nil end
		if a.slots[n] then return n end
		return nil
	end

	return nil
end

--------------------------------------------------------------------------------
-- The dispatcher registered with BetterBags (called once per item, cached).
--------------------------------------------------------------------------------
function EBBC:AnyActive()
	local db = self.db
	for _, k in ipairs({ BACKPACK, BANK }) do
		local bc = db.bags[k]
		if bc and (bc.weapon.mode ~= "off" or bc.armor.mode ~= "off") then return true end
	end
	if next(db.suppressed[BACKPACK]) or next(db.suppressed[BANK]) then return true end
	return false
end

---@param data ItemData
---@return string|nil
function EBBC:Dispatch(data)
	if not data or not data.itemInfo then return nil end
	if not self:AnyActive() then return nil end -- fast path: addon inert

	-- Layer A: schemes, most specific first (weapons, then armor).
	local name = self:WeaponCategory(data) or self:ArmorCategory(data)

	-- Layer B: suppression with fall-through. Only intervene when the item's
	-- natural section is actually suppressed for this bag; otherwise stay out of
	-- the way and let BetterBags categorize it natively.
	if not name then
		local sup = self.db.suppressed[data.kind]
		if sup and next(sup) then
			local natural = self:ComputeNaturalCategory(data, nil)
			if natural and sup[natural] then
				name = self:ComputeNaturalCategory(data, sup)
			end
		end
	end

	-- Record every section we route into. BetterBags caches our result in
	-- ephemeralCategoryByItemID and ReprocessAllItems does NOT clear that cache, so
	-- ApplyConfig must WipeCategory each touched name to release the items when the
	-- configuration changes (e.g. recovering a suppressed default).
	if name then self.touched[name] = true end
	return name
end

--------------------------------------------------------------------------------
-- Managed categories: pre-created so they carry our priority (and can be recolored
-- / hidden in BetterBags' own pane). Delete-then-create on every apply, because
-- BetterBags' CreateCategory is a no-op for an already-present ephemeral name and
-- its ephemeral store does not persist priority/color.
--------------------------------------------------------------------------------
EBBC.managed = {} -- name -> true (categories we currently own this session)
EBBC.touched = {} -- name -> true (every section our dispatcher has routed into)

-- Union of managed section names across BOTH bags → best (lowest) priority.
-- A name is created if either bag's scheme produces it; per-bag gating happens in
-- the dispatcher (WeaponCategory/ArmorCategory read the item's own bag config).
---@return table<string, number> name -> priority
function EBBC:ComputeManagedNames()
	local set = {}
	local function add(name, pr)
		if not name or name == "" then return end
		if set[name] == nil or pr < set[name] then set[name] = pr end
	end

	for _, k in ipairs({ BACKPACK, BANK }) do
		local bc = self.db.bags[k]
		if bc then
			local w, a = bc.weapon, bc.armor
			if w.mode == "on" then
				if w.all1h then add("One-Handed Weapons", w.priority) end
				if w.all2h then add("Two-Handed Weapons", w.priority) end
				if w.allRanged then add("Ranged Weapons", w.priority) end
				for _, e in ipairs(self:WeaponSubclasses()) do
					if w.subclasses[e.id] then add(e.name, w.priority) end
				end
			end

			if a.mode == "type" then
				for _, e in ipairs(self:ArmorTypeKeys()) do
					if a.types[e.key] then
						local base = (C_Item and C_Item.GetItemSubClassInfo
							and C_Item.GetItemSubClassInfo(CLASS_ARMOR, e.sub)) or e.key
						add(base .. " Armor", a.priority)
					end
				end
			elseif a.mode == "slot" then
				for _, n in ipairs(self:ArmorSlotNames()) do
					if a.slots[n] then add(n, a.priority) end
				end
			end
		end
	end

	return set
end

-- A user's own SAVED custom category (hand-filed items). We must NEVER wipe or
-- delete one of these — that would destroy their data. If a managed/fall-through
-- name happens to collide with one, we leave it entirely alone.
local function IsUserSaved(name)
	return database:GetItemCategory(name) ~= nil
end

-- ApplyConfig rebuilds the managed categories and forces a full re-categorization.
-- Safe to call repeatedly (on login and on every config change).
function EBBC:ApplyConfig()
	local ctx = NewCtx("EBBC_Apply")
	local newSet = self:ComputeManagedNames()

	-- Release every item our dispatcher previously routed. WipeCategory clears the
	-- category's ephemeral itemList and the ephemeralCategoryByItemID cache for those
	-- items (which ReprocessAllItems alone does not), so fall-through re-routes are
	-- undone when the config changes. Native (non-routed) items are untouched.
	for name in pairs(self.touched) do
		if not IsUserSaved(name) then
			pcall(categories.WipeCategory, categories, ctx, name)
		end
	end
	wipe(self.touched)

	-- Delete any category we intend to own — both this session's managed set AND the
	-- new target names — so stale ephemeral entries BetterBags reloaded from a prior
	-- session are cleared before we recreate with our priority (CreateCategory no-ops
	-- on an already-present name). Never delete a user's saved category.
	local toDelete = {}
	for name in pairs(self.managed) do toDelete[name] = true end
	for name in pairs(newSet) do toDelete[name] = true end
	for name in pairs(toDelete) do
		if not IsUserSaved(name) then
			pcall(categories.DeleteCategory, categories, ctx, name)
		end
	end
	self.managed = {}

	-- (Re)create the current managed set with our priority. Skip a name that is a
	-- user's saved category — our dispatcher will still route into it (as a shadow),
	-- but we leave ownership with the user.
	for name, priority in pairs(newSet) do
		if not IsUserSaved(name) then
			pcall(categories.CreateCategory, categories, ctx, {
				name = name,
				priority = priority,
				itemList = {},
				save = false,
				dynamic = true,
				enabled = { [BACKPACK] = true, [BANK] = true },
			})
		end
		self.managed[name] = true
	end

	-- Wipe the no-category cache and redraw everything against the new rules.
	pcall(categories.ReprocessAllItems, categories, ctx)
end

--------------------------------------------------------------------------------
-- Suppression list API (used by Config.lua and the slash command).
--------------------------------------------------------------------------------
---@param kind BagKind
---@param name string
function EBBC:IsSuppressed(kind, name)
	return self.db.suppressed[kind] and self.db.suppressed[kind][name] == true
end

---@param kind BagKind
---@param name string
---@param suppressed boolean
function EBBC:SetSuppressed(kind, name, suppressed)
	if name == NAME_EVERYTHING then return end -- never suppress the catch-all
	self.db.suppressed[kind][name] = suppressed and true or nil
	self:ApplyConfig()
end

---@param kind? BagKind  when omitted, restores both bags
function EBBC:RestoreAllDefaults(kind)
	if kind then
		wipe(self.db.suppressed[kind])
	else
		wipe(self.db.suppressed[BACKPACK])
		wipe(self.db.suppressed[BANK])
	end
	self:ApplyConfig()
end

-- The BetterBags-natural (computed) sections currently visible in a bag — i.e. the
-- section names that are NOT backed by a real custom/search/ephemeral category.
-- These are exactly the "rigid defaults" the user can suppress.
---@param kind BagKind
---@return string[]
function EBBC:CurrentDefaultSections(kind)
	local out, seen = {}, {}
	local bag = kind == BACKPACK and BB.Bags and BB.Bags.Backpack
		or (BB.Bags and BB.Bags.Bank)
	local view = bag and bag.currentView
	if view and view.sections then
		for sName in pairs(view.sections) do
			if sName ~= NAME_EVERYTHING and sName ~= Loc("Free Space")
				and sName ~= Loc("Recent Items") and not self.managed[sName]
				and not categories:GetCategoryByName(sName) -- nil ⇒ computed/dynamic
				and not seen[sName]
			then
				seen[sName] = true
				table.insert(out, sName)
			end
		end
	end
	-- Include already-suppressed names so they can be un-suppressed even though
	-- they no longer appear as a live section.
	for sName in pairs(self.db.suppressed[kind]) do
		if not seen[sName] then
			seen[sName] = true
			table.insert(out, sName)
		end
	end
	table.sort(out)
	return out
end

--------------------------------------------------------------------------------
-- Slash command: a reliable control surface independent of the /bb config frame.
--------------------------------------------------------------------------------
local function Print(msg)
	print("|cff0CD29DCategory Schemes|r: " .. msg)
end

-- Suppress/recover a default in BOTH bags with a single re-apply.
local function SetSuppressedBoth(name, suppressed)
	if name == NAME_EVERYTHING then return end
	EBBC.db.suppressed[BACKPACK][name] = suppressed and true or nil
	EBBC.db.suppressed[BANK][name] = suppressed and true or nil
	EBBC:ApplyConfig()
end

local function HandleSlash(msg)
	msg = strtrim(msg or "")
	-- lower-case only the command word; preserve case for category names.
	local cmd, rest = msg:match("^(%S*)%s*(.-)$")
	cmd = (cmd or ""):lower()

	if cmd == "weapon" then
		local m = rest:lower()
		if m == "off" or m == "on" then
			EBBC.db.bags[BACKPACK].weapon.mode = m
			EBBC.db.bags[BANK].weapon.mode = m
			EBBC:ApplyConfig(); Print("weapon grouping = " .. m .. " (both bags)")
		else
			Print("weapon grouping (backpack) is '" .. EBBC.db.bags[BACKPACK].weapon.mode .. "'. Use: /bbcs weapon off|on (then tick All 1H / All 2H / subtypes in /bb)")
		end
	elseif cmd == "armor" then
		local m = rest:lower()
		if m == "off" or m == "type" or m == "slot" then
			EBBC.db.bags[BACKPACK].armor.mode = m
			EBBC.db.bags[BANK].armor.mode = m
			EBBC:ApplyConfig(); Print("armor grouping = " .. m .. " (both bags)")
		else
			Print("armor mode (backpack) is '" .. EBBC.db.bags[BACKPACK].armor.mode .. "'. Use: /bbcs armor off|type|slot")
		end
	elseif cmd == "remove" and rest ~= "" then
		SetSuppressedBoth(rest, true)
		Print(("removed default '%s' (items fall through). Use /bbcs restore %s to recover."):format(rest, rest))
	elseif cmd == "restore" and rest:lower() == "all" then
		EBBC:RestoreAllDefaults(); Print("restored all default categories in both bags.")
	elseif cmd == "restore" and rest ~= "" then
		SetSuppressedBoth(rest, false); Print(("recovered default '%s'."):format(rest))
	elseif cmd == "apply" then
		EBBC:ApplyConfig(); Print("re-applied.")
	elseif cmd == "weapons" then
		-- Diagnostic: dump the enumerated weapon subclasses (id → client name) and
		-- which are enabled for the Backpack, so the real IDs can be verified.
		Print("weapon subclasses on this client (id : name : backpack-enabled):")
		local en = EBBC.db.bags[BACKPACK].weapon.subclasses
		for _, e in ipairs(EBBC:WeaponSubclasses()) do
			print(("  %2d : %-22s : %s"):format(e.id, e.name, en[e.id] and "|cff40ff40ON|r" or "off"))
		end
	elseif cmd == "probe" then
		-- Diagnostic: report the class/subclass of the item on the cursor.
		local t, id = GetCursorInfo()
		if t ~= "item" or not id then
			Print("pick the item up onto your cursor first, then /bbcs probe.")
		else
			local _, itemType, itemSubType, equipLoc, _, classID, subclassID = C_Item.GetItemInfoInstant(id)
			local scName = (C_Item.GetItemSubClassInfo and classID and subclassID
				and C_Item.GetItemSubClassInfo(classID, subclassID)) or "?"
			Print(("item %s: classID=%s (%s), subclassID=%s (%s), equipLoc=%s"):format(
				tostring(id), tostring(classID), tostring(itemType), tostring(subclassID),
				tostring(scName), tostring(equipLoc)))
			if classID == CLASS_WEAPON then
				local on = EBBC.db.bags[BACKPACK].weapon.subclasses[subclassID]
				Print(("  → weapon subclass %s is %s for the Backpack."):format(
					tostring(subclassID), on and "|cff40ff40ENABLED|r" or "|cffff4040NOT enabled|r"))
			end
			ClearCursor()
		end
	elseif cmd == "open" then
		pcall(function()
			local config = BB:GetModule("Config", true)
			if config then
				if not config.configFrame then config:OnEnable() end
				config:Open()
			end
		end)
	else
		Print("commands: weapon off|on · armor off|type|slot · remove <Name> · restore <Name> · restore all · apply · open · weapons (list) · probe (item on cursor)")
	end
end

--------------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------------
local boot = CreateFrame("Frame")
pcall(boot.RegisterEvent, boot, "ADDON_LOADED")
pcall(boot.RegisterEvent, boot, "PLAYER_LOGIN")
boot:SetScript("OnEvent", function(_, event, name)
	if event == "ADDON_LOADED" and name == addonName then
		InitDB()
	elseif event == "PLAYER_LOGIN" then
		if not EBBC.db then InitDB() end

		-- Register the dispatcher exactly once. RegisterCategoryFunction asserts on
		-- a duplicate id, so guard it.
		if not EBBC._registered then
			local ok, err = pcall(categories.RegisterCategoryFunction, categories,
				"BetterBagsCategorySchemes", function(data) return EBBC:Dispatch(data) end)
			EBBC._registered = ok
			if not ok then Print("|cffff4040error registering category function:|r " .. tostring(err)) end
		end

		-- Slash command. IMPORTANT: the SlashCmdList key must equal the token in the
		-- SLASH_<TOKEN>N global (here "BBCS"); WoW looks up SlashCmdList["BBCS"].
		_G.SlashCmdList = _G.SlashCmdList or {}
		_G.SLASH_BBCS1 = "/bbcs"
		_G.SLASH_BBCS2 = "/categoryschemes"
		_G.SlashCmdList["BBCS"] = HandleSlash

		-- Build managed categories + first categorization pass.
		local okApply, applyErr = pcall(EBBC.ApplyConfig, EBBC)
		if not okApply then Print("|cffff4040error applying config:|r " .. tostring(applyErr)) end

		-- Set up the settings UI. Config.lua registers the per-bag hook at file scope
		-- when the patched API is present; RegisterConfig here only builds the fallback
		-- tabs when the API is absent (patch not applied).
		if EBBC.RegisterConfig then
			local okCfg, cfgErr = pcall(EBBC.RegisterConfig, EBBC)
			if not okCfg then Print("|cffff4040error building settings panel:|r " .. tostring(cfgErr)) end
		end

		local where = EBBC._hasBagHook
			and "Open |cff0CD29D/bb|r → Backpack (or Bank) → \"Extra Categories\" to configure."
			or "Open |cff0CD29D/bb|r → the \"Category: …\" tabs to configure."
		Print("loaded. " .. where)
	end
end)
