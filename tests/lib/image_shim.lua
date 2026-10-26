-- IMAGE SHIM: the engine's image.* (crates/floptle-script/src/image_api.rs)
-- in plain Lua, for code that draws pictures and runs offline under luajit
-- (tests, tools). The same algorithms as the engine's, so a picture drawn
-- here matches the engine's to a level or two of rounding:
--
--   local image = dofile("solar/tests/lib/image_shim.lua")
--   env.image = image          -- before loading the script under test
--
-- Covered: image.new, image.fromPixels, img.width/height, img:clear, fill,
-- blend, circle, ring, line, polygon, draw, getPixel, setPixel, copy, bytes.
-- img:texture() answers nil (nothing draws here), img:png() and img:text()
-- raise: offline code must not need them.
local floor, sqrt, min, max, abs = math.floor, math.sqrt, math.min, math.max, math.abs
local char, byte = string.char, string.byte
local unpack = unpack or table.unpack

local Img = {}
Img.__index = Img

local function q(v)   -- 0..1 → a byte, as the engine rounds
  if v <= 0 then return 0 elseif v >= 1 then return 255 end
  return floor(v * 255 + 0.5)
end

local function new(w, h, r, g, b, a)
  assert(w >= 1 and h >= 1 and w % 1 == 0 and h % 1 == 0, "image.new: whole pixel sizes")
  local px = {}
  local R, G, B, A = 0, 0, 0, 0
  if r then R, G, B, A = q(r), q(g), q(b), q(a or 1) end
  for i = 0, w * h - 1 do
    local o = i * 4
    px[o + 1], px[o + 2], px[o + 3], px[o + 4] = R, G, B, A
  end
  return setmetatable({ width = w, height = h, px = px }, Img)
end

local function fromPixels(w, h, s)
  assert(#s == w * h * 4, "image.fromPixels: wrong byte count")
  local px = {}
  for i = 1, #s, 4096 do
    local t = { byte(s, i, min(#s, i + 4095)) }
    for j = 1, #t do px[i + j - 1] = t[j] end
  end
  return setmetatable({ width = w, height = h, px = px }, Img)
end

-- "over" in plain alpha, as Image::over
local function over(px, i, r, g, b, a, cover)
  local sa = a * cover
  if sa <= 0 then return end
  local da = px[i + 3] / 255
  local keep = da * (1 - sa)
  local oa = sa + keep
  if oa <= 0 then return end
  px[i] = q((r * sa + px[i] / 255 * keep) / oa)
  px[i + 1] = q((g * sa + px[i + 1] / 255 * keep) / oa)
  px[i + 2] = q((b * sa + px[i + 2] / 255 * keep) / oa)
  px[i + 3] = q(oa)
end

local function span(a, len, m)
  local lo = min(max(floor(a + 0.5), 0), m)
  local hi = min(max(floor(a + len + 0.5), 0), m)
  return lo, max(hi, lo)
end

function Img:rect(x, y, w, h, r, g, b, a, blend)
  a = a or 1
  local x0, x1 = span(x, w, self.width)
  local y0, y1 = span(y, h, self.height)
  local px, W = self.px, self.width
  local R, G, B, A = q(r), q(g), q(b), q(a)
  for py = y0, y1 - 1 do
    for xx = x0, x1 - 1 do
      local i = (py * W + xx) * 4 + 1
      if blend then over(px, i, r, g, b, a, 1) else px[i], px[i + 1], px[i + 2], px[i + 3] = R, G, B, A end
    end
  end
end
function Img:fill(x, y, w, h, r, g, b, a) self:rect(x, y, w, h, r, g, b, a, false) end
function Img:blend(x, y, w, h, r, g, b, a) self:rect(x, y, w, h, r, g, b, a, true) end
function Img:clear(r, g, b, a)
  if r == nil then r, g, b, a = 0, 0, 0, 0 end
  self:rect(0, 0, self.width, self.height, r, g, b, a, false)
end

function Img:shade(bx0, by0, bx1, by1, r, g, b, a, cover)
  a = a or 1
  local x0, y0 = max(floor(bx0), 0), max(floor(by0), 0)
  local x1, y1 = min(max(math.ceil(bx1), 0), self.width), min(max(math.ceil(by1), 0), self.height)
  local px, W = self.px, self.width
  for py = y0, y1 - 1 do
    local cy = py + 0.5
    for xx = x0, x1 - 1 do
      local k = cover(xx + 0.5, cy)
      if k > 0 then over(px, (py * W + xx) * 4 + 1, r, g, b, a, k > 1 and 1 or k) end
    end
  end
end

function Img:circle(cx, cy, rad, r, g, b, a)
  self:shade(cx - rad - 1, cy - rad - 1, cx + rad + 1, cy + rad + 1, r, g, b, a, function(x, y)
    return rad - sqrt((x - cx) ^ 2 + (y - cy) ^ 2) + 0.5
  end)
end

function Img:ring(cx, cy, rad, wd, r, g, b, a)
  local half = wd * 0.5
  local reach = rad + half + 1
  self:shade(cx - reach, cy - reach, cx + reach, cy + reach, r, g, b, a, function(x, y)
    return half - abs(sqrt((x - cx) ^ 2 + (y - cy) ^ 2) - rad) + 0.5
  end)
end

function Img:line(x1, y1, x2, y2, wd, r, g, b, a)
  local half = wd * 0.5
  local dx, dy = x2 - x1, y2 - y1
  local len2 = max(dx * dx + dy * dy, 1e-12)
  local pad = half + 1
  self:shade(min(x1, x2) - pad, min(y1, y2) - pad, max(x1, x2) + pad, max(y1, y2) + pad, r, g, b, a, function(x, y)
    local t = ((x - x1) * dx + (y - y1) * dy) / len2
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return half - sqrt((x - x1 - t * dx) ^ 2 + (y - y1 - t * dy) ^ 2) + 0.5
  end)
end

-- even-odd, four sample rows per pixel, exact span coverage along each row
function Img:polygon(pts, r, g, b, a)
  a = a or 1
  local n = #pts / 2
  if n < 3 then return end
  local lx, ly, hx, hy = math.huge, math.huge, -math.huge, -math.huge
  for i = 1, #pts, 2 do
    lx, hx = min(lx, pts[i]), max(hx, pts[i])
    ly, hy = min(ly, pts[i + 1]), max(hy, pts[i + 1])
  end
  local W = self.width
  local x0, x1 = max(floor(lx), 0), min(max(math.ceil(hx), 0), W)
  local y0, y1 = max(floor(ly), 0), min(max(math.ceil(hy), 0), self.height)
  if x0 >= x1 or y0 >= y1 then return end
  local px = self.px
  local cover, xs = {}, {}
  for py = y0, y1 - 1 do
    for i = x0, x1 - 1 do cover[i] = 0 end
    for rr = 0, 3 do
      local sy = py + (rr + 0.5) / 4
      local nx = 0
      for i = 1, n do
        local j = (i == n) and 1 or i + 1
        local ax, ay, bx, by = pts[2 * i - 1], pts[2 * i], pts[2 * j - 1], pts[2 * j]
        if (ay <= sy) ~= (by <= sy) then
          nx = nx + 1
          xs[nx] = ax + (sy - ay) / (by - ay) * (bx - ax)
        end
      end
      for i = nx + 1, #xs do xs[i] = nil end
      table.sort(xs)
      for p = 1, nx - 1, 2 do
        local sa, sb = max(xs[p], x0), min(xs[p + 1], x1)
        if sb > sa then
          local xx = floor(sa)
          while xx < sb and xx < x1 do
            local ov = min(sb, xx + 1) - max(sa, xx)
            if ov > 0 then cover[xx] = cover[xx] + ov / 4 end
            xx = xx + 1
          end
        end
      end
    end
    for xx = x0, x1 - 1 do
      local k = cover[xx]
      if k > 0 then over(px, (py * W + xx) * 4 + 1, r, g, b, a, k > 1 and 1 or k) end
    end
  end
end

-- bilinear, premultiplied while mixing, as Image::sample
function Img:sample(u, v)
  local w, h, px = self.width, self.height, self.px
  local fx = min(max(u - 0.5, 0), w - 1)
  local fy = min(max(v - 0.5, 0), h - 1)
  local ix, iy = floor(fx), floor(fy)
  local tx, ty = fx - ix, fy - iy
  local jx, jy = min(ix + 1, w - 1), min(iy + 1, h - 1)
  local function at(x, y)
    local i = (y * w + x) * 4 + 1
    local al = px[i + 3] / 255
    return px[i] / 255 * al, px[i + 1] / 255 * al, px[i + 2] / 255 * al, al
  end
  local a0, a1, a2, a3 = at(ix, iy)
  local b0, b1, b2, b3 = at(jx, iy)
  local c0, c1, c2, c3 = at(ix, jy)
  local d0, d1, d2, d3 = at(jx, jy)
  local function mix(p, q2, r2, s)
    local top = p + (q2 - p) * tx
    local bot = r2 + (s - r2) * tx
    return top + (bot - top) * ty
  end
  local r, g, b, a = mix(a0, b0, c0, d0), mix(a1, b1, c1, d1), mix(a2, b2, c2, d2), mix(a3, b3, c3, d3)
  if a > 0 then r, g, b = r / a, g / a, b / a end
  return r, g, b, a
end

function Img:draw(src, x, y, w, h, alpha)
  w, h, alpha = w or src.width, h or src.height, alpha or 1
  if w <= 0 or h <= 0 then return end
  if src == self then src = self:copy() end
  local x0, x1 = span(x, w, self.width)
  local y0, y1 = span(y, h, self.height)
  local sx, sy = src.width / w, src.height / h
  local px, W = self.px, self.width
  for py = y0, y1 - 1 do
    for xx = x0, x1 - 1 do
      local r, g, b, a = src:sample((xx + 0.5 - x) * sx, (py + 0.5 - y) * sy)
      over(px, (py * W + xx) * 4 + 1, r, g, b, a, alpha)
    end
  end
end

function Img:getPixel(x, y)
  if x < 0 or y < 0 or x >= self.width or y >= self.height then return nil end
  local i = (floor(y) * self.width + floor(x)) * 4 + 1
  local px = self.px
  return px[i] / 255, px[i + 1] / 255, px[i + 2] / 255, px[i + 3] / 255
end

function Img:setPixel(x, y, r, g, b, a)
  if x < 0 or y < 0 or x >= self.width or y >= self.height then return end
  local i = (floor(y) * self.width + floor(x)) * 4 + 1
  local px = self.px
  px[i], px[i + 1], px[i + 2], px[i + 3] = q(r), q(g), q(b), q(a or 1)
end

function Img:copy()
  local px = {}
  for i = 1, #self.px do px[i] = self.px[i] end
  return setmetatable({ width = self.width, height = self.height, px = px }, Img)
end

function Img:bytes()
  local px, parts = self.px, {}
  for i = 1, #px, 4096 do parts[#parts + 1] = char(unpack(px, i, min(#px, i + 4095))) end
  return table.concat(parts)
end

function Img:texture() return nil, "the image shim draws nothing" end
function Img:png() error("img:png isn't in the image shim") end
function Img:text() error("img:text isn't in the image shim") end

return { new = new, fromPixels = fromPixels, shim = true }
