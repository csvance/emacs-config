;;; early-init.el --- Runs before the first frame is drawn -*- lexical-binding: t; -*-

;; Paint the first frame in Catppuccin Mocha's base and text colors so there is
;; no white flash before init.el loads the full theme. Update these if you
;; change `catppuccin-flavor' in init.el.
(push '(background-color . "#1e1e2e") default-frame-alist)
(push '(foreground-color . "#cdd6f4") default-frame-alist)

;; Hide the tool bar and menu bar before they are drawn, not after
;; (init.el turns the modes off too; F10 still opens the menus).
(push '(tool-bar-lines . 0) default-frame-alist)
(push '(menu-bar-lines . 0) default-frame-alist)

;;; early-init.el ends here
