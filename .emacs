(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
;; Comment/uncomment this line to enable MELPA Stable if desired.  See `package-archive-priorities`
;; and `package-pinned-packages`. Most users will not need or want to do this.
;; (add-to-list 'package-archives '("melpa-stable" . "https://stable.melpa.org/packages/") t)
(package-initialize)
(custom-set-variables
 ;; custom-set-variables was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 '(package-selected-packages
   '(catppuccin-theme claude-code ibuffer-project julia-snail magit
		      markdown-mode monet multiple-cursors vterm
		      window-purpose))
 '(package-vc-selected-packages
   '((monet :url "https://github.com/stevemolitor/monet")
     (claude-code :url
		  "https://github.com/stevemolitor/claude-code.el"))))
(custom-set-faces
 ;; custom-set-faces was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 )

;; theme
(setq catppuccin-flavor 'macchiato) ; or 'latte, 'macchiato, or 'mocha
(load-theme 'catppuccin t)

;; multiple cursors
(require 'multiple-cursors)
(global-set-key (kbd "C-S-c C-S-c") 'mc/edit-lines)

;; window-purpose
(require 'window-purpose)
(purpose-mode)

;; julia-snail
(use-package julia-snail
  :vc (:url "https://github.com/csvance/julia-snail" :branch "multimedia-export")
  :ensure t
  :hook (julia-mode . julia-snail-mode))

(setq julia-snail-multimedia-enable t)
(setq julia-snail-multimedia-buffer-style :single-reuse)
(setq julia-snail-multimedia-buffer-autoswitch t)
(setq julia-snail-executable "~/.juliaup/bin/julia")
(setq julia-snail-multimedia-export-enable t)
(setq julia-snail-multimedia-export-path "~/Pictures/julia-snail")

;; claude-code
(use-package inheritenv
  :vc (:url "https://github.com/purcell/inheritenv" :rev :newest))

(use-package monet
  :vc (:url "https://github.com/stevemolitor/monet" :rev :newest))

(use-package claude-code :ensure t
  :vc (:url "https://github.com/stevemolitor/claude-code.el" :rev :newest)
  :config
  ;; optional IDE integration with Monet
  (add-hook 'claude-code-process-environment-functions #'monet-start-server-function)
  (monet-mode 1)

  (claude-code-mode)
  :bind-keymap ("C-c c" . claude-code-command-map)

  ;; Optionally define a repeat map so that "M" will cycle thru Claude auto-accept/plan/confirm modes after invoking claude-code-cycle-mode / C-c M.
  :bind
  (:repeat-map my-claude-code-map ("M" . claude-code-cycle-mode)))

(setq claude-code-terminal-backend 'vterm)

(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '(julia-mode . ("~/Git/ReLint.jl/build/bin/lsp"))))

(add-hook 'julia-mode-hook 'eglot-ensure)

(setq inhibit-startup-screen t)
(dired default-directory)
