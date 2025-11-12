# copyv

Version control for copy paste! `copyv` will keep copy-pasted code up to date with a single command, even merging updates with your changes.

## Installation

```sh
git clone git@github.com:jacobsandlund/copyv.git
cd copyv
zig build -Doptimize=ReleaseFast
cp zig-out/bin/copyv ~/.local/bin # or somewhere on your PATH
```

## Usage

Instead of copying code from GitHub, select the desired lines, copy the URL, then add a `copyv:` comment in your code. (To get the URL, click the first line number, then shift-click the final. For markdown files, first switch to the Code tab instead of the Preview.)

```lua
-- copyv: https://github.com/nvim-telescope/telescope.nvim/blob/master/README.md?plain=1#L141-L145
```

Run `copyv <file>` to copy the code.

(If you actually want to try running this example, use this URL instead, since this is an example of running `copyv` in the past: `https://github.com/nvim-telescope/telescope.nvim/blob/63e279049652b514b7c3cbe5f6b248db53d77516/README.md?plain=1#L138-L142`)

```console
$ copyv ~/.config/nvim/init.lua
```

Your file now contains:

```lua
-- copyv: track https://github.com/nvim-telescope/telescope.nvim/blob/63e279049652b514b7c3cbe5f6b248db53d77516/README.md?plain=1#L157-L161
local builtin = require('telescope.builtin')
vim.keymap.set('n', 'ff', builtin.find_files, {})
vim.keymap.set('n', 'fg', builtin.live_grep, {})
vim.keymap.set('n', 'fb', builtin.buffers, {})
vim.keymap.set('n', 'fh', builtin.help_tags, {})
```

Later, when the upstream config improves, run `copyv` (no args) to update all tagged code:

```console
$ copyv
```

This merges in all the changes up to the latest, including [commit `286628d`](https://github.com/nvim-telescope/telescope.nvim/commit/286628d9f2056cc71d3f3871b5ca4f3209de0dbf) which adds a missing `<leader>`, and updates the SHA:

```diff
-- copyv: track https://github.com/nvim-telescope/telescope.nvim/blob/3a12a853ebf21ec1cce9a92290e3013f8ae75f02/README.md?plain=1#L145-L149
local builtin = require('telescope.builtin')
vim.keymap.set('n', '<leader>ff', builtin.find_files, { desc = 'Telescope find files' })
vim.keymap.set('n', '<leader>fg', builtin.live_grep, { desc = 'Telescope live grep' })
vim.keymap.set('n', '<leader>fb', builtin.buffers, { desc = 'Telescope buffers' })
vim.keymap.set('n', '<leader>fh', builtin.help_tags, { desc = 'Telescope help tags' })
-- copyv: end
```
