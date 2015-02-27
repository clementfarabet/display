# display: a browser-based graphics server

Originally forked from [gfx.js](https://github.com/clementfarabet/gfx.js/).

The initial goal was to remain compatible with the torch/python API of `gfx.js`,
but remove the term.js/tty.js/pty.js stuff which is served just fine by ssh.

Compared to `gfx.js`:

  - no terminal windows (no term.js)
  - [dygraphs](http://dygraphs.com/) instead of nvd3 (have built in zoom and are perfect for time-series plots)
  - plots resize when windows are resized
  - images support zoom and pan
  - image lists are rendered as one image to speed up loading
  - windows remember their positions
  - implementation not relying on the filesystem, supports remote clients (sources)

## Technical overview

The server is a trivial message forwarder:

    POST /events -> EventSource('/events')

The Lua client sends JSON commands directly to the server. The browser script
interprets these commands, e.g.

    { command: 'image', src: 'data:image/jpg;base64,....', title: 'lena' }

### Supported commands

Common parameters:
  - `win`: identifier of the window to be reused (pick a random one if you want a new window)
  - `title`: title for the window title bar

`image` creates a zoomable `<img>` element
  - `src`: URL for the `<img>` element
  - `width`: initial width in pixels
  - `zoom`: zoom in/out the canvas, with linear interpolation (useful to zoom in small filters/pictures)
  - `labels`: array of 3-element arrays `[ x, y, text ]`, where `x`, `y` are the coordinates
    `(0, 0)` is top-left, `(1, 1)` is bottom-right; `text` is the label content

`plot` creates a Dygraph, all [Dygraph options](http://dygraphs.com/options.html) are supported
  - `file`: see [Dygraph data formats](http://dygraphs.com/data.html) for supported formats
  - `labels`: list of strings, first element is the X label

## Installation and usage

Install:

    luarocks make

Launch the server:

    ~/.display/run.js &
    # or simply load display in th:
    th
    > d = require 'display'

Note, there is no authentication and by default the server listens on external IP (port 8000),
so **don't use "as is" for sensitive data**.

See `example.lua` for sample usage.

    local disp = require 'display'
    disp.image(image.lena())
    disp.plot(torch.cat(torch.linspace(0, 10, 10), torch.randn(10), 2))
