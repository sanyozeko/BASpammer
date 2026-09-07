-- BASpammer: спам заданного текста в выбранный номерной канал с заданным интервалом.

local BA_PATTERN_COUNT = 20
-- Подпись для незаполненного шаблона: показывается только в списке и в поле
-- "Шаблон:", в самом тексте шаблона при этом пусто.
local BA_EMPTY_LABEL = "Пусто"
local BA_MIN_INTERVAL  = 10
local BA_MAX_BYTES     = 255

-- Длина превью в символах: поле "Шаблон:", выпадающий список, поле "Канал:".
local BA_PREVIEW_FIELD   = 18
local BA_PREVIEW_MENU    = 34
local BA_PREVIEW_CHANNEL = 20

BASpammerTooltip = CreateFrame("GameTooltip", "BASpammerTooltip", nil, "GameTooltipTemplate")

-- Файл SavedVariables выполняется после файлов аддона и заменяет эту таблицу целиком,
-- поэтому значения по умолчанию проставляются в BA_InitDB() по ADDON_LOADED.
BASpammerDB = BASpammerDB or {}

local BASpammerRaidIconList = {
[1] = { text = RAID_TARGET_1, color = {r = 1.0, g = 0.92, b = 0}, icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcons", tCoordLeft = 0, tCoordRight = 0.25, tCoordTop = 0, tCoordBottom = 0.25 };
[2] = { text = RAID_TARGET_2, color = {r = 0.98, g = 0.57, b = 0}, icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcons", tCoordLeft = 0.25, tCoordRight = 0.5, tCoordTop = 0, tCoordBottom = 0.25 };
[3] = { text = RAID_TARGET_3, color = {r = 0.83, g = 0.22, b = 0.9}, icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcons", tCoordLeft = 0.5, tCoordRight = 0.75, tCoordTop = 0, tCoordBottom = 0.25 };
[4] = { text = RAID_TARGET_4, color = {r = 0.04, g = 0.95, b = 0}, icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcons", tCoordLeft = 0.75, tCoordRight = 1, tCoordTop = 0, tCoordBottom = 0.25 };
[5] = { text = RAID_TARGET_5, color = {r = 0.7, g = 0.82, b = 0.875}, icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcons", tCoordLeft = 0, tCoordRight = 0.25, tCoordTop = 0.25, tCoordBottom = 0.5 };
[6] = { text = RAID_TARGET_6, color = {r = 0, g = 0.71, b = 1}, icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcons", tCoordLeft = 0.25, tCoordRight = 0.5, tCoordTop = 0.25, tCoordBottom = 0.5 };
[7] = { text = RAID_TARGET_7, color = {r = 1.0, g = 0.24, b = 0.168}, icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcons", tCoordLeft = 0.5, tCoordRight = 0.75, tCoordTop = 0.25, tCoordBottom = 0.5 };
[8] = { text = RAID_TARGET_8, color = {r = 0.98, g = 0.98, b = 0.98}, icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcons", tCoordLeft = 0.75, tCoordRight = 1, tCoordTop = 0.25, tCoordBottom = 0.5 };
}

-- === Утилиты ===

local function BA_Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[BASpammer]|r " .. msg)
end

-- Обрезка по байтам (чат режет по 255 байтам), но строго по границе UTF-8 символа,
-- иначе кириллица в конце строки превращается в мусор.
local function BA_TrimToBytes(text, limit)
    if not text then return "" end
    if #text <= limit then return text end
    local cut = limit
    while cut > 0 do
        local b = string.byte(text, cut + 1)
        if not b or b < 128 or b >= 192 then break end
        cut = cut - 1
    end
    return string.sub(text, 1, cut)
end

local function BA_IsBlank(msg)
    return (not msg) or msg == ""
end

-- Обрезка по символам (не по байтам) для превью в интерфейсе.
local function BA_TrimToChars(text, maxChars)
    local chars, pos, len = 0, 1, #text
    while pos <= len do
        if chars == maxChars then return string.sub(text, 1, pos - 1), true end
        local b = string.byte(text, pos)
        local size = 1
        if b >= 240 then size = 4 elseif b >= 224 then size = 3 elseif b >= 192 then size = 2 end
        chars = chars + 1
        pos = pos + size
    end
    return text, false
end

-- Убирает escape-последовательности (ссылки, цвет, текстуры) из превью.
local function BA_PlainText(s)
    if not s then return "" end
    s = string.gsub(s, "|H.-|h(.-)|h", "%1")
    s = string.gsub(s, "|c%x%x%x%x%x%x%x%x", "")
    s = string.gsub(s, "|r", "")
    s = string.gsub(s, "|T.-|t", "")
    s = string.gsub(s, "%s+", " ")
    s = string.gsub(s, "^%s", "")
    return s
end

-- "3. начало текста шаблона..."
local function BA_PatternLabel(index, maxChars)
    local db = BASpammerDB
    local txt = BA_PlainText(db.Pattern and db.Pattern[index])
    if txt == "" then txt = BA_EMPTY_LABEL end
    local cut, trimmed = BA_TrimToChars(txt, maxChars)
    if trimmed then cut = cut .. "..." end
    return index .. ". " .. cut
end

-- Номера каналов меняются между сессиями, поэтому канал доищивается по имени.
local function BA_ResolveChannel()
    local db = BASpammerDB
    if db.ChannelName then
        local id = GetChannelName(db.ChannelName)
        if id and id > 0 then db.Channel = id end
    end
    local _, name = GetChannelName(db.Channel or 0)
    if name and name ~= "" then db.ChannelName = name end
    return db.Channel, name
end

local function BA_ChannelLabel(withNumber)
    local id, name = BA_ResolveChannel()
    if not name or name == "" then return "Канал " .. tostring(id) end
    local cut, trimmed = BA_TrimToChars(name, BA_PREVIEW_CHANNEL)
    if trimmed then cut = cut .. "..." end
    if withNumber then return id .. ". " .. cut end
    return cut
end

-- === Сохранённые настройки ===

local function BA_InitDB()
    if type(BASpammerDB) ~= "table" then BASpammerDB = {} end
    local db = BASpammerDB

    if type(db.Pattern) ~= "table" then db.Pattern = {} end
    for i = 1, BA_PATTERN_COUNT do
        if type(db.Pattern[i]) ~= "string" then db.Pattern[i] = "" end
        -- До 1.18 слово "Пусто" лежало прямо в тексте шаблона, вычищаем.
        if db.Pattern[i] == BA_EMPTY_LABEL then db.Pattern[i] = "" end
    end

    db.CheckedPattern = tonumber(db.CheckedPattern) or 1
    if db.CheckedPattern < 1 or db.CheckedPattern > BA_PATTERN_COUNT then db.CheckedPattern = 1 end

    db.Channel  = tonumber(db.Channel) or 1
    if type(db.ChannelName) ~= "string" or db.ChannelName == "" then db.ChannelName = nil end
    db.Interval = tonumber(db.Interval) or BA_MIN_INTERVAL
    if db.Interval < BA_MIN_INTERVAL then db.Interval = BA_MIN_INTERVAL end

    -- По умолчанию надпись. В 1.21 умолчанием была миникарта, но это был
    -- не выбор пользователя, поэтому пока он сам не переключил - надпись.
    if not db.LauncherSet then db.Launcher = 3 end
    db.Launcher = tonumber(db.Launcher) or 3
    if db.Launcher < 1 or db.Launcher > 3 then db.Launcher = 3 end
    db.MinimapAngle = tonumber(db.MinimapAngle) or 200

    db.Tumbler = false
    db.LastTimeSpam = 0
    db.Flag = nil -- поле из версий до 1.05
end

-- === Состояние ===

local BA_intervalNext            -- текущий интервал с рандомом
local BA_prevMaxFPSBk            -- сохранённое значение maxFPSBk
local BA_channelWarned = false
local BA_blankWarned = false
local BA_guardText = false
local BA_guardInterval = false
local BA_lastTaximeter = 0

-- === Обновление интерфейса ===

-- === Кнопка вызова ===

local BA_ART = "Interface\\AddOns\\BASpammer\\Textures\\"
local BA_MINIMAP_RADIUS = 80

-- Значок меняет цвет вместе с состоянием: красный без полосок - молчит,
-- зелёный с полосками - идёт спам.
local function BA_SetToggleText()
    local on = BASpammerDB.Tumbler
    if on then
        BASpammerText:SetText("BASpammer |cff00ff00On|r")
    else
        BASpammerText:SetText("BASpammer |cffff0000Off|r")
    end
    if BASpammerIcon then
        BASpammerIcon:SetNormalTexture(BA_ART .. (on and "logo-on" or "logo-off"))
    end
    if BASpammerMinimapButtonIcon then
        BASpammerMinimapButtonIcon:SetTexture(BA_ART .. (on and "logo-round-on" or "logo-round-off"))
    end
end

local function BA_PlaceMinimapButton()
    local angle = math.rad(BASpammerDB.MinimapAngle or 200)
    BASpammerMinimapButton:ClearAllPoints()
    BASpammerMinimapButton:SetPoint("CENTER", Minimap, "CENTER",
        math.cos(angle) * BA_MINIMAP_RADIUS, math.sin(angle) * BA_MINIMAP_RADIUS)
end

-- Показывается ровно одна кнопка, остальные прячутся. Таймер живёт на отдельной
-- рамке BASpammerDriver, поэтому спам не зависит от того, что видно на экране.
local function BA_ApplyLauncher()
    local mode = BASpammerDB.Launcher
    BASpammerMinimapButton:Hide()
    BASpammerIcon:Hide()
    BASpammer:Hide()
    if mode == 1 then
        BA_PlaceMinimapButton()
        BASpammerMinimapButton:Show()
    elseif mode == 2 then
        BASpammerIcon:Show()
    else
        BASpammer:Show()
    end
    BA_SetToggleText()
end

local function BA_RefreshOptions()
    local mode = BASpammerDB.Launcher
    BASpammerOptionsLauncher1:SetChecked(mode == 1)
    BASpammerOptionsLauncher2:SetChecked(mode == 2)
    BASpammerOptionsLauncher3:SetChecked(mode == 3)
end

-- Подсказка одна на все три кнопки вызова, привязывается к той, на которую навели.
local function BA_ShowTooltip(owner)
    local db = BASpammerDB
    GameTooltip_SetDefaultAnchor(BASpammerTooltip, owner)
    BASpammerTooltip:ClearLines()
    BASpammerTooltip:SetHyperlink("|cff9d9d9d|Hitem::0:0:0:0:0:0:0:0|h[]|h|r")
    if db.Tumbler then
        BASpammerTooltip:AddLine("Идет спам!", 0.1, 1, 0.1)
    else
        BASpammerTooltip:AddLine("Спам выключен", 1, 0.3, 0.3)
    end
    BASpammerTooltip:AddLine("Канал: " .. "|cffffffff" .. BA_ChannelLabel(true) .. "|r")
    BASpammerTooltip:AddLine("Интервал: " .. "|cffffffff" .. tostring(db.Interval) .. " сек|r")
    local msg = db.Pattern and db.Pattern[db.CheckedPattern]
    if msg and msg ~= "" then
        BASpammerTooltip:AddLine("Текст:")
        BASpammerTooltip:AddLine(msg, 1, 1, 1, "true")
    end
    BASpammerTooltip:Show()
end

local function BA_UpdateSymbolText()
    if not BASpammerSettingTextSymbols then return end
    local db = BASpammerDB
    local txt = (db and db.Pattern and db.Pattern[db.CheckedPattern]) or ""
    BASpammerSettingTextSymbols:SetFormattedText("%d / %d", #txt, BA_MAX_BYTES)
end

-- Без цветовых кодов: кнопка красит текст сама, стандартным золотым.
local function BA_SetToggleButton()
    if BASpammerDB.Tumbler then
        BASpammerSettingStartButton:SetText("Стоп")
    else
        BASpammerSettingStartButton:SetText("Старт")
    end
end

-- Поле текста закрыто полупрозрачной панелью, пока в нём не стоит курсор.
local function BA_ClearEditFocus()
    if BASpammerSettingTextBox then BASpammerSettingTextBox:ClearFocus() end
    if BASpammerSettingIntervalEditBox then BASpammerSettingIntervalEditBox:ClearFocus() end
end

local function BA_HasEditFocus()
    return (BASpammerSettingTextBox and BASpammerSettingTextBox:HasFocus())
        or (BASpammerSettingIntervalEditBox and BASpammerSettingIntervalEditBox:HasFocus())
end

local function BA_MouseInsideUI()
    if MouseIsOver(BASpammerSetting) then return true end
    if DropDownList1 and DropDownList1:IsShown() and MouseIsOver(DropDownList1) then return true end
    if DropDownList2 and DropDownList2:IsShown() and MouseIsOver(DropDownList2) then return true end
    return false
end

-- Клик мимо окна тоже снимает курсор. Ловушка на весь экран съедала бы этот клик,
-- поэтому просто смотрим, зажата ли кнопка мыши вне окна.
local function BA_CheckOutsideClick()
    if not (BASpammerSetting and BASpammerSetting:IsShown()) then return end
    if not BA_HasEditFocus() then return end
    if not (IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")) then return end
    if BA_MouseInsideUI() then return end
    BA_ClearEditFocus()
end

local function BA_UpdatePatternLabel()
    BASpammerSettingTextPatternEditBox:SetText(BA_PatternLabel(BASpammerDB.CheckedPattern, BA_PREVIEW_FIELD))
end

local function BA_RefreshSettingWidgets()
    local db = BASpammerDB
    if not db.Pattern then BA_InitDB() end
    BA_UpdatePatternLabel()
    -- Текст можно править во время спама, поэтому не сбрасываем поле без нужды.
    if BASpammerSettingTextBox:GetText() ~= db.Pattern[db.CheckedPattern] then
        BASpammerSettingTextBox:SetText(db.Pattern[db.CheckedPattern])
    end
    if BASpammerSettingIntervalEditBox:GetText() ~= tostring(db.Interval) then
        BASpammerSettingIntervalEditBox:SetText(tostring(db.Interval))
    end
    BASpammerSettingChanelEditBox:SetText(BA_ChannelLabel())
    BA_UpdateSymbolText()
end

local function BA_ToggleSettings()
    BA_RefreshSettingWidgets()
    if BASpammerSetting:IsShown() then
        BASpammerSetting:Hide()
    else
        BASpammerSetting:Show()
    end
end

function BASpammer:OnMouseDown(self, arg1)
    BA_RefreshSettingWidgets()
    if arg1 == "RightButton" then
        BA_ToggleSettings()
    end
end

-- === Вставка ссылок в поле "Текст:" ===

-- Вставлять можно только в реально видимое поле, иначе ссылка молча уходила
-- в спрятанный редактор и подменяла шаблон.
local function BA_CanInsertIntoBox()
    return BASpammerSetting and BASpammerSetting:IsShown()
       and BASpammerSettingText and BASpammerSettingText:IsShown()
       and BASpammerSettingTextBox ~= nil
end

local function BA_InsertLink(link)
    if not link or not BA_CanInsertIntoBox() then return false end
    BASpammerSettingTextBox:SetFocus()
    BASpammerSettingTextBox:Insert(link)
    return true
end

local BA_ChatEdit_InsertLink_Orig = ChatEdit_InsertLink
ChatEdit_InsertLink = function(link, ...)
    if BA_InsertLink(link) then return true end
    return BA_ChatEdit_InsertLink_Orig(link, ...)
end

local function BA_ShouldIntercept()
    return BA_CanInsertIntoBox() and IsShiftKeyDown()
end

-- SHIFT + клик по чекбоксу отслеживания квеста/ачивки кладёт ссылку в шаблон.
local function BA_HookTrackFunction(name, getLink)
    local orig = _G[name]
    if type(orig) ~= "function" then return end
    _G[name] = function(index, ...)
        if index and BA_ShouldIntercept() and BA_InsertLink(getLink(index)) then return end
        return orig(index, ...)
    end
end

BA_HookTrackFunction("AddQuestWatch", GetQuestLink)
BA_HookTrackFunction("RemoveQuestWatch", GetQuestLink)
BA_HookTrackFunction("AddTrackedAchievement", GetAchievementLink)
BA_HookTrackFunction("RemoveTrackedAchievement", GetAchievementLink)

local function BA_AchievementLinkOf(frame)
    local id = frame and (frame.id or frame.achievementID or (frame.GetID and frame:GetID()))
    if not id then return nil end
    return GetAchievementLink(id)
end

local BA_origAchClick, BA_origAchToggle, BA_origAchSummary

local function BA_HookAchievementUI()
    if AchievementButton_OnClick and not BA_origAchClick then
        BA_origAchClick = AchievementButton_OnClick
        AchievementButton_OnClick = function(self, button, down)
            if BA_ShouldIntercept() and BA_InsertLink(BA_AchievementLinkOf(self)) then return end
            return BA_origAchClick(self, button, down)
        end
    end
    if AchievementButton_ToggleTracking and not BA_origAchToggle then
        BA_origAchToggle = AchievementButton_ToggleTracking
        AchievementButton_ToggleTracking = function(id)
            if id and BA_ShouldIntercept() and BA_InsertLink(GetAchievementLink(id)) then return end
            return BA_origAchToggle(id)
        end
    end
    if AchievementFrameSummaryAchievement_OnClick and not BA_origAchSummary then
        BA_origAchSummary = AchievementFrameSummaryAchievement_OnClick
        AchievementFrameSummaryAchievement_OnClick = function(self)
            if BA_ShouldIntercept() and BA_InsertLink(BA_AchievementLinkOf(self)) then return end
            return BA_origAchSummary(self)
        end
    end
end

-- === Выпадающие списки ===

local info

local BASpammerChannelsDropdown = CreateFrame("Frame", "BASpammerChannelsDropdown")
BASpammerChannelsDropdown.displayMode = "MENU"
BASpammerChannelsDropdown.point = "TOPRIGHT"
BASpammerChannelsDropdown.relativePoint = "BOTTOMRIGHT"
BASpammerChannelsDropdown.relativeTo = "BASpammerSettingChanelButton"
BASpammerChannelsDropdown.initialize = function(self, level)
    if not level then return end
    -- GetChannelList() отдаёт пары (номер, название); номер берём как число,
    -- иначе каналы с номером 10 и выше превращались в канал 1.
    local count = select("#", GetChannelList())
    local list = { GetChannelList() }
    for i = 1, count - 1, 2 do
        local id, name = tonumber(list[i]), list[i + 1]
        if id and name then
            info = UIDropDownMenu_CreateInfo()
            info.text = id .. ". " .. name
            info.arg1 = id
            info.notCheckable = 1
            info.func = function(_, arg1)
                CloseDropDownMenus()
                BASpammerDB.Channel = arg1
                BASpammerDB.ChannelName = name
                BA_channelWarned = false -- канал сменили, предупреждение можно показать снова
                BASpammerSettingChanelEditBox:SetText(BA_ChannelLabel())
            end
            UIDropDownMenu_AddButton(info)
        end
    end
    info = UIDropDownMenu_CreateInfo()
    info.text = CLOSE
    info.notCheckable = 1
    info.func = function() CloseDropDownMenus() end
    UIDropDownMenu_AddButton(info)
end

local TextPatternDropdown = CreateFrame("Frame", "TextPatternDropdown")
TextPatternDropdown.displayMode = "MENU"
TextPatternDropdown.point = "TOPRIGHT"
TextPatternDropdown.relativePoint = "BOTTOMRIGHT"
TextPatternDropdown.relativeTo = "BASpammerSettingTextPatternButton"
TextPatternDropdown.initialize = function(self, level)
    if not level then return end
    for i = 1, BA_PATTERN_COUNT do
        info = UIDropDownMenu_CreateInfo()
        info.text = BA_PatternLabel(i, BA_PREVIEW_MENU)
        info.arg1 = i
        info.notCheckable = 1
        info.tooltipTitle = "Шаблон " .. i
        info.tooltipText = BASpammerDB.Pattern and BASpammerDB.Pattern[i]
        info.tooltipOnButton = 1
        info.func = function(_, arg1)
            CloseDropDownMenus()
            -- Номер меняем до SetText, иначе OnTextChanged запишет текст в старый шаблон.
            BASpammerDB.CheckedPattern = arg1
            BASpammerSettingTextBox:SetText(BASpammerDB.Pattern[arg1])
            BA_blankWarned = false
            BA_UpdatePatternLabel()
        end
        UIDropDownMenu_AddButton(info)
    end
    info = UIDropDownMenu_CreateInfo()
    info.text = CLOSE
    info.notCheckable = 1
    info.func = function() CloseDropDownMenus() end
    UIDropDownMenu_AddButton(info)
end

local BASpammerMarkersDropdown = CreateFrame("Frame", "BASpammerMarkersDropdown")
BASpammerMarkersDropdown.displayMode = "MENU"
BASpammerMarkersDropdown.initialize = function(self, level)
    if not level then return end
    for i = 1, 8 do
        local color = BASpammerRaidIconList[i].color
        info = UIDropDownMenu_CreateInfo()
        info.text = BASpammerRaidIconList[i].text
        info.colorCode = string.format("|cFF%02x%02x%02x", color.r * 255, color.g * 255, color.b * 255)
        info.icon = BASpammerRaidIconList[i].icon
        info.tCoordLeft = BASpammerRaidIconList[i].tCoordLeft
        info.tCoordRight = BASpammerRaidIconList[i].tCoordRight
        info.tCoordTop = BASpammerRaidIconList[i].tCoordTop
        info.tCoordBottom = BASpammerRaidIconList[i].tCoordBottom
        info.arg1 = i
        info.notCheckable = 1
        info.func = function(_, arg1)
            CloseDropDownMenus()
            BASpammerSettingTextBox:Insert("{rt" .. arg1 .. "}")
        end
        UIDropDownMenu_AddButton(info)
    end
    info = UIDropDownMenu_CreateInfo()
    info.text = CLOSE
    info.notCheckable = 1
    info.func = function() CloseDropDownMenus() end
    UIDropDownMenu_AddButton(info)
end

-- === Перетаскивание кнопки вызова ===

-- Клик и перетаскивание висят на одной кнопке, поэтому отличаем их по тому,
-- сдвинулась рамка или нет.
function BASpammerLauncher_OnMouseDown(self)
    self.dragging = true
    if self == BASpammerIcon then
        self.moved = false
        self.startX, self.startY = self:GetLeft(), self:GetTop()
        self:StartMoving()
    else
        self.moved = false
    end
end

function BASpammerLauncher_OnMouseUp(self)
    self.dragging = false
    if self == BASpammerIcon then
        self:StopMovingOrSizing()
        local x, y = self:GetLeft(), self:GetTop()
        if x and y and self.startX and self.startY then
            if math.abs(x - self.startX) > 2 or math.abs(y - self.startY) > 2 then
                self.moved = true
                BASpammerDB.IconX, BASpammerDB.IconY = x, y
            end
        end
    end
    if not self.moved then
        BA_ToggleSettings()
    end
end

-- Кнопка на миникарте ездит по кольцу, поэтому позиция хранится углом.
function BASpammerMinimapButton_OnUpdate(self)
    if not self.dragging then return end
    local mx, my = Minimap:GetCenter()
    local scale = UIParent:GetScale()
    local cx, cy = GetCursorPosition()
    cx, cy = cx / scale, cy / scale
    local angle = math.deg(math.atan2(cy - my, cx - mx))
    if math.abs(angle - (BASpammerDB.MinimapAngle or 200)) > 0.5 then self.moved = true end
    BASpammerDB.MinimapAngle = angle
    BA_PlaceMinimapButton()
end

function BASpammerLauncher_OnEnter(self)
    BA_ShowTooltip(self)
end

-- Кнопка-шестерёнка рядом с крестиком открывает окно настроек.
function BASpammerSettingSkinButton_OnClick()
    BA_ClearEditFocus()
    if BASpammerOptions:IsShown() then
        BASpammerOptions:Hide()
    else
        BA_RefreshOptions()
        BASpammerOptions:Show()
    end
end

function BASpammerOptionsLauncher_OnClick(mode)
    BASpammerDB.Launcher = mode
    BASpammerDB.LauncherSet = true
    BA_ApplyLauncher()
    BA_RefreshOptions()
end

function BASpammerSettingSkinButton_OnEnter()
    GameTooltip:SetOwner(BASpammerSettingSkinButton, "ANCHOR_LEFT")
    GameTooltip:SetText("Настройки")
    GameTooltip:Show()
end

function BASpammerSettingChanelButton_OnClick()
    BA_ClearEditFocus()
    ToggleDropDownMenu(1, nil, BASpammerChannelsDropdown, "BASpammerSettingChanelButton", 0, 0)
end

function BASpammerSettingTextPatternButton_OnClick()
    BA_ClearEditFocus()
    ToggleDropDownMenu(1, nil, TextPatternDropdown, "BASpammerSettingTextPatternButton", 0, 0)
end

local function BA_GetCursorScaledPosition()
    local scale, x, y = UIParent:GetScale(), GetCursorPosition()
    return x / scale, y / scale
end

local function BA_OpenMarkersMenu()
    local x, y = BA_GetCursorScaledPosition()
    ToggleDropDownMenu(1, nil, BASpammerMarkersDropdown, "UIParent", x, y)
end

function BASpammerSettingTextBox_OnMouseDown(self, arg1)
    if arg1 == "RightButton" then
        BA_OpenMarkersMenu()
    end
end

-- Клик по накрывающей панели снимает блокировку и ставит курсор в текст.
function BASpammerSettingTextCover_OnClick(self, arg1)
    BASpammerSettingTextCover:Hide()
    BASpammerSettingTextBox:SetFocus()
    if arg1 == "RightButton" then
        BA_OpenMarkersMenu()
    end
end

function BASpammerSettingTextBox_OnEditFocusGained()
    BASpammerSettingTextCover:Hide()
end

function BASpammerSettingTextBox_OnEditFocusLost()
    BASpammerSettingTextBox:HighlightText(0, 0) -- убрать выделение вместе с курсором
    BASpammerSettingTextCover:Show()
end

function BASpammerSettingTextBox_OnEscapePressed()
    BASpammerSettingTextBox:ClearFocus()
end

-- === Собственно спам ===

-- Разброс симметричен вокруг заданного интервала и не опускает его ниже минимума.
-- Запас считается заранее, а не обрезается после: обрезка съедала только минусовую
-- половину, из-за чего на 10 секундах отсчёт скакал до 12, а средний интервал полз вверх.
local function BA_NextInterval(base)
    base = tonumber(base) or BA_MIN_INTERVAL
    if base < BA_MIN_INTERVAL then base = BA_MIN_INTERVAL end

    local span = base - BA_MIN_INTERVAL
    if span > 2 then span = 2 end
    if span <= 0 then return base end -- на минимуме разброса нет: 10 в поле = 10 в отсчёте

    local jitter = math.random(0, span)
    if math.random(2) == 1 then jitter = -jitter end
    return base + jitter
end

local function BA_SendPattern()
    local db = BASpammerDB
    -- Текст читается в момент отправки, поэтому правки применяются со следующего сообщения.
    local msg = db.Pattern and db.Pattern[db.CheckedPattern]
    if BA_IsBlank(msg) then
        if not BA_blankWarned then
            BA_blankWarned = true
            BA_Print("|cffff0000Шаблон пуст, отправка приостановлена.|r")
        end
        return
    end
    BA_blankWarned = false

    local id, name = BA_ResolveChannel()
    if not name then
        if not BA_channelWarned then
            BA_channelWarned = true
            BA_Print("|cffff0000Канал " .. tostring(db.ChannelName or db.Channel) .. " не подключён, сообщение не отправлено.|r")
        end
        return
    end
    BA_channelWarned = false

    SendChatMessage(BA_TrimToBytes(msg, BA_MAX_BYTES), "CHANNEL", nil, id)
end

function BASpammer:OnUpdate()
    BA_CheckOutsideClick()

    local db = BASpammerDB
    if not db or not db.Tumbler then return end

    local now = GetTime()
    -- Интервал правится на ходу, поэтому минимум сторожим здесь, а не только в Start.
    local base = tonumber(db.Interval) or BA_MIN_INTERVAL
    if base < BA_MIN_INTERVAL then base = BA_MIN_INTERVAL end
    local interval = BA_intervalNext or base

    if (now - (db.LastTimeSpam or 0)) >= interval then
        BA_SendPattern()
        db.LastTimeSpam = now
        BA_intervalNext = BA_NextInterval(base)
        interval = BA_intervalNext
    end

    if (now - BA_lastTaximeter) >= 0.1 then
        BA_lastTaximeter = now
        local remain = interval - (now - (db.LastTimeSpam or now))
        if remain < 0 then remain = 0 end
        remain = math.floor(remain + 0.5)
        BASpammerSettingTaximeterText:SetFormattedText("%d:%02d", math.floor(remain / 60), remain - math.floor(remain / 60) * 60)
    end
end

-- OnUpdate не тикает, когда клиент свёрнут и фоновый FPS занижен (ALT+TAB).
local function BA_EnsureBackgroundFPS()
    if BA_prevMaxFPSBk ~= nil then return end
    local v = tonumber(GetCVar("maxFPSBk")) or 0
    if v > 0 and v < 30 then -- 0 означает "без ограничения", его трогать не нужно
        BA_prevMaxFPSBk = v
        SetCVar("maxFPSBk", "30")
    end
end

local function BA_RestoreBackgroundFPS()
    if BA_prevMaxFPSBk ~= nil then
        SetCVar("maxFPSBk", tostring(BA_prevMaxFPSBk))
        BA_prevMaxFPSBk = nil
    end
end

function BASpammerSettingStartButton_OnClick()
    local db = BASpammerDB
    if BA_IsBlank(db.Pattern and db.Pattern[db.CheckedPattern]) then
        BA_Print("|cffff0000Шаблон " .. tostring(db.CheckedPattern) .. " пуст, спам не запущен.|r")
        return
    end
    if (tonumber(db.Interval) or 0) < BA_MIN_INTERVAL then
        db.Interval = BA_MIN_INTERVAL
        BASpammerSettingIntervalEditBox:SetText(tostring(BA_MIN_INTERVAL))
    end

    -- Отсчёт живёт отдельно от кнопок и считает от последней отправки:
    -- первый запуск (и пауза длиннее интервала) отправляет сразу,
    -- короткая пауза досчитывает остаток, а не начинает отсчёт заново.
    BA_intervalNext = BA_intervalNext or BA_NextInterval(db.Interval)

    db.Tumbler = true
    BA_channelWarned = false
    BA_blankWarned = false
    BA_SetToggleText()
    BA_SetToggleButton()

    -- Текст, канал, шаблон и интервал меняются на ходу, ничего не прячем.
    BASpammerSettingTaximeter:Show()

    BA_EnsureBackgroundFPS()
end

function BASpammerSettingStopButton_OnClick()
    BASpammerDB.Tumbler = false
    BA_SetToggleText()
    BA_SetToggleButton()

    BASpammerSettingTaximeter:Hide()

    BA_RestoreBackgroundFPS()
end

function BASpammerSettingToggleButton_OnClick()
    BA_ClearEditFocus()
    if BASpammerDB.Tumbler then
        BASpammerSettingStopButton_OnClick()
    else
        BASpammerSettingStartButton_OnClick()
    end
end

-- === Поля ввода ===

function BASpammerSettingTextBox_OnTextChanged()
    if BA_guardText then return end
    local db = BASpammerDB
    if not db.Pattern then return end

    local txt = BASpammerSettingTextBox:GetText() or ""
    -- Перенос строки в чат всё равно не уйдёт, поэтому сразу меняем его на пробел.
    local clean = string.gsub(txt, "[\r\n]", " ")
    clean = BA_TrimToBytes(clean, BA_MAX_BYTES)
    if clean ~= txt then
        BA_guardText = true
        BASpammerSettingTextBox:SetText(clean)
        BA_guardText = false
        txt = clean
    end

    db.Pattern[db.CheckedPattern] = txt
    BA_UpdateSymbolText()
    BA_UpdatePatternLabel()
end

-- Enter завершает правку: курсор снимается, поле снова закрывается панелью.
function BASpammerSettingTextBox_OnEnterPressed()
    BASpammerSettingTextBox:ClearFocus()
end

function BASpammerSettingTextBox_OnTabPressed()
    BASpammerSettingTextBox:Insert("    ")
end

function BASpammerSettingIntervalEditBox_OnTextChanged()
    if BA_guardInterval then return end
    local txt = BASpammerSettingIntervalEditBox:GetText() or ""
    local digits = string.gsub(txt, "%D", "")
    if digits ~= txt then
        BA_guardInterval = true
        BASpammerSettingIntervalEditBox:SetText(digits)
        BA_guardInterval = false
    end
    BASpammerDB.Interval = tonumber(digits) or 0
    BA_intervalNext = nil
end

-- Подтягиваем поле к минимуму, когда пользователь закончил ввод.
function BASpammerSettingIntervalEditBox_OnEditFocusLost()
    local db = BASpammerDB
    if (tonumber(db.Interval) or 0) < BA_MIN_INTERVAL then
        db.Interval = BA_MIN_INTERVAL
        BA_guardInterval = true
        BASpammerSettingIntervalEditBox:SetText(tostring(BA_MIN_INTERVAL))
        BA_guardInterval = false
    end
end

function BASpammerSettingIntervalEditBox_OnEnterPressed()
    BASpammerSettingIntervalEditBox:ClearFocus()
end

-- === Позиции окон ===

function BASpammer:SavePosition(argpos)
    local frame = (argpos == 1 and BASpammer) or (argpos == 2 and BASpammerSetting)
    if not frame then return end
    local left, top = frame:GetLeft(), frame:GetTop()
    if not (left and top) then return end
    if argpos == 1 then
        BASpammerDB.posx, BASpammerDB.posy = left, top
    else
        BASpammerDB.posx1, BASpammerDB.posy1 = left, top
    end
end

local function BA_SetupFrames()
    if BASpammerDB.posx and BASpammerDB.posy then
        BASpammer:ClearAllPoints()
        BASpammer:SetPoint("TOPLEFT", "UIParent", "BOTTOMLEFT", BASpammerDB.posx, BASpammerDB.posy)
    end
    if BASpammerDB.posx1 and BASpammerDB.posy1 then
        BASpammerSetting:ClearAllPoints()
        BASpammerSetting:SetPoint("TOPLEFT", "UIParent", "BOTTOMLEFT", BASpammerDB.posx1, BASpammerDB.posy1)
    end
    BASpammerSettingTaximeter:Hide()
    -- Панель должна перекрывать поле ввода, иначе клик уйдёт мимо неё.
    BASpammerSettingTextCover:SetFrameLevel(BASpammerSettingTextBox:GetFrameLevel() + 5)
    BASpammerSettingTextCover:Show()
    BA_SetToggleButton()
    BASpammerSettingTitleText1:SetText("BASpammer v" .. (GetAddOnMetadata("BASpammer", "Version") or ""))

    if BASpammerDB.IconX and BASpammerDB.IconY then
        BASpammerIcon:ClearAllPoints()
        BASpammerIcon:SetPoint("TOPLEFT", "UIParent", "BOTTOMLEFT", BASpammerDB.IconX, BASpammerDB.IconY)
    end
    BA_ApplyLauncher()
    BA_RefreshOptions()
end

-- === Подсказка ===

function BASpammer:OnEnter()
    BA_ShowTooltip(BASpammer)
end

function BASpammer:OnLeave()
    BASpammerTooltip:Hide()
end

-- === События ===

local function BA_OnEvent(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == "BASpammer" then
            BA_InitDB()
            BA_SetupFrames()
            BA_SetToggleText()
            BA_UpdateSymbolText()
            BA_Print("аддон загружен, /baspammer - настройки.")
        elseif arg1 == "Blizzard_AchievementUI" then
            BA_HookAchievementUI()
        end
    elseif event == "VARIABLES_LOADED" then
        BA_InitDB()
        BA_SetToggleText()
    elseif event == "PLAYER_LOGIN" then
        if IsAddOnLoaded("Blizzard_AchievementUI") then BA_HookAchievementUI() end
    elseif event == "PLAYER_LOGOUT" then
        BA_RestoreBackgroundFPS() -- иначе maxFPSBk остаётся изменённым после выхода
    end
end

BASpammer:SetScript("OnEvent", BA_OnEvent)
BASpammer:RegisterEvent("ADDON_LOADED")
BASpammer:RegisterEvent("VARIABLES_LOADED")
BASpammer:RegisterEvent("PLAYER_LOGIN")
BASpammer:RegisterEvent("PLAYER_LOGOUT")

SLASH_BASPAMMER1 = "/baspammer"
SLASH_BASPAMMER2 = "/bas"
SlashCmdList["BASPAMMER"] = function()
    BA_ToggleSettings()
end

-- Версия 1.01
--- Добавлено рандомное значение интервала; удалена лишняя папка Image
-- Версия 1.02
--- Исправлено: кол-во символов в поле ввода соответветствует выводимому в чате
--- Добавлена обработка нажатия в поле ввода Enter и Tab
-- Версия 1.03
--- Минимальный интервал снижен до 10 с
-- Версия 1.04
--- добавлен линк квестов/ачив через ID и SHIFT + клик. Фикс несрабатывания аддона при ALT+TAB
-- Версия 1.05
--- Исправлены каналы с номером 10 и выше (спам уходил в канал 1)
--- Обрезка текста по 255 байтам больше не рвёт кириллицу пополам
--- Настройки корректно инициализируются и мигрируют со старых версий
--- maxFPSBk восстанавливается при выходе и релоаде UI, значение 0 больше не занижается
--- Рандом интервала больше не опускает его ниже 10 с
--- Перед отправкой проверяется, подключён ли канал
--- Вставка ссылок больше не пишет в скрытое поле во время спама (только SHIFT + клик)
--- Убраны кнопки "Вставить квест" и "Вставить ачивку"
--- Добавлена команда /baspammer (/bas)
-- Версия 1.06
--- Текст можно править прямо во время спама (отсчёт переехал на место интервала)
--- В поле "Канал:" показывается название канала, а не его номер
--- В поле "Шаблон:" и в списке шаблонов показывается начало текста шаблона
--- Полный текст шаблона виден в подсказке при наведении на пункт списка
--- Канал ищется по имени, если сервер выдал ему другой номер
-- Версия 1.07
--- Канал и шаблон переключаются во время спама, без остановки
-- Версия 1.08
--- Отсчёт переехал вниз по центру окна, поле "Интервал:" больше не прячется
--- Интервал тоже правится во время спама (минимум 10 с сторожится на лету)
-- Версия 1.09
--- Start больше не отправляет сообщение мгновенно: сначала проходит отсчёт
--- Короткая пауза продолжает прежний отсчёт, а не начинает его заново
-- Версия 1.10
--- Перекроено окно: поле текста шире (400), высота 300 -> 264
--- Start и Stop заменены одной кнопкой-переключателем
--- Рядом с отсчётом появилась надпись "Идёт спам", сам отсчёт в формате м:сс
--- Счётчик символов переехал в правый угол поля
-- Версия 1.11
--- Первое сообщение снова уходит сразу после Start
--- Короткая пауза по-прежнему досчитывает остаток, а не шлёт повторно
-- Версия 1.12
--- Кнопка Стоп красится штатным золотым, без цветового кода
-- Версия 1.13
--- Поле текста закрыто панелью "Нажмите, чтобы изменить текст", пока его не выбрали
--- Клик мимо поля, Esc и любая кнопка панели убирают из него курсор
-- Версия 1.14
--- Поле интервала тоже теряет курсор при клике мимо него
-- Версия 1.15
--- Курсор снимается и при клике за пределами окна аддона
-- Версия 1.16
--- Разброс интервала больше не задирает отсчёт выше заданного значения
-- Версия 1.17
--- Шаблонов стало 20 вместо 10
--- Кнопка "Выход" переименована в "Свернуть"
--- Enter в поле текста завершает правку и снова закрывает его панелью
-- Версия 1.18
--- Пустой шаблон теперь действительно пустой: "Пусто" осталось только подписью в списке
-- Версия 1.21
--- Логотип-рупор: красный без полосок молчит, зелёный с полосками спамит
--- Три способа вызова окна: миникарта, иконка на экране, надпись
--- Выбор живёт в новом окне настроек под шестерёнкой
--- Таймер переехал на отдельную рамку, спрятанная кнопка больше не глушит спам
-- Версия 1.22
--- В настройках рядом с каждым вариантом видно, как кнопка выглядит
--- Подписи вариантов сделаны отдельными строками: атрибут text у чекбокса не работает
--- По умолчанию снова надпись, а не миникарта
