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
--            grays wash out and drawing over existing content ghosts -> faint UI; ~737ms.
--   mode 1 = full GC16-style flash -- solid blacks; ~1845ms.
--   mode 2 = gray4 (4-level) -- non-flashing; ~1098ms. (A 2026-07-14 note called this
--            NOT idempotent -- "a re-drive settles a shade lighter". RETRACTED: the
--            2026-07-17 ramp below held tone over 10s and on an identical re-drive.)
-- So: page-turns (mostly black text) use the fast mode; full refreshes use the full
-- flashing mode; menus/dialogs use gray4, which is the only mode that renders gray at
-- all (see the measurement below) -- needed so disabled items look disabled.
-- Per refresh class: {eink_mode, eink_dither}. MEASURED 2026-07-17 with a 16-band
-- labelled ramp (0x00..0xFF step 0x11), one drive per mode, read off-panel:
--   {1,0} -> BINARIZES: cut between 0xBB (black) and 0xCC (white). No middle tones at
--           all, so mode 1 + dither off cannot express gray, at any value.
--   {2,0} -> three real tiers: black <=0x77, gray 0x88..0xBB, white >=0xCC. Held tone
--           for 10s AND on an identical re-drive => idempotent for solid areas.
-- dither=1 spatially dithers (tone for photos, but makes gray *text* faint).
local EINK_FULL     = {1, 1}  -- full flash: book full-page + images. The dither value
                              -- here is a fallback; refreshFullImp honors KOReader's
                              -- own per-refresh hint instead. See refreshFullImp.
-- EXPERIMENT (2026-07-17): UI back on gray4, BOTH classes together so they can't mix.
-- Why revisit: under {1,0} disabled menu items (COLOR_DARK_GRAY 0x88) render solid
-- black, i.e. indistinguishable from enabled -- a real bug, and unfixable at {1,0}
-- since that mode has no gray.
-- Hypothesis for the old "menu fades light after it opens": NOT a gray4 settle (the
-- ramp above is idempotent), but a MIX of classes -- open via flashui{1,0} (AA glyph
-- edges + 0x88 chrome fall under the 0xC0 cut, snap black => looks solid/bold) then an
-- in-menu ui{2,0} re-render (same pixels become true gray => "faded"). Hence: identical.
-- REVERT BOTH TO {1,0} if menus read too light, or ghost (mode 2 is non-flashing).
local EINK_UI       = {2, 0}  -- menus/dialogs: gray4, real grays, ~1098ms
local EINK_FLASH_UI = {2, 0}  -- menu/dialog open -- kept identical to EINK_UI on purpose
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
--
-- `d` is KOReader's own "this content needs dithering" hint, and it is exactly the
-- image/not-image signal we want: ReaderView sets it per-page from `colorful`,
-- ImageWidget/ImageViewer/BookStatus set it, plain text pages leave it false. On this
-- 2-bit panel dither=1 is the only way to fake tone for photos, but it renders gray
-- *text*/chrome faint -- so honor the hint instead of always dithering. (SW dithering
-- is off here: setupDithering only enables it at 8bpp, and we're RGB565 16bpp.)
function framebuffer:refreshFullImp(x, y, w, h, d)
    self:_einkRefresh({EINK_FULL[1], d and 1 or 0}, true)
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
