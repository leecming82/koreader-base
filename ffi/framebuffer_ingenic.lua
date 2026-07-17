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

-- Waveform (eink_mode) selection per refresh class.
--
-- eink_mode is 0..3, NOT 0..2 -- mode 3 was missed until 2026-07-17 (stock's own
-- script/refreshall.sh uses it on this SoC, and libeinkcommon only ever writes 0 and 2,
-- so it never showed up in a userspace trace). The four modes are a 2x2 of
-- {1-bit, gray4} x {partial, full}, confirmed against the driver disassembly
-- (eink_qingyue426.ko: rgb565_to_1bit / rgb565_to_2bit1 / rgb565_to_2bit2) and timed
-- on-panel 2026-07-17:
--   mode 0 = 1-bit, partial/non-flashing (A2-ish). 2 levels.  ~707ms
--   mode 1 = 1-bit, full flash.             2 levels.  ~1846ms
--   mode 2 = gray4, partial, custom lut_grayscale. 3 levels (BUGGY). ~1085ms
--   mode 3 = gray4, full, panel OTP waveform.      4 levels.         ~1317ms
--
-- mode 1 is MONOCHROME -- its 1-bit quantizer cuts at Y>=192, which is exactly the
-- 0xBB(black)/0xCC(white) boundary a 16-band ramp measured. It has no grays to render,
-- at any value; an earlier note here claiming it shows "solid blacks AND grays" was
-- wrong and cost a lot of chasing.
--
-- mode 2 is gray4 but its quantizer (rgb565_to_2bit2) aliases black onto white's plane
-- code (0,0) and never emits (1,1), so LUT3 of the driver's embedded lut_grayscale is
-- dead code -> only 3 of 4 tones. mode 3 (rgb565_to_2bit1) emits all four. Measured: a
-- ramp shows 4 distinct tones under mode 3, 3 under mode 2.
--
-- So: mode 3 for anything that needs real gray (UI chrome, images) -- it is both better
-- AND cheaper than mode 1. Page-turns stay 1-bit: text is black-on-white, mode 0 is the
-- fastest thing that renders it, and keeping full refreshes 1-bit too (mode 1) means the
-- periodic promoted full refresh matches the mode-0 partials instead of subtly
-- re-weighting the text every Nth page.
-- Per refresh class: {eink_mode, eink_dither}. MEASURED 2026-07-17 with a 16-band
-- labelled ramp (0x00..0xFF step 0x11), one drive per mode, read off-panel:
--   {1,0} -> BINARIZES: cut between 0xBB (black) and 0xCC (white). No middle tones at
--           all, so mode 1 + dither off cannot express gray, at any value.
--   {2,0} -> three real tiers: black <=0x77, gray 0x88..0xBB, white >=0xCC. Held tone
--           for 10s AND on an identical re-drive => idempotent for solid areas.
-- dither=1 spatially dithers (tone for photos, but makes gray *text* faint).
local EINK_TEXT_FULL = {1, 0} -- book full-page: 1-bit, matches the mode-0 partials
local EINK_IMG_FULL  = {3, 1} -- images: 4-level + dither. refreshFullImp picks between
                              -- these two off KOReader's own hint. See refreshFullImp.
-- UI is on mode 2 despite mode 2 being the *buggy* gray4 path, and that is deliberate.
-- KOReader renders anti-aliased text; on a 219dpi panel a large share of glyph pixels
-- are AA edges, so how a mode buckets the dark end decides how BOLD text looks:
--   mode 1: Y<192 -> black. Crushes nearly every AA edge black => boldest, but 1-bit,
--           so COLOR_DARK_GRAY disabled items also go solid black (bug).
--   mode 2: Y<64 and Y>=192 share a code, so 0x00..0x77 all render black => still bold,
--           and 0x88..0xBB is a real gray => disabled items look disabled.
--   mode 3: correct 4 tones, so 0x44..0x77 becomes dark gray instead of black => AA
--           edges stop being crushed and UI text reads visibly FAINT (user-confirmed).
-- i.e. mode 2's aliasing bug accidentally bolds text while still leaving one gray, which
-- is why it is the best UI compromise on this panel. Correctness is not the goal here;
-- legibility at 219dpi is. Both UI classes stay identical so a menu that opens via
-- flashui and then takes an in-menu ui refresh cannot re-render in a different waveform.
-- UI is on mode 2 despite mode 2 being the *buggy* gray4 path, and that is deliberate.
-- KOReader renders anti-aliased text; on a 219dpi panel a large share of glyph pixels
-- are AA edges, so how a mode buckets the dark end decides how BOLD text looks:
--   mode 1: Y<192 -> black. Crushes nearly every AA edge black => boldest, but 1-bit,
--           so COLOR_DARK_GRAY disabled items also go solid black (bug).
--   mode 2: Y<64 and Y>=192 share a code, so 0x00..0x77 all render black => still bold,
--           and 0x88..0xBB is a real gray => disabled items look disabled.
--   mode 3: correct 4 tones, so 0x44..0x77 becomes dark gray instead of black => AA
--           edges stop being crushed and UI text reads visibly FAINT (user-confirmed).
-- i.e. mode 2's aliasing bug accidentally bolds text while still leaving one gray, which
-- is why it is the best UI compromise on this panel. Correctness is not the goal here;
-- legibility at 219dpi is.
--
-- Tried and rejected (2026-07-17): thresholding UI glyph coverage to 1-bit in
-- ffi/freetype.lua, so text would not depend on the waveform crushing its AA edges and
-- the UI could take mode 3's 4 correct tones. Renders badly -- hinting is off
-- (FT_LOAD_NO_HINTING, to protect synthetic bold), so stems sit on fractional pixels and
-- AA is what hides it; thresholding exposes uneven stems. Would need hinting re-enabled
-- first, which fights synthetic bold. Not pursued.
--
-- Both UI classes stay identical so a menu that opens via flashui and then takes an
-- in-menu ui refresh cannot re-render in a different waveform.
local EINK_UI       = {2, 0}  -- menus/dialogs: gray4 partial, 3 tones, bold-ish, ~1085ms
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
-- ImageWidget/ImageViewer/BookStatus set it, plain text pages leave it false. So use it
-- to pick the whole waveform, not just the dither bit: images get gray4+dither (4 tones
-- + Bayer, the best this panel can do for a photo), text gets the 1-bit path that
-- matches the mode-0 partials it sits between. (SW dithering can't help either way:
-- setupDithering only enables it at 8bpp, and we're RGB565 16bpp.)
function framebuffer:refreshFullImp(x, y, w, h, d)
    self:_einkRefresh(d and EINK_IMG_FULL or EINK_TEXT_FULL, true)
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
