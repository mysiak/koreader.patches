-- NAME IT "2--ui-font.lua": it NEEDS to be the 1st user patch to be executed

-- Based on patch:
-- https://github.com/sebdelsol/KOReader.patches/blob/main/2--ui-font.lua by @sebdelsol
-- Updated by @mysiak with Github Copilot and Claude Sonnet 4.5 + Claude Opus 4.5

local Font = require("ui/font")
local _ = require("gettext")
local T = require("ffi/util").template
local FontList = require("fontlist")
local UIManager = require("ui/uimanager")
local cre = require("document/credocument"):engineInit()

-- util
local function get_bold_path(path_regular)
    -- Try "Font-Regular.ext" -> "Font-Bold.ext"
    local path_bold, n_repl = path_regular:gsub("%-Regular%.", "-Bold.", 1)
    if n_repl > 0 then return path_bold end
    -- Try "Font.ext" -> "Font-Bold.ext"
    path_bold, n_repl = path_regular:gsub("(%.)([^.]+)$", "-Bold.%2", 1)
    return n_repl > 0 and path_bold
end

-- UI font
local UIFont = {
    setting = { name = "ui_font_name" },
    enabled_setting = { name = "ui_font_enabled", default = true },
    font_type = { regular = "NotoSans-Regular.ttf", bold = "NotoSans-Bold.ttf" },
}

function UIFont:getSetting() return G_reader_settings:readSetting(self.setting.name) end
function UIFont:setSetting(value) G_reader_settings:saveSetting(self.setting.name, value) end
function UIFont:getEnabled() return G_reader_settings:readSetting(self.enabled_setting.name, self.enabled_setting.default) end
function UIFont:setEnabled(value) G_reader_settings:saveSetting(self.enabled_setting.name, value) end

function UIFont:init()
    local path_exists = {}
    -- stylua: ignore
    for _, font in ipairs(FontList.fontlist) do path_exists[font] = true end

    self.font_list = {}
    self.fonts = {}
    for _, name in ipairs(cre.getFontFaces()) do
        local path_regular = cre.getFontFaceFilenameAndFaceIndex(name)
        if path_regular then
            local path_bold = get_bold_path(path_regular)
            if path_exists[path_regular] and path_exists[path_bold] then
                table.insert(self.font_list, name)
                self.fonts[name] = { regular = path_regular, bold = path_bold }
            end
        end
    end

    local type_font = {}
    self.to_be_replaced = {}
    -- stylua: ignore start
    for typ, font in pairs(self.font_type) do type_font[font] = typ end
    for name, font in pairs(Font.fontmap) do self.to_be_replaced[name] = type_font[font] end
    -- stylua: ignore end

    self:applyFont()
end

function UIFont:getBookFont()
    -- Try to get the book font from ReaderUI
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or not ReaderUI or not ReaderUI.instance then return nil, nil, {} end
    
    local ui = ReaderUI.instance
    if not ui.document then return nil, nil, {} end
    
    local custom_font
    
    -- Get the currently selected/custom font from ReaderFont module
    if ui.font and ui.font.font_face then
        custom_font = ui.font.font_face
    end
    
    -- Fallback for custom font: get from document directly
    if not custom_font and ui.document.getFontFace then
        custom_font = ui.document:getFontFace()
    end
    
    -- Check if custom font is available in system
    local custom_available = custom_font and self.fonts[custom_font] ~= nil
    
    -- Get all embedded fonts
    local embedded_fonts = {}
    if ui.document.getEmbeddedFontList then
        local embedded_list = ui.document:getEmbeddedFontList()
        if embedded_list then
            for font_name, ign in pairs(embedded_list) do
                local is_available = self.fonts[font_name] ~= nil
                table.insert(embedded_fonts, { name = font_name, available = is_available })
            end
            -- Sort by name
            table.sort(embedded_fonts, function(a, b) return a.name < b.name end)
        end
    end
    
    return custom_font, custom_available, embedded_fonts
end

function UIFont:applyFont()
    if not self:getEnabled() then return end
    local name = self:getSetting()
    if not name or not self.fonts[name] then return end
    for font, typ in pairs(self.to_be_replaced) do
        Font.fontmap[font] = self.fonts[name][typ]
    end
end

function UIFont:setFont(name)
    local current_name = self:getSetting()
    if name ~= current_name then
        if not self.fonts[name] then return false end
        self:setSetting(name)
        return true
    end
end

function UIFont:menu()
    return {
        text_func = function()
            if self:getEnabled() then
                local font = self:getSetting()
                if font then
                    return T(_("UI font: %1"), font)
                else
                    return _("UI font: [Select a font]")
                end
            else
                return _("UI font: [Disabled]")
            end
        end,
        sub_item_table_func = function()
            local items = {
                {
                    text = self:getEnabled() and _("Disable font replacement") or _("Enable font replacement"),
                    callback = function()
                        self:setEnabled(not self:getEnabled())
                        self:applyFont()
                        UIManager:askForRestart(_("Restart to apply the change"))
                    end,
                },
                { text = "---" },
            }
            
            -- Get book font and all embedded fonts
            local custom_font, custom_available, embedded_fonts = self:getBookFont()
            
            -- Add custom book font if detected
            if custom_font then
                table.insert(items, {
                    text = T(_("Book font: %1"), custom_font),
                    enabled_func = function() 
                        return custom_available and self:getEnabled() and custom_font ~= self:getSetting() 
                    end,
                    font_func = function(size)
                        if custom_available then
                            return Font:getFace(self.fonts[custom_font].regular, size)
                        end
                        return nil
                    end,
                    callback = function()
                        if custom_available and self:setFont(custom_font) then
                            self:applyFont()
                            UIManager:askForRestart(_("Restart to apply the UI font change"))
                        end
                    end,
                })
            end
            
            -- Add embedded fonts as a sub-menu
            if #embedded_fonts > 0 then
                local embedded_sub_items = {}
                for idx, efont in ipairs(embedded_fonts) do
                    -- Skip if same as custom font (already shown above)
                    if efont.name ~= custom_font then
                        table.insert(embedded_sub_items, {
                            text = efont.name,
                            enabled_func = function() 
                                return efont.available and self:getEnabled() and efont.name ~= self:getSetting() 
                            end,
                            font_func = function(size)
                                if efont.available then
                                    return Font:getFace(self.fonts[efont.name].regular, size)
                                end
                                return nil
                            end,
                            callback = function()
                                if efont.available and self:setFont(efont.name) then
                                    self:applyFont()
                                    UIManager:askForRestart(_("Restart to apply the UI font change"))
                                end
                            end,
                        })
                    end
                end
                
                if #embedded_sub_items > 0 then
                    table.insert(items, {
                        text = T(_("Embedded fonts (%1)"), #embedded_sub_items),
                        enabled_func = function() return self:getEnabled() end,
                        sub_item_table = embedded_sub_items,
                    })
                end
            end
            
            -- Add separator if we had any book fonts
            if custom_font or #embedded_fonts > 0 then
                table.insert(items, { text = "---" })
            end
            
            for i, name in ipairs(self.font_list) do
                table.insert(items, {
                    text = name,
                    enabled_func = function() return name ~= self:getSetting() end,
                    font_func = function(size) return Font:getFace(self.fonts[name].regular, size) end,
                    callback = function()
                        if not self:getEnabled() then
                            self:setEnabled(true)
                        end
                        if self:setFont(name) then
                            self:applyFont()
                            UIManager:askForRestart(_("Restart to apply the UI font change"))
                        end
                    end,
                })
            end
            return items
        end,
    }
end

--singleton
UIFont:init()

-- menu
local FileManagerMenu = require("apps/filemanager/filemanagermenu")
local ReaderMenu = require("apps/reader/modules/readermenu")

local function patch(menu, order)
    table.insert(order.setting, "----------------------------")
    table.insert(order.setting, "ui_font")
    menu.menu_items.ui_font = UIFont:menu()
end

local orig_FileManagerMenu_setUpdateItemTable = FileManagerMenu.setUpdateItemTable
function FileManagerMenu:setUpdateItemTable()
    patch(self, require("ui/elements/filemanager_menu_order"))
    orig_FileManagerMenu_setUpdateItemTable(self)
end

local orig_ReaderMenu_setUpdateItemTable = ReaderMenu.setUpdateItemTable
function ReaderMenu:setUpdateItemTable()
    patch(self, require("ui/elements/reader_menu_order"))
    orig_ReaderMenu_setUpdateItemTable(self)
end
