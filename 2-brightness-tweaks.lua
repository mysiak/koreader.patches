-- Brightness tweaks for swipe gestures
-- Prevents accidentally setting brightness too low via swipe gestures
-- Manual brightness settings are not affected
-- Automatically lowers brightness when charging (USB connected)

local Device = require("device")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

-- Settings
local min_brightness_setting = G_reader_settings:readSetting("brightness_tweaks_min_brightness", 1)
local round_to_5_setting = G_reader_settings:readSetting("brightness_tweaks_round_to_5", false)
local usb_brightness_enabled = G_reader_settings:readSetting("brightness_tweaks_usb_enabled", false)
local usb_brightness_level = G_reader_settings:readSetting("brightness_tweaks_usb_level", 5)

-- State
local is_manual_change = false
local saved_brightness_before_usb = nil
local polling_scheduled = false

-- Restore brightness on startup if needed
local function restoreBrightnessOnStartup()
    if not Device:hasFrontlight() then return end
    
    local saved_brightness = G_reader_settings:readSetting("brightness_tweaks_saved_brightness")
    if saved_brightness then
        local powerd = Device:getPowerDevice()
        if powerd and powerd:isFrontlightOn() then
            local current = powerd:frontlightIntensity()
            
            if current == usb_brightness_level then
                is_manual_change = true
                powerd:setIntensity(saved_brightness)
            end
        end
        
        G_reader_settings:delSetting("brightness_tweaks_saved_brightness")
        G_reader_settings:flush()
    end
end

restoreBrightnessOnStartup()

-- Polling-based charging detection
local function checkChargingState()
    polling_scheduled = false
    
    if not usb_brightness_enabled or not Device:hasFrontlight() then
        return
    end
    
    local powerd = Device:getPowerDevice()
    if not powerd then return end
    
    local is_charging = false
    if Device:hasBattery() and powerd.isCharging then
        is_charging = powerd:isCharging() == true
    end
    
    local frontlight_on = powerd:isFrontlightOn()
    local current_intensity = powerd:frontlightIntensity()
    
    if is_charging and not saved_brightness_before_usb and frontlight_on then
        if current_intensity ~= usb_brightness_level then
            saved_brightness_before_usb = current_intensity
            G_reader_settings:saveSetting("brightness_tweaks_saved_brightness", saved_brightness_before_usb)
            G_reader_settings:flush()
            is_manual_change = true
            powerd:setIntensity(usb_brightness_level)
        end
    elseif not is_charging and saved_brightness_before_usb and frontlight_on then
        is_manual_change = true
        powerd:setIntensity(saved_brightness_before_usb)
        saved_brightness_before_usb = nil
        G_reader_settings:delSetting("brightness_tweaks_saved_brightness")
        G_reader_settings:flush()
    end
    
    if usb_brightness_enabled then
        polling_scheduled = true
        UIManager:scheduleIn(2, checkChargingState)
    end
end

-- Start/stop polling helper
local function startPolling()
    if usb_brightness_enabled and not polling_scheduled and Device:hasFrontlight() then
        polling_scheduled = true
        UIManager:scheduleIn(0.5, checkChargingState)
    end
end

local function stopPolling()
    polling_scheduled = false
end

-- Start polling if feature enabled
startPolling()

-- Hook Resume event
local orig_Resume = UIManager.event_handlers.Resume
UIManager.event_handlers.Resume = function(...)
    startPolling()
    if orig_Resume then
        return orig_Resume(...)
    end
end

-- Hook frontlight
if Device:hasFrontlight() then
    local powerd = Device:getPowerDevice()
    local setIntensity_orig = powerd.setIntensity

    powerd.setIntensity = function(self, intensity)
        if not is_manual_change then
            if min_brightness_setting > 0 then
                intensity = math.max(intensity, min_brightness_setting)
            end
            if round_to_5_setting then
                intensity = math.floor((intensity + 2.5) / 5) * 5
            end
        end
        is_manual_change = false
        return setIntensity_orig(self, intensity)
    end

    local FrontLightWidget = require("ui/widget/frontlightwidget")
    
    local toggleFrontlight_orig = FrontLightWidget.toggleFrontlight
    FrontLightWidget.toggleFrontlight = function(self, step)
        if saved_brightness_before_usb then
            saved_brightness_before_usb = nil
            G_reader_settings:delSetting("brightness_tweaks_saved_brightness")
            G_reader_settings:flush()
        end
        is_manual_change = true
        return toggleFrontlight_orig(self, step)
    end

    local setFrontLightIntensity_orig = FrontLightWidget.setFrontLightIntensity
    FrontLightWidget.setFrontLightIntensity = function(self, intensity)
        if saved_brightness_before_usb then
            saved_brightness_before_usb = nil
            G_reader_settings:delSetting("brightness_tweaks_saved_brightness")
            G_reader_settings:flush()
        end
        is_manual_change = true
        return setFrontLightIntensity_orig(self, intensity)
    end
end

-- Menu - consolidated in Settings
local ReaderMenu = require("apps/reader/modules/readermenu")
local orig_setUpdateItemTable = ReaderMenu.setUpdateItemTable

function ReaderMenu:setUpdateItemTable()
    local menu_order = require("ui/elements/reader_menu_order")

    -- Add single menu entry to Settings
    if not menu_order.setting.brightness_tweaks then
        table.insert(menu_order.setting, "brightness_tweaks")
    end

    self.menu_items.brightness_tweaks = {
        text = _("Brightness tweaks"),
        separator = true,
        sub_item_table = {
            {
                text = _("Gesture protection"),
                sub_item_table = {
                    {
                        text = _("Set minimum brightness"),
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            local SpinWidget = require("ui/widget/spinwidget")
                            local spin_widget = SpinWidget:new{
                                value = min_brightness_setting,
                                value_min = 0,
                                value_max = 100,
                                value_step = 1,
                                value_hold_step = 5,
                                title_text = _("Minimum brightness for swipe gestures"),
                                info_text = _("Prevents accidentally setting brightness too low via swipe gestures. Manual brightness settings are not affected. Set to 0 to disable."),
                                ok_text = _("Set minimum"),
                                callback = function(spin)
                                    min_brightness_setting = spin.value
                                    G_reader_settings:saveSetting("brightness_tweaks_min_brightness", min_brightness_setting)
                                    touchmenu_instance:updateItems()
                                end,
                            }
                            UIManager:show(spin_widget)
                        end,
                    },
                    {
                        text = _("Round to multiples of 5"),
                        checked_func = function()
                            return round_to_5_setting
                        end,
                        callback = function()
                            round_to_5_setting = not round_to_5_setting
                            G_reader_settings:saveSetting("brightness_tweaks_round_to_5", round_to_5_setting)
                        end,
                    },
                },
            },
            {
                text = _("USB charging automation"),
                sub_item_table = {
                    {
                        text = _("Low brightness when charging"),
                        checked_func = function()
                            return usb_brightness_enabled
                        end,
                        callback = function()
                            usb_brightness_enabled = not usb_brightness_enabled
                            G_reader_settings:saveSetting("brightness_tweaks_usb_enabled", usb_brightness_enabled)
                            if usb_brightness_enabled then
                                startPolling()
                            else
                                stopPolling()
                            end
                        end,
                    },
                    {
                        text = _("Charging brightness level"),
                        keep_menu_open = true,
                        enabled_func = function()
                            return usb_brightness_enabled
                        end,
                        callback = function(touchmenu_instance)
                            local SpinWidget = require("ui/widget/spinwidget")
                            local spin_widget = SpinWidget:new{
                                value = usb_brightness_level,
                                value_min = 0,
                                value_max = 100,
                                value_step = 1,
                                value_hold_step = 5,
                                title_text = _("Brightness when charging"),
                                info_text = _("Sets brightness to this level when device is charging. Previous brightness is restored when unplugged."),
                                ok_text = _("Set level"),
                                callback = function(spin)
                                    usb_brightness_level = spin.value
                                    G_reader_settings:saveSetting("brightness_tweaks_usb_level", usb_brightness_level)
                                    touchmenu_instance:updateItems()
                                end,
                            }
                            UIManager:show(spin_widget)
                        end,
                    },
                },
            },
        },
    }

    orig_setUpdateItemTable(self)
end
