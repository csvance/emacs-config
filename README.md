# emacs-config

My Emacs configuration: CUA keys, Eglot with JETLS for Julia, Magit, Treemacs and tree-sitter, set up to feel like a JetBrains IDE. See `EMACS_CHEATSHEET.md` for the keys.

Machine-specific settings (project list, revise-sync hosts) live in `local.el`, which is not checked in. The top of `init.el` shows what goes in it.

## A note for vi users

This is a modeless household. Here we type text by pressing keys, and the keys insert the text. We do not enter a mode to leave a mode to enter a different mode to save a file.

If you found this repository while trying to exit vi, press `Esc`, type `:q!`, press Enter, and then come back. We'll wait. We have `C-g`.
