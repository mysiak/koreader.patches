-- Based on these two patches:
-- https://github.com/oh1apps/koreader_header by @oh1apps
-- https://github.com/sebdelsol/KOReader.patches/blob/main/2-statusbar-thin-chapter.lua by @sebdelsol
-- Updated by @mysiak with Github Copilot and Claude Sonnet 4.5
-- Optimizations and code cleanup by Claude Opus 4.5

local Blitbuffer = require("ffi/blitbuffer")
local TextWidget = require("ui/widget/textwidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ProgressWidget = require("ui/widget/progresswidget")
local NetworkMgr = require("ui/network/manager")
local BD = require("ui/bidi")
local Size = require("ui/size")
local Geom = require("ui/geometry")
local Device = require("device")
local Font = require("ui/font")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("util")
local datetime = require("datetime")
local Screen = Device.screen
local _ = require("gettext")
local T = require("ffi/util").template
local ReaderView = require("apps/reader/modules/readerview")
local ReaderMenu = require("apps/reader/modules/readermenu")

-- Available header items
local HEADER_ITEMS = {
    time = { name = T(_("Current time (%1)"), "⌚"), generator = nil, is_spacer = false },
    battery = { name = T(_("Battery percentage (%1)"), ""), generator = nil, is_spacer = false },
    wifi = { name = T(_("Wi-Fi status (%1)"), ""), generator = nil, is_spacer = false },
    percentage = { name = T(_("Progress percentage (%1)"), "%"), generator = nil, is_spacer = false },
    page_progress = { name = T(_("Current page (%1)"), "/"), generator = nil, is_spacer = false },
    pages_left_book = { name = T(_("Pages left in book (%1)"), "→"), generator = nil, is_spacer = false },
    pages_left = { name = T(_("Pages left in chapter (%1)"), "⇒"), generator = nil, is_spacer = false },
    chapter_progress = { name = T(_("Current page in chapter (%1)"), "//"), generator = nil, is_spacer = false },
    book_time_to_read = { name = T(_("Time left to finish book (%1)"), "⏳"), generator = nil, is_spacer = false },
    chapter_time_to_read = { name = T(_("Time left to finish chapter (%1)"), "⤻"), generator = nil, is_spacer = false },
    title = { name = _("Book title"), generator = nil, is_spacer = false },
    author = { name = _("Book author"), generator = nil, is_spacer = false },
    chapter = { name = _("Chapter title"), generator = nil, is_spacer = false },
    frontlight = { name = T(_("Brightness level (%1)"), "☼"), generator = nil, is_spacer = false },
    frontlight_warmth = { name = T(_("Warmth level (%1)"), "⊛"), generator = nil, is_spacer = false },
    mem_usage = { name = T(_("KOReader memory usage (%1)"), ""), generator = nil, is_spacer = false },
    bookmark_count = { name = T(_("Bookmark count (%1)"), "\u{F097}"), generator = nil, is_spacer = false },
    custom_text = { name = _("Custom text"), generator = nil, is_spacer = false, is_dynamic = true },
    spacer = { name = _("Dynamic filler"), generator = nil, is_spacer = true },
}

-- Menu order
local ITEMS_ORDER = {
    "time", "battery", "wifi", "percentage", "page_progress", "chapter_progress",
    "pages_left_book", "pages_left",
    "book_time_to_read", "chapter_time_to_read",
    "title", "author", "chapter",
    "frontlight", "frontlight_warmth", "mem_usage", "bookmark_count",
    "custom_text", "spacer"
}

-- Separator styles
local SEPARATOR_STYLES = {
    "  ",
    " • ",
    " - ",
    " ○ ",
    " : ",
    "custom",
}

-- Default header items
local header_defaults = {
    enabled = true,
    items = {"time", "battery", "spacer", "percentage"},
    separator_style = 1,
    item_separator = "  ",
    show_progress_bar = true,
    progress_bar_height = 3,
    progress_bar_mode = "book", -- "book" or "chapter"
    chapter_markers = "none", -- "none", "main", or "all"
    font_size = 14,
    font_bold = false,
    custom_texts = {},
    disabled_custom_texts = {},
    custom_separator = " - ",
    header_top_margin = 2,
    header_side_margin = 10,
    header_bottom_margin = 2,
    follow_book_margins = false,
    hide_icons = {},
    wifi_on_only = false,
    title_max_width = 100,
    header_opacity = 100,
    background_opacity = 70,
    background_enabled = false,
    auto_background_for_pdf = true,
}

local function getHeaderSettings()
    local settings = G_reader_settings:readSetting("custom_header")
    if not settings then
        settings = util.tableDeepCopy(header_defaults)
        G_reader_settings:saveSetting("custom_header", settings)
    end
    if not settings.items then settings.items = {"time", "battery", "spacer", "percentage"} end
    if not settings.separator_style then settings.separator_style = 1 end
    if settings.custom_separator == nil then settings.custom_separator = " - " end
    -- Set item_separator based on style (use custom if style is "custom")
    if SEPARATOR_STYLES[settings.separator_style] == "custom" then
        settings.item_separator = settings.custom_separator
    else
        settings.item_separator = SEPARATOR_STYLES[settings.separator_style]
    end
    if settings.enabled == nil then settings.enabled = true end
    if settings.show_progress_bar == nil then settings.show_progress_bar = true end
    if settings.progress_bar_height == nil then settings.progress_bar_height = 3 end
    if settings.progress_bar_mode == nil then settings.progress_bar_mode = "book" end
    if settings.show_chapter_markers == nil then settings.show_chapter_markers = false end
    if settings.font_size == nil then settings.font_size = 14 end
    if settings.font_bold == nil then settings.font_bold = false end
    if settings.custom_texts == nil then settings.custom_texts = {} end
    if settings.disabled_custom_texts == nil then settings.disabled_custom_texts = {} end
    if settings.hide_icons == nil then settings.hide_icons = {} end
    if settings.wifi_on_only == nil then settings.wifi_on_only = false end
    if settings.title_max_width == nil then settings.title_max_width = 100 end
    if settings.header_opacity == nil then settings.header_opacity = 100 end
    if settings.background_opacity == nil then settings.background_opacity = 70 end
    if settings.background_enabled == nil then settings.background_enabled = false end
    if settings.auto_background_for_pdf == nil then settings.auto_background_for_pdf = true end
    
    -- Clean up unsupported settings - keep only valid keys
    local valid_keys = {
        enabled = true,
        items = true,
        separator_style = true,
        item_separator = true,
        show_progress_bar = true,
        progress_bar_height = true,
        progress_bar_mode = true,
        chapter_markers = true,
        font_size = true,
        font_bold = true,
        custom_texts = true,
        disabled_custom_texts = true,
        custom_separator = true,
        header_top_margin = true,
        header_side_margin = true,
        header_bottom_margin = true,
        follow_book_margins = true,
        hide_icons = true,
        wifi_on_only = true,
        title_max_width = true,
        header_opacity = true,
        background_opacity = true,
        background_enabled = true,
        auto_background_for_pdf = true,
        _background_manually_set = true,  -- Internal tracking state
    }
    
    local cleaned = false
    for key in pairs(settings) do
        if not valid_keys[key] then
            settings[key] = nil
            cleaned = true
        end
    end
    
    -- Save settings if we cleaned anything
    if cleaned then
        G_reader_settings:saveSetting("custom_header", settings)
    end
    
    return settings
end

local function saveHeaderSettings(settings)
    G_reader_settings:saveSetting("custom_header", settings)
end

local function isHeaderEnabled()
    return getHeaderSettings().enabled
end

local function hasItem(items_list, item_key)
    for _, key in ipairs(items_list) do
        if key == item_key then return true end
    end
    return false
end

local function toggleItem(items_list, item_key)
    for i, key in ipairs(items_list) do
        if key == item_key then
            table.remove(items_list, i)
            return
        end
    end
    table.insert(items_list, item_key)
end

local function setSeparatorStyle(style_index)
    local h_settings = getHeaderSettings()
    h_settings.separator_style = style_index
    saveHeaderSettings(h_settings)
end

-- Generator functions (defined at module level to avoid recreation on each render)
local function generate_time(self, h_settings)
    local time_string = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")) or ""
    if time_string:match("^%d:") then
        time_string = "0" .. time_string
    end
    if h_settings.hide_icons["time"] then
        return time_string
    else
        return "⌚ " .. time_string
    end
end

local function generate_battery(self, h_settings)
    local battery = ""
    if Device:hasBattery() then
        local power_dev = Device:getPowerDevice()
        local batt_lvl = power_dev:getCapacity() or 0
        local is_charging = power_dev:isCharging() or false
        if h_settings.hide_icons["battery"] then
            battery = batt_lvl .. "%"
        else
            local batt_prefix = power_dev:getBatterySymbol(power_dev:isCharged(), is_charging, batt_lvl) or ""
            battery = batt_prefix .. batt_lvl .. "%"
        end
    end
    return battery
end

local function generate_wifi(self, h_settings)
    if NetworkMgr:isWifiOn() then
        return ""  -- WiFi on icon
    elseif h_settings.wifi_on_only then
        return ""  -- Don't show anything when wifi is off
    else
        return ""  -- WiFi off icon
    end
end

local function generate_percentage(self, h_settings)
    local pageno = self.state.page or 1
    local pages = (self.ui.doc_settings and self.ui.doc_settings.data and self.ui.doc_settings.data.doc_pages) or 1
    local percentage = (pageno / pages) * 100
    if h_settings.hide_icons["percentage"] then
        return string.format("%.0f", percentage) .. "%"
    else
        return "(" .. string.format("%.0f", percentage) .. "%)"
    end
end

local function generate_page_progress(self, h_settings)
    local pageno = self.state.page or 1
    local pages = (self.ui.doc_settings and self.ui.doc_settings.data and self.ui.doc_settings.data.doc_pages) or 1
    return ("%d / %d"):format(pageno, pages)
end

local function generate_pages_left_book(self, h_settings)
    local pageno = self.state.page or 1
    local pages = (self.ui.doc_settings and self.ui.doc_settings.data and self.ui.doc_settings.data.doc_pages) or 1
    local remaining = pages - pageno
    if h_settings.hide_icons["pages_left_book"] then
        return ("%d / %d"):format(remaining, pages)
    else
        return ("→ %d / %d"):format(remaining, pages)
    end
end

local function generate_pages_left(self, h_settings)
    local pageno = self.state.page or 1
    if self.ui.toc then
        local left = self.ui.toc:getChapterPagesLeft(pageno) or 0
        if h_settings.hide_icons["pages_left"] then
            return ("%d"):format(left)
        else
            return ("⇒ %d"):format(left)
        end
    end
    return ""
end

local function generate_chapter_progress(self, h_settings)
    local pageno = self.state.page or 1
    if self.ui.toc then
        local pages_done = self.ui.toc:getChapterPagesDone(pageno) or 0
        pages_done = pages_done + 1
        local pages_chapter = self.ui.toc:getChapterPageCount(pageno) or 0
        if pages_chapter > 0 then
            if h_settings.hide_icons["chapter_progress"] then
                return ("%d / %d"):format(pages_done, pages_chapter)
            else
                return ("%d // %d"):format(pages_done, pages_chapter)
            end
        end
    end
    return ""
end

local function generate_book_time_to_read(self, h_settings)
    if self.ui.document and self.ui.statistics and type(self.ui.document.getTotalPagesLeft) == "function" and type(self.ui.statistics.getTimeForPages) == "function" then
        local pageno = self.state.page or 1
        local ok, left = pcall(function() return self.ui.document:getTotalPagesLeft(pageno) end)
        if ok and left and type(left) == "number" then
            local ok2, time_str = pcall(function() return self.ui.statistics:getTimeForPages(left) end)
            if ok2 and time_str then
                if h_settings.hide_icons["book_time_to_read"] then
                    return time_str
                else
                    return "⏳ " .. time_str
                end
            end
        end
    end
    return ""
end

local function generate_chapter_time_to_read(self, h_settings)
    if self.ui.statistics and type(self.ui.statistics.getTimeForPages) == "function" then
        local pageno = self.state.page or 1
        local left = nil
        
        -- Try to get chapter pages left
        if self.ui.toc and type(self.ui.toc.getChapterPagesLeft) == "function" then
            local ok, result = pcall(function() return self.ui.toc:getChapterPagesLeft(pageno) end)
            if ok and result then
                left = result
            end
        end
        
        -- Fallback to total pages left
        if not left and self.ui.document and type(self.ui.document.getTotalPagesLeft) == "function" then
            local ok, result = pcall(function() return self.ui.document:getTotalPagesLeft(pageno) end)
            if ok and result then
                left = result
            end
        end
        
        if left and type(left) == "number" then
            local ok, time_str = pcall(function() return self.ui.statistics:getTimeForPages(left) end)
            if ok and time_str then
                if h_settings.hide_icons["chapter_time_to_read"] then
                    return time_str
                else
                    return "⤻ " .. time_str
                end
            end
        end
    end
    return ""
end

local function generate_title(self, h_settings)
    if self.ui.doc_props then
        local title = self.ui.doc_props.display_title or ""
        return title
    end
    return ""
end

local function generate_author(self, h_settings)
    if self.ui.doc_props then
        local author = self.ui.doc_props.authors or ""
        if author:find("\n") then
            author = T(_("%%1 et al."), util.splitToArray(author, "\n")[1])
        end
        return author
    end
    return ""
end

local function generate_chapter(self, h_settings)
    local pageno = self.state.page or 1
    if self.ui.toc then
        return self.ui.toc:getTocTitleByPage(pageno) or ""
    end
    return ""
end

local function generate_frontlight(self, h_settings)
    if Device:hasFrontlight() then
        local powerd = Device:getPowerDevice()
        if powerd:isFrontlightOn() then
            local level = powerd:frontlightIntensity()
            local level_str
            if Device:isCervantes() or Device:isKobo() then
                level_str = ("%d%%"):format(level)
            else
                level_str = ("%d"):format(level)
            end
            if h_settings.hide_icons["frontlight"] then
                return level_str
            else
                return "☼" .. level_str
            end
        else
            if h_settings.hide_icons["frontlight"] then
                return _("Off")
            else
                return "☼" .. _("Off")
            end
        end
    end
    return ""
end

local function generate_frontlight_warmth(self, h_settings)
    if Device:hasNaturalLight() then
        local powerd = Device:getPowerDevice()
        if powerd:isFrontlightOn() then
            local warmth = powerd:frontlightWarmth()
            if warmth then
                local warmth_str = ("%d%%"):format(warmth)
                if h_settings.hide_icons["frontlight_warmth"] then
                    return warmth_str
                else
                    return "⊛" .. warmth_str
                end
            end
        else
            if h_settings.hide_icons["frontlight_warmth"] then
                return _("Off")
            else
                return "⊛" .. _("Off")
            end
        end
    end
    return ""
end

local function generate_mem_usage(self, h_settings)
    -- Cache memory usage to avoid file I/O on every render (update every 15 seconds for e-readers)
    local current_time = os.time()
    self._header_cache = self._header_cache or {}
    local mem_cache_time = self._header_cache.mem_time or 0
    if current_time - mem_cache_time >= 15 then
        local statm = io.open("/proc/self/statm", "r")
        if statm then
            local dummy, rss = statm:read("*number", "*number")
            statm:close()
            rss = math.floor(rss * (4096 / 1024 / 1024))
            self._header_cache.mem_value = "" .. ("%d MiB"):format(rss)
        else
            self._header_cache.mem_value = ""
        end
        self._header_cache.mem_time = current_time
    end
    return self._header_cache.mem_value or ""
end

local function generate_bookmark_count(self, h_settings)
    if self.ui.annotation then
        local count = self.ui.annotation:getNumberOfAnnotations()
        if h_settings.hide_icons["bookmark_count"] then
            return ("%d"):format(count)
        else
            return "\u{F097}" .. ("%d"):format(count)
        end
    end
    return ""
end

-- Generator lookup table
local GENERATORS = {
    time = generate_time,
    battery = generate_battery,
    wifi = generate_wifi,
    percentage = generate_percentage,
    page_progress = generate_page_progress,
    pages_left_book = generate_pages_left_book,
    pages_left = generate_pages_left,
    chapter_progress = generate_chapter_progress,
    book_time_to_read = generate_book_time_to_read,
    chapter_time_to_read = generate_chapter_time_to_read,
    title = generate_title,
    author = generate_author,
    chapter = generate_chapter,
    frontlight = generate_frontlight,
    frontlight_warmth = generate_frontlight_warmth,
    mem_usage = generate_mem_usage,
    bookmark_count = generate_bookmark_count,
}

local _ReaderView_paintTo_orig = ReaderView.paintTo
local header_settings = G_reader_settings:readSetting("footer")

-- Touch zones
local function setupHeaderTouchZone(reader_ui)
    if not Device:isTouchDevice() then return end
    
    local header_height = Size.item.height_default -- touch zone height
    local header_zone = {
        ratio_x = 0, 
        ratio_y = 0,
        ratio_w = 1, 
        ratio_h = header_height / Screen:getHeight(),
    }
    
    reader_ui:registerTouchZones({
        {
            id = "reader_header_tap",
            ges = "tap",
            screen_zone = header_zone,
            handler = function(ges)
                local h_settings = getHeaderSettings()
                
                -- Mark that background has been manually set
                h_settings._background_manually_set = true
                
                -- Check if background option is available:
                -- 1. Manually enabled in settings, OR
                -- 2. Auto-enabled for this PDF
                local background_available = h_settings.background_enabled
                if not background_available and h_settings.auto_background_for_pdf and reader_ui.document then
                    local doc_info = reader_ui.document.info
                    if doc_info and doc_info.has_pages then
                        background_available = true
                    end
                end
                
                -- Cycle modes
                if not h_settings.enabled then
                    -- Currently off -> turn on without background
                    h_settings.enabled = true
                    h_settings.background_enabled = false
                elseif background_available and h_settings.background_enabled then
                    -- Currently on with background -> turn off
                    h_settings.enabled = false
                    h_settings.background_enabled = false
                elseif background_available and not h_settings.background_enabled then
                    -- Currently on without background -> enable background
                    h_settings.background_enabled = true
                else
                    -- Background not available, just toggle on/off
                    h_settings.enabled = false
                end
                
                saveHeaderSettings(h_settings)
                UIManager:setDirty(reader_ui.dialog, "ui")
                return true
            end,
            overrides = {
                "readerconfigmenu_ext_tap",
                "readerconfigmenu_tap",
            },
        },
    })
end

-- Main function
ReaderView.paintTo = function(self, bb, x, y)
    _ReaderView_paintTo_orig(self, bb, x, y)
    -- Removed render_mode check to enable header on all document types (PDFs, CBZs, etc.) like footer
    if not isHeaderEnabled() then return end -- Exit if disabled
    
    -- Cache settings - fetch once per render
    local h_settings = getHeaderSettings()
    
    -- Get screen width dynamically to handle rotation
    local screen_width = Screen:getWidth()
    
    -- ===========================!!!!!!!!!!!!!!!=========================== -
    -- Configure formatting options for header here, if desired (defaults to footer options)
    local header_font_face = "ffont"
    local header_font_size = h_settings.font_size
    local header_font_bold = h_settings.font_bold
    local header_font_color = Blitbuffer.COLOR_BLACK
    local header_top_padding = h_settings.header_top_margin or 2
    local header_use_book_margins = h_settings.follow_book_margins or false
    local header_margin = h_settings.header_side_margin or 10
    local left_max_width_pct = 48
    local right_max_width_pct = 48
    -- Progress bar settings from header settings
    local show_progress_bar = h_settings.show_progress_bar
    local progress_bar_height = h_settings.progress_bar_height
    local progress_bar_margin = h_settings.header_bottom_margin or 2
    local chapter_markers = h_settings.chapter_markers or "none"
    local toc_markers_width = header_settings and header_settings.toc_markers_width or 2
    -- ===========================!!!!!!!!!!!!!!!=========================== -

    -- Build set of generators actually needed (only for enabled items)
    local needed_generators = {}
    for _, item_key in ipairs(h_settings.items) do
        local item_base_key = item_key:match("^([^_]+_[^_]+)") or item_key
        if GENERATORS[item_key] then
            needed_generators[item_key] = true
        elseif GENERATORS[item_base_key] then
            needed_generators[item_base_key] = true
        end
    end
    
    -- Also check custom texts for variable references (only enabled ones)
    if h_settings.custom_texts then
        for idx, text in ipairs(h_settings.custom_texts) do
            -- Skip disabled custom texts
            if text and not h_settings.disabled_custom_texts[idx] then
                for var_name in text:gmatch("{([^}]+)}") do
                    if GENERATORS[var_name] then
                        needed_generators[var_name] = true
                    end
                end
            end
        end
    end
    
    -- Cache only needed generator results (with error isolation)
    local generator_cache = {}
    for key in pairs(needed_generators) do
        local generator = GENERATORS[key]
        if generator then
            local ok, result = pcall(generator, self, h_settings)
            generator_cache[key] = ok and (result or "") or ""
        end
    end

    -- Variable substitution for custom text
    local function substituteVariables(text)
        if not text or text == "" then return "" end
        
        -- Replace {variable} with actual values from cache
        local result = text:gsub("{([^}]+)}", function(var_name)
            return generator_cache[var_name] or "{" .. var_name .. "}"
        end)
        
        return result
    end

    -- Spacer and dynamic custom text handling
    local custom_text_counter = 0
    local function buildHeaderWidgets()
        local groups = {}
        local current_group = {}
        local current_group_has_title = false
        
        for _, item_key in ipairs(h_settings.items) do
            local item_base_key = item_key:match("^([^_]+_[^_]+)") or item_key
            local item = HEADER_ITEMS[item_base_key] or HEADER_ITEMS[item_key]
            if item then
                if item.is_spacer then
                   
                    if #current_group > 0 then
                        table.insert(groups, {text = current_group, has_title = current_group_has_title})
                        current_group = {}
                        current_group_has_title = false
                    end
                    table.insert(groups, "spacer")
                elseif item_key:match("^custom_text") then
                    -- Handle dynamic custom text items with variable substitution
                    custom_text_counter = custom_text_counter + 1
                    -- Check if this custom text is disabled
                    if not h_settings.disabled_custom_texts[custom_text_counter] then
                        local text = h_settings.custom_texts[custom_text_counter] or ""
                        if text and text ~= "" then
                            -- Check if custom text contains title or author variables
                            if text:match("{title}") or text:match("{author}") then
                                current_group_has_title = true
                            end
                            text = substituteVariables(text)
                            if text ~= "" then
                                table.insert(current_group, text)
                            end
                        end
                    end
                elseif GENERATORS[item_key] or GENERATORS[item_base_key] then
                    -- Use cached generator result
                    local text = generator_cache[item_key] or generator_cache[item_base_key] or ""
                    if text and text ~= "" then
                        table.insert(current_group, text)
                        if item_key == "title" then
                            current_group_has_title = true
                        end
                    end
                end
            end
        end

        if #current_group > 0 then
            table.insert(groups, {text = current_group, has_title = current_group_has_title})
        end
        
        local text_groups = {}
        for _, group in ipairs(groups) do
            if type(group) == "table" and group.text then
                table.insert(text_groups, {
                    text = table.concat(group.text, h_settings.item_separator),
                    has_title = group.has_title
                })
            else
                table.insert(text_groups, group)
            end
        end
        
        return text_groups
    end
    
    local text_groups = buildHeaderWidgets()

    -- Calculate margins
    local margins = 0
    local left_margin = header_margin
    local right_margin = header_margin
    if header_use_book_margins and self.document.getPageMargins then
        local page_margins = self.document:getPageMargins()
        left_margin = page_margins.left or header_margin
        right_margin = page_margins.right or header_margin
    end
    margins = left_margin + right_margin
    local avail_width = screen_width - margins

    -- Cache font face to avoid repeated Font:getFace calls
    local header_font = Font:getFace(header_font_face, header_font_size)
    
    -- Helper function to create fitted text widget directly (avoids double widget creation)
    local function createFittedTextWidget(text, max_width_pct)
        if text == nil or text == "" then
            return nil
        end
        -- First get the fitted text
        local temp_widget = TextWidget:new{
            text = text:gsub(" ", "\u{00A0}"),
            max_width = math.floor(avail_width * max_width_pct / 100),
            face = header_font,
            bold = header_font_bold,
            padding = 0,
        }
        local fitted_text, add_ellipsis = temp_widget:getFittedText()
        temp_widget:free()
        if add_ellipsis then
            -- Remove trailing spaces (including non-breaking spaces) before adding ellipsis
            fitted_text = fitted_text:gsub("[\u{0020}\u{00A0}]+$", "")
            fitted_text = fitted_text .. "…"
        end
        -- Return final widget with proper styling
        return TextWidget:new{
            text = BD.auto(fitted_text),
            face = header_font,
            bold = header_font_bold,
            fgcolor = header_font_color,
            padding = 0,
        }
    end

    -- Build header widgets from text groups
    local header_widgets = {}
    local total_text_width = 0
    local spacer_count = 0
    
    for _, group in ipairs(text_groups) do
        if group == "spacer" then
            spacer_count = spacer_count + 1
            table.insert(header_widgets, "spacer")
        else
            -- For title items, use title_max_width with 5% reduction for separators/spacing
            local max_width_pct = 48
            if type(group) == "table" and group.has_title then
                local user_pct = h_settings.title_max_width or 100
                max_width_pct = math.max(10, user_pct - 5)
            end
            local text_to_fit = type(group) == "table" and group.text or group
            local text_widget = createFittedTextWidget(text_to_fit, max_width_pct)
            if text_widget then
                total_text_width = total_text_width + text_widget:getSize().w
                table.insert(header_widgets, text_widget)
            end
        end
    end
    
    -- Calculate spacer width
    local spacer_width = 0
    if spacer_count > 0 then
        spacer_width = math.max(0, (avail_width - total_text_width) / spacer_count)
    end
    
    -- Build horizontal group with spacers
    local horizontal_items = {}
    for _, widget in ipairs(header_widgets) do
        if widget == "spacer" then
            table.insert(horizontal_items, HorizontalSpan:new { width = spacer_width })
        else
            table.insert(horizontal_items, widget)
        end
    end
    
    -- If no spacers, align everything to the left (add spacer at the end)
    if spacer_count == 0 then
        local remaining_space = avail_width - total_text_width
        if remaining_space > 0 then
            table.insert(horizontal_items, HorizontalSpan:new { width = remaining_space })
        end
    end
    
    -- Calculate header height
    local max_height = 0
    for _, widget in ipairs(header_widgets) do
        if widget ~= "spacer" then
            max_height = math.max(max_height, widget:getSize().h)
        end
    end

    -- Get progress percentage - use footer's values if available for accurate progress
    local progress_percentage = 0
    local pageno = 1
    local pages = 1
    local progress_bar_mode = h_settings.progress_bar_mode or "book"
    
    -- Try to get values from footer first (most accurate)
    if self.ui.view and self.ui.view.footer then
        local footer = self.ui.view.footer
        if footer.pageno and type(footer.pageno) == "number" then
            pageno = footer.pageno
        end
        if footer.pages and type(footer.pages) == "number" and footer.pages > 0 then
            pages = footer.pages
        end
        if footer.percent_finished and type(footer.percent_finished) == "number" then
            progress_percentage = footer.percent_finished
        else
            progress_percentage = pageno / pages
        end
    else
        -- Fallback to state values
        pageno = self.state.page or 1
        pages = (self.ui.doc_settings and self.ui.doc_settings.data and self.ui.doc_settings.data.doc_pages) or 1
        progress_percentage = pageno / pages
    end
    
    -- Calculate chapter progress if in chapter mode
    if progress_bar_mode == "chapter" and self.ui.toc then
        local chapter_pages_done = self.ui.toc:getChapterPagesDone(pageno)
        local chapter_page_count = self.ui.toc:getChapterPageCount(pageno)
        if chapter_pages_done and chapter_page_count and chapter_page_count > 0 then
            progress_percentage = (chapter_pages_done + 1) / chapter_page_count
        end
    end

    -- Create progress bar with proper width accounting for margins
    local progress_bar_width = screen_width - left_margin - right_margin
    local progress_bar = nil
    if show_progress_bar then
        progress_bar = ProgressWidget:new{
            width = progress_bar_width,
            height = progress_bar_height,
            percentage = progress_percentage,
            tick_width = Screen:scaleBySize(toc_markers_width),
            ticks = nil,
            last = nil, -- will be set with ticks if needed
        }
        
        -- Apply thin style like footer does
        progress_bar:updateStyle(false, progress_bar_height)
        progress_bar.thin_ticks = (chapter_markers ~= "none") -- enable thin ticks if chapter markers enabled
        
        -- Add TOC markers (chapter markers) if enabled and in book mode
        if progress_bar_mode == "book" and chapter_markers ~= "none" and self.ui.document and self.ui.document.getToc then
            -- Get TOC for cache validation (check entry count to detect structure changes)
            local ok, toc = pcall(function() return self.ui.document:getToc() end)
            local toc_count = (ok and toc and type(toc) == "table") and #toc or 0
            
            -- Cache TOC markers (generated once and reused until settings or TOC structure changes)
            self._header_cache = self._header_cache or {}
            if not self._header_cache.toc or 
               self._header_cache.toc.chapter_markers ~= chapter_markers or 
               self._header_cache.toc.pages ~= pages or
               self._header_cache.toc.toc_count ~= toc_count then
                if ok and toc and type(toc) == "table" and #toc > 0 then
                    local ticks = {}
                    
                    for i, item in ipairs(toc) do
                        -- For "main" mode, only include depth 1 (main chapters)
                        -- For "all" mode, include all chapters
                        if chapter_markers == "all" or (chapter_markers == "main" and item.depth == 1) then
                            if item.page and type(item.page) == "number" and item.page > 0 and item.page <= pages then
                                table.insert(ticks, item.page)
                            end
                        end
                    end
                    
                    self._header_cache.toc = {
                        ticks = ticks,
                        chapter_markers = chapter_markers,
                        pages = pages,
                        toc_count = toc_count,
                    }
                else
                    self._header_cache.toc = {
                        ticks = {},
                        chapter_markers = chapter_markers,
                        pages = pages,
                        toc_count = toc_count,
                    }
                end
            end
            
            -- Use cached ticks
            if self._header_cache.toc and #self._header_cache.toc.ticks > 0 then
                progress_bar.ticks = self._header_cache.toc.ticks
                progress_bar.last = pages
            end
        end
        
        progress_bar:setPercentage(progress_percentage)
    end

    -- Build vertical group with header items and progress bar
    local vertical_items = {
        VerticalSpan:new { width = header_top_padding },
        HorizontalGroup:new(horizontal_items),
    }

    -- Add progress bar below items if enabled
    if show_progress_bar and progress_bar then
        table.insert(vertical_items, VerticalSpan:new { width = progress_bar_margin })
        table.insert(vertical_items, HorizontalGroup:new{
            HorizontalSpan:new { width = left_margin },
            progress_bar,
            HorizontalSpan:new { width = right_margin },
        })
    end

    -- Calculate total header height
    local total_height = max_height + header_top_padding
    if show_progress_bar then
        total_height = total_height + progress_bar_margin + progress_bar_height
    end
    
    -- Check if background should be drawn
    local background_enabled = h_settings.background_enabled
    
    -- Auto-enable for PDFs (doesn't change the setting, just renders with background)
    if not background_enabled and h_settings.auto_background_for_pdf and self.ui.document then
        local doc_info = self.ui.document.info
        if doc_info and doc_info.has_pages then
            -- Only apply auto-enable if user hasn't manually cycled yet
            if h_settings._background_manually_set ~= true then
                background_enabled = true
            end
        end
    end
    
    -- Draw semi-transparent background if enabled
    if background_enabled then
        local bg_intensity = (h_settings.background_opacity or 70) / 100.0
        -- Lighten the area behind the header (blend white over background)
        bb:lightenRect(x, y, screen_width, total_height, bg_intensity)
    end

    -- Build header widget
    local header = CenterContainer:new {
        dimen = Geom:new{ 
            w = screen_width, 
            h = total_height
        },
        VerticalGroup:new(vertical_items),
    }
    
    -- Apply opacity/transparency
    local opacity = h_settings.header_opacity or 100
    if opacity < 100 then
        -- Create a compose buffer for alpha blending
        local compose_bb = Blitbuffer.new(screen_width, total_height, bb:getType())
        
        -- Copy the underlying background region first for true transparency
        compose_bb:blitFrom(bb, 0, 0, x, y, screen_width, total_height)
        
        -- Paint header on top of the background copy
        header:paintTo(compose_bb, 0, 0)
        
        -- Blend the composed result back to the target buffer
        -- Alpha range: 0.0 = fully transparent (shows original), 1.0 = fully opaque (shows header)
        local alpha = opacity / 100.0
        bb:addblitFrom(compose_bb, x, y, 0, 0, screen_width, total_height, alpha)
        
        -- Free the temporary buffer
        compose_bb:free()
    else
        -- Paint directly at 100% opacity
        header:paintTo(bb, x, y)
    end
end

-- Menu
local ReaderUI = require("apps/reader/readerui")
local orig_ReaderUI_init = ReaderUI.init

function ReaderUI:init()
    orig_ReaderUI_init(self)
    setupHeaderTouchZone(self)
    
    -- Auto-enable header for PDFs/CBZ if auto_background_for_pdf is on
    local h_settings = getHeaderSettings()
    if h_settings.auto_background_for_pdf and self.document then
        local doc_info = self.document.info
        if doc_info and doc_info.has_pages then
            -- Only auto-enable if user hasn't manually set it yet
            if h_settings._background_manually_set ~= true then
                h_settings.enabled = true
                saveHeaderSettings(h_settings)
            end
        end
    end
end

-- Hook into ReaderView to handle frontlight state changes for header refresh
local orig_ReaderView_onFrontlightStateChanged = ReaderView.onFrontlightStateChanged
ReaderView.onFrontlightStateChanged = function(self, ...)
    if orig_ReaderView_onFrontlightStateChanged then
        orig_ReaderView_onFrontlightStateChanged(self, ...)
    end
    -- Refresh header when frontlight changes
    if isHeaderEnabled() and self.ui and self.ui.dialog then
        UIManager:setDirty(self.ui.dialog, "ui")
    end
end

-- Hook into ReaderView to handle screen dimension changes (rotation)
local orig_ReaderView_onSetDimensions = ReaderView.onSetDimensions
ReaderView.onSetDimensions = function(self, dimen, ...)
    if orig_ReaderView_onSetDimensions then
        orig_ReaderView_onSetDimensions(self, dimen, ...)
    end
    -- Force header refresh on screen rotation/resize
    if isHeaderEnabled() and self.ui and self.ui.dialog then
        UIManager:setDirty(self.ui.dialog, "ui")
    end
end

-- Hook into ReaderView to clear header caches when document is closed
local orig_ReaderView_onCloseDocument = ReaderView.onCloseDocument
ReaderView.onCloseDocument = function(self, ...)
    -- Clear header caches before document closes
    self._header_cache = nil
    -- Reset manual background flag so auto-enable can work on next document
    local h_settings = getHeaderSettings()
    h_settings._background_manually_set = false
    saveHeaderSettings(h_settings)
    if orig_ReaderView_onCloseDocument then
        return orig_ReaderView_onCloseDocument(self, ...)
    end
end

local orig_ReaderMenu_setUpdateItemTable = ReaderMenu.setUpdateItemTable

function ReaderMenu:setUpdateItemTable()
    local menu_order = require("ui/elements/reader_menu_order")
    local SortWidget = require("ui/widget/sortwidget")
    
    -- Helper function to create multi-select item list
    local function createItemsSelector()
        return {
            text_func = function()
                local h_settings = getHeaderSettings()
                local count = #h_settings.items
                return T(_("Header items (%1)"), count)
            end,
            sub_item_table = (function()
                local items = {}
                for i, key in ipairs(ITEMS_ORDER) do
                    local item = HEADER_ITEMS[key]
                    if key == "custom_text" then
                        -- Special handling for custom text - allow multiple instances like spacer
                        table.insert(items, {
                            text_func = function()
                                local h_settings = getHeaderSettings()
                                local count = 0
                                for _, k in ipairs(h_settings.items) do
                                    if k:match("^custom_text") then count = count + 1 end
                                end
                                return T(_("Custom text (%1)"), count)
                            end,
                            sub_item_table = {
                                {
                                    text = _("Available variables"),
                                    callback = function()
                                        local InfoMessage = require("ui/widget/infomessage")
                                        local variable_list = [[
You can use these variables in custom text by wrapping them in curly braces:

{time} - Current time
{battery} - Battery percentage
{wifi} - Wi-Fi status
{percentage} - Reading progress %
{page_progress} - Current/total pages
{pages_left_book} - Pages left in book
{pages_left} - Pages left in chapter
{chapter_progress} - Current page in chapter
{book_time_to_read} - Time to finish book
{chapter_time_to_read} - Time to finish chapter
{title} - Book title
{author} - Book author
{chapter} - Chapter title
{frontlight} - Brightness level
{frontlight_warmth} - Warmth level
{mem_usage} - Memory usage
{bookmark_count} - Bookmark count

Examples:
  By {author}
  📖 {title}
  {author} - {percentage}]]
                                        UIManager:show(InfoMessage:new{
                                            text = variable_list,
                                            width = math.floor(Screen:getWidth() * 0.9),
                                            height = math.floor(Screen:getHeight() * 0.8),
                                            scroll = true,
                                        })
                                    end,
                                    keep_menu_open = true,
                                },
                                {
                                    text = _("Add custom text"),
                                    callback = function(touchmenu_instance)
                                        local h_settings = getHeaderSettings()
                                        local InputDialog = require("ui/widget/inputdialog")
                                        local input_dialog
                                        input_dialog = InputDialog:new{
                                            title = _("Enter custom text"),
                                            input = "",
                                            buttons = {
                                                {
                                                    {
                                                        text = _("Cancel"),
                                                        id = "close",
                                                        callback = function()
                                                            UIManager:close(input_dialog)
                                                        end,
                                                    },
                                                    {
                                                        text = _("Add"),
                                                        is_enter_default = true,
                                                        callback = function()
                                                            local text = input_dialog:getInputText()
                                                            if text and text ~= "" then
                                                                table.insert(h_settings.custom_texts, text)
                                                                local new_key = "custom_text_" .. #h_settings.custom_texts
                                                                table.insert(h_settings.items, new_key)
                                                                saveHeaderSettings(h_settings)
                                                            end
                                                            UIManager:close(input_dialog)
                                                            touchmenu_instance:updateItems()
                                                            if self.ui and self.ui.document then
                                                                UIManager:setDirty(self.ui.dialog, "ui")
                                                            end
                                                        end,
                                                    },
                                                },
                                            },
                                        }
                                        UIManager:show(input_dialog)
                                        input_dialog:onShowKeyboard()
                                    end,
                                    keep_menu_open = true,
                                },
                                {
                                    text = _("Edit custom texts"),
                                    enabled_func = function()
                                        local h_settings = getHeaderSettings()
                                        return #h_settings.custom_texts > 0
                                    end,
                                    sub_item_table_func = function()
                                        local h_settings = getHeaderSettings()
                                        local edit_items = {}
                                        for idx, text in ipairs(h_settings.custom_texts) do
                                            table.insert(edit_items, {
                                                text_func = function()
                                                    local current_settings = getHeaderSettings()
                                                    local current_text = current_settings.custom_texts[idx] or ""
                                                    local status = current_settings.disabled_custom_texts[idx] and " [✗]" or ""
                                                    return T(_("Text %1: '%2'%3"), idx, current_text, status)
                                                end,
                                                sub_item_table = {
                                                    {
                                                        text = _("Enable/disable"),
                                                        checked_func = function()
                                                            local current_settings = getHeaderSettings()
                                                            return not current_settings.disabled_custom_texts[idx]
                                                        end,
                                                        callback = function(touchmenu_instance)
                                                            local toggle_settings = getHeaderSettings()
                                                            toggle_settings.disabled_custom_texts[idx] = not toggle_settings.disabled_custom_texts[idx]
                                                            saveHeaderSettings(toggle_settings)
                                                            touchmenu_instance:updateItems()
                                                            if self.ui and self.ui.document then
                                                                UIManager:setDirty(self.ui.dialog, "ui")
                                                            end
                                                        end,
                                                    },
                                                    {
                                                        text = _("Edit text"),
                                                        callback = function(touchmenu_instance)
                                                            local current_settings = getHeaderSettings()
                                                    local InputDialog = require("ui/widget/inputdialog")
                                                    local input_dialog
                                                    input_dialog = InputDialog:new{
                                                        title = T(_("Edit custom text %1"), idx),
                                                        input = current_settings.custom_texts[idx],
                                                        buttons = {
                                                            {
                                                                {
                                                                    text = _("Cancel"),
                                                                    id = "close",
                                                                    callback = function()
                                                                        UIManager:close(input_dialog)
                                                                    end,
                                                                },
                                                                {
                                                                    text = _("Save"),
                                                                    is_enter_default = true,
                                                                    callback = function()
                                                                        local save_settings = getHeaderSettings()
                                                                        save_settings.custom_texts[idx] = input_dialog:getInputText()
                                                                        saveHeaderSettings(save_settings)
                                                                        UIManager:close(input_dialog)
                                                                        touchmenu_instance:updateItems()
                                                                        if self.ui and self.ui.document then
                                                                            UIManager:setDirty(self.ui.dialog, "ui")
                                                                        end
                                                                    end,
                                                                },
                                                            },
                                                        },
                                                    }
                                                    UIManager:show(input_dialog)
                                                    input_dialog:onShowKeyboard()
                                                end,
                                                keep_menu_open = true,
                                            },
                                        },
                                    })
                                        end
                                        return edit_items
                                    end,
                                },
                                {
                                    text = _("Remove last custom text"),
                                    enabled_func = function()
                                        local h_settings = getHeaderSettings()
                                        for _, k in ipairs(h_settings.items) do
                                            if k:match("^custom_text") then return true end
                                        end
                                        return false
                                    end,
                                    callback = function(touchmenu_instance)
                                        local h_settings = getHeaderSettings()
                                        -- Remove last occurrence of custom_text from items
                                        for i = #h_settings.items, 1, -1 do
                                            if h_settings.items[i]:match("^custom_text") then
                                                table.remove(h_settings.items, i)
                                                break
                                            end
                                        end
                                        -- Remove last text from custom_texts
                                        if #h_settings.custom_texts > 0 then
                                            table.remove(h_settings.custom_texts)
                                        end
                                        saveHeaderSettings(h_settings)
                                        touchmenu_instance:updateItems()
                                        if self.ui and self.ui.document then
                                            UIManager:setDirty(self.ui.dialog, "ui")
                                        end
                                    end,
                                    keep_menu_open = true,
                                },
                                {
                                    text = _("Remove all custom texts"),
                                    enabled_func = function()
                                        local h_settings = getHeaderSettings()
                                        for _, k in ipairs(h_settings.items) do
                                            if k:match("^custom_text") then return true end
                                        end
                                        return false
                                    end,
                                    callback = function(touchmenu_instance)
                                        local h_settings = getHeaderSettings()
                                        -- Remove all custom_text items
                                        local new_items = {}
                                        for _, k in ipairs(h_settings.items) do
                                            if not k:match("^custom_text") then
                                                table.insert(new_items, k)
                                            end
                                        end
                                        h_settings.items = new_items
                                        h_settings.custom_texts = {}
                                        saveHeaderSettings(h_settings)
                                        touchmenu_instance:updateItems()
                                        if self.ui and self.ui.document then
                                            UIManager:setDirty(self.ui.dialog, "ui")
                                        end
                                    end,
                                    keep_menu_open = true,
                                },
                            },
                        })
                    elseif key == "spacer" then
                        -- Special handling for spacer - allow multiple instances
                        table.insert(items, {
                            text_func = function()
                                local h_settings = getHeaderSettings()
                                local count = 0
                                for _, k in ipairs(h_settings.items) do
                                    if k == "spacer" then count = count + 1 end
                                end
                                return T(_("Dynamic filler (%1)"), count)
                            end,
                            sub_item_table = {
                                {
                                    text = _("Add filler"),
                                    callback = function(touchmenu_instance)
                                        local h_settings = getHeaderSettings()
                                        table.insert(h_settings.items, "spacer")
                                        saveHeaderSettings(h_settings)
                                        touchmenu_instance:updateItems()
                                        if self.ui and self.ui.document then
                                            UIManager:setDirty(self.ui.dialog, "ui")
                                        end
                                    end,
                                    keep_menu_open = true,
                                },
                                {
                                    text = _("Remove last filler"),
                                    enabled_func = function()
                                        local h_settings = getHeaderSettings()
                                        return hasItem(h_settings.items, "spacer")
                                    end,
                                    callback = function(touchmenu_instance)
                                        local h_settings = getHeaderSettings()
                                        -- Remove last occurrence of spacer
                                        for i = #h_settings.items, 1, -1 do
                                            if h_settings.items[i] == "spacer" then
                                                table.remove(h_settings.items, i)
                                                break
                                            end
                                        end
                                        saveHeaderSettings(h_settings)
                                        touchmenu_instance:updateItems()
                                        if self.ui and self.ui.document then
                                            UIManager:setDirty(self.ui.dialog, "ui")
                                        end
                                    end,
                                    keep_menu_open = true,
                                },
                                {
                                    text = _("Remove all fillers"),
                                    enabled_func = function()
                                        local h_settings = getHeaderSettings()
                                        return hasItem(h_settings.items, "spacer")
                                    end,
                                    callback = function(touchmenu_instance)
                                        local h_settings = getHeaderSettings()
                                        -- Remove all spacers
                                        local new_items = {}
                                        for _, k in ipairs(h_settings.items) do
                                            if k ~= "spacer" then
                                                table.insert(new_items, k)
                                            end
                                        end
                                        h_settings.items = new_items
                                        saveHeaderSettings(h_settings)
                                        touchmenu_instance:updateItems()
                                        if self.ui and self.ui.document then
                                            UIManager:setDirty(self.ui.dialog, "ui")
                                        end
                                    end,
                                },
                            },
                        })  
                    else
                        -- Check if item has icon/bracket that can be toggled
                        local has_toggle = (key == "time" or key == "battery" or 
                                           key == "percentage" or key == "pages_left_book" or 
                                           key == "pages_left" or key == "chapter_progress" or 
                                           key == "book_time_to_read" or key == "chapter_time_to_read" or 
                                           key == "frontlight" or key == "frontlight_warmth" or 
                                           key == "mem_usage" or key == "bookmark_count" or key == "title")
                        
                        if has_toggle then
                            -- Item with icon/bracket - add submenu
                            local toggle_text
                            if key == "percentage" then
                                toggle_text = _("Hide brackets")
                            elseif key == "title" then
                                toggle_text = nil  -- Title doesn't have an icon to hide
                            else
                                toggle_text = _("Hide icon")
                            end
                            
                            local sub_items = {
                                {
                                    text = _("Enable/disable item"),
                                    checked_func = function()
                                        local h_settings = getHeaderSettings()
                                        return hasItem(h_settings.items, key)
                                    end,
                                    callback = function(touchmenu_instance)
                                        local h_settings = getHeaderSettings()
                                        toggleItem(h_settings.items, key)
                                        saveHeaderSettings(h_settings)
                                        touchmenu_instance:updateItems()
                                        if self.ui and self.ui.document then
                                            UIManager:setDirty(self.ui.dialog, "ui")
                                        end
                                    end,
                                },
                            }
                            
                            -- Add icon/bracket toggle if applicable
                            if toggle_text then
                                table.insert(sub_items, {
                                    text = toggle_text,
                                    checked_func = function()
                                        local h_settings = getHeaderSettings()
                                        return h_settings.hide_icons[key] == true
                                    end,
                                    callback = function(touchmenu_instance)
                                        local h_settings = getHeaderSettings()
                                        h_settings.hide_icons[key] = not h_settings.hide_icons[key]
                                        saveHeaderSettings(h_settings)
                                        touchmenu_instance:updateItems()
                                        if self.ui and self.ui.document then
                                            UIManager:setDirty(self.ui.dialog, "ui")
                                        end
                                    end,
                                    separator = true,
                                })
                            end
                            
                            -- Add title-specific options
                            if key == "title" then
                                table.insert(sub_items, {
                                    text_func = function()
                                        local h_settings = getHeaderSettings()
                                        return T(_("Max width: %1%"), h_settings.title_max_width or 100)
                                    end,
                                    callback = function(touchmenu_instance)
                                        local h_settings = getHeaderSettings()
                                        local SpinWidget = require("ui/widget/spinwidget")
                                        local spin_widget = SpinWidget:new{
                                            value = h_settings.title_max_width or 100,
                                            value_min = 10,
                                            value_max = 100,
                                            value_step = 1,
                                            value_hold_step = 5,
                                            title_text = _("Maximum title width (% of original)"),
                                            ok_text = _("Set width"),
                                            callback = function(spin)
                                                h_settings.title_max_width = spin.value
                                                saveHeaderSettings(h_settings)
                                                touchmenu_instance:updateItems()
                                                if self.ui and self.ui.document then
                                                    UIManager:setDirty(self.ui.dialog, "ui")
                                                end
                                            end,
                                        }
                                        UIManager:show(spin_widget)
                                    end,
                                    keep_menu_open = true,
                                })
                            end
                            
                            table.insert(items, {
                                text = item.name,
                                checked_func = function()
                                    local h_settings = getHeaderSettings()
                                    return hasItem(h_settings.items, key)
                                end,
                                sub_item_table = sub_items,
                            })
                        elseif key == "wifi" then
                            -- WiFi has special submenu with only wifi_on_only option
                            table.insert(items, {
                                text = item.name,
                                checked_func = function()
                                    local h_settings = getHeaderSettings()
                                    return hasItem(h_settings.items, key)
                                end,
                                sub_item_table = {
                                    {
                                        text = _("Enable/disable item"),
                                        checked_func = function()
                                            local h_settings = getHeaderSettings()
                                            return hasItem(h_settings.items, key)
                                        end,
                                        callback = function(touchmenu_instance)
                                            local h_settings = getHeaderSettings()
                                            toggleItem(h_settings.items, key)
                                            saveHeaderSettings(h_settings)
                                            touchmenu_instance:updateItems()
                                            if self.ui and self.ui.document then
                                                UIManager:setDirty(self.ui.dialog, "ui")
                                            end
                                        end,
                                    },
                                    {
                                        text = _("Show icon only when on"),
                                        checked_func = function()
                                            local h_settings = getHeaderSettings()
                                            return h_settings.wifi_on_only == true
                                        end,
                                        callback = function(touchmenu_instance)
                                            local h_settings = getHeaderSettings()
                                            h_settings.wifi_on_only = not h_settings.wifi_on_only
                                            saveHeaderSettings(h_settings)
                                            touchmenu_instance:updateItems()
                                            if self.ui and self.ui.document then
                                                UIManager:setDirty(self.ui.dialog, "ui")
                                            end
                                        end,
                                        separator = true,
                                    },
                                },
                            })
                        else
                            -- Regular item without icon
                            table.insert(items, {
                                text = item.name,
                                checked_func = function()
                                    local h_settings = getHeaderSettings()
                                    return hasItem(h_settings.items, key)
                                end,
                                callback = function(touchmenu_instance)
                                    local h_settings = getHeaderSettings()
                                    toggleItem(h_settings.items, key)
                                    saveHeaderSettings(h_settings)
                                    touchmenu_instance:updateItems()
                                    if self.ui and self.ui.document then
                                        UIManager:setDirty(self.ui.dialog, "ui")
                                    end
                                end,
                            })
                        end
                    end
                end
                return items
            end)(),
        }
    end
    
    -- Helper function to create reorder using SortWidget
    local function createReorderMenu()
        return {
            text = _("Arrange items"),
            keep_menu_open = true,
            enabled_func = function()
                local h_settings = getHeaderSettings()
                return #h_settings.items > 1
            end,
            callback = function()
                local h_settings = getHeaderSettings()
                local item_table = {}
                
                for i, key in ipairs(h_settings.items) do
                    local item = HEADER_ITEMS[key]
                    local display_text = ""
                    
                    if key:match("^custom_text_(%d+)") then
                        -- Handle dynamic custom text items
                        local idx = tonumber(key:match("^custom_text_(%d+)"))
                        local text = h_settings.custom_texts[idx] or ""
                        display_text = T(_("Custom text: '%1'"), text)
                    elseif item then
                        display_text = item.name
                    end
                    
                    if display_text ~= "" then
                        table.insert(item_table, {
                            text = display_text,
                            label = key,
                        })
                    end
                end
                
                UIManager:show(SortWidget:new{
                    title = _("Arrange header items"),
                    item_table = item_table,
                    callback = function()
                        local new_items = {}
                        for i, item in ipairs(item_table) do
                            table.insert(new_items, item.label)
                        end
                        h_settings.items = new_items
                        saveHeaderSettings(h_settings)
                        if self.ui and self.ui.document then
                            UIManager:setDirty(self.ui.dialog, "ui")
                        end
                    end,
                })
            end,
        }
    end

    -- Helper function to create separator style selector
    local function createSeparatorStyleSelector()
        return {
            text = _("Separator style"),
            sub_item_table = (function()
                local items = {}
                for i, style in ipairs(SEPARATOR_STYLES) do
                    local style_ref = style
                    table.insert(items, {
                        text_func = function()
                            local style_name = style_ref
                            if style_ref == "  " then 
                                style_name = "Double space"
                            elseif style_ref == "custom" then 
                                local current_settings = getHeaderSettings()
                                style_name = T(_("Custom: '%1'"), current_settings.custom_separator)
                            end
                            return style_name
                        end,
                        checked_func = function()
                            local h_settings = getHeaderSettings()
                            return h_settings.separator_style == i
                        end,
                        callback = function(touchmenu_instance)
                            setSeparatorStyle(i)
                            touchmenu_instance:updateItems()
                            if self.ui and self.ui.document then
                                UIManager:setDirty(self.ui.dialog, "ui")
                            end
                        end,
                    })
                end
                -- Add custom separator editor
                table.insert(items, {
                    text_func = function()
                        local h_settings = getHeaderSettings()
                        return T(_("Edit custom separator: '%1'"), h_settings.custom_separator)
                    end,
                    separator = true,
                    callback = function(touchmenu_instance)
                        local current_settings = getHeaderSettings()
                        local InputDialog = require("ui/widget/inputdialog")
                        local input_dialog
                        input_dialog = InputDialog:new{
                            title = _("Enter custom separator"),
                            input = current_settings.custom_separator,
                            buttons = {
                                {
                                    {
                                        text = _("Cancel"),
                                        id = "close",
                                        callback = function()
                                            UIManager:close(input_dialog)
                                        end,
                                    },
                                    {
                                        text = _("Set separator"),
                                        is_enter_default = true,
                                        callback = function()
                                            local save_settings = getHeaderSettings()
                                            save_settings.custom_separator = input_dialog:getInputText()
                                            saveHeaderSettings(save_settings)
                                            UIManager:close(input_dialog)
                                            touchmenu_instance:updateItems()
                                            if self.ui and self.ui.document then
                                                UIManager:setDirty(self.ui.dialog, "ui")
                                            end
                                        end,
                                    },
                                },
                            },
                        }
                        UIManager:show(input_dialog)
                        input_dialog:onShowKeyboard()
                    end,
                    keep_menu_open = true,
                })
                return items
            end)(),
        }
    end
    
    -- Main Header submenu
    table.insert(menu_order.setting, "----------------------------")
    table.insert(menu_order.setting, "header_toggle")
    table.insert(menu_order.setting, "header_settings")
    
    self.menu_items.header_toggle = {
        text = _("Show header"),
        checked_func = isHeaderEnabled,
        callback = function(touchmenu_instance)
            local h_settings = getHeaderSettings()
            h_settings.enabled = not h_settings.enabled
            saveHeaderSettings(h_settings)
            touchmenu_instance:updateItems()
            if self.ui and self.ui.document then
                UIManager:setDirty(self.ui.dialog, "ui")
            end
        end,
    }
    
    self.menu_items.header_settings = {
        text = _("Header"),
        sub_item_table = {
            createItemsSelector(),
            createReorderMenu(),
            createSeparatorStyleSelector(),
            {
                text = _("Font settings"),
                separator = true,
                sub_item_table = {
                    {
                        text_func = function()
                            local h_settings = getHeaderSettings()
                            return T(_("Font size: %1"), h_settings.font_size)
                        end,
                        callback = function(touchmenu_instance)
                            local h_settings = getHeaderSettings()
                            local SpinWidget = require("ui/widget/spinwidget")
                            local spin_widget = SpinWidget:new{
                                value = h_settings.font_size,
                                value_min = 8,
                                value_max = 36,
                                value_step = 1,
                                value_hold_step = 2,
                                title_text = _("Header font size"),
                                ok_text = _("Set size"),
                                callback = function(spin)
                                    h_settings.font_size = spin.value
                                    saveHeaderSettings(h_settings)
                                    touchmenu_instance:updateItems()
                                    if self.ui and self.ui.document then
                                        UIManager:setDirty(self.ui.dialog, "ui")
                                    end
                                end,
                            }
                            UIManager:show(spin_widget)
                        end,
                        keep_menu_open = true,
                    },
                    {
                        text = _("Bold font"),
                        checked_func = function()
                            local h_settings = getHeaderSettings()
                            return h_settings.font_bold
                        end,
                        callback = function(touchmenu_instance)
                            local h_settings = getHeaderSettings()
                            h_settings.font_bold = not h_settings.font_bold
                            saveHeaderSettings(h_settings)
                            touchmenu_instance:updateItems()
                            if self.ui and self.ui.document then
                                UIManager:setDirty(self.ui.dialog, "ui")
                            end
                        end,
                    },
                },
            },
            {
                text = _("Status bar opacity"),
                callback = function(touchmenu_instance)
                    local h_settings = getHeaderSettings()
                    local SpinWidget = require("ui/widget/spinwidget")
                    local spin_widget = SpinWidget:new{
                        value = h_settings.header_opacity or 100,
                        value_min = 0,
                        value_max = 100,
                        value_step = 5,
                        value_hold_step = 10,
                        title_text = _("Status bar opacity"),
                        info_text = _("Adjust transparency of the status bar content (100% = fully opaque, 0% = fully transparent)"),
                        ok_text = _("Set opacity"),
                        callback = function(spin)
                            h_settings.header_opacity = spin.value
                            saveHeaderSettings(h_settings)
                            touchmenu_instance:updateItems()
                            if self.ui and self.ui.document then
                                UIManager:setDirty(self.ui.dialog, "ui")
                            end
                        end,
                    }
                    UIManager:show(spin_widget)
                end,
                keep_menu_open = true,
            },
            {
                text = _("Status bar background opacity"),
                sub_item_table = {
                    {
                        text = _("Enable for all books"),
                        checked_func = function()
                            local h_settings = getHeaderSettings()
                            return h_settings.background_enabled
                        end,
                        callback = function(touchmenu_instance)
                            local h_settings = getHeaderSettings()
                            h_settings.background_enabled = not h_settings.background_enabled
                            saveHeaderSettings(h_settings)
                            touchmenu_instance:updateItems()
                            if self.ui and self.ui.document then
                                UIManager:setDirty(self.ui.dialog, "ui")
                            end
                        end,
                    },
                    {
                        text = _("Enable for non-reflowable books"),
                        checked_func = function()
                            local h_settings = getHeaderSettings()
                            return h_settings.auto_background_for_pdf
                        end,
                        callback = function(touchmenu_instance)
                            local h_settings = getHeaderSettings()
                            h_settings.auto_background_for_pdf = not h_settings.auto_background_for_pdf
                            saveHeaderSettings(h_settings)
                            touchmenu_instance:updateItems()
                            if self.ui and self.ui.document then
                                UIManager:setDirty(self.ui.dialog, "ui")
                            end
                        end,
                    },
                    {
                        text_func = function()
                            local h_settings = getHeaderSettings()
                            return T(_("Background opacity: %1%"), h_settings.background_opacity or 70)
                        end,
                        callback = function(touchmenu_instance)
                            local h_settings = getHeaderSettings()
                            local SpinWidget = require("ui/widget/spinwidget")
                            local spin_widget = SpinWidget:new{
                                value = h_settings.background_opacity or 70,
                                value_min = 0,
                                value_max = 100,
                                value_step = 5,
                                value_hold_step = 10,
                                title_text = _("Background opacity"),
                                info_text = _("Opacity of the background behind status bar (100% = fully opaque, 0% = fully transparent)"),
                                ok_text = _("Set opacity"),
                                callback = function(spin)
                                    h_settings.background_opacity = spin.value
                                    saveHeaderSettings(h_settings)
                                    touchmenu_instance:updateItems()
                                    if self.ui and self.ui.document then
                                        UIManager:setDirty(self.ui.dialog, "ui")
                                    end
                                end,
                            }
                            UIManager:show(spin_widget)
                        end,
                        keep_menu_open = true,
                    },
                },
                separator = true,
            },
            {
                text = _("Margins"),
                separator = true,
                sub_item_table = {
                    {
                        text_func = function()
                            local h_settings = getHeaderSettings()
                            return T(_("Top margin: %1"), h_settings.header_top_margin or 2)
                        end,
                        callback = function(touchmenu_instance)
                            local h_settings = getHeaderSettings()
                            local SpinWidget = require("ui/widget/spinwidget")
                            local spin_widget = SpinWidget:new{
                                value = h_settings.header_top_margin or 2,
                                value_min = 0,
                                value_max = 20,
                                value_step = 1,
                                value_hold_step = 2,
                                title_text = _("Header top margin"),
                                ok_text = _("Set margin"),
                                callback = function(spin)
                                    h_settings.header_top_margin = spin.value
                                    saveHeaderSettings(h_settings)
                                    touchmenu_instance:updateItems()
                                    if self.ui and self.ui.document then
                                        UIManager:setDirty(self.ui.dialog, "ui")
                                    end
                                end,
                            }
                            UIManager:show(spin_widget)
                        end,
                        keep_menu_open = true,
                    },
                    {
                        text = _("Follow book margins"),
                        checked_func = function()
                            local h_settings = getHeaderSettings()
                            return h_settings.follow_book_margins
                        end,
                        callback = function(touchmenu_instance)
                            local h_settings = getHeaderSettings()
                            h_settings.follow_book_margins = not h_settings.follow_book_margins
                            saveHeaderSettings(h_settings)
                            touchmenu_instance:updateItems()
                            if self.ui and self.ui.document then
                                UIManager:setDirty(self.ui.dialog, "ui")
                            end
                        end,
                    },
                    {
                        text_func = function()
                            local h_settings = getHeaderSettings()
                            return T(_("Side margins: %1"), h_settings.header_side_margin or 10)
                        end,
                        enabled_func = function()
                            local h_settings = getHeaderSettings()
                            return not h_settings.follow_book_margins
                        end,
                        callback = function(touchmenu_instance)
                            local h_settings = getHeaderSettings()
                            local SpinWidget = require("ui/widget/spinwidget")
                            local spin_widget = SpinWidget:new{
                                value = h_settings.header_side_margin or 10,
                                value_min = 0,
                                value_max = 50,
                                value_step = 1,
                                value_hold_step = 5,
                                title_text = _("Header side margins (left & right)"),
                                ok_text = _("Set margins"),
                                callback = function(spin)
                                    h_settings.header_side_margin = spin.value
                                    saveHeaderSettings(h_settings)
                                    touchmenu_instance:updateItems()
                                    if self.ui and self.ui.document then
                                        UIManager:setDirty(self.ui.dialog, "ui")
                                    end
                                end,
                            }
                            UIManager:show(spin_widget)
                        end,
                        keep_menu_open = true,
                    },
                    {
                        text_func = function()
                            local h_settings = getHeaderSettings()
                            return T(_("Progress bar top margin: %1"), h_settings.header_bottom_margin or 2)
                        end,
                        callback = function(touchmenu_instance)
                            local h_settings = getHeaderSettings()
                            local SpinWidget = require("ui/widget/spinwidget")
                            local spin_widget = SpinWidget:new{
                                value = h_settings.header_bottom_margin or 2,
                                value_min = 0,
                                value_max = 20,
                                value_step = 1,
                                value_hold_step = 2,
                                title_text = _("Margin between items and progress bar"),
                                ok_text = _("Set margin"),
                                callback = function(spin)
                                    h_settings.header_bottom_margin = spin.value
                                    saveHeaderSettings(h_settings)
                                    touchmenu_instance:updateItems()
                                    if self.ui and self.ui.document then
                                        UIManager:setDirty(self.ui.dialog, "ui")
                                    end
                                end,
                            }
                            UIManager:show(spin_widget)
                        end,
                        keep_menu_open = true,
                    },
                },
            },
            {
                text = _("Progress bar"),
                separator = true,
                sub_item_table = {
                    {
                        text = _("Show progress bar"),
                        checked_func = function()
                            local h_settings = getHeaderSettings()
                            return h_settings.show_progress_bar
                        end,
                        callback = function(touchmenu_instance)
                            local h_settings = getHeaderSettings()
                            h_settings.show_progress_bar = not h_settings.show_progress_bar
                            saveHeaderSettings(h_settings)
                            touchmenu_instance:updateItems()
                            if self.ui and self.ui.document then
                                UIManager:setDirty(self.ui.dialog, "ui")
                            end
                        end,
                    },
                    {
                        text_func = function()
                            local h_settings = getHeaderSettings()
                            return T(_("Bar height: %1"), h_settings.progress_bar_height)
                        end,
                        enabled_func = function()
                            local h_settings = getHeaderSettings()
                            return h_settings.show_progress_bar
                        end,
                        callback = function(touchmenu_instance)
                            local h_settings = getHeaderSettings()
                            local SpinWidget = require("ui/widget/spinwidget")
                            local spin_widget = SpinWidget:new{
                                value = h_settings.progress_bar_height,
                                value_min = 1,
                                value_max = 20,
                                value_step = 1,
                                value_hold_step = 2,
                                title_text = _("Progress bar height"),
                                ok_text = _("Set height"),
                                callback = function(spin)
                                    h_settings.progress_bar_height = spin.value
                                    saveHeaderSettings(h_settings)
                                    touchmenu_instance:updateItems()
                                    if self.ui and self.ui.document then
                                        UIManager:setDirty(self.ui.dialog, "ui")
                                    end
                                end,
                            }
                            UIManager:show(spin_widget)
                        end,
                        keep_menu_open = true,
                    },
                    {
                        text = _("Progress bar mode"),
                        enabled_func = function()
                            local h_settings = getHeaderSettings()
                            return h_settings.show_progress_bar
                        end,
                        sub_item_table = {
                            {
                                text = _("Whole book"),
                                checked_func = function()
                                    local h_settings = getHeaderSettings()
                                    return (h_settings.progress_bar_mode or "book") == "book"
                                end,
                                callback = function(touchmenu_instance)
                                    local h_settings = getHeaderSettings()
                                    h_settings.progress_bar_mode = "book"
                                    saveHeaderSettings(h_settings)
                                    touchmenu_instance:updateItems()
                                    if self.ui and self.ui.document then
                                        UIManager:setDirty(self.ui.dialog, "ui")
                                    end
                                end,
                            },
                            {
                                text = _("Current chapter"),
                                checked_func = function()
                                    local h_settings = getHeaderSettings()
                                    return h_settings.progress_bar_mode == "chapter"
                                end,
                                callback = function(touchmenu_instance)
                                    local h_settings = getHeaderSettings()
                                    h_settings.progress_bar_mode = "chapter"
                                    saveHeaderSettings(h_settings)
                                    touchmenu_instance:updateItems()
                                    if self.ui and self.ui.document then
                                        UIManager:setDirty(self.ui.dialog, "ui")
                                    end
                                end,
                            },
                        },
                    },
                    {
                        text = _("Chapter markers"),
                        enabled_func = function()
                            local h_settings = getHeaderSettings()
                            local mode = h_settings.progress_bar_mode or "book"
                            return h_settings.show_progress_bar and mode == "book"
                        end,
                        sub_item_table = {
                            {
                                text = _("None"),
                                checked_func = function()
                                    local h_settings = getHeaderSettings()
                                    return h_settings.chapter_markers == "none"
                                end,
                                callback = function(touchmenu_instance)
                                    local h_settings = getHeaderSettings()
                                    h_settings.chapter_markers = "none"
                                    saveHeaderSettings(h_settings)
                                    touchmenu_instance:updateItems()
                                    if self.ui and self.ui.document then
                                        UIManager:setDirty(self.ui.dialog, "ui")
                                    end
                                end,
                            },
                            {
                                text = _("Main chapters only"),
                                checked_func = function()
                                    local h_settings = getHeaderSettings()
                                    return h_settings.chapter_markers == "main"
                                end,
                                callback = function(touchmenu_instance)
                                    local h_settings = getHeaderSettings()
                                    h_settings.chapter_markers = "main"
                                    saveHeaderSettings(h_settings)
                                    touchmenu_instance:updateItems()
                                    if self.ui and self.ui.document then
                                        UIManager:setDirty(self.ui.dialog, "ui")
                                    end
                                end,
                            },
                            {
                                text = _("All chapters"),
                                checked_func = function()
                                    local h_settings = getHeaderSettings()
                                    return h_settings.chapter_markers == "all"
                                end,
                                callback = function(touchmenu_instance)
                                    local h_settings = getHeaderSettings()
                                    h_settings.chapter_markers = "all"
                                    saveHeaderSettings(h_settings)
                                    touchmenu_instance:updateItems()
                                    if self.ui and self.ui.document then
                                        UIManager:setDirty(self.ui.dialog, "ui")
                                    end
                                end,
                            },
                        },
                    },
                },
            },
        },
    }
    
    orig_ReaderMenu_setUpdateItemTable(self)
end
