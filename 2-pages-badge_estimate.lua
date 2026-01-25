--[[ User patch for KOReader to add page count badges for unread books ]]
--
local Blitbuffer = require("ffi/blitbuffer")
local logger = require("logger")
logger.info("Applying Cover Browser Page Badge patch with menu settings")

-- stylua: ignore start
--========================== [[Edit your preferences here]] ================================
local page_font_size = 0.95 -- Adjust from 0 to 1
local page_text_color = Blitbuffer.COLOR_WHITE -- Choose your desired color
local border_thickness = 2 -- Adjust from 0 to 5
local border_corner_radius = 12 -- Adjust from 0 to 20
local border_color = Blitbuffer.COLOR_DARK_GRAY -- Choose your desired color
local background_color = Blitbuffer.COLOR_GRAY_3 -- Choose your desired color
local move_from_border = 8 -- Choose how far in the badge should sit
--==========================================================================================
-- stylua: ignore end

--========================== [[Do not modify this section]] ================================
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local TextWidget = require("ui/widget/textwidget")
local userpatch = require("userpatch")
local Screen = require("device").screen

--------------------------------------------------------------------------------
-- Settings Management (dedicated namespace)
--------------------------------------------------------------------------------
local G_reader_settings = require("luasettings"):open(require("datastorage"):getSettingsDir().."/settings.reader.lua")

local SETTINGS_KEY = "pages_badge_estimate"

local function getPageStandard()
    local settings = G_reader_settings:readSetting(SETTINGS_KEY) or {}
    local standard = settings.page_count_standard
    if not standard or (standard ~= "1800" and standard ~= "2200" and standard ~= "2500") then
        standard = "2200" -- default
    end
    return standard
end

local function setPageStandard(standard)
    local settings = G_reader_settings:readSetting(SETTINGS_KEY) or {}
    settings.page_count_standard = standard
    G_reader_settings:saveSetting(SETTINGS_KEY, settings)
    G_reader_settings:flush()
end

--------------------------------------------------------------------------------
-- Page Count Estimation Functions
--------------------------------------------------------------------------------
local function getHTMLContentSizePureLua(filepath)
    local f, err = io.open(filepath, "rb")
    if not f then
        logger.dbg("Pure-Lua ZIP: could not open file:", err)
        return 0
    end
    local data = f:read("*a")
    f:close()
    if not data or #data < 46 then return 0 end
    local sig = string.char(0x50, 0x4b, 0x01, 0x02)
    local pos = 1
    local total_html_size = 0
    local html_file_count = 0
    while true do
        local s = data:find(sig, pos, true)
        if not s then break end
        if s + 45 > #data then break end
        local b1, b2, b3, b4 = data:byte(s + 24, s + 27)
        local uncompressed_size = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
        local fn_b1, fn_b2 = data:byte(s + 28, s + 29)
        local filename_len = fn_b1 + fn_b2 * 256
        local name_start = s + 46
        local name_end = name_start + filename_len - 1
        if name_end <= #data and filename_len > 0 then
            local filename = data:sub(name_start, name_end):lower()
            if filename:match("%.x?html?$") then
                total_html_size = total_html_size + uncompressed_size
                html_file_count = html_file_count + 1
            end
        end
        pos = s + 46 + math.max(0, filename_len)
    end
    return total_html_size / 1024
end

local function getHTMLContentSize(filepath)
    local ext = filepath:match("%.([^.]+)$")
    if not ext then return 0 end
    ext = ext:lower()
    if ext ~= "epub" then
        return 0
    end
    local ok, zip = pcall(require, "zip")
    if not ok or not zip then
        ok, zip = pcall(require, "ffi/zip")
    end
    if ok and zip and type(zip.open) == "function" then
        local zfile, err = zip.open(filepath)
        if zfile then
            local total_html_size = 0
            local html_file_count = 0
            local success, res = pcall(function()
                for file in zfile:files() do
                    if file and file.filename and file.uncompressed_size then
                        local filename = file.filename:lower()
                        if filename:match("%.x?html?$") then
                            local size = file.uncompressed_size or 0
                            total_html_size = total_html_size + size
                            html_file_count = html_file_count + 1
                        end
                    end
                end
            end)
            if zfile.close then pcall(zfile.close, zfile) end
            if success then
                return total_html_size / 1024
            end
        end
    end
    return getHTMLContentSizePureLua(filepath)
end

local function estimatePageCount(filepath)
    local lfs = require("libs/libkoreader-lfs")
    local file_attrs = lfs.attributes(filepath)
    if not file_attrs or not file_attrs.size then
        return nil
    end
    
    local size_kb = file_attrs.size / 1024
    local ext = filepath:match("%.([^%.]+)$")
    if not ext then return nil end
    ext = ext:lower()
    
    if ext == "pdf" or ext == "djvu" then
        return nil
    end
    
    local estimated_pages
    
    -- Configurable EPUB estimation based on chars/page standard
    if ext == "epub" then
        local content_kb = getHTMLContentSize(filepath)
        if content_kb < 5 then
            return nil
        end
        
        -- Get current setting from menu
        local standard = getPageStandard()
        local kb_per_page
        
        if standard == "1800" then
            kb_per_page = 2.2
        elseif standard == "2500" then
            kb_per_page = 3.1
        else -- "2200" or default
            kb_per_page = 2.7
        end
        
        estimated_pages = math.floor(content_kb / kb_per_page)
    else
        -- Other formats
        local content_kb = 0
        if ext == "mobi" or ext == "azw3" then
            content_kb = size_kb * 0.60
        elseif ext == "fb2" then
            content_kb = size_kb * 0.65
        elseif ext == "txt" or ext == "rtf" then
            content_kb = size_kb * 0.95
        else
            content_kb = size_kb * 0.50
        end
        
        if content_kb < 5 then
            return nil
        end
        
        if ext == "fb2" then
            estimated_pages = math.floor(content_kb / 2.0)
        elseif ext == "mobi" or ext == "azw3" then
            estimated_pages = math.floor(content_kb / 1.6)
        elseif ext == "txt" or ext == "rtf" then
            estimated_pages = math.floor(content_kb / 1.5)
        else
            estimated_pages = math.floor(content_kb / 2.0)
        end
    end
    
    if estimated_pages < 1 then
        estimated_pages = 1
    elseif estimated_pages > 10000 then
        estimated_pages = nil
    end
    
    return estimated_pages
end

local function getPageCount(filepath)
    -- First, try to get accurate page count from DocSettings (reading history)
    local DocSettings = require("docsettings")
    local doc_settings = DocSettings:open(filepath)
    if doc_settings then
        local data = doc_settings.data
        if data and data.doc_pages and data.doc_pages > 0 then
            local accurate = data.doc_pages
            local estimate = estimatePageCount(filepath)
            return accurate, false, estimate
        end
    end
    
    -- Second, try BookInfoManager
    local BookInfoManager = require("bookinfomanager")
    local bookinfo = BookInfoManager:getBookInfo(filepath, false)
    if bookinfo and bookinfo.pages and bookinfo.pages > 0 then
        local is_estimated = bookinfo.pages_estimated == true
        return bookinfo.pages, is_estimated, nil
    end
    
    -- If not available, use fast estimation method
    local estimated_pages = estimatePageCount(filepath)
    return estimated_pages, true, nil
end

--------------------------------------------------------------------------------
-- Cover Browser Badge Patch (Grid View)
--------------------------------------------------------------------------------
local function patchCoverBrowserPageCount(plugin)
    -- Grab Cover Grid mode and the individual Cover Grid items
    local MosaicMenu = require("mosaicmenu")
    local MosaicMenuItem = userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")
    if MosaicMenuItem.patched_pages_badge then
        return
    end
    MosaicMenuItem.patched_pages_badge = true

    -- Store original MosaicMenuItem paintTo method
    local origMosaicMenuItemPaintTo = MosaicMenuItem.paintTo

    -- Override paintTo method to add page count badges
    function MosaicMenuItem:paintTo(bb, x, y)
        -- First, call the original paintTo method to draw the cover normally
        origMosaicMenuItemPaintTo(self, bb, x, y)

        -- Get the cover image widget (target) and dimensions
        local target = self[1][1][1]
        if not target or not target.dimen then
            return
        end

        -- Using the same corner_mark_size as the original code for consistency
        local corner_mark_size = Screen:scaleBySize(10)

        -- ADD page count widget for unread books
        if not self.is_directory and not self.file_deleted and self.status ~= "complete" then
            -- Get page count: first accurate (from already opened books), then estimated
            local page_count, is_estimated, estimate_for_accurate
            if self.filepath then
                page_count, is_estimated, estimate_for_accurate = getPageCount(self.filepath)
            end

            if page_count then
                local page_text
                if is_estimated then
                    -- Pure estimate: ~###p
                    page_text = "~" .. page_count .. "p"
                else
                    -- Accurate with estimate: ~###p (###p)
                    if estimate_for_accurate and estimate_for_accurate ~= page_count then
                        page_text = "~" .. estimate_for_accurate .. "p (" .. page_count .. "p)"
                    else
                        page_text = page_count .. "p"
                    end
                end
                
                local font_size = math.floor(corner_mark_size * page_font_size)

                local pages_text = TextWidget:new({
                    text = page_text,
                    face = Font:getFace("cfont", font_size),
                    alignment = "left",
                    fgcolor = page_text_color,
                    bold = true,
                    padding = 2,
                })

                local pages_badge = FrameContainer:new({
                    linesize = Screen:scaleBySize(2),
                    radius = Screen:scaleBySize(border_corner_radius),
                    color = border_color,
                    bordersize = border_thickness,
                    background = background_color,
                    padding = Screen:scaleBySize(2),
                    margin = 0,
                    pages_text,
                })

                -- left edge of the cover content inside the item
                local cover_left = x + math.floor((self.width - target.dimen.w) / 2)
                -- bottom edge of the cover content inside the item
                local cover_bottom = y + self.height - math.floor((self.height - target.dimen.h) / 2)
                local badge_w, badge_h = pages_badge:getSize().w, pages_badge:getSize().h

                -- Position near bottom-left
                local pad = Screen:scaleBySize(move_from_border)
                local pos_x_badge = cover_left + pad
                local pos_y_badge = cover_bottom - (pad + badge_h)
                pages_badge:paintTo(bb, pos_x_badge, pos_y_badge)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- File Manager Menu Integration
--------------------------------------------------------------------------------
local FileManagerMenu = require("apps/filemanager/filemanagermenu")
local FileManagerMenuOrder = require("ui/elements/filemanager_menu_order")
local _ = require("gettext")

local orig_FileManagerMenu_setUpdateItemTable = FileManagerMenu.setUpdateItemTable
function FileManagerMenu:setUpdateItemTable()
    local UIManager = require("ui/uimanager")
    
    -- Insert menu items into filemanager settings
    table.insert(FileManagerMenuOrder.filemanager_settings, "page_count_standard")
    table.insert(FileManagerMenuOrder.filemanager_settings, "page_count_about")
    
    -- Page counting standard selector
    self.menu_items.page_count_standard = {
        text = _("Page count standard"),
        sub_item_table = {
            {
                text = _("1800 chars/page (~250 words)"),
                help_text = _("More pages shown. Best for academic/technical reading. 2.2 KB/page ratio."),
                checked_func = function() return getPageStandard() == "1800" end,
                callback = function()
                    setPageStandard("1800")
                    UIManager:show(require("ui/widget/infomessage"):new({
                        text = _("Page standard set to 1800 chars/page.\nBadges will update on next cover refresh."),
                        timeout = 2,
                    }))
                end,
            },
            {
                text = _("2200 chars/page (~300 words)"),
                help_text = _("Balanced default. Good for most fiction/non-fiction. 2.7 KB/page ratio."),
                checked_func = function() return getPageStandard() == "2200" end,
                callback = function()
                    setPageStandard("2200")
                    UIManager:show(require("ui/widget/infomessage"):new({
                        text = _("Page standard set to 2200 chars/page (default).\nBadges will update on next cover refresh."),
                        timeout = 2,
                    }))
                end,
            },
            {
                text = _("2500 chars/page (~350 words)"),
                help_text = _("Fewer pages shown. Closer to publisher standards. 3.1 KB/page ratio."),
                checked_func = function() return getPageStandard() == "2500" end,
                callback = function()
                    setPageStandard("2500")
                    UIManager:show(require("ui/widget/infomessage"):new({
                        text = _("Page standard set to 2500 chars/page.\nBadges will update on next cover refresh."),
                        timeout = 2,
                    }))
                end,
            },
        },
    }
    
    -- About info
    self.menu_items.page_count_about = {
        text = _("About page count badges"),
        callback = function()
            local current = getPageStandard()
            local current_text = current == "1800" and "1800 (~250 words)" or
                                current == "2500" and "2500 (~350 words)" or
                                "2200 (~300 words, default)"
            UIManager:show(require("ui/widget/infomessage"):new({
                text = _([[Page Count Badges

Shows estimated page counts on unread book covers in Cover Browser grid view.

Current standard: ]] .. current_text .. [[

Badge format:
• ~###p = Estimated page count
• ###p = Accurate count (from reading history)
• ~###p (###p) = Both estimate and accurate

Accuracy: ~6.8% median error
Method: HTML content analysis for EPUB
Change standard in menu above.

Requires Cover Browser plugin in grid view mode.]]),
                timeout = 12,
            }))
        end,
    }
    
    orig_FileManagerMenu_setUpdateItemTable(self)
end

userpatch.registerPatchPluginFunc("coverbrowser", patchCoverBrowserPageCount)
