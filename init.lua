--
-- A torch client for `display` graphics server
-- Based heavily on https://github.com/clementfarabet/gfx.js/blob/master/clients/torch/js.lua
--

local mime = require 'mime'
local http = require 'socket.http'
local ltn12 = require 'ltn12'
local json = require 'cjson'

require 'image'
require 'torch'

local M = {
  host = '127.0.0.1',
  port = os.getenv('PORT') or 8000,
}

local function uid()
  return 'pane_' .. (os.time() .. math.random()):gsub('%.', '')
end

local function send(command)
  -- TODO: make this asynchronous, don't care about result, but don't want to block execution
  command = json.encode(command)
  http.request({
    url = 'http://' .. M.host .. ':' .. M.port .. '/events',
    method = 'POST',
    headers = { ['content-length'] = #command, ['content-type'] = 'application/json' },
    source = ltn12.source.string(command),
  })
end

-- Normalize an image for display:
local function normalize(img, opts)
  -- rescale image to 0 .. 1
  local min = opts.min or img:min()
  local max = opts.max or img:max()

  img = torch.FloatTensor(img:size()):copy(img)
  img:add(-min):mul(1/(max-min))
  return img
end

-- Render one image:
function M.image(img, opts)
  -- options:
  opts = opts or {}
  local win = opts.win or uid()      -- id of the window to be reused
  local zoom = opts.zoom or 1

  -- backward compat:
  opts.title = opts.title or opts.legend

  if type(img) == 'table' then
    return M.images(img, opts)
  end

  -- img is a collection?
  if img:dim() == 4 or (img:dim() == 3 and img:size(1) > 3) then
    local images = {}
    for i = 1,img:size(1) do
      images[i] = img[i]
    end
    return M.images(images, opts)
  end

  -- normalize for display:
  img = normalize(img, opts)

  -- zoom?
  if zoom ~= 1 then
     img = image.scale(img, img:size(3)*zoom, img:size(2)*zoom, 'simple')
  end

  -- Save image and encode to base64
  local buffer
  if image.saveToString then
     buffer = image.saveToString(img, 100)
  else
     local tf = os.tmpname()
     image.saveJPG(tf, img)
     local f = io.open(tf)
     buffer = f:read('*all')
     f:close()
     os.remove(tf)
  end
  local imgdata = 'data:image/jpg;base64,' .. mime.b64(buffer)

  -- Send image:
  send({ command='image', id=win, src=imgdata, labels=opts._labels, width=opts.width, title=opts.title })

  -- Reusable descriptor:
  return win
end

-- Render multiple images:
function M.images(images, opts)
  opts = opts or {}
  local labels = opts.labels or opts.legends or {}
  local nperrow = opts.nperrow or math.ceil(math.sqrt(#images))
  local padding = opts.padding or 4

  local maxsize = {1, 0, 0}
  for i, img in ipairs(images) do
    if opts.normalize then
      img = normalize(img, opts)
    end
    if img:dim() == 2 then
      img = torch.expand(img:view(1, img:size(1), img:size(2)), maxsize[1], img:size(1), img:size(2))
    end
    images[i] = img
    maxsize[1] = math.max(maxsize[1], img:size(1))
    maxsize[2] = math.max(maxsize[2], img:size(2))
    maxsize[3] = math.max(maxsize[3], img:size(3))
  end

  -- merge all images onto one big canvas
  local _labels = {}
  local numrows = math.ceil(#images / nperrow)
  local canvas = torch.FloatTensor(
     maxsize[1],
     maxsize[2] * numrows + padding * (numrows-1),
     maxsize[3] * nperrow + padding * (nperrow-1)
  ):fill(0.5)
  local row = 0
  local col = 0
  for i, img in ipairs(images) do
    canvas:narrow(2, (padding+maxsize[2]) * row + 1, img:size(2)):narrow(3, (padding+maxsize[3]) * col + 1, img:size(3)):copy(img)
    if labels[i] then
       table.insert(_labels, { col / nperrow, row / numrows, labels[i] })
    end
    col = col + 1
    if col == nperrow then
      col = 0
      row = row + 1
    end
  end
  opts._labels = _labels;

  return M.image(canvas, opts)
end

-- data is either a 2-d torch.Tensor, or a list of lists
-- opts.labels is a list of series names, e.g.
-- plot({ { 1, 23 }, { 2, 12 } }, { labels={'iteration', 'score'} })
-- first series is always the X-axis
-- See http://dygraphs.com/options.html for supported options
function M.plot(data, opts)
  opts = opts or {}
  local win = opts.win or uid()

  local dataset = {}
  if torch.typename(data) then
    for i = 1, data:size(1) do
      local row = {}
      for j = 1, data:size(2) do
        table.insert(row, data[{i, j}])
      end
      table.insert(dataset, row)
    end
  else
     -- Concatenate fields to support CSV:
    for i, v in ipairs(data) do
      table.insert(dataset, table.concat(v,','))
    end
    dataset = table.concat(dataset,'\n')
  end

  -- clone opts into options
  options = {}
  for k, v in pairs(opts) do
    options[k] = v
  end

  options.file = dataset
  if options.labels then
     local labels = {'-'}
     for _,label in ipairs(options.labels) do
        table.insert(labels, label)
     end
     options.labels = labels
  end

  -- Don't pass our options to dygraphs. 'title' is ok
  options.win = nil

  -- Issue command:
  send({ command='plot', id=win, title=opts.title, options=options })
  return win
end

function M.startserver(port)
   -- port:
   M.port = port or M.port

   -- running?
   local status = io.popen('curl -s http://'..M.host..':'..M.port..'/'):read('*all'):gsub('%s*','')
   if status == '' then
      -- start up server:
      os.execute('PORT='..M.port..' node "' .. os.getenv('HOME') .. '/.display/run.js" '..M.port..' > "' .. os.getenv('HOME') .. '/.display/server.log" &')
      print('server started on port '..M.port..', graphics will be rendered into http://localhost:'..M.port)
   else
      print('server listening on port '..M.port..', graphics will be rendered into http://localhost:'..M.port)
   end
end

function M.killserver(port)
   -- port:
   M.port = port or M.port

   -- find job
   local line = io.popen('ps -ef | grep -v grep | grep "run.js '..M.port..'"'):read('*line')
   local uid
   if line then
      local splits = stringx.split(line)
      uid = splits[2]
   end

   -- kill job
   if uid then
      local res = io.popen('kill ' .. uid):read('*all')
      print('server stopped on port ' .. M.port)
   else
      print('server not found on port ' .. M.port)
   end
end

function M.show()
   -- port:
   M.port = port or M.port

   -- OS
   local los = io.popen('uname'):read('*all'):gsub('%s*','')

   -- browse:
   if los == 'Darwin' then
      sys.sleep(0.1)
      os.execute('open http://'..M.host..':'..M.port)
   elseif los == 'Linux' then
      sys.sleep(0.1)
      os.execute('xdg-open http://'..M.host..':'..M.port)
   else
      print('show() is only supported on Mac OS/Linux - other OSes: navigate to http://localhost:PORT by hand')
   end
end

function M.clear()
   -- provided for legacy support (nothing to clear)
end

-- Always start
M.startserver()

-- Package:
return M
