--[[
	BetterBags — Category Schemes (Config)

	Renders the settings INSIDE BetterBags' own Backpack and Bank config sections,
	right below the category filters, using the config:RegisterBagConfig hook added
	by _BetterBags-CustomPatches. Settings are per-bag (each section controls its own
	bag). The controls are a compact custom grid (small font, 3-column checkboxes, a
	segmented mode selector, hover tooltips) built into the section pane, with its
	height reserved through the layout (addHeight) — no BetterBags file is touched at
	runtime beyond the one supported hook call.

	If the hook is absent (patch not applied), RegisterConfig falls back to building
	two standalone "Category: Backpack" / "Category: Bank" tabs, so the addon still
	works — the patch only upgrades placement.
]]

local BB = LibStub("AceAddon-3.0"):GetAddon("BetterBags", true)
if not BB then return end

local EBBC = _G.BetterBagsCategorySchemes
if not EBBC then return end

local const = EBBC.const
local BACKPACK = const.BAG_KIND.BACKPACK
local BANK     = const.BAG_KIND.BANK

--------------------------------------------------------------------------------
-- Layout constants
--------------------------------------------------------------------------------
local COLS   = 3
local COL_W  = 200   -- column pitch (px)
local ROW_H  = 22    -- checkbox row pitch
local LINE_H = 26    -- control line pitch
local LABEL_GREY = { 0.78, 0.78, 0.78 }
local HEADER_GOLD = { 1, 0.82, 0 }

--------------------------------------------------------------------------------
-- Small widget builders (standard Blizzard templates, shrunk)
--------------------------------------------------------------------------------
local function Tooltip(owner, text)
	if not text then return end
	owner:HookScript("OnEnter", function()
		GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
		GameTooltip:SetText(text, 1, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	owner:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

local function FS(parent, text, fontObject, color)
	local fs = parent:CreateFontString(nil, "OVERLAY", fontObject or "GameFontHighlightSmall")
	fs:SetText(text)
	if color then fs:SetTextColor(color[1], color[2], color[3]) end
	fs:SetJustifyH("LEFT")
	return fs
end

local function MakeCheck(parent, label, tip, getFn, setFn)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate") --[[@as CheckButton]]
	cb:SetSize(20, 20)
	cb:SetChecked(getFn() and true or false)
	local fs = FS(cb, label, "GameFontHighlightSmall", LABEL_GREY)
	fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	fs:SetWidth(COL_W - 26)
	fs:SetWordWrap(false)
	cb.label = fs
	cb:SetScript("OnClick", function() setFn(cb:GetChecked() and true or false) end)
	Tooltip(cb, tip)
	return cb
end

-- Segmented control: a row of small buttons, one highlighted for the current value.
local function MakeSegmented(parent, anchorFrame, opts, getVal, setVal, onChange)
	local btns, prev = {}, nil
	for i, o in ipairs(opts) do
		local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate") --[[@as Button]]
		btn:SetSize(78, 20)
		btn:SetText(o.text)
		local bfs = btn:GetFontString(); if bfs then bfs:SetFontObject("GameFontHighlightSmall") end
		if prev then btn:SetPoint("LEFT", prev, "RIGHT", 3, 0)
		else btn:SetPoint("LEFT", anchorFrame, "RIGHT", 8, 0) end
		btns[i] = btn; prev = btn
	end
	local function refresh()
		for i, o in ipairs(opts) do
			local on = (getVal() == o.value)
			local bfs = btns[i]:GetFontString()
			if bfs then bfs:SetTextColor(on and 1 or 0.6, on and 0.82 or 0.6, on and 0 or 0.6) end
		end
	end
	for i, o in ipairs(opts) do
		btns[i]:SetScript("OnClick", function()
			setVal(o.value); refresh(); if onChange then onChange() end
		end)
	end
	refresh()
	return refresh
end

local function MakePriority(parent, getFn, setFn)
	local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate") --[[@as EditBox]]
	box:SetSize(34, 20)
	box:SetAutoFocus(false)
	box:SetNumeric(true)
	box:SetMaxLetters(2)
	box:SetFontObject("GameFontHighlightSmall")
	box:SetText(tostring(getFn()))
	local function commit()
		local n = tonumber(box:GetText()) or 10
		n = math.max(0, math.min(99, math.floor(n + 0.5)))
		box:SetText(tostring(n)); setFn(n); box:ClearFocus()
	end
	box:SetScript("OnEnterPressed", commit)
	box:SetScript("OnEditFocusLost", commit)
	Tooltip(box, "Section priority (0-99). Lower wins; 10 ties with a user search category.")
	return box
end

--------------------------------------------------------------------------------
-- Pane builder (top-down, tracks height)
--------------------------------------------------------------------------------
local function NewBuilder(content) return { content = content, y = 6 } end

local function AddControlLine(b, text)
	local fs = FS(b.content, text, "GameFontNormalSmall", HEADER_GOLD)
	fs:SetPoint("TOPLEFT", b.content, "TOPLEFT", 4, -b.y)
	b.y = b.y + LINE_H
	return fs
end

local function AddPriorityLine(b, labelText, getFn, setFn)
	local fs = FS(b.content, labelText, "GameFontNormalSmall", LABEL_GREY)
	fs:SetPoint("TOPLEFT", b.content, "TOPLEFT", 8, -b.y)
	local box = MakePriority(b.content, getFn, setFn)
	box:SetPoint("LEFT", fs, "RIGHT", 8, 0)
	b.y = b.y + LINE_H
end

-- Grid of checkboxes from specs = { {label, tip, get, set}, ... }. Returns the
-- created CheckButtons so the caller can enable/disable them as a group.
local function AddCheckGrid(b, specs)
	local created = {}
	for i, s in ipairs(specs) do
		local col = (i - 1) % COLS
		local row = math.floor((i - 1) / COLS)
		local cb = MakeCheck(b.content, s.label, s.tip, s.get, s.set)
		cb:SetPoint("TOPLEFT", b.content, "TOPLEFT", 4 + col * COL_W, -(b.y + row * ROW_H))
		created[#created + 1] = cb
	end
	b.y = b.y + math.ceil(#specs / COLS) * ROW_H + 4
	return created
end

local function SetGroupEnabled(checks, enabled)
	for _, cb in ipairs(checks) do
		cb:SetEnabled(enabled)
		local g = enabled and LABEL_GREY or { 0.4, 0.4, 0.4 }
		cb.label:SetTextColor(g[1], g[2], g[3])
	end
end

--------------------------------------------------------------------------------
-- Build the compact controls for one bag into `content`; return total height.
--------------------------------------------------------------------------------
local function PopulateBagPane(content, kind)
	local b = NewBuilder(content)
	local cfg = EBBC.db.bags[kind]

	-- After any edit: when Sync is on, mirror this bag's whole config to the other
	-- bag so the two stay identical; then re-categorize.
	local function afterWrite()
		if EBBC.db.syncBags then EBBC:SyncFrom(kind) end
		EBBC:ApplyConfig()
	end

	-- SYNC --------------------------------------------------------------------
	local syncCb = MakeCheck(content, "Sync Backpack & Bank",
		"When on, edits in either bag apply to both. Turning it on copies THIS bag's settings to the other.",
		function() return EBBC.db.syncBags == true end,
		function(v)
			EBBC.db.syncBags = v or nil
			if v then EBBC:SyncFrom(kind) end
			EBBC:ApplyConfig()
		end)
	syncCb:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -b.y)
	b.y = b.y + ROW_H + 4

	-- WEAPONS ------------------------------------------------------------------
	local wlbl = AddControlLine(b, "Weapons")
	local wChecks
	MakeSegmented(content, wlbl, {
		{ text = "Off", value = "off" }, { text = "On", value = "on" },
	}, function() return cfg.weapon.mode end,
	function(v) cfg.weapon.mode = v; afterWrite() end,
	function() if wChecks then SetGroupEnabled(wChecks, cfg.weapon.mode == "on") end end)

	AddPriorityLine(b, "Priority", function() return cfg.weapon.priority end,
		function(n) cfg.weapon.priority = n; afterWrite() end)

	-- The lump buckets come FIRST (their whole point is to save you from ticking
	-- every subtype); a specific subtype ticked below still wins over its bucket.
	local wspecs = {
		{ label = "All One-Handed", tip = "Lump every one-handed weapon into one 'One-Handed Weapons' section.",
			get = function() return cfg.weapon.all1h == true end,
			set = function(v) cfg.weapon.all1h = v or nil; afterWrite() end },
		{ label = "All Two-Handed", tip = "Lump every two-handed weapon into one 'Two-Handed Weapons' section.",
			get = function() return cfg.weapon.all2h == true end,
			set = function(v) cfg.weapon.all2h = v or nil; afterWrite() end },
		{ label = "All Ranged", tip = "Lump bows/guns/crossbows/wands/thrown into one 'Ranged Weapons' section.",
			get = function() return cfg.weapon.allRanged == true end,
			set = function(v) cfg.weapon.allRanged = v or nil; afterWrite() end },
	}
	for _, e in ipairs(EBBC:WeaponSubclasses()) do
		local id = e.id
		wspecs[#wspecs + 1] = {
			label = e.name, tip = "Give '" .. e.name .. "' its own section (overrides the lump bucket).",
			get = function() return cfg.weapon.subclasses[id] == true end,
			set = function(v) cfg.weapon.subclasses[id] = v or nil; afterWrite() end,
		}
	end
	wChecks = AddCheckGrid(b, wspecs)
	SetGroupEnabled(wChecks, cfg.weapon.mode == "on")

	-- ARMOR --------------------------------------------------------------------
	local albl = AddControlLine(b, "Armor")
	local typeChecks, slotChecks
	MakeSegmented(content, albl, {
		{ text = "Off", value = "off" }, { text = "Material", value = "type" }, { text = "Slot", value = "slot" },
	}, function() return cfg.armor.mode end,
	function(v) cfg.armor.mode = v; afterWrite() end,
	function()
		if typeChecks then SetGroupEnabled(typeChecks, cfg.armor.mode == "type") end
		if slotChecks then SetGroupEnabled(slotChecks, cfg.armor.mode == "slot") end
	end)

	AddPriorityLine(b, "Priority", function() return cfg.armor.priority end,
		function(n) cfg.armor.priority = n; afterWrite() end)

	local tspecs = {}
	for _, e in ipairs(EBBC:ArmorTypeKeys()) do
		local key = e.key
		tspecs[#tspecs + 1] = {
			label = key .. " Armor", tip = "Group all " .. key .. " armor (in 'Material' mode).",
			get = function() return cfg.armor.types[key] == true end,
			set = function(v) cfg.armor.types[key] = v or nil; afterWrite() end,
		}
	end
	typeChecks = AddCheckGrid(b, tspecs)
	SetGroupEnabled(typeChecks, cfg.armor.mode == "type")

	local sspecs = {}
	for _, n in ipairs(EBBC:ArmorSlotNames()) do
		local slot = n
		sspecs[#sspecs + 1] = {
			label = slot, tip = "Give the '" .. slot .. "' slot its own section (in 'Slot' mode).",
			get = function() return cfg.armor.slots[slot] == true end,
			set = function(v) cfg.armor.slots[slot] = v or nil; afterWrite() end,
		}
	end
	slotChecks = AddCheckGrid(b, sspecs)
	SetGroupEnabled(slotChecks, cfg.armor.mode == "slot")

	-- REMOVE DEFAULTS ----------------------------------------------------------
	local rlbl = AddControlLine(b, "Remove defaults (items fall through)")
	local defChecks
	local restore = CreateFrame("Button", nil, content, "UIPanelButtonTemplate") --[[@as Button]]
	restore:SetSize(96, 20)
	restore:SetText("Restore all")
	local rfs = restore:GetFontString(); if rfs then rfs:SetFontObject("GameFontHighlightSmall") end
	restore:SetPoint("LEFT", rlbl, "RIGHT", 8, 0)
	restore:SetScript("OnClick", function()
		if EBBC.db.syncBags then EBBC:RestoreAllDefaults() else EBBC:RestoreAllDefaults(kind) end
		if defChecks then for _, cb in ipairs(defChecks) do cb:SetChecked(false) end end
	end)
	Tooltip(restore, "Recover every removed default in this bag.")

	local dspecs = {}
	for _, name in ipairs(EBBC:DefaultNameCandidates()) do
		local n = name
		dspecs[#dspecs + 1] = {
			label = n, tip = "Remove '" .. n .. "' — its items fall through to the next category. Untick to recover.",
			get = function() return EBBC:IsSuppressed(kind, n) end,
			set = function(v) EBBC.db.suppressed[kind][n] = v or nil; afterWrite() end,
		}
	end
	defChecks = AddCheckGrid(b, dspecs)

	return b.y + 6
end

--------------------------------------------------------------------------------
-- Height reservation in the tabbed layout (so the pane scrolls properly).
--------------------------------------------------------------------------------
local function ReserveContent(f, anchor, content, height)
	content:SetHeight(height)
	content:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -6)
	content:SetPoint("RIGHT", anchor, "RIGHT", 0, 0)
	local layout = f.layout
	if layout then
		layout.nextFrame = content
		if layout.addHeight then layout:addHeight(height + 6) end
	end
	if f.Resize then pcall(f.Resize, f) end
end

-- Find the tab container (the frame tagged with .tabIndex) above `frame`.
local function FindPane(frame)
	local p = frame
	while p and not p.tabIndex do p = p:GetParent() end
	return p or frame
end

--------------------------------------------------------------------------------
-- Hook path: render inline in a bag section (called during CreateConfig).
--------------------------------------------------------------------------------
function EBBC:BuildBagConfig(f, bagType)
	if not self.db then return end
	if not (f and f.layout and f.AddInlineSubSection) then return end
	f:AddInlineSubSection({
		title = "Extra Categories",
		description = "Weapon / armor grouping and removable defaults for this bag.",
	})
	local anchor = f.layout.nextFrame
	local pane = FindPane(anchor)
	local content = CreateFrame("Frame", nil, pane)
	local h = PopulateBagPane(content, bagType.kind)
	ReserveContent(f, anchor, content, h)
end

--------------------------------------------------------------------------------
-- Fallback path: our own top-level section (when the hook API is absent).
--------------------------------------------------------------------------------
local function BuildStandaloneSection(f, title, kind)
	local ok = pcall(function() f:AddSection({ title = title, description = "" }) end)
	if not ok then return end
	local layout = f.layout
	local anchor = layout and layout.nextFrame
	local pane = (layout and layout.tabContainers and layout.tabContainers[#layout.tabContainers]) or anchor
	if not (anchor and pane) then return end
	local content = CreateFrame("Frame", nil, pane)
	local h = PopulateBagPane(content, kind)
	ReserveContent(f, anchor, content, h)
end

-- Called at PLAYER_LOGIN. Only builds fallback tabs when the hook is unavailable.
function EBBC:RegisterConfig()
	if EBBC._hasBagHook then return end -- native per-bag hook handles it
	local config = BB:GetModule("Config", true)
	if not config then return end
	if not config.configFrame then pcall(config.OnEnable, config) end
	local f = config.configFrame
	if not f or not f.AddSection then return end
	if config.__ellesmereCategoriesRegistered then return end
	config.__ellesmereCategoriesRegistered = true
	BuildStandaloneSection(f, "Category: Backpack", BACKPACK)
	BuildStandaloneSection(f, "Category: Bank", BANK)
end

--------------------------------------------------------------------------------
-- Register the per-bag hook as early as possible (before the config is built).
--------------------------------------------------------------------------------
do
	local config = BB:GetModule("Config", true)
	if config and config.RegisterBagConfig then
		EBBC._hasBagHook = true
		config:RegisterBagConfig(function(f, bagType)
			local ok, err = pcall(function() EBBC:BuildBagConfig(f, bagType) end)
			if not ok then
				print("|cff0CD29DCategory Schemes|r: bag config error: " .. tostring(err))
			end
		end)
	else
		EBBC._hasBagHook = false
	end
end
