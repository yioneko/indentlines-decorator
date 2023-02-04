# indentlines-decorator

This is a implementation of indent lines using decoration provider api of neovim to resolve several hard problems of the well knonwn plugin [indent-blankline.nvim](indent-blankline.nvim):

- Indent lines of folded lines now will be correctly drawn on open.
- Completely sync with nvim window redrawing and no any flicker.
- On demand redraw, only lines needing redrawn will be rerendered. Performance might be better on large screen.
- Incorporate idea from [echasnovski/mini.indentscope](https://github.com/echasnovski/mini.indentscope) to highlight cursor indent scope and not rely on treesitter which has bad perf on large file.

**Extra notice**:

- This is a POC implementation and not well tested. Issues are generally expected.
- I won't maintain this actively in the near future. To use it, just copy the single source file to dotfiles. And feel free to publish new plugin (or create pr to other existing plugins) based on the idea or implementation here.

Special thanks to the mentioned plugins above.
