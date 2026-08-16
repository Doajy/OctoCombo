--[[
	OctoCombo
	A simple, lightweight combo point and energy display for the 1.12
	vanilla client (built and tested for Turtle WoW). Works for Rogues
	and Feral Druids.

	Slash commands:
	  /octocombo lock    - lock the frame in place (click-through)
	  /octocombo unlock  - unlock the frame so you can drag it and reveal the resize handle
	  /octocombo reset   - reset the frame back to its default position, size, and colors
	  /octocombo scale n - set the frame scale directly (e.g. /octocombo scale 1.5)
	  /octocombo energy  - toggle the energy bar on/off

	While unlocked, drag the small handle in the bottom-right corner to
	resize the whole tracker, or click the small dot on the title bar
	above the pips for an options menu: show/hide the energy bar, a
	color palette for the combo point pips, a color palette for the
	energy number text, and locking the frame. Each color option also
	offers a full custom color picker. The title bar itself (with the
	"Combo Points" label) is only shown while unlocked.
]]

local NUM_PIPS = 5
local UPDATE_INTERVAL = 0.1

-- ---------------------------------------------------------------------
-- Saved variables / defaults
-- ---------------------------------------------------------------------

local defaults = {
	point = "CENTER",
	x = 0,
	y = -220,
	locked = false,
	scale = 1.0,
	showEnergy = true,
	pipColorR = 0.85,
	pipColorG = 0.15,
	pipColorB = 0.1,
	energyTextColorR = 1.0,
	energyTextColorG = 0.82,
	energyTextColorB = 0.0,
}

local function EnsureDB()
	if not OctoComboDB then
		OctoComboDB = {}
	end
	for k, v in pairs(defaults) do
		if OctoComboDB[k] == nil then
			OctoComboDB[k] = v
		end
	end
end

-- ---------------------------------------------------------------------
-- Frame construction
-- ---------------------------------------------------------------------

local PIP_TEXTURE = "Interface\\AddOns\\OctoCombo\\ComboPoint.tga"

local PADDING = 8
local PIP_SIZE = 28
local PIP_GAP = 6
local BAR_GAP = 8
local BAR_HEIGHT = 14

local FRAME_WIDTH = NUM_PIPS * (PIP_SIZE + PIP_GAP) + PADDING * 2 - PIP_GAP
local FRAME_HEIGHT = PADDING + PIP_SIZE + BAR_GAP + BAR_HEIGHT + PADDING
local FRAME_HEIGHT_NO_ENERGY = PADDING + PIP_SIZE + PADDING

local frame = CreateFrame("Frame", "OctoComboFrame", UIParent)
frame:SetWidth(FRAME_WIDTH)
frame:SetHeight(FRAME_HEIGHT)
frame:SetFrameStrata("MEDIUM")
frame:EnableMouse(true)
frame:SetMovable(true)
frame:RegisterForDrag("LeftButton")

-- borderless: no backdrop, just a very faint dim behind the pips so they're
-- readable over any background, shown only while unlocked.
local dim = frame:CreateTexture(nil, "BACKGROUND")
dim:SetAllPoints(frame)
dim:SetTexture("Interface\\Buttons\\WHITE8x8")
dim:SetVertexColor(0, 0, 0, 0.25)

-- Title bar: a separate strip that sits above the pips, rather than
-- squeezing the lock/options dot into the tracker's own corner. Houses
-- the "Combo Points" label and (further down) the lock button.
local titleBar = CreateFrame("Frame", "OctoComboTitleBar", frame)
titleBar:SetHeight(16)
titleBar:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, 4)
titleBar:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 0, 4)

local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
title:SetPoint("CENTER", titleBar, "CENTER", 0, 0)
title:SetText("Combo Points")
title:SetTextColor(1, 0.82, 0)

-- pips (round, no borders)
local pips = {}
for i = 1, NUM_PIPS do
	local pip = frame:CreateTexture(nil, "ARTWORK")
	pip:SetWidth(PIP_SIZE)
	pip:SetHeight(PIP_SIZE)
	pip:SetTexture(PIP_TEXTURE)

	if i == 1 then
		pip:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -PADDING)
	else
		pip:SetPoint("LEFT", pips[i - 1], "RIGHT", PIP_GAP, 0)
	end

	pips[i] = pip
end

-- ---------------------------------------------------------------------
-- Energy bar (Rogue / Feral Druid resource), sits under the pips
-- ---------------------------------------------------------------------

local energyBar = CreateFrame("StatusBar", nil, frame)
energyBar:SetPoint("TOPLEFT", pips[1], "BOTTOMLEFT", 0, -BAR_GAP)
energyBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING, -(PADDING + PIP_SIZE + BAR_GAP))
energyBar:SetHeight(BAR_HEIGHT)
energyBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
energyBar:SetStatusBarColor(1.0, 0.92, 0.3) -- classic energy yellow
energyBar:SetMinMaxValues(0, 100)
energyBar:SetValue(0)

local energyBarBG = energyBar:CreateTexture(nil, "BACKGROUND")
energyBarBG:SetAllPoints(energyBar)
energyBarBG:SetTexture("Interface\\Buttons\\WHITE8x8")
energyBarBG:SetVertexColor(0, 0, 0, 0.5)

local energyText = energyBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
energyText:SetPoint("CENTER", energyBar, "CENTER", 0, 0)
energyText:SetText("100 / 100")
energyText:SetTextColor(1, 1, 1)

-- resize handle and lock button, declared here so they're in scope for
-- ApplyLockState below. The lock button is parented to titleBar (the
-- separate strip above the pips), not squeezed into the tracker's corner.
local resizeGrip = CreateFrame("Frame", nil, frame)
local menuButton = CreateFrame("Button", nil, titleBar)
local menuIcon = menuButton:CreateTexture(nil, "OVERLAY")

-- ---------------------------------------------------------------------
-- Colors
-- ---------------------------------------------------------------------
-- COLOR_ON is the customizable pip color (building combo points); it's
-- mutated in place by SetPipColor below rather than replaced, so the
-- change takes effect immediately. COLOR_FULL (the gold glow at 5/5,
-- meaning "finisher ready") is intentionally left fixed so that signal
-- stays readable no matter what color the player picks.

local COLOR_OFF = { 0.15, 0.15, 0.15, 0.6 }
local COLOR_ON = { 0.85, 0.15, 0.1, 1.0 }
local COLOR_FULL = { 1.0, 0.82, 0.1, 1.0 }

local PIP_COLOR_PRESETS = {
	{ name = "Red (Default)", r = 0.85, g = 0.15, b = 0.1 },
	{ name = "Orange", r = 0.95, g = 0.55, b = 0.1 },
	{ name = "Yellow", r = 0.95, g = 0.85, b = 0.15 },
	{ name = "Green", r = 0.25, g = 0.85, b = 0.25 },
	{ name = "Blue", r = 0.25, g = 0.55, b = 0.95 },
	{ name = "Purple", r = 0.65, g = 0.25, b = 0.95 },
	{ name = "Pink", r = 0.95, g = 0.35, b = 0.75 },
	{ name = "White", r = 0.9, g = 0.9, b = 0.9 },
}

local ENERGY_TEXT_COLOR_PRESETS = {
	{ name = "Gold (Default)", r = 1.0, g = 0.82, b = 0.0 },
	{ name = "White", r = 1.0, g = 1.0, b = 1.0 },
	{ name = "Red", r = 0.9, g = 0.2, b = 0.15 },
	{ name = "Orange", r = 0.95, g = 0.55, b = 0.1 },
	{ name = "Green", r = 0.3, g = 0.9, b = 0.3 },
	{ name = "Blue", r = 0.35, g = 0.6, b = 0.95 },
	{ name = "Purple", r = 0.7, g = 0.3, b = 0.95 },
	{ name = "Pink", r = 0.95, g = 0.4, b = 0.75 },
}

local function ApplyColor(tex, color)
	tex:SetVertexColor(color[1], color[2], color[3], color[4])
end

local function ColorText(text, r, g, b)
	return string.format("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, text)
end

-- ---------------------------------------------------------------------
-- Combo point update
-- ---------------------------------------------------------------------

local lastCP = -1
local elapsedSince = 0

local function UpdateComboPoints()
	local cp = GetComboPoints() or 0

	if cp == lastCP then
		return
	end
	lastCP = cp

	for i = 1, NUM_PIPS do
		if i <= cp then
			if cp == NUM_PIPS then
				ApplyColor(pips[i], COLOR_FULL)
			else
				ApplyColor(pips[i], COLOR_ON)
			end
		else
			ApplyColor(pips[i], COLOR_OFF)
		end
	end
end

-- ---------------------------------------------------------------------
-- Pip color (customizable via the options menu)
-- ---------------------------------------------------------------------

local function SetPipColor(r, g, b)
	COLOR_ON[1], COLOR_ON[2], COLOR_ON[3] = r, g, b
	OctoComboDB.pipColorR = r
	OctoComboDB.pipColorG = g
	OctoComboDB.pipColorB = b

	lastCP = -1 -- force a repaint even if the point count hasn't changed
	UpdateComboPoints()
end

local function OpenPipColorPicker()
	local startR, startG, startB = COLOR_ON[1], COLOR_ON[2], COLOR_ON[3]

	ColorPickerFrame.func = function()
		local r, g, b = ColorPickerFrame:GetColorRGB()
		SetPipColor(r, g, b)
	end
	ColorPickerFrame.cancelFunc = function()
		SetPipColor(startR, startG, startB)
	end
	ColorPickerFrame.hasOpacity = false

	ColorPickerFrame:SetColorRGB(startR, startG, startB)
	ShowUIPanel(ColorPickerFrame)
end

-- ---------------------------------------------------------------------
-- Energy text color (the current/max numbers on the energy bar), via the
-- options menu. The "Combo Points" title stays a fixed gold and isn't
-- customizable.
-- ---------------------------------------------------------------------

local function SetEnergyTextColor(r, g, b)
	energyText:SetTextColor(r, g, b)
	OctoComboDB.energyTextColorR = r
	OctoComboDB.energyTextColorG = g
	OctoComboDB.energyTextColorB = b
end

local function OpenEnergyTextColorPicker()
	local startR, startG, startB = OctoComboDB.energyTextColorR, OctoComboDB.energyTextColorG, OctoComboDB.energyTextColorB

	ColorPickerFrame.func = function()
		local r, g, b = ColorPickerFrame:GetColorRGB()
		SetEnergyTextColor(r, g, b)
	end
	ColorPickerFrame.cancelFunc = function()
		SetEnergyTextColor(startR, startG, startB)
	end
	ColorPickerFrame.hasOpacity = false

	ColorPickerFrame:SetColorRGB(startR, startG, startB)
	ShowUIPanel(ColorPickerFrame)
end

-- ---------------------------------------------------------------------
-- Position handling
-- ---------------------------------------------------------------------

local function SavePosition()
	local point, _, _, x, y = frame:GetPoint()
	OctoComboDB.point = point
	OctoComboDB.x = x
	OctoComboDB.y = y
end

local function LoadPosition()
	frame:ClearAllPoints()
	frame:SetPoint(OctoComboDB.point, UIParent, OctoComboDB.point, OctoComboDB.x, OctoComboDB.y)
	frame:SetScale(OctoComboDB.scale)
end

local function ApplyLockState()
	if OctoComboDB.locked then
		frame:EnableMouse(false)
		dim:SetVertexColor(0, 0, 0, 0)
		resizeGrip:Hide()
		menuButton:Hide()
		title:Hide()
	else
		frame:EnableMouse(true)
		dim:SetVertexColor(0, 0, 0, 0.25)
		resizeGrip:Show()
		menuButton:Show()
		title:Show()
		menuIcon:SetVertexColor(0.2, 0.85, 0.2, 1) -- green = unlocked
	end
end

local function ApplyOptions()
	if OctoComboDB.showEnergy then
		energyBar:Show()
		frame:SetHeight(FRAME_HEIGHT)
	else
		energyBar:Hide()
		frame:SetHeight(FRAME_HEIGHT_NO_ENERGY)
	end
end

frame:SetScript("OnDragStart", function()
	if not OctoComboDB.locked then
		frame:StartMoving()
	end
end)

frame:SetScript("OnDragStop", function()
	frame:StopMovingOrSizing()
	SavePosition()
end)

-- ---------------------------------------------------------------------
-- Resize handle (bottom-right corner, drag to scale the whole tracker)
-- ---------------------------------------------------------------------

local isSizing = false
local sizeStartX, sizeStartY, sizeStartScale = 0, 0, 1

resizeGrip:SetWidth(16)
resizeGrip:SetHeight(16)
resizeGrip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 2, -2)
resizeGrip:EnableMouse(true)

local gripTex = resizeGrip:CreateTexture(nil, "OVERLAY")
gripTex:SetAllPoints(resizeGrip)
gripTex:SetTexture("Interface\\Buttons\\WHITE8x8")
gripTex:SetVertexColor(1, 1, 1, 0.35)

resizeGrip:SetScript("OnMouseDown", function()
	isSizing = true
	sizeStartX, sizeStartY = GetCursorPosition()
	sizeStartScale = frame:GetScale()
end)

resizeGrip:SetScript("OnMouseUp", function()
	isSizing = false
	OctoComboDB.scale = frame:GetScale()
end)

-- Note: OnMouseUp only fires if the cursor is still over this small
-- handle when the button is released, which won't be true after a fast
-- outward drag. Checking the button state every tick below means we
-- always catch the release and never leave isSizing stuck "on".
resizeGrip:SetScript("OnUpdate", function()
	if not isSizing then
		return
	end

	if not IsMouseButtonDown("LeftButton") then
		isSizing = false
		OctoComboDB.scale = frame:GetScale()
		return
	end

	local x, y = GetCursorPosition()
	local uiScale = UIParent:GetEffectiveScale()
	local delta = ((x - sizeStartX) - (y - sizeStartY)) / uiScale
	local newScale = sizeStartScale + (delta / 220)

	if newScale < 0.5 then newScale = 0.5 end
	if newScale > 3.0 then newScale = 3.0 end

	frame:SetScale(newScale)
end)

-- ---------------------------------------------------------------------
-- Options button (small green dot, left end of the title bar above the
-- pips). Only shown while unlocked, for a clean look once you've locked
-- the frame in place; unlock again with /octocombo unlock (reminder
-- printed to chat on lock).
-- ---------------------------------------------------------------------

menuButton:SetWidth(12)
menuButton:SetHeight(12)
menuButton:SetPoint("LEFT", titleBar, "LEFT", 2, 0)
menuButton:EnableMouse(true)
menuButton:RegisterForClicks("LeftButtonUp")

menuIcon:SetAllPoints(menuButton)
menuIcon:SetTexture("Interface\\Buttons\\WHITE8x8")

local menuHighlight = menuButton:CreateTexture(nil, "HIGHLIGHT")
menuHighlight:SetAllPoints(menuButton)
menuHighlight:SetTexture("Interface\\Buttons\\WHITE8x8")
menuHighlight:SetVertexColor(1, 1, 1, 0.4)
menuHighlight:SetBlendMode("ADD")

-- only visible while unlocked; click opens the options menu (which
-- includes "Lock Frame"), rather than locking directly
menuButton:SetScript("OnEnter", function()
	GameTooltip:SetOwner(menuButton, "ANCHOR_TOPLEFT")
	GameTooltip:SetText("OctoCombo")
	GameTooltip:AddLine("Click for the options menu.", 1, 1, 1, true)
	GameTooltip:Show()
end)

menuButton:SetScript("OnLeave", function()
	GameTooltip:Hide()
end)

-- ---------------------------------------------------------------------
-- Options menu (click the corner button)
-- ---------------------------------------------------------------------

local optionsMenu = CreateFrame("Frame", "OctoComboOptionsMenu", UIParent, "UIDropDownMenuTemplate")
local PIP_COLOR_SUBMENU = "OCTOCOMBO_PIP_COLOR_SUBMENU"
local ENERGY_TEXT_COLOR_SUBMENU = "OCTOCOMBO_ENERGY_TEXT_COLOR_SUBMENU"

-- shared by both color submenus below: lists the given presets plus a
-- "Custom Color..." entry that opens the given picker function. The
-- preset is passed through Blizzard's own info.arg1 (read back as the
-- button's own arg1 at click time) rather than a closure over the loop
-- variable, since the dropdown button pool otherwise ended up calling
-- these with a stale/nil preset.
local function OnPresetColorClick(self, setColorFunc, preset)
	setColorFunc(preset.r, preset.g, preset.b)
end

local function AddColorSubmenuButtons(level, presets, setColorFunc, openPickerFunc)
	for _, preset in ipairs(presets) do
		local info = {}
		info.text = ColorText(preset.name, preset.r, preset.g, preset.b)
		info.notCheckable = true
		info.func = OnPresetColorClick
		info.arg1 = setColorFunc
		info.arg2 = preset
		UIDropDownMenu_AddButton(info, level)
	end

	local info = {}
	info.text = "Custom Color..."
	info.notCheckable = true
	info.func = openPickerFunc
	UIDropDownMenu_AddButton(info, level)
end

local function InitOptionsMenu()
	local level = UIDROPDOWNMENU_MENU_LEVEL or 1
	local value = UIDROPDOWNMENU_MENU_VALUE

	if level == 2 and value == PIP_COLOR_SUBMENU then
		AddColorSubmenuButtons(level, PIP_COLOR_PRESETS, SetPipColor, OpenPipColorPicker)
		return
	end

	if level == 2 and value == ENERGY_TEXT_COLOR_SUBMENU then
		AddColorSubmenuButtons(level, ENERGY_TEXT_COLOR_PRESETS, SetEnergyTextColor, OpenEnergyTextColorPicker)
		return
	end

	local info = {}
	info.text = "OctoCombo Options"
	info.isTitle = true
	info.notCheckable = true
	UIDropDownMenu_AddButton(info, level)

	info = {}
	info.text = "Show Energy Bar"
	info.checked = OctoComboDB.showEnergy
	info.keepShownOnClick = true
	info.func = function()
		OctoComboDB.showEnergy = not OctoComboDB.showEnergy
		ApplyOptions()
	end
	UIDropDownMenu_AddButton(info, level)

	info = {}
	info.text = "Combo Point Color"
	info.notCheckable = true
	info.hasArrow = true
	info.value = PIP_COLOR_SUBMENU
	UIDropDownMenu_AddButton(info, level)

	info = {}
	info.text = "Energy Text Color"
	info.notCheckable = true
	info.hasArrow = true
	info.value = ENERGY_TEXT_COLOR_SUBMENU
	UIDropDownMenu_AddButton(info, level)

	info = {}
	info.text = "Lock Frame"
	info.notCheckable = true
	info.func = function()
		OctoComboDB.locked = true
		ApplyLockState()
		DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00OctoCombo:|r locked. Type |cff33ff99/octocombo unlock|r to move or resize it again.")
	end
	UIDropDownMenu_AddButton(info, level)
end

menuButton:SetScript("OnClick", function()
	UIDropDownMenu_Initialize(optionsMenu, InitOptionsMenu, "MENU")
	ToggleDropDownMenu(1, nil, optionsMenu, "OctoComboTitleBar", 0, 0)
end)

-- ---------------------------------------------------------------------
-- Energy update
-- ---------------------------------------------------------------------
-- Note: in the 1.12 API every class's primary resource (mana, rage,
-- energy, or focus) comes through the same UnitMana / UnitManaMax calls.
-- This addon is built for Rogues and Feral Druids, whose resource is
-- energy, so that's how the bar is labeled and colored.
--
-- UnitManaMax("player") is the engine's live max-energy value, so it
-- already includes any talent bonus (e.g. Vigor, +5/+10 max energy) the
-- moment it's learned -- no manual talent detection needed here.

local lastEnergy, lastEnergyMax = -1, -1

local function UpdateEnergy()
	local cur = UnitMana("player") or 0
	local max = UnitManaMax("player") or 0
	if max <= 0 then max = 1 end

	if cur == lastEnergy and max == lastEnergyMax then
		return
	end
	lastEnergy, lastEnergyMax = cur, max

	energyBar:SetMinMaxValues(0, max)
	energyBar:SetValue(cur)
	energyText:SetText(cur .. " / " .. max)
end

frame:SetScript("OnUpdate", function()
	elapsedSince = elapsedSince + arg1
	if elapsedSince < UPDATE_INTERVAL then
		return
	end
	elapsedSince = 0
	UpdateComboPoints()
	UpdateEnergy()
end)

-- ---------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------
-- Both combo point events are registered since 1.12's real event is
-- PLAYER_COMBO_POINTS (UNIT_COMBO_POINTS wasn't added until later
-- expansions); registering an event that doesn't exist on this client is
-- a harmless no-op, so this covers any server-side variation safely.

frame:RegisterEvent("VARIABLES_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("PLAYER_COMBO_POINTS")
frame:RegisterEvent("UNIT_COMBO_POINTS")
frame:RegisterEvent("UNIT_MANA")
frame:RegisterEvent("UNIT_MAXMANA")

frame:SetScript("OnEvent", function()
	if event == "VARIABLES_LOADED" then
		EnsureDB()
		LoadPosition()
		ApplyLockState()
		ApplyOptions()
		SetPipColor(OctoComboDB.pipColorR, OctoComboDB.pipColorG, OctoComboDB.pipColorB)
		SetEnergyTextColor(OctoComboDB.energyTextColorR, OctoComboDB.energyTextColorG, OctoComboDB.energyTextColorB)
		lastEnergy, lastEnergyMax = -1, -1
		UpdateEnergy()
	elseif event == "PLAYER_ENTERING_WORLD" then
		-- safety net: force a full refresh after loading screens/zoning,
		-- in case anything was left stale
		lastCP = -1
		lastEnergy, lastEnergyMax = -1, -1
		UpdateComboPoints()
		UpdateEnergy()
	elseif event == "PLAYER_TARGET_CHANGED" or event == "PLAYER_COMBO_POINTS" or event == "UNIT_COMBO_POINTS" then
		lastCP = -1 -- force a refresh
		UpdateComboPoints()
	elseif event == "UNIT_MANA" or event == "UNIT_MAXMANA" then
		if arg1 == "player" then
			lastEnergy, lastEnergyMax = -1, -1
			UpdateEnergy()
		end
	end
end)

-- ---------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------

SLASH_OCTOCOMBO1 = "/octocombo"
SlashCmdList["OCTOCOMBO"] = function(msg)
	msg = string.lower(msg or "")

	if msg == "lock" then
		OctoComboDB.locked = true
		ApplyLockState()
		DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00OctoCombo:|r locked. Type |cff33ff99/octocombo unlock|r to move or resize it again.")
	elseif msg == "unlock" then
		OctoComboDB.locked = false
		ApplyLockState()
		DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00OctoCombo:|r unlocked, drag to move.")
	elseif msg == "reset" then
		OctoComboDB.point = defaults.point
		OctoComboDB.x = defaults.x
		OctoComboDB.y = defaults.y
		OctoComboDB.scale = defaults.scale
		LoadPosition()
		SetPipColor(defaults.pipColorR, defaults.pipColorG, defaults.pipColorB)
		SetEnergyTextColor(defaults.energyTextColorR, defaults.energyTextColorG, defaults.energyTextColorB)
		DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00OctoCombo:|r position, size, and colors reset.")
	elseif msg == "energy" then
		OctoComboDB.showEnergy = not OctoComboDB.showEnergy
		ApplyOptions()
		if OctoComboDB.showEnergy then
			DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00OctoCombo:|r energy bar shown.")
		else
			DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00OctoCombo:|r energy bar hidden.")
		end
	elseif string.find(msg, "^scale") then
		local _, _, num = string.find(msg, "^scale%s+([%d%.]+)")
		num = tonumber(num)
		if num and num > 0.3 and num < 3 then
			OctoComboDB.scale = num
			frame:SetScale(num)
			DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00OctoCombo:|r scale set to " .. num .. ".")
		else
			DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00OctoCombo:|r usage: /octocombo scale 1.2 (between 0.3 and 3)")
		end
	else
		DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00OctoCombo|r commands:")
		DEFAULT_CHAT_FRAME:AddMessage("  /octocombo lock - lock the frame")
		DEFAULT_CHAT_FRAME:AddMessage("  /octocombo unlock - unlock and drag to move")
		DEFAULT_CHAT_FRAME:AddMessage("  /octocombo reset - reset position, scale, and colors")
		DEFAULT_CHAT_FRAME:AddMessage("  /octocombo scale n - set scale, e.g. /octocombo scale 1.2")
		DEFAULT_CHAT_FRAME:AddMessage("  /octocombo energy - toggle the energy bar on/off")
		DEFAULT_CHAT_FRAME:AddMessage("  drag the bottom-right handle (while unlocked) to resize")
		DEFAULT_CHAT_FRAME:AddMessage("  click the corner dot (while unlocked) for the options menu")
	end
end
