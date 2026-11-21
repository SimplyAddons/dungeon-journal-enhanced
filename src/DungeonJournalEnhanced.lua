-- Dungeon Journal Enhanced
-- Adds a sort button (level / name) and a grid/list toggle to DungeonJournal's
-- home page, next to Hide Dungeons. The < > dungeon arrows follow the sort too.
--
-- Doesn't touch DJ's files. DJ calls FDJ.UpdateRPGHeader(frame) at the end of
-- every home page refresh, so we hook that and rearrange the cards it just laid
-- out. List view reuses DJ's own cards, which is why the done ticks, Hide
-- Dungeons, RPG Mode etc. still work. Each card's original layout gets saved
-- the first time we see it so grid view can put it back.
--
-- None of this is a public API, so a DJ update can break it. If that happens we
-- leave DJ's layout alone and print a message once. Things we depend on:
--   FDJ (ForeverDungeonJournal_NS): UpdateRPGHeader, ApplyRPGCard,
--     DungeonNavList, RefreshHomeCards
--   journal frame: homePanel, homeScroll, homeCardsContent,
--     languageSelectorButton, hideDungeonsButton
--   cards: dungeonName, title, meta, counts, art, topShade, coverBorder,
--     hiddenText, comingSoon, rpgPage.questCount
--
-- ****************************************************************************
-- Hey Exehn, if you're reading this: thanks for DungeonJournal. If you ever
-- want any of this in DJ itself, or want a proper hook so this doesn't depend
-- on your internals, I'm happy to collaborate whenever you are.
-- https://github.com/SimplyAddons/dungeon-journal-enhanced
-- ****************************************************************************

local ADDON_NAME = ...

local FDJ = _G.ForeverDungeonJournal_NS
if type(FDJ) ~= "table" then return end

-- 1.0.0 was installed as DungeonJournalEnhanced. If that folder is still
-- around it loads first (alphabetical), and running both would double every
-- button, so this copy stays off and says why once you log in.
local OLD_FOLDER = "DungeonJournalEnhanced"
local function OldCopyLoaded()
    if ADDON_NAME == OLD_FOLDER then return false end
    local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or _G.IsAddOnLoaded
    return isLoaded and isLoaded(OLD_FOLDER) and true or false
end

local ROW_HEIGHT = 36 -- list row
local ROW_GAP = 6
-- Level column, wide enough for "LV 58-60+" so the names line up.
local LEVEL_W = 62
-- Space on the right of a row for the tick and "14/14 quests".
local COUNTS_W = 180
-- Art area of a grid card at the default window size (352x126 minus the 4px
-- border). List rows show a slice of the art with the same aspect ratio.
local GRID_ART_ASPECT = 344 / 118
local DEFAULT_CROP = { 0.03, 0.97, 0.05, 0.95 }
-- "Hidden" and "Coming Soon" in list rows.
local LIST_FONT = "ForeverDJ_GameFontNormalLarge"
-- DJ's right margin with and without a scrollbar (RefreshHomeDungeonCards).
local GUTTER_SCROLL, GUTTER_NONE = -31, -15
local WHITE = "Interface\\Buttons\\WHITE8X8"

-- Settings (account-wide)

local DB_NAME = "DungeonJournalEnhancedDB"

local function Get(key)
    local db = _G[DB_NAME]
    if type(db) ~= "table" then return nil end
    return db[key]
end

local function Set(key, value)
    if type(_G[DB_NAME]) ~= "table" then _G[DB_NAME] = {} end
    _G[DB_NAME][key] = value
end

local function IsListView() return Get("listView") == true end
local function SetListView(on) Set("listView", on and true or nil) end
local function GetSort() return Get("sort") == "name" and "name" or "level" end
local function SetSort(mode) Set("sort", mode == "name" and "name" or nil) end

-- Text

-- Same 10 languages as DJ (FDJ.GetLanguage returns one of these, esMX comes
-- back as esES). Wording matches DJ's own translations of "Dungeon list" and
-- "Level range".
local TEXT = {
    list = {
        enUS = "Show as list", deDE = "Als Liste anzeigen", frFR = "Afficher en liste",
        esES = "Mostrar como lista", itIT = "Mostra come elenco", ptBR = "Mostrar como lista",
        ruRU = "Показать списком", koKR = "목록으로 보기", zhCN = "以列表显示", zhTW = "以列表顯示",
    },
    grid = {
        enUS = "Show as grid", deDE = "Als Raster anzeigen", frFR = "Afficher en grille",
        esES = "Mostrar como cuadrícula", itIT = "Mostra come griglia", ptBR = "Mostrar como grade",
        ruRU = "Показать сеткой", koKR = "격자로 보기", zhCN = "以网格显示", zhTW = "以網格顯示",
    },
    sortName = {
        enUS = "Sort by name", deDE = "Nach Name sortieren", frFR = "Trier par nom",
        esES = "Ordenar por nombre", itIT = "Ordina per nome", ptBR = "Ordenar por nome",
        ruRU = "Сортировать по названию", koKR = "이름순 정렬", zhCN = "按名称排序", zhTW = "依名稱排序",
    },
    sortLevel = {
        enUS = "Sort by level", deDE = "Nach Stufe sortieren", frFR = "Trier par niveau",
        esES = "Ordenar por nivel", itIT = "Ordina per livello", ptBR = "Ordenar por nível",
        ruRU = "Сортировать по уровню", koKR = "레벨순 정렬", zhCN = "按等级排序", zhTW = "依等級排序",
    },
    -- Chat message when a DJ update broke something (shown once).
    broken = {
        enUS = "Could not arrange the dungeon list (DungeonJournal may have changed):",
        deDE = "Die Dungeonliste konnte nicht angeordnet werden (DungeonJournal hat sich vielleicht geändert):",
        frFR = "Impossible d'organiser la liste des donjons (DungeonJournal a peut-être changé) :",
        esES = "No se pudo ordenar la lista de mazmorras (puede que DungeonJournal haya cambiado):",
        itIT = "Impossibile disporre l'elenco delle spedizioni (DungeonJournal potrebbe essere cambiato):",
        ptBR = "Não foi possível organizar a lista de masmorras (o DungeonJournal pode ter mudado):",
        ruRU = "Не удалось упорядочить список подземелий (возможно, DungeonJournal изменился):",
        koKR = "던전 목록을 정렬할 수 없습니다 (DungeonJournal이 변경되었을 수 있습니다):",
        zhCN = "无法排列地下城列表（DungeonJournal 可能已更改）：",
        zhTW = "無法排列地城列表（DungeonJournal 可能已變更）：",
    },
    -- Chat message when the old DungeonJournalEnhanced folder is also
    -- installed. The folder path goes after it.
    oldCopy = {
        enUS = "An old copy of this addon is still installed, so this one is turned off. Delete this folder and reload:",
        deDE = "Eine alte Kopie dieses Addons ist noch installiert, deshalb ist diese ausgeschaltet. Lösche diesen Ordner und lade neu:",
        frFR = "Une ancienne copie de cet addon est encore installée, celle-ci est donc désactivée. Supprimez ce dossier puis rechargez :",
        esES = "Todavía hay una copia antigua de este addon instalada, así que esta está desactivada. Borra esta carpeta y recarga:",
        itIT = "È ancora installata una vecchia copia di questo addon, quindi questa è disattivata. Elimina questa cartella e ricarica:",
        ptBR = "Uma cópia antiga deste addon ainda está instalada, então esta está desligada. Apague esta pasta e recarregue:",
        ruRU = "Старая копия этого аддона всё ещё установлена, поэтому эта отключена. Удалите эту папку и перезагрузите интерфейс:",
        koKR = "이 애드온의 이전 사본이 아직 설치되어 있어 이 애드온은 꺼져 있습니다. 이 폴더를 삭제하고 UI를 다시 불러오세요:",
        zhCN = "此插件的旧版本仍然安装着，因此本插件已关闭。请删除此文件夹并重载界面：",
        zhTW = "此插件的舊版本仍然安裝著，因此本插件已關閉。請刪除此資料夾並重新載入介面：",
    },
}

-- Sort-by-name button label for non-Latin alphabets.
local ALPHABET = { ruRU = "А-Я", koKR = "가-하" }

local function Language()
    return FDJ.GetLanguage and FDJ.GetLanguage() or "enUS"
end

local function AlphabetLabel()
    return ALPHABET[Language()] or "A-Z"
end

local function Text(which)
    return TEXT[which][Language()] or TEXT[which].enUS
end

local function Print(message)
    print("|cffffd100[Dungeon Journal Enhanced]|r " .. message)
end

if OldCopyLoaded() then
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_LOGIN")
    f:SetScript("OnEvent", function()
        Print(Text("oldCopy") .. " Interface\\AddOns\\" .. OLD_FOLDER)
    end)
    return
end

-- pcall that prints the first error once per session. Most likely cause is a
-- DJ update changing something we rely on.
local warned
local function Safe(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok and not warned then
        warned = true
        Print(Text("broken") .. " " .. tostring(err))
    end
    return ok
end

-- Sorting

-- Lowercase name as shown. In English a leading "The" is skipped, so The
-- Deadmines goes under D.
local function NameKey(name)
    local shown = FDJ.LocalizeDungeonName and FDJ.LocalizeDungeonName(name) or name
    shown = tostring(shown or name):lower()
    if Language() == "enUS" then
        shown = shown:gsub("^the%s+", "")
    end
    return shown
end

-- Comparator for dungeon names: by name, or by min level then max level. Ties
-- fall back to DJ's own order (FDJ.ORDER).
local function MakeLess(names)
    local order = {}
    for i, n in ipairs(FDJ.ORDER or {}) do order[n] = i end
    local byName = GetSort() == "name"
    local keys = {}
    for _, name in ipairs(names) do
        if byName then
            keys[name] = NameKey(name)
        else
            local low, top
            if FDJ.DungeonLevelRange and FDJ.DB then low, top = FDJ.DungeonLevelRange(FDJ.DB[name]) end
            keys[name] = { low or math.huge, top or low or math.huge }
        end
    end
    return function(a, b)
        local ka, kb = keys[a], keys[b]
        if byName then
            if ka ~= kb then return ka < kb end
        else
            if ka[1] ~= kb[1] then return ka[1] < kb[1] end
            if ka[2] ~= kb[2] then return ka[2] < kb[2] end
        end
        local oa, ob = order[a] or math.huge, order[b] or math.huge
        if oa ~= ob then return oa < ob end
        return a < b
    end
end

-- Make the < > dungeon arrows step through the dungeons in our order.
local navList = FDJ.DungeonNavList
if navList then
    FDJ.DungeonNavList = function(...)
        local list = navList(...)
        if type(list) == "table" and #list > 1 then
            pcall(table.sort, list, MakeLess(list))
        end
        return list
    end
end

-- Saving and restoring DJ's layout

local function SavePoints(region)
    local points = {}
    for i = 1, region:GetNumPoints() do points[i] = { region:GetPoint(i) } end
    return points
end

local function RestorePoints(region, points)
    region:ClearAllPoints()
    for _, p in ipairs(points) do
        region:SetPoint(p[1], p[2] or region:GetParent(), p[3], p[4], p[5])
    end
end

-- Anchored on both sides means the anchors set the width.
local function RestoreWidth(fs, points, width)
    fs:SetWidth(#points > 1 and 0 or width)
end

local function SaveFont(fs)
    local font, size, flags = fs:GetFont()
    return {
        object = fs:GetFontObject(), font = font, size = size, flags = flags,
        color = { fs:GetTextColor() }, shadow = { fs:GetShadowColor() }, offset = { fs:GetShadowOffset() },
    }
end

-- SetFontObject resets the text colour, so colour and shadow go back on after.
local function RestoreFont(fs, saved, fontObject)
    if fontObject then
        fs:SetFontObject(fontObject)
    elseif saved.object then
        fs:SetFontObject(saved.object)
    elseif saved.font then
        fs:SetFont(saved.font, saved.size, saved.flags)
    end
    local c, s, o = saved.color, saved.shadow, saved.offset
    if c[1] then fs:SetTextColor(c[1], c[2], c[3], c[4]) end
    if s[1] then fs:SetShadowColor(s[1], s[2], s[3], s[4]) end
    if o[1] then fs:SetShadowOffset(o[1], o[2]) end
end

local function ListFont()
    return _G[LIST_FONT] and LIST_FONT or nil
end

-- Snapshot of a card as DJ made it, taken before we change anything.
local function Remember(card)
    local s = card.fdjListSort
    if s then return s end
    s = {
        height = card:GetHeight(),
        title = SavePoints(card.title),
        titleWidth = card.title:GetWidth(),
        titleV = card.title:GetJustifyV(),
        titleWrap = card.title:CanWordWrap(),
        meta = SavePoints(card.meta),
        metaWidth = card.meta:GetWidth(),
        counts = SavePoints(card.counts),
    }
    if card.topShade then s.shade = card.topShade:GetHeight() end
    if card.coverBorder then s.border = card.coverBorder:IsShown() end
    if card.hiddenText then s.hidden = SaveFont(card.hiddenText) end
    card.fdjListSort = s
    return s
end

-- List rows

-- Horizontal strip through the middle of the card art, sized to keep the grid
-- card's aspect ratio on a w x h row.
local function ListSlice(crop, w, h)
    local left, right, top, bottom = crop[1], crop[2], crop[3], crop[4]
    local tall = bottom - top
    local span = math.min(tall, tall * (h / math.max(1, w)) * GRID_ART_ASPECT)
    local mid = top + tall / 2
    return left, right, mid - span / 2, mid + span / 2
end

-- Switches a card between a list row and DJ's own layout. Call it after the
-- card has been sized. Returns true if the card actually switched.
local function SetCardMode(card, list)
    local s = Remember(card)
    local title, meta, counts = card.title, card.meta, card.counts
    local switched = (card.fdjListSortList or false) ~= list
    if switched then
        card.fdjListSortList = list
        if list then
            meta:ClearAllPoints()
            meta:SetPoint("LEFT", 14, 0)
            meta:SetWidth(LEVEL_W)
            title:ClearAllPoints()
            title:SetPoint("LEFT", 14 + LEVEL_W, 0)
            title:SetJustifyV("MIDDLE")
            title:SetWordWrap(false)
            counts:ClearAllPoints()
            counts:SetPoint("RIGHT", -14, 0)
        else
            card:SetHeight(s.height)
            RestorePoints(title, s.title)
            RestoreWidth(title, s.title, s.titleWidth)
            title:SetJustifyV(s.titleV)
            title:SetWordWrap(s.titleWrap)
            RestorePoints(meta, s.meta)
            RestoreWidth(meta, s.meta, s.metaWidth)
            RestorePoints(counts, s.counts)
            if card.topShade and s.shade then card.topShade:SetHeight(s.shade) end
        end
        -- Faint line across the middle of the card, would cut through the text.
        if card.coverBorder then card.coverBorder:SetShown((not list) and s.border or false) end
        if card.hiddenText and s.hidden then
            RestoreFont(card.hiddenText, s.hidden, list and ListFont() or nil)
        end
    end

    -- DJ only creates comingSoon once a preview dungeon lands on this card.
    local soon = card.comingSoon
    if soon then
        if not soon.fdjListSort then
            soon.fdjListSort = { points = SavePoints(soon), font = SaveFont(soon) }
        end
        if (soon.fdjListSortList or false) ~= list then
            soon.fdjListSortList = list
            if list then
                soon:ClearAllPoints()
                soon:SetPoint("RIGHT", -14, 0)
            else
                RestorePoints(soon, soon.fdjListSort.points)
            end
            RestoreFont(soon, soon.fdjListSort.font, list and ListFont() or nil)
        end
    end

    if list then
        -- These depend on the row width, and the window can be resized.
        local w, h = card:GetWidth() or 0, card:GetHeight() or 0
        title:SetWidth(math.max(80, w - 14 - LEVEL_W - COUNTS_W))
        -- Stretch the dark title band over the whole row.
        if card.topShade then card.topShade:SetHeight(math.max(1, h - 8)) end
        local crops = FDJ.DUNGEON_HOME_TEXCOORD
        local crop = crops and crops[card.dungeonName] or DEFAULT_CROP
        card.art:SetTexCoord(ListSlice(crop, w - 8, h - 8))
        -- DJ's HomeBottomBand covers a dark strip at the bottom of some art.
        -- Our slice never reaches it.
        if card.fdjBand then card.fdjBand:Hide() end
        if card.fdjBandFade then card.fdjBandFade:Hide() end
    end
    return switched
end

-- RPG Mode puts a quest count in the top right of its page. On a list row it
-- goes on the right edge instead. DJ's extra arg (edit mode) is kept so we can
-- call this again ourselves.
local lastExtra
local applyRPGCard = FDJ.ApplyRPGCard
if applyRPGCard then
    FDJ.ApplyRPGCard = function(card, name, extra, ...)
        lastExtra = extra
        applyRPGCard(card, name, extra, ...)
        local count = card and card.rpgPage and card.rpgPage.questCount
        if not count then return end
        if not count.fdjListSort then count.fdjListSort = SavePoints(count) end
        local list = card.fdjListSortList or false
        if (count.fdjListSortList or false) ~= list then
            count.fdjListSortList = list
            if list then
                count:ClearAllPoints()
                count:SetPoint("RIGHT", -10, 0)
            else
                RestorePoints(count, count.fdjListSort)
            end
        end
    end
end

-- RPG Mode copies the art's tex coords onto its torn page, so it has to run
-- again after we change them.
local function ReapplyRPG(card)
    if FDJ.ApplyRPGCard then pcall(FDJ.ApplyRPGCard, card, card.dungeonName, lastExtra) end
end

-- Home page

local function SetScrollGutter(scroll, needsScroll)
    for i = 1, scroll:GetNumPoints() do
        local point, rel, relPoint, x, y = scroll:GetPoint(i)
        if point == "BOTTOMRIGHT" then
            local want = needsScroll and GUTTER_SCROLL or GUTTER_NONE
            if x ~= want then scroll:SetPoint(point, rel, relPoint, want, y) end
            return
        end
    end
end

-- Same as DJ's UpdateScrollBarVisibility.
local function ShowScrollBar(scroll, shown)
    local name = scroll.GetName and scroll:GetName()
    local bar = scroll.ScrollBar or (name and _G[name .. "ScrollBar"])
    local parts = {}
    if bar then
        parts[1], parts[2], parts[3], parts[4] = bar, bar.ScrollUpButton, bar.ScrollDownButton, bar.ThumbTexture
    end
    if name then
        parts[5] = _G[name .. "ScrollBarScrollUpButton"]
        parts[6] = _G[name .. "ScrollBarScrollDownButton"]
        parts[7] = _G[name .. "ScrollBarThumbTexture"]
    end
    for i = 1, 7 do
        local part = parts[i]
        if part and part.SetShown then part:SetShown(shown) end
    end
    if not shown then scroll:SetVerticalScroll(0) end
end

local function SortCards(cards, less)
    table.sort(cards, function(a, b) return less(a.dungeonName, b.dungeonName) end)
end

-- Grid: DJ already placed the cards in its own order. Reuse those spots and
-- hand them out in our order.
local function SortGrid(content, cards, less)
    local slots = {}
    for i, card in ipairs(cards) do
        if card:GetNumPoints() ~= 1 then return end
        local point, rel, relPoint, x, y = card:GetPoint(1)
        if rel ~= content then return end
        slots[i] = { point, rel, relPoint, x or 0, y or 0 }
    end
    -- Top row first (y goes negative downwards), then left to right.
    table.sort(slots, function(a, b)
        if math.abs(a[5] - b[5]) > 0.5 then return a[5] > b[5] end
        return a[4] < b[4]
    end)
    SortCards(cards, less)
    for i, card in ipairs(cards) do
        local slot = slots[i]
        card:ClearAllPoints()
        card:SetPoint(slot[1], slot[2], slot[3], slot[4], slot[5])
    end
end

-- List: one column of rows. The list is a different height than the grid, so
-- the scrollbar margin and content size get redone too.
local function LayOutList(scroll, content, cards, less)
    SortCards(cards, less)
    local step = ROW_HEIGHT + ROW_GAP
    local height = #cards * step - ROW_GAP
    local viewport = scroll:GetHeight() or 0
    local needsScroll = viewport > 0 and height > viewport + 4
    SetScrollGutter(scroll, needsScroll)
    local width = math.max(700, (scroll:GetWidth() or 760) - 2)
    content:SetWidth(width)
    for i, card in ipairs(cards) do
        card:SetSize(width, ROW_HEIGHT)
        card:ClearAllPoints()
        card:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(i - 1) * step)
        SetCardMode(card, true)
        ReapplyRPG(card)
    end
    content:SetHeight(height)
    ShowScrollBar(scroll, needsScroll)
end

-- Runs after DJ lays out the home page. Safe to run twice in a row without a DJ
-- refresh in between (the Run Log calls UpdateRPGHeader on its own).
local function Arrange(frame)
    local content, scroll = frame and frame.homeCardsContent, frame and frame.homeScroll
    if not (content and scroll) then return end
    local cards, names = {}, {}
    for _, child in ipairs({ content:GetChildren() }) do
        if child:IsShown() and type(child.dungeonName) == "string"
            and child.title and child.meta and child.counts and child.art then
            Remember(child)
            cards[#cards + 1] = child
            names[#names + 1] = child.dungeonName
        end
    end
    if #cards == 0 then return end
    local less = MakeLess(names)
    if IsListView() then
        LayOutList(scroll, content, cards, less)
    else
        for _, card in ipairs(cards) do
            if SetCardMode(card, false) then ReapplyRPG(card) end
        end
        SortGrid(content, cards, less)
    end
end

-- Buttons

local function Square(parent, x, y, w, h)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetTexture(WHITE)
    t:SetVertexColor(1.00, 0.82, 0.27, 1)
    t:SetSize(w, h)
    t:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    return t
end

-- The buttons show what a click switches to: the list icon in grid view, "A-Z"
-- when sorted by level, "1-60" when sorted by name.
local function PaintLayout(b)
    local list = IsListView()
    b.gridIcon:SetShown(list)
    b.listIcon:SetShown(not list)
end

local function PaintSort(b)
    -- Size for the wider of the two labels so the button doesn't jump around
    -- when clicked.
    local widest = 0
    for _, text in ipairs({ "1-60", AlphabetLabel() }) do
        b.label:SetText(text)
        widest = math.max(widest, b.label:GetStringWidth() or 0)
    end
    b:SetWidth(math.max(28, math.ceil(widest + 12)))
    b.label:SetText(GetSort() == "name" and "1-60" or AlphabetLabel())
end

local function ShowTip(b)
    GameTooltip:SetOwner(b, "ANCHOR_BOTTOM")
    GameTooltip:SetText(Text(b.fdjTip()), 1, 0.82, 0)
    GameTooltip:Show()
end

local function ClickSound()
    if PlaySound and SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON then
        pcall(PlaySound, SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end
end

-- Small square button styled like DJ's other header buttons. Contents go on
-- b.glyph, which moves down a pixel while the button is held.
local function NewButton(frame, tip, onClick)
    local b = CreateFrame("Button", nil, frame.homePanel, "BackdropTemplate")
    b:SetSize(28, 28)
    b:SetBackdrop({
        bgFile = WHITE,
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    b:SetBackdropColor(0.12, 0.115, 0.105, 0.98)
    b:SetBackdropBorderColor(0.48, 0.40, 0.27, 1)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    b.glyph = CreateFrame("Frame", nil, b)
    b.glyph:SetSize(20, 12)
    b.glyph:SetPoint("CENTER")
    b.fdjTip = tip

    b:SetScript("OnMouseDown", function(self) self.glyph:SetPoint("CENTER", 1, -1) end)
    b:SetScript("OnMouseUp", function(self) self.glyph:SetPoint("CENTER", 0, 0) end)
    b:SetScript("OnEnter", ShowTip)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnClick", function(self)
        ClickSound()
        onClick(self)
        -- Back to the top, the old scroll position means nothing now.
        if frame.homeScroll then frame.homeScroll:SetVerticalScroll(0) end
        if FDJ.RefreshHomeCards then pcall(FDJ.RefreshHomeCards) end
        if GameTooltip:IsOwned(self) then ShowTip(self) end
    end)

    -- The Tier Sets page hides homeScroll while it's open. Hide with it.
    local scroll = frame.homeScroll
    if scroll and scroll.HookScript then
        scroll:HookScript("OnShow", function() b:Show() end)
        scroll:HookScript("OnHide", function(self)
            if not self:IsShown() then b:Hide() end
        end)
    end
    return b
end

-- Grid/list toggle.
local function BuildLayout(frame)
    local b = NewButton(frame,
        function() return IsListView() and "grid" or "list" end,
        function(self)
            SetListView(not IsListView())
            PaintLayout(self)
        end)

    -- 12x12 icons: four squares for grid, three bulleted lines for list.
    b.gridIcon = CreateFrame("Frame", nil, b.glyph)
    b.gridIcon:SetSize(12, 12)
    b.gridIcon:SetPoint("CENTER")
    for _, p in ipairs({ { 0, 0 }, { 7, 0 }, { 0, 7 }, { 7, 7 } }) do
        Square(b.gridIcon, p[1], p[2], 5, 5)
    end
    b.listIcon = CreateFrame("Frame", nil, b.glyph)
    b.listIcon:SetSize(12, 12)
    b.listIcon:SetPoint("CENTER")
    for _, y in ipairs({ 1, 5, 9 }) do
        Square(b.listIcon, 0, y, 2, 2)
        Square(b.listIcon, 4, y, 8, 2)
    end
    frame.fdjListSortLayoutButton = b
    return b
end

-- Level/name toggle.
local function BuildSort(frame)
    local b = NewButton(frame,
        function() return GetSort() == "name" and "sortLevel" or "sortName" end,
        function(self)
            SetSort(GetSort() == "name" and "level" or "name")
            PaintSort(self)
        end)
    b.label = b.glyph:CreateFontString(nil, "OVERLAY", "ForeverDJ_GameFontNormalSmall")
    b.label:SetPoint("CENTER", 0, 0)
    b.label:SetTextColor(1.00, 0.82, 0.27)
    frame.fdjListSortSortButton = b
    return b
end

-- Far right of the header: Hide Dungeons, sort, grid/list. Grid/list lines up
-- with the right edge of the language menu (and the cards). DJ chains its other
-- header buttons off Hide Dungeons, so they all shift left with it.
local function Place(frame)
    if not (frame and frame.homePanel) then return end
    local layout = frame.fdjListSortLayoutButton or BuildLayout(frame)
    local sort = frame.fdjListSortSortButton or BuildSort(frame)
    if not layout.fdjPlaced then
        layout.fdjPlaced = true
        layout:ClearAllPoints()
        if frame.languageSelectorButton then
            -- Same offset DJ uses for Hide Dungeons.
            layout:SetPoint("TOPRIGHT", frame.languageSelectorButton, "BOTTOMRIGHT", 0, -26)
        else
            layout:SetPoint("TOPRIGHT", frame.homePanel, "TOPRIGHT", -31, -13)
        end
        sort:ClearAllPoints()
        sort:SetPoint("RIGHT", layout, "LEFT", -8, 0)
        local hide = frame.hideDungeonsButton
        if hide then
            hide:ClearAllPoints()
            hide:SetPoint("RIGHT", sort, "LEFT", -8, 0)
        end
    end
    PaintLayout(layout)
    PaintSort(sort)
    local shown = not frame.homeScroll or frame.homeScroll:IsShown()
    layout:SetShown(shown)
    sort:SetShown(shown)
end

-- Hook

-- DJ calls this at the end of every home page refresh. RPG Mode and the Forever
-- filter hook it as well.
local updateHeader = FDJ.UpdateRPGHeader
FDJ.UpdateRPGHeader = function(frame, ...)
    local ok, err = true, nil
    if updateHeader then ok, err = pcall(updateHeader, frame, ...) end
    Safe(Arrange, frame)
    Safe(Place, frame)
    if not ok then error(err, 0) end
end
