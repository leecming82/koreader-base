--[[
E-ink framebuffer backend for the Guowen/OBOOK 4.26" (Ingenic X2000, spi_fb panel).

All facts below were reverse-engineered from the kernel modules and then CONFIRMED
live on-device (see obook5 docs/guowen-obook-426.md "EPD framebuffer & refresh
path" + "EPD live bring-up"):

  * /dev/fb0 is a *standard* Linux fbdev provided by spi_fb: 800x480 landscape,
    RGB565 (16bpp), stride 1600, yres_virtual=960. We draw into the yoffset=0
    buffer only (single-buffered is enough).
  * Refresh trigger is the *standard* FBIOPAN_DISPLAY pan. There is NO custom
    refresh ioctl. The pan BLOCKS until the panel has taken the frame (the driver
    waits on the panel READY gpio, eink_wait_ready), so we need no separate
    wait/ready polling -- the pan itself is the serialization.
  * The pan refreshes the WHOLE panel; there is no rectangular partial update.
    So the (x,y,w,h) refresh-region args are ignored -- every refresh is full-frame.
  * Waveform is selected by writing sysfs *before* the pan (sticky global driver
    state), not via an ioctl arg:
        /sys/bus/spi/devices/spi1.0/eink_mode    (0/1/2)
        /sys/bus/spi/devices/spi1.0/eink_dither  (0/1)
    Measured full-screen refresh times: mode 0 -> 737ms, 1 -> 1845ms, 2 -> 1098ms.
    The exact full/partial/gray4 identity of 0/1/2 still needs a visual pass with
    real text at bring-up; mode 0 is the vendor's idle default and the cleanest,
    so we default everything to it and expose the mapping below for tuning.
  * The panel is physically PORTRAIT 480x800 while the fb is LANDSCAPE 800x480,
    so a 90-degree rotation is required (fb origin (0,0) = physical bottom-left;
    upright logical (lx,ly) -> fb_x = 799-ly, fb_y = lx). That rotation is applied
    at the KOReader Screen level -- device/ingenic/device.lua sets the default
    rotation mode; this backend just exposes the native landscape fb.

Model: extends the generic linux fbdev backend and only overrides the refresh
implementation (mmap/bb/rotation plumbing is all inherited).
--]]

local ffi = require("ffi")
local C = ffi.C
local bit = require("bit")

-- Not in ffi/linux_fb_h; define the standard fbdev pan ioctl.
local FBIOPAN_DISPLAY = 0x4606

-- Waveform (eink_mode) selection per refresh class. Confirmed on-panel (2026-07-14):
--   mode 0 = fast, non-flashing partial (A2-ish) -- pure-black text is crisp, but
--            grays wash out and drawing over existing content ghosts -> faint UI.
--   mode 1 = full GC16-style flash -- solid blacks AND grays, clean; ~1.8s.
--   mode 2 = gray4 (4-level) -- non-flashing, but NOT idempotent: a single gray4
--            re-drive drives dark then SETTLES a shade lighter, so menus rendered
--            with it come up "black enough" then visibly fade to a too-light tone.
-- So: page-turns (mostly black text) use the fast mode; full refreshes use the full
-- flashing mode; and menus/dialogs use the full flashing mode too (mode 1) so their
-- gray chrome + text render SOLID and stay put (the gray4 light-settle above is
-- exactly the "menu fades light after it opens" bug -- do NOT use mode 2 for UI).
-- Per refresh class: {eink_mode, eink_dither}. dither=0 THRESHOLDS gray (pushes
-- KOReader's gray menu chrome toward solid black -> readable); dither=1 spatially
-- dithers (good for photos, but makes gray *text* look faint on this 2-bit panel).
local EINK_FULL     = {1, 1}  -- full flash, dithered: book full-page + images
local EINK_UI       = {1, 0}  -- menus/dialogs: mode-1 GC16 flash, dither off.
                              -- Solid black text + solid gray chrome that STAYS
                              -- (no gray4 light-settle). Flashes (~1.8s) -- accepted
                              -- as the tradeoff for consistently readable menus.
local EINK_FLASH_UI = {1, 0}  -- "flashui"/"flashpartial" (menu/dialog open with a
                              -- ghost-clearing flash). Same solid mode-1/dither-off
                              -- as EINK_UI. Without this override these classes fall
                              -- through to refreshFull -> EINK_FULL {1,1} (dither ON),
                              -- which re-renders the just-opened menu faint/light.
local EINK_PARTIAL  = {0, 1}  -- fast page-turns (black text renders fine)
local EINK_FAST     = {0, 1}

local SYS_EINK_MODE   = "/sys/bus/spi/devices/spi1.0/eink_mode"
local SYS_EINK_DITHER = "/sys/bus/spi/devices/spi1.0/eink_dither"

local framebuffer = {
    -- The spi_fb is landscape-native (800x480) but the panel is physically
    -- portrait (480x800). Flip the blitbuffer 90deg at init so KOReader's logical
    -- screen is upright portrait (480x800). See device docs "EPD live bring-up".
    is_always_portrait = true,
}

local function write_sysfs(path, value)
    local f = io.open(path, "w")
    if not f then return end
    f:write(tostring(value))
    f:close()
end

function framebuffer:init()
    -- Standard linux fbdev init (opens /dev/fb0, mmaps, builds self.bb at the
    -- native 800x480 geometry). is_always_portrait flips the bb -90deg into
    -- portrait, but on this panel that lands upside-down, so add 180deg to get
    -- upright portrait (matches the confirmed transform fb_x=799-ly, fb_y=lx).
    framebuffer.parent.init(self)
    self.bb:rotate(180)
    self.blitbuffer_rotation_mode = self.bb:getRotation()
end

-- Cheap strided fingerprint (sum + xor over ~3k sampled 32-bit words) of the mmap'd
-- frame we're about to flush. Two byte-identical frames give the same pair; different
-- content practically never collides on both accumulators.
local FP_STRIDE = 61
function framebuffer:_fbFingerprint()
    if not self.data or not self.fb_size then return nil, nil end
    local p = ffi.cast("uint32_t*", self.data)
    local words = math.floor(self.fb_size / 4)
    local s, x = 0, 0
    local i = 0
    while i < words do
        local v = p[i]
        s = (s + v) % 4294967296
        x = bit.bxor(x, v)
        i = i + FP_STRIDE
    end
    return s, x
end

-- Select the waveform + dither (sysfs), then flush the whole panel via the pan.
--
-- Redundant-refresh dedup: every refresh here is a full-frame re-flash of the WHOLE
-- panel (the hardware has no partial region), and a mode-1 flash is heavy (~1.8s).
-- KOReader routinely issues two refreshes for a single menu open (e.g. an "ui" plus a
-- "flashui", or readerconfig's onShowConfigPanel paint + UIManager:show) -- upstream
-- these are small partials and cheap, but here they become two identical full flashes,
-- so the menu flashes twice. So: skip a flush whose frame is byte-identical to what is
-- already on the panel. `force` (used by refreshFull) always flushes, preserving a
-- de-ghost escape hatch; every real flush updates the stored panel fingerprint, so a
-- refresh that genuinely changes pixels (or reopening a menu after the page was
-- redrawn) is never skipped.
function framebuffer:_einkRefresh(spec, force)
    local s, x = self:_fbFingerprint()
    if not force and s and s == self._panel_fp_s and x == self._panel_fp_x then
        return  -- identical content already on the panel; drop the redundant re-flash
    end
    write_sysfs(SYS_EINK_MODE, spec[1])
    write_sysfs(SYS_EINK_DITHER, spec[2])
    -- We draw into the yoffset=0 buffer, so pan there. The ioctl blocks until the
    -- driver has clocked the frame out over SPI and the panel signals READY.
    self._vinfo.yoffset = 0
    C.ioctl(self.fd, FBIOPAN_DISPLAY, self._vinfo)
    self._panel_fp_s, self._panel_fp_x = s, x
end

-- Region args are ignored: the hardware only does full-frame pans.
-- Full refreshes always flush (never deduped) -- they're the de-ghost class.
function framebuffer:refreshFullImp(x, y, w, h, d)
    self:_einkRefresh(EINK_FULL, true)
end

function framebuffer:refreshPartialImp(x, y, w, h, d)
    self:_einkRefresh(EINK_PARTIAL)
end

function framebuffer:refreshFastImp(x, y, w, h, d)
    self:_einkRefresh(EINK_FAST)
end

-- Menus/dialogs. Full flashing mode + threshold (dither off) so gray chrome + text
-- render solid instead of faint/light. (Default routes refreshUI->refreshPartial.)
function framebuffer:refreshUIImp(x, y, w, h, d)
    self:_einkRefresh(EINK_UI)
end

-- "flashui"/"flashpartial" = a UI/partial refresh WITH a ghost-clearing flash (used
-- e.g. when a menu or dialog opens). The base class routes both to refreshFullImp,
-- which on this backend is the DITHERED image waveform ({1,1}) -- that re-renders the
-- just-painted menu chrome faint/light. Override them to flash with dither OFF.
function framebuffer:refreshFlashUIImp(x, y, w, h, d)
    self:_einkRefresh(EINK_FLASH_UI)
end

function framebuffer:refreshFlashPartialImp(x, y, w, h, d)
    self:_einkRefresh(EINK_FLASH_UI)
end

return require("ffi/framebuffer_linux"):extend(framebuffer)
