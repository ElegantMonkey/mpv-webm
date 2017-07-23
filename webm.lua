local mp = require("mp")
local assdraw = require("mp.assdraw")
local msg = require("mp.msg")
local utils = require("mp.utils")
local mpopts = require("mp.options")
local options = {
  -- Defaults to shift+w
  keybind = "W",
  -- If empty, saves on the same directory of the playing video.
  -- A starting "~" will be replaced by the home dir.
  output_directory = "",
  run_detached = false,
  -- Format string for the output file
  -- %f - Filename, with extension
  -- %F - Filename, without extension
  -- %T - Media title, if it exists, or filename, with extension (useful for some streams, such as YouTube).
  -- %s, %e - Start and end time, with milliseconds
  -- %S, %E - Start and time, without milliseconds
  -- %M - "-audio", if audio is enabled, empty otherwise
  output_format = "%F-[%s-%e]%M",
  -- Scale video to a certain height, keeping the aspect ratio. -1 disables it.
  scale_height = -1,
  -- Target filesize, in kB.
  target_filesize = 2500,
  -- If true, will use stricter flags to ensure the resulting file doesn't
  -- overshoot the target filesize. Not recommended, as constrained quality
  -- mode should work well, unless you're really having trouble hitting
  -- the target size.
  strict_filesize_constraint = false,
  strict_bitrate_multiplier = 0.95,
  -- In kilobits.
  strict_audio_bitrate = 64,
  video_codec = "libvpx",
  audio_codec = "libvorbis",
  twopass = true,
  -- Set the number of encoding threads, for codecs libvpx and libvpx-vp9
  libvpx_threads = 4,
  additional_flags = "--sub=no",
  -- Useful for flags that may impact output filesize, such as crf, qmin, qmax etc
  -- Won't be applied when strict_filesize_constraint is on.
  non_strict_additional_flags = "--ovcopts-add=crf=10",
  -- Only encode tracks that are actually playing
  only_active_tracks = true,
  -- If subs are visible, will attempt to 'burn' the subs into the resulting video.
  -- Haven't tested with external subs, but it should? work.
  hardsub = true,
  output_extension = "webm",
  -- The font size used in the menu. Isn't used for the notifications (started encode, finished encode etc)
  font_size = 24,
  margin = 10,
  message_duration = 5
}
mpopts.read_options(options)
local bold
bold = function(text)
  return "{\\b1}" .. tostring(text) .. "{\\b0}"
end
local message
message = function(text, duration)
  local ass = mp.get_property_osd("osd-ass-cc/0")
  ass = ass .. text
  return mp.osd_message(ass, duration or options.message_duration)
end
local append
append = function(a, b)
  for _, val in ipairs(b) do
    a[#a + 1] = val
  end
  return a
end
local dimensions_changed = true
local _video_dimensions = { }
local get_video_dimensions
get_video_dimensions = function()
  if not (dimensions_changed) then
    return _video_dimensions
  end
  local video_params = mp.get_property_native("video-out-params")
  if not video_params then
    return nil
  end
  dimensions_changed = false
  local keep_aspect = mp.get_property_bool("keepaspect")
  local w = video_params["w"]
  local h = video_params["h"]
  local dw = video_params["dw"]
  local dh = video_params["dh"]
  if mp.get_property_number("video-rotate") % 180 == 90 then
    w, h = h, w
    dw, dh = dh, dw
  end
  _video_dimensions = {
    top_left = { },
    bottom_right = { },
    ratios = { }
  }
  local window_w, window_h = mp.get_osd_size()
  if keep_aspect then
    local unscaled = mp.get_property_native("video-unscaled")
    local panscan = mp.get_property_number("panscan")
    local fwidth = window_w
    local fheight = math.floor(window_w / dw * dh)
    if fheight > window_h or fheight < h then
      local tmpw = math.floor(window_h / dh * dw)
      if tmpw <= window_w then
        fheight = window_h
        fwidth = tmpw
      end
    end
    local vo_panscan_area = window_h - fheight
    local f_w = fwidth / fheight
    local f_h = 1
    if vo_panscan_area == 0 then
      vo_panscan_area = window_h - fwidth
      f_w = 1
      f_h = fheight / fwidth
    end
    if unscaled or unscaled == "downscale-big" then
      vo_panscan_area = 0
      if unscaled or (dw <= window_w and dh <= window_h) then
        fwidth = dw
        fheight = dh
      end
    end
    local scaled_width = fwidth + math.floor(vo_panscan_area * panscan * f_w)
    local scaled_height = fheight + math.floor(vo_panscan_area * panscan * f_h)
    local split_scaling
    split_scaling = function(dst_size, scaled_src_size, zoom, align, pan)
      scaled_src_size = math.floor(scaled_src_size * 2 ^ zoom)
      align = (align + 1) / 2
      local dst_start = math.floor((dst_size - scaled_src_size) * align + pan * scaled_src_size)
      if dst_start < 0 then
        dst_start = dst_start + 1
      end
      local dst_end = dst_start + scaled_src_size
      if dst_start >= dst_end then
        dst_start = 0
        dst_end = 1
      end
      return dst_start, dst_end
    end
    local zoom = mp.get_property_number("video-zoom")
    local align_x = mp.get_property_number("video-align-x")
    local pan_x = mp.get_property_number("video-pan-x")
    _video_dimensions.top_left.x, _video_dimensions.bottom_right.x = split_scaling(window_w, scaled_width, zoom, align_x, pan_x)
    local align_y = mp.get_property_number("video-align-y")
    local pan_y = mp.get_property_number("video-pan-y")
    _video_dimensions.top_left.y, _video_dimensions.bottom_right.y = split_scaling(window_h, scaled_height, zoom, align_y, pan_y)
  else
    _video_dimensions.top_left.x = 0
    _video_dimensions.bottom_right.x = window_w
    _video_dimensions.top_left.y = 0
    _video_dimensions.bottom_right.y = window_h
  end
  _video_dimensions.ratios.w = w / (_video_dimensions.bottom_right.x - _video_dimensions.top_left.x)
  _video_dimensions.ratios.h = h / (_video_dimensions.bottom_right.y - _video_dimensions.top_left.y)
  return _video_dimensions
end
local set_dimensions_changed
set_dimensions_changed = function()
  dimensions_changed = true
end
local clamp
clamp = function(min, val, max)
  if val <= min then
    return min
  end
  if val >= max then
    return max
  end
  return val
end
local clamp_point
clamp_point = function(top_left, point, bottom_right)
  return {
    x = clamp(top_left.x, point.x, bottom_right.x),
    y = clamp(top_left.y, point.y, bottom_right.y)
  }
end
local seconds_to_time_string
seconds_to_time_string = function(seconds, no_ms, full)
  if seconds < 0 then
    return "unknown"
  end
  local ret = ""
  if not (no_ms) then
    ret = string.format(".%03d", seconds * 1000 % 1000)
  end
  ret = string.format("%02d:%02d%s", math.floor(seconds / 60) % 60, math.floor(seconds) % 60, ret)
  if full or seconds > 3600 then
    ret = string.format("%d:%s", math.floor(seconds / 3600), ret)
  end
  return ret
end
local seconds_to_path_element
seconds_to_path_element = function(seconds, no_ms, full)
  local time_string = seconds_to_time_string(seconds, no_ms, full)
  local _
  time_string, _ = time_string:gsub(":", "_")
  return time_string
end
local file_exists
file_exists = function(name)
  local f = io.open(name, "r")
  if f ~= nil then
    io.close(f)
    return true
  end
  return false
end
local VideoPoint
do
  local _class_0
  local _base_0 = {
    set_from_screen = function(self, sx, sy)
      local d = get_video_dimensions()
      local point = clamp_point(d.top_left, {
        x = sx,
        y = sy
      }, d.bottom_right)
      self.x = math.floor(d.ratios.w * (point.x - d.top_left.x) + 0.5)
      self.y = math.floor(d.ratios.h * (point.y - d.top_left.y) + 0.5)
    end,
    to_screen = function(self)
      local d = get_video_dimensions()
      return {
        x = math.floor(self.x / d.ratios.w + d.top_left.x + 0.5),
        y = math.floor(self.y / d.ratios.h + d.top_left.y + 0.5)
      }
    end
  }
  _base_0.__index = _base_0
  _class_0 = setmetatable({
    __init = function(self)
      self.x = -1
      self.y = -1
    end,
    __base = _base_0,
    __name = "VideoPoint"
  }, {
    __index = _base_0,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  VideoPoint = _class_0
end
local Region
do
  local _class_0
  local _base_0 = {
    is_valid = function(self)
      return self.x > -1 and self.y > -1 and self.w > -1 and self.h > -1
    end,
    set_from_points = function(self, p1, p2)
      self.x = math.min(p1.x, p2.x)
      self.y = math.min(p1.y, p2.y)
      self.w = math.abs(p1.x - p2.x)
      self.h = math.abs(p1.y - p2.y)
    end
  }
  _base_0.__index = _base_0
  _class_0 = setmetatable({
    __init = function(self)
      self.x = -1
      self.y = -1
      self.w = -1
      self.h = -1
    end,
    __base = _base_0,
    __name = "Region"
  }, {
    __index = _base_0,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  Region = _class_0
end
local format_filename
format_filename = function(startTime, endTime)
  local replaceTable = {
    ["%%f"] = mp.get_property("filename"),
    ["%%F"] = mp.get_property("filename/no-ext"),
    ["%%s"] = seconds_to_path_element(startTime),
    ["%%S"] = seconds_to_path_element(startTime, true),
    ["%%e"] = seconds_to_path_element(endTime),
    ["%%E"] = seconds_to_path_element(endTime, true),
    ["%%T"] = mp.get_property("media-title"),
    ["%%M"] = (mp.get_property_native('aid') and mp.get_property_native('mute')) and '' or '-audio'
  }
  local filename = options.output_format
  for format, value in pairs(replaceTable) do
    local _
    filename, _ = filename:gsub(format, value)
  end
  local _
  filename, _ = filename:gsub("[<>:\"/\\|?*]", "")
  return tostring(filename) .. "." .. tostring(options.output_extension)
end
local parse_directory
parse_directory = function(dir)
  local home_dir = os.getenv("HOME")
  if not home_dir then
    home_dir = os.getenv("USERPROFILE")
  end
  if not home_dir then
    local drive = os.getenv("HOMEDRIVE")
    local path = os.getenv("HOMEPATH")
    if drive and path then
      home_dir = utils.join_path(drive, path)
    else
      msg.warn("Couldn't find home dir.")
      home_dir = ""
    end
  end
  local _
  dir, _ = dir:gsub("^~", home_dir)
  return dir
end
local get_null_path
get_null_path = function()
  if file_exists("/dev/null") then
    return "/dev/null"
  end
  return "NUL"
end
local escape_filter_path
escape_filter_path = function(path)
  path = path:gsub("\\", "/")
  path = path:gsub("([:[,;])", "\\%1")
  path = path:gsub("(])", "\\%1")
  return path
end
local get_active_tracks
get_active_tracks = function()
  local accepted = {
    video = true,
    audio = not mp.get_property_bool("mute"),
    sub = mp.get_property_bool("sub-visibility")
  }
  local active = { }
  for _, track in ipairs(mp.get_property_native("track-list")) do
    if track["selected"] and accepted[track["type"]] then
      active[#active + 1] = track
    end
  end
  return active
end
local get_subtitle_filters
get_subtitle_filters = function(path)
  if not (options.hardsub and mp.get_property_bool("sub-visibility")) then
    return { }
  end
  local sub_index = -1
  for _, track in ipairs(mp.get_property_native("track-list")) do
    if track["type"] == "sub" and not track["external"] then
      sub_index = sub_index + 1
    end
    if track["selected"] and track["type"] == "sub" then
      if track["external"] then
        return {
          "subtitles='" .. tostring(escape_filter_path(track['external-filename'])) .. "'"
        }
      else
        return {
          "subtitles='" .. tostring(escape_filter_path(path)) .. "':si=" .. tostring(sub_index)
        }
      end
    end
  end
  return { }
end
local get_color_conversion_filters
get_color_conversion_filters = function()
  local colormatrixFilter = {
    ["bt.709"] = "bt709",
    ["bt.2020"] = "bt2020"
  }
  local ret = { }
  local colormatrix = mp.get_property_native("video-params/colormatrix")
  if options.video_codec == "libvpx" and colormatrixFilter[colormatrix] then
    append(ret, {
      "colormatrix=" .. tostring(colormatrixFilter[colormatrix]) .. ":bt601"
    })
  end
  return ret
end
local get_scale_filters
get_scale_filters = function()
  if options.scale_height > 0 then
    return {
      "scale=-1:" .. tostring(options.scale_height)
    }
  end
  return { }
end
local encode
encode = function(region, startTime, endTime)
  local path = mp.get_property("path")
  if not path then
    message("No file is being played")
    return 
  end
  local is_stream = not file_exists(path)
  local command = {
    "mpv",
    path,
    "--start=" .. seconds_to_time_string(startTime, false, true),
    "--end=" .. seconds_to_time_string(endTime, false, true),
    "--ovc=" .. tostring(options.video_codec),
    "--oac=" .. tostring(options.audio_codec)
  }
  local vid = -1
  local aid = -1
  local sid = -1
  if options.only_active_tracks then
    for _, track in ipairs(get_active_tracks()) do
      local arg = ""
      local _exp_0 = track["type"]
      if "video" == _exp_0 then
        vid = track['id']
      elseif "audio" == _exp_0 then
        aid = track['id']
      elseif "sub" == _exp_0 then
        sid = track['id']
      end
    end
  end
  append(command, {
    "--vid=" .. (vid >= 0 and tostring(vid) or "no"),
    "--aid=" .. (aid >= 0 and tostring(aid) or "no"),
    "--sid=" .. (sid >= 0 and tostring(sid) or "no")
  })
  local filters = { }
  append(filters, get_color_conversion_filters())
  append(filters, get_subtitle_filters(path))
  if region and region:is_valid() then
    append(filters, {
      "crop=" .. tostring(region.w) .. ":" .. tostring(region.h) .. ":" .. tostring(region.x) .. ":" .. tostring(region.y)
    })
  end
  append(filters, get_scale_filters())
  if #filters > 0 then
    append(command, {
      "--vf",
      "lavfi=[" .. tostring(table.concat(filters, ',')) .. "]"
    })
  end
  if options.video_codec == "libvpx" or options.audio_codec == "libvpx-vp9" then
    append(command, {
      "--ovcopts-add=threads=" .. tostring(options.libvpx_threads)
    })
  end
  if options.target_filesize > 0 then
    local dT = endTime - startTime
    if options.strict_filesize_constraint then
      local video_kilobits = options.target_filesize * 8
      if aid >= 0 then
        video_kilobits = video_kilobits - dT * options.strict_audio_bitrate
        append(command, {
          "--oacopts-add=b=" .. tostring(options.strict_audio_bitrate) .. "k"
        })
      end
      video_kilobits = video_kilobits * options.strict_bitrate_multiplier
      local bitrate = math.floor(video_kilobits / dT)
      append(command, {
        "--ovcopts-add=b=" .. tostring(bitrate) .. "k",
        "--ovcopts-add=minrate=" .. tostring(bitrate) .. "k",
        "--ovcopts-add=maxrate=" .. tostring(bitrate) .. "k"
      })
    else
      local bitrate = math.floor(options.target_filesize * 8 / dT)
      append(command, {
        "--ovcopts-add=b=" .. tostring(bitrate) .. "k"
      })
    end
  end
  for token in string.gmatch(options.additional_flags, "[^%s]+") do
    command[#command + 1] = token
  end
  if not options.strict_filesize_constraint then
    for token in string.gmatch(options.non_strict_additional_flags, "[^%s]+") do
      command[#command + 1] = token
    end
  end
  if options.twopass and not is_stream then
    local first_pass_cmdline
    do
      local _accum_0 = { }
      local _len_0 = 1
      for _index_0 = 1, #command do
        local arg = command[_index_0]
        _accum_0[_len_0] = arg
        _len_0 = _len_0 + 1
      end
      first_pass_cmdline = _accum_0
    end
    append(first_pass_cmdline, {
      "--ovcopts-add=flags=+pass1",
      "-of=" .. tostring(options.output_extension),
      "-o=" .. tostring(get_null_path())
    })
    message("Starting first pass...")
    msg.verbose("First-pass command line: ", table.concat(first_pass_cmdline, " "))
    local res = utils.subprocess({
      args = first_pass_cmdline,
      cancellable = false
    })
    if res.status ~= 0 then
      message("First pass failed! Check the logs for details.")
      return 
    end
    append(command, {
      "--ovcopts-add=flags=+pass2"
    })
  end
  local dir = ""
  if is_stream then
    dir = parse_directory("~")
  else
    local _
    dir, _ = utils.split_path(path)
  end
  if options.output_directory ~= "" then
    dir = parse_directory(options.output_directory)
  end
  local formatted_filename = format_filename(startTime, endTime)
  local out_path = utils.join_path(dir, formatted_filename)
  append(command, {
    "-o=" .. tostring(out_path)
  })
  msg.info("Encoding to", out_path)
  msg.verbose("Command line:", table.concat(command, " "))
  if options.run_detached then
    message("Started encode, process was detached.")
    return utils.subprocess_detached({
      args = command
    })
  else
    message("Started encode...")
    local res = utils.subprocess({
      args = command,
      cancellable = false
    })
    if res.status == 0 then
      return message("Encoded successfully! Saved to\\N" .. tostring(bold(out_path)))
    else
      return message("Encode failed! Check the logs for details.")
    end
  end
end
local Page
do
  local _class_0
  local _base_0 = {
    add_keybinds = function(self)
      for key, func in pairs(self.keybinds) do
        mp.add_forced_key_binding(key, key, func, {
          repeatable = true
        })
      end
    end,
    remove_keybinds = function(self)
      for key, _ in pairs(self.keybinds) do
        mp.remove_key_binding(key)
      end
    end,
    clear = function(self)
      local window_w, window_h = mp.get_osd_size()
      mp.set_osd_ass(window_w, window_h, "")
      return mp.osd_message("", 0)
    end,
    prepare = function(self)
      return nil
    end,
    dispose = function(self)
      return nil
    end,
    show = function(self)
      self.visible = true
      self:add_keybinds()
      self:prepare()
      self:clear()
      return self:draw()
    end,
    hide = function(self)
      self.visible = false
      self:remove_keybinds()
      self:clear()
      return self:dispose()
    end,
    setup_text = function(self, ass)
      ass:pos(options.margin, options.margin)
      return ass:append("{\\fs" .. tostring(options.font_size) .. "}")
    end
  }
  _base_0.__index = _base_0
  _class_0 = setmetatable({
    __init = function() end,
    __base = _base_0,
    __name = "Page"
  }, {
    __index = _base_0,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  Page = _class_0
end
local CropPage
do
  local _class_0
  local _parent_0 = Page
  local _base_0 = {
    reset = function(self)
      local dimensions = get_video_dimensions()
      local xa, ya
      do
        local _obj_0 = dimensions.top_left
        xa, ya = _obj_0.x, _obj_0.y
      end
      self.pointA:set_from_screen(xa, ya)
      local xb, yb
      do
        local _obj_0 = dimensions.bottom_right
        xb, yb = _obj_0.x, _obj_0.y
      end
      self.pointB:set_from_screen(xb, yb)
      if self.visible then
        return self:draw()
      end
    end,
    setPointA = function(self)
      local posX, posY = mp.get_mouse_pos()
      self.pointA:set_from_screen(posX, posY)
      if self.visible then
        return self:draw()
      end
    end,
    setPointB = function(self)
      local posX, posY = mp.get_mouse_pos()
      self.pointB:set_from_screen(posX, posY)
      if self.visible then
        return self:draw()
      end
    end,
    cancel = function(self)
      return self.callback(false, nil)
    end,
    finish = function(self)
      local region = Region()
      region:set_from_points(self.pointA, self.pointB)
      return self.callback(true, region)
    end,
    prepare = function(self)
      local properties = {
        "keepaspect",
        "video-out-params",
        "video-unscaled",
        "panscan",
        "video-zoom",
        "video-align-x",
        "video-pan-x",
        "video-align-y",
        "video-pan-y",
        "osd-width",
        "osd-height"
      }
      for _, p in ipairs(properties) do
        mp.observe_property(p, "native", set_dimensions_changed)
      end
    end,
    dispose = function(self)
      return mp.unobserve_property(set_dimensions_changed)
    end,
    draw_box = function(self, ass)
      local region = Region()
      region:set_from_points(self.pointA:to_screen(), self.pointB:to_screen())
      local d = get_video_dimensions()
      ass:new_event()
      ass:pos(0, 0)
      ass:append('{\\bord0}')
      ass:append('{\\shad0}')
      ass:append('{\\c&H000000&}')
      ass:append('{\\alpha&H77}')
      ass:draw_start()
      ass:rect_cw(d.top_left.x, d.top_left.y, region.x, region.y + region.h)
      ass:rect_cw(region.x, d.top_left.y, d.bottom_right.x, region.y)
      ass:rect_cw(d.top_left.x, region.y + region.h, region.x + region.w, d.bottom_right.y)
      ass:rect_cw(region.x + region.w, region.y, d.bottom_right.x, d.bottom_right.y)
      return ass:draw_stop()
    end,
    draw = function(self)
      local window = { }
      window.w, window.h = mp.get_osd_size()
      local ass = assdraw.ass_new()
      self:draw_box(ass)
      ass:new_event()
      self:setup_text(ass)
      ass:append(tostring(bold('Crop:')) .. "\\N")
      ass:append(tostring(bold('1:')) .. " change point A (" .. tostring(self.pointA.x) .. ", " .. tostring(self.pointA.y) .. ")\\N")
      ass:append(tostring(bold('2:')) .. " change point B (" .. tostring(self.pointB.x) .. ", " .. tostring(self.pointB.y) .. ")\\N")
      ass:append(tostring(bold('r:')) .. " reset to whole screen\\N")
      ass:append(tostring(bold('ESC:')) .. " cancel crop\\N")
      ass:append(tostring(bold('ENTER:')) .. " confirm crop\\N")
      return mp.set_osd_ass(window.w, window.h, ass.text)
    end
  }
  _base_0.__index = _base_0
  setmetatable(_base_0, _parent_0.__base)
  _class_0 = setmetatable({
    __init = function(self, callback, region)
      self.pointA = VideoPoint()
      self.pointB = VideoPoint()
      self.keybinds = {
        ["1"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.setPointA
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["2"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.setPointB
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["r"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.reset
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["ESC"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.cancel
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["ENTER"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.finish
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)()
      }
      self:reset()
      self.callback = callback
      if region and region:is_valid() then
        self.pointA.x = region.x
        self.pointA.y = region.y
        self.pointB.x = region.x + region.w
        self.pointB.y = region.y + region.h
      end
    end,
    __base = _base_0,
    __name = "CropPage",
    __parent = _parent_0
  }, {
    __index = function(cls, name)
      local val = rawget(_base_0, name)
      if val == nil then
        local parent = rawget(cls, "__parent")
        if parent then
          return parent[name]
        end
      else
        return val
      end
    end,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  if _parent_0.__inherited then
    _parent_0.__inherited(_parent_0, _class_0)
  end
  CropPage = _class_0
end
local Option
do
  local _class_0
  local _base_0 = {
    leftKey = function(self)
      local _exp_0 = self.optType
      if "bool" == _exp_0 then
        self.value = not self.value
      elseif "list" == _exp_0 then
        if self.value > 1 then
          self.value = self.value - 1
        end
      end
    end,
    rightKey = function(self)
      local _exp_0 = self.optType
      if "bool" == _exp_0 then
        self.value = not self.value
      elseif "list" == _exp_0 then
        if self.value < #self.possibleValues then
          self.value = self.value + 1
        end
      end
    end,
    getValue = function(self)
      local _exp_0 = self.optType
      if "bool" == _exp_0 then
        return self.value
      elseif "list" == _exp_0 then
        local value, _
        do
          local _obj_0 = self.possibleValues[self.value]
          value, _ = _obj_0[1], _obj_0[2]
        end
        return value
      end
    end,
    setValue = function(self, value)
      local _exp_0 = self.optType
      if "bool" == _exp_0 then
        self.value = value
      elseif "list" == _exp_0 then
        local set = false
        for i, possiblePair in ipairs(self.possibleValues) do
          local possibleValue, _
          possibleValue, _ = possiblePair[1], possiblePair[2]
          if possibleValue == value then
            set = true
            self.value = i
            break
          end
        end
        if not set then
          return msg.warn("Tried to set invalid value " .. tostring(value) .. " to " .. tostring(self.displayText) .. " option.")
        end
      end
    end,
    getDisplayValue = function(self)
      local _exp_0 = self.optType
      if "bool" == _exp_0 then
        return self.value and "yes" or "no"
      elseif "list" == _exp_0 then
        local value, displayValue
        do
          local _obj_0 = self.possibleValues[self.value]
          value, displayValue = _obj_0[1], _obj_0[2]
        end
        return displayValue or value
      end
    end,
    draw = function(self, ass, selected)
      if selected then
        ass:append(tostring(bold(self.displayText)) .. ": ")
      else
        ass:append(tostring(self.displayText) .. ": ")
      end
      if self.optType == "bool" or self.value > 1 then
        ass:append("◀ ")
      end
      ass:append(self:getDisplayValue())
      if self.optType == "bool" or self.value < #self.possibleValues then
        ass:append(" ▶")
      end
      return ass:append("\\N")
    end
  }
  _base_0.__index = _base_0
  _class_0 = setmetatable({
    __init = function(self, optType, displayText, value, possibleValues)
      self.optType = optType
      self.displayText = displayText
      self.possibleValues = possibleValues
      self.value = 1
      return self:setValue(value)
    end,
    __base = _base_0,
    __name = "Option"
  }, {
    __index = _base_0,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  Option = _class_0
end
local EncodeOptionsPage
do
  local _class_0
  local _parent_0 = Page
  local _base_0 = {
    getCurrentOption = function(self)
      return self.options[self.currentOption][2]
    end,
    leftKey = function(self)
      (self:getCurrentOption()):leftKey()
      return self:draw()
    end,
    rightKey = function(self)
      (self:getCurrentOption()):rightKey()
      return self:draw()
    end,
    prevOpt = function(self)
      self.currentOption = math.max(1, self.currentOption - 1)
      return self:draw()
    end,
    nextOpt = function(self)
      self.currentOption = math.min(#self.options, self.currentOption + 1)
      return self:draw()
    end,
    confirmOpts = function(self)
      for _, optPair in ipairs(self.options) do
        local optName, opt
        optName, opt = optPair[1], optPair[2]
        options[optName] = opt:getValue()
      end
      self:hide()
      return self.callback(true)
    end,
    cancelOpts = function(self)
      self:hide()
      return self.callback(false)
    end,
    draw = function(self)
      local window_w, window_h = mp.get_osd_size()
      local ass = assdraw.ass_new()
      ass:new_event()
      self:setup_text(ass)
      ass:append(tostring(bold('Options:')) .. "\\N\\N")
      for i, optPair in ipairs(self.options) do
        local opt = optPair[2]
        opt:draw(ass, self.currentOption == i)
      end
      ass:append("\\N▲ / ▼: navigate\\N")
      ass:append(tostring(bold('ENTER:')) .. " confirm options\\N")
      ass:append(tostring(bold('ESC:')) .. " cancel\\N")
      return mp.set_osd_ass(window_w, window_h, ass.text)
    end
  }
  _base_0.__index = _base_0
  setmetatable(_base_0, _parent_0.__base)
  _class_0 = setmetatable({
    __init = function(self, callback)
      self.callback = callback
      self.currentOption = 1
      local scaleHeightOpts = {
        {
          -1,
          "no"
        },
        {
          240
        },
        {
          360
        },
        {
          480
        },
        {
          720
        },
        {
          1080
        },
        {
          1440
        },
        {
          2160
        }
      }
      self.options = {
        {
          "twopass",
          Option("bool", "Two Pass", options.twopass)
        },
        {
          "scale_height",
          Option("list", "Scale Height", options.scale_height, scaleHeightOpts)
        },
        {
          "hardsub",
          Option("bool", "Hardsub", options.hardsub)
        },
        {
          "strict_filesize_constraint",
          Option("bool", "Strict Filesize Constraint", options.strict_filesize_constraint)
        }
      }
      self.keybinds = {
        ["LEFT"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.leftKey
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["RIGHT"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.rightKey
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["UP"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.prevOpt
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["DOWN"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.nextOpt
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["ENTER"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.confirmOpts
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["ESC"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.cancelOpts
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)()
      }
    end,
    __base = _base_0,
    __name = "EncodeOptionsPage",
    __parent = _parent_0
  }, {
    __index = function(cls, name)
      local val = rawget(_base_0, name)
      if val == nil then
        local parent = rawget(cls, "__parent")
        if parent then
          return parent[name]
        end
      else
        return val
      end
    end,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  if _parent_0.__inherited then
    _parent_0.__inherited(_parent_0, _class_0)
  end
  EncodeOptionsPage = _class_0
end
local MainPage
do
  local _class_0
  local _parent_0 = Page
  local _base_0 = {
    setStartTime = function(self)
      self.startTime = mp.get_property_number("time-pos")
      if self.visible then
        self:clear()
        return self:draw()
      end
    end,
    setEndTime = function(self)
      self.endTime = mp.get_property_number("time-pos")
      if self.visible then
        self:clear()
        return self:draw()
      end
    end,
    draw = function(self)
      local window_w, window_h = mp.get_osd_size()
      local ass = assdraw.ass_new()
      ass:new_event()
      self:setup_text(ass)
      ass:append("WebM maker\\N")
      ass:append(tostring(bold('c:')) .. " crop\\N")
      ass:append(tostring(bold('1:')) .. " set start time (current is " .. tostring(seconds_to_time_string(self.startTime)) .. ")\\N")
      ass:append(tostring(bold('2:')) .. " set end time (current is " .. tostring(seconds_to_time_string(self.endTime)) .. ")\\N")
      ass:append(tostring(bold('o:')) .. " change encode options\\N")
      ass:append(tostring(bold('e:')) .. " encode\\N")
      ass:append(tostring(bold('ESC:')) .. " close\\N")
      return mp.set_osd_ass(window_w, window_h, ass.text)
    end,
    onUpdateCropRegion = function(self, updated, newRegion)
      if updated then
        self.region = newRegion
      end
      return self:show()
    end,
    crop = function(self)
      self:hide()
      local cropPage = CropPage((function()
        local _base_1 = self
        local _fn_0 = _base_1.onUpdateCropRegion
        return function(...)
          return _fn_0(_base_1, ...)
        end
      end)(), self.region)
      return cropPage:show()
    end,
    onOptionsChanged = function(self, updated)
      return self:show()
    end,
    changeOptions = function(self)
      self:hide()
      local encodeOptsPage = EncodeOptionsPage((function()
        local _base_1 = self
        local _fn_0 = _base_1.onOptionsChanged
        return function(...)
          return _fn_0(_base_1, ...)
        end
      end)())
      return encodeOptsPage:show()
    end,
    encode = function(self)
      self:hide()
      if self.startTime < 0 then
        message("No start time, aborting")
        return 
      end
      if self.endTime < 0 then
        message("No end time, aborting")
        return 
      end
      if self.startTime >= self.endTime then
        message("Start time is ahead of end time, aborting")
        return 
      end
      return encode(self.region, self.startTime, self.endTime)
    end
  }
  _base_0.__index = _base_0
  setmetatable(_base_0, _parent_0.__base)
  _class_0 = setmetatable({
    __init = function(self)
      self.keybinds = {
        ["c"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.crop
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["1"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.setStartTime
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["2"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.setEndTime
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["o"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.changeOptions
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["e"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.encode
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["ESC"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.hide
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)()
      }
      self.startTime = -1
      self.endTime = -1
      self.region = Region()
    end,
    __base = _base_0,
    __name = "MainPage",
    __parent = _parent_0
  }, {
    __index = function(cls, name)
      local val = rawget(_base_0, name)
      if val == nil then
        local parent = rawget(cls, "__parent")
        if parent then
          return parent[name]
        end
      else
        return val
      end
    end,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  if _parent_0.__inherited then
    _parent_0.__inherited(_parent_0, _class_0)
  end
  MainPage = _class_0
end
local mainPage = MainPage()
return mp.add_key_binding(options.keybind, "display-webm-encoder", (function()
  local _base_0 = mainPage
  local _fn_0 = _base_0.show
  return function(...)
    return _fn_0(_base_0, ...)
  end
end)(), {
  repeatable = false
})
