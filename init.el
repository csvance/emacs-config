;;; init.el --- Julia + JETLS + Magit setup -*- lexical-binding: t; -*-
;; Requires Emacs 29 or later (Eglot and use-package are built in).

;;;; Package archives
(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-initialize)
(require 'use-package-ensure)         ; needed for always-ensure to take effect
(setq use-package-always-ensure t)   ; install missing packages automatically

;;;; Theme (first, so the rest of startup is already themed)
(use-package catppuccin-theme
  :config
  (setq catppuccin-flavor 'mocha)     ; options: latte, frappe, macchiato, mocha
  (load-theme 'catppuccin t))

;;;; Machine-specific settings (local.el is not checked in)
;; Example local.el:
;;   (setq my/projects '("~/Git/some-repo" "~/Git/other-repo"))
;;   (setq agents-hosts '((:name "repl" :ssh "user@repl-host")))  ; campfire sessions
;;   (setq revise-sync-default-host "user@repl-host")
;;   (setq revise-sync-projects '("~/Git/some-repo" ("~/Git/other-repo" . "other-host")))
;;   (setq my/vterm-sessions
;;         '((:name "remote" :title "Remote tool" :key "<f6>" :menu "r"
;;            :command "ssh -t user@host some-command")
;;           (:name "remote-shell" :title "Remote shell in a directory" :menu "s"
;;            :command "ssh -t user@host 'cd ~/some/dir && exec $SHELL -l'")))
(defvar my/projects nil
  "Project roots registered with project.el at startup.  Set in local.el.")
(defvar my/vterm-sessions nil
  "Persistent terminal sessions, as a list of plists.  Set in local.el.
Each has :name (buffer *NAME*), :title (label in the F1 menu), :command, and
optionally :key (a global key) and :menu (its key in the F1 menu).  Opening a
session switches to its buffer if open, else starts COMMAND in a new terminal.
When COMMAND exits, the buffer closes.")
(load (locate-user-emacs-file "local.el") 'noerror)

;; API keys live in secrets/authinfo (ignored by Git, mode 600), not ~/.authinfo:
;; ~/.emacs.d persists in the sandbox, and a directory survives where a single
;; bind-mounted file loses its Kerberos-backed NFS access.  One line per key:
;;   machine HOST:PORT login apikey password KEY
(setq auth-sources (list (locate-user-emacs-file "secrets/authinfo")))

;;;; Familiar editing behavior
(cua-mode 1)                          ; C-c / C-x / C-v / C-z when text is selected
(delete-selection-mode 1)             ; typing replaces the selection
(global-set-key (kbd "C-S-z") #'undo-redo)
(recentf-mode 1)                      ; M-x recentf-open for recent files

;; JetBrains-style saving: files save after 5 idle seconds and when Emacs loses focus
(auto-save-visited-mode 1)
(add-function :after after-focus-change-function
              (lambda ()
                (unless (frame-focus-state)
                  (save-some-buffers t))))    ; t = save all without asking

;; No clutter next to your files.  Saving the file itself every few seconds
;; (above) makes the #file# auto-save copies redundant, the .#file lock files
;; only guard against a second Emacs editing the same file, and file~ backups
;; (the version before this session's first save) go in one directory.
(setq auto-save-default nil
      create-lockfiles nil
      backup-directory-alist `(("." . ,(locate-user-emacs-file "backups"))))
;; IDE-style mouse: right-click menu, Ctrl+click to go to definition,
;; mouse side buttons to go back and forward
(context-menu-mode 1)
(global-unset-key (kbd "C-<down-mouse-1>"))  ; frees C-click from the buffer menu
(global-set-key (kbd "C-<mouse-1>") #'xref-find-definitions-at-mouse)
(global-set-key (kbd "<mouse-8>") #'xref-go-back)
(global-set-key (kbd "<mouse-9>") #'xref-go-forward)
(defun my/context-menu-ide-labels (menu _click)
  "Rename the right-click \"Find Definition\" item to \"Go to Definition\"."
  (let ((entry (assq 'xref-find-def (cdr menu)))) ; raw entry; lookup-key drops the label
    (when (eq (car-safe (cdr entry)) 'menu-item)
      (setcdr entry `(menu-item "Go to Definition" ,@(cdddr entry)))))
  menu)
(add-hook 'prog-mode-hook             ; run after prog-mode adds its xref items
          (lambda () (add-hook 'context-menu-functions #'my/context-menu-ide-labels 90 t)))
;; M-. and M-? act on the symbol at point without asking (C-u first to type a name)
(setq xref-prompt-for-identifier
      '(not xref-find-definitions xref-find-definitions-other-window
            xref-find-definitions-other-frame xref-find-references))

;;;; Completion: vertical, searchable prompts everywhere (M-x, C-x b, find file, ...)
(use-package vertico                  ; show candidates as a vertical list
  :init (vertico-mode 1))
(use-package orderless                ; match space-separated words in any order
  :custom
  (completion-styles '(orderless basic))
  (completion-category-overrides '((file (styles basic partial-completion)))))
(use-package marginalia               ; mode, folder and size next to each candidate
  :init (marginalia-mode 1))
(use-package consult                  ; buffer switching with live preview
  :bind (("C-x b" . consult-buffer)
         ("C-x p b" . consult-project-buffer)))

;;;; Buffer list: C-x C-b shows all buffers grouped by project
(global-set-key [remap list-buffers] #'ibuffer)
(use-package ibuffer-project
  :hook (ibuffer . (lambda ()
                     (setq ibuffer-filter-groups (ibuffer-project-generate-filter-groups))
                     (ibuffer-update nil t))))  ; redraw with the project groups

;;;; Languages
(use-package julia-mode)
(use-package go-mode)                 ; fallback if the tree-sitter grammar is missing
(use-package rust-mode)               ; fallback if the tree-sitter grammar is missing
;; Python and shell script support are built in.

(use-package protobuf-mode)           ; fallback if the tree-sitter grammar is missing
(use-package protobuf-ts-mode         ; tree-sitter highlighting for .proto files
  :defer t)                           ; treesit-auto maps .proto to it; loading early warns if the grammar is missing
(use-package bazel)                   ; BUILD, WORKSPACE, MODULE.bazel, .bzl, .bazelrc
(use-package dockerfile-mode
  :mode ("\\(?:Container\\|Docker\\)file\\(?:\\..*\\)?\\'" . dockerfile-mode))
(use-package markdown-mode
  :mode ("README\\.md\\'" . gfm-mode)  ; GitHub flavor for READMEs; other .md files use markdown-mode
  :bind (:map markdown-view-mode-map   ; shared by gfm-view-mode
              ("e" . my/markdown-edit))
  :custom
  (markdown-fontify-code-blocks-natively t) ; highlight fenced code in its own language
  :config
  (defun my/markdown-view ()
    "Show the current Markdown buffer rendered: markup hidden, larger headings, read-only."
    (gfm-view-mode)
    ;; Scale headings in this buffer only; `markdown-header-scaling' would resize them everywhere
    (dotimes (n 6)
      (face-remap-add-relative (intern (format "markdown-header-face-%d" (1+ n)))
                               :height (float (nth n markdown-header-scaling-values)))))
  (defun my/markdown-edit ()
    "Leave the rendered view and edit the file in its usual Markdown mode."
    (interactive)
    (read-only-mode -1)
    (normal-mode)))                   ; reapplies the auto-mode-alist choice; drops the heading remaps

;; Tree-sitter modes give richer, more accurate highlighting.
;; treesit-auto offers to download each grammar the first time you open a file
;; (needs a C compiler such as gcc) and falls back to the modes above otherwise.
(use-package treesit-auto
  :custom
  (treesit-auto-install 'prompt)
  :config
  (setq treesit-auto-langs '(python go gomod rust proto bash dockerfile toml yaml json))
  (treesit-auto-add-to-auto-mode-alist treesit-auto-langs)
  (global-treesit-auto-mode 1))

;;;; Eglot: JETLS for Julia; other servers found automatically
(use-package eglot
  :ensure nil                         ; built in
  ;; Only Julia and Python get a language server; shell, Go and Rust use tree-sitter highlighting
  :hook ((julia-mode python-mode python-ts-mode) . eglot-ensure)
  :config
  ;; JETLS instantiates package environments without asking (may update Manifest.toml)
  (setq-default eglot-workspace-configuration
                '(:jetls (:full_analysis (:auto_instantiate "always"))))
  ;; JETLS can analyze the first file before it has read the setting above and
  ;; still ask, so answer its "Instantiate it now?" question automatically.
  (cl-defmethod eglot-handle-request :around
    (_server (_method (eql window/showMessageRequest)) &key message actions &allow-other-keys)
    (if (and (stringp message)
             (string-match-p "Instantiate it now\\?" message)
             (seq-find (lambda (a) (equal (plist-get a :title) "Instantiate")) actions))
        '(:title "Instantiate")
      (cl-call-next-method)))
  (add-to-list 'eglot-server-programs
               '(((julia-mode :language-id "julia")
                  (julia-ts-mode :language-id "julia"))
                 "jetls" "serve" "--socket" :autoport)))

;;;; Projects: switch with C-x p p; the Treemacs sidebar follows the current one
(use-package project
  :ensure nil                         ; built in
  :init
  (defvar my/treemacs-pinned nil
    "Non-nil while the sidebar keeps a project chosen with C-x p p.
Treemacs otherwise follows the selected buffer's project, which is still the
old one until you open something in the new one.")
  (defun my/treemacs-unpin (frame)
    "Let the sidebar follow again once a window of the editing area shows another buffer."
    (when (and my/treemacs-pinned
               (seq-some (lambda (w) (not (or (window-parameter w 'window-side)
                                              (eq (window-old-buffer w) (window-buffer w)))))
                         (window-list frame 'nomini)))
      (setq my/treemacs-pinned nil)))
  (add-hook 'window-buffer-change-functions #'my/treemacs-unpin)
  (advice-add 'treemacs--do-follow-project :before-until (lambda () my/treemacs-pinned))
  (defun my/project-show-in-sidebar ()
    "Show the current project in the Treemacs sidebar and move there, opening no buffer."
    (interactive)
    (require 'treemacs)
    (setq my/treemacs-pinned t)
    (let ((default-directory (project-root (project-current t))))
      (unless (eq (treemacs-current-visibility) 'visible)
        (agents-sidebar-toggle))
      (treemacs-add-and-display-current-project-exclusively)
      (select-window (treemacs-get-local-window)))) ; treemacs-select-window would toggle back out
  :custom
  (project-switch-commands #'my/project-show-in-sidebar) ; no action menu, no new buffer
  :config
  ;; Never treat the home directory itself as a project, even if a stray ~/.git appears
  (advice-add 'project-try-vc :filter-return
              (lambda (proj)
                (unless (and proj (file-equal-p (project-root proj) "~/"))
                  proj)))
  (dolist (dir my/projects)
    (when-let* ((proj (and (file-directory-p dir) (project-current nil dir))))
      (project-remember-project proj))))

;;;; Magit
(use-package magit
  :bind ("C-x g" . magit-status)
  :config
  ;; List all worktrees (e.g. ones agents create) below the status headers
  (magit-add-section-hook 'magit-status-sections-hook
                          'magit-insert-worktrees 'magit-insert-status-headers t))

;;;; File browser
;; After first launch, run M-x nerd-icons-install-fonts once, then restart.
(use-package nerd-icons)

(use-package treemacs
  :hook (emacs-startup . my/treemacs-at-startup)   ; F8 is `agents-sidebar-toggle', below
  :init
  (defun my/treemacs-at-startup ()
    "Open the sidebar (Treemacs and the agents pane) at startup, cursor in the editor."
    (unless (daemonp)
      (agents-sidebar-toggle)))
  :config
  (treemacs-follow-mode 1)            ; highlight the current file
  (treemacs-project-follow-mode 1)    ; show only the current buffer's project
  (treemacs-git-mode 'deferred))      ; color files by Git status

(use-package treemacs-nerd-icons
  :after treemacs
  :config
  (treemacs-load-theme "nerd-icons"))

(use-package treemacs-magit
  :after (treemacs magit))

;;;; Terminal: F12 opens a terminal in the project root (C-u F12 for another one)
;; vterm compiles a native module on first load; needs cmake, libtool-bin and libvterm-dev.
(use-package vterm
  :commands vterm
  :bind (("<f12>" . my/project-vterm)
         :map vterm-mode-map
         ("C-S-v" . vterm-yank))          ; paste, as in other terminals
  :custom
  (vterm-always-compile-module t)         ; build the module without asking
  (vterm-max-scrollback 10000)
  (vterm-min-window-width 20)             ; fit side-by-side windows (default 80 overflows)
  ;; Let programs set the kill ring and clipboard (OSC 52), as Claude Code does
  ;; when you select text with the mouse; they cannot read it back
  (vterm-enable-manipulate-selection-data-by-osc52 t)
  ;; Keep these for Emacs instead of sending them to the terminal program
  (vterm-keymap-exceptions (append '("C-c" "C-x" "C-u" "C-g" "C-h" "C-l" "M-x" "M-o" "C-y" "M-y"
                                     "<f1>" "<f2>" "<f3>" "<f4>" "<f8>" "<f9>" "<f12>")
                                   (delq nil (mapcar (lambda (s) (plist-get s :key))
                                                     my/vterm-sessions))))
  :init
  (defun my/vterm-session (name command)
    "Switch to terminal *NAME* running COMMAND, starting it if needed.
From inside that terminal, go back to the previous buffer."
    (let ((buf (format "*%s*" name)))
      (cond ((equal (buffer-name) buf) (switch-to-buffer (other-buffer (current-buffer) t)))
            ((get-buffer buf) (switch-to-buffer buf))
            (t (require 'vterm)
               (defvar vterm-shell)         ; bind vterm's option, not a local variable
               (let ((vterm-shell command)
                     (default-directory (expand-file-name "~/")))
                 (vterm buf))))))
  (defun my/vterm-session-command (session)
    "Return a command that opens SESSION, a plist from `my/vterm-sessions'."
    (lambda () (interactive)
      (my/vterm-session (plist-get session :name) (plist-get session :command))))
  (dolist (session my/vterm-sessions)
    (when-let* ((key (plist-get session :key)))
      (global-set-key (kbd key) (my/vterm-session-command session))))
  (defun my/recent-project-root ()
    "Root of the current buffer's project, else of the most recent buffer with one.
Covers buffers outside any project, such as *scratch* or a remote session."
    (seq-some (lambda (buf)
                (with-current-buffer buf
                  (unless (file-remote-p default-directory)
                    (when-let* ((proj (project-current)))
                      (project-root proj)))))
              (cons (current-buffer) (buffer-list))))
  (defun my/project-vterm (&optional new)
    "Switch to the current project's terminal, or back from it.
With prefix argument NEW, always open another terminal."
    (interactive "P")
    (if (and (derived-mode-p 'vterm-mode) (not new))
        (switch-to-buffer (other-buffer (current-buffer) t))
      (let* ((default-directory (or (my/recent-project-root) default-directory))
             (name (format "*vterm: %s*" (file-name-nondirectory
                                           (directory-file-name default-directory)))))
        (if (and (not new) (get-buffer name))
            (switch-to-buffer name)
          (vterm (if new (generate-new-buffer-name name) name))))))
  :config
  (require 'tui-mouse)                  ; forward the mouse to TUIs (lisp/tui-mouse.el)
  (add-hook 'vterm-mode-hook
            (lambda ()
              ;; Box-drawing characters (TUI borders) draw slightly past their line,
              ;; so Emacs takes the cursor's line for cut off and scrolls one line,
              ;; hiding the screen's top row (such as a tab bar)
              (setq-local make-cursor-line-fully-visible nil)))
  ;; When the program is not asking for the mouse, the wheel scrolls the
  ;; scrollback in Emacs, but the program's redraws keep jumping the view back
  ;; to the bottom.  Scrolling up freezes the terminal in copy mode; scrolling
  ;; back to the bottom, typing or Escape resumes it.
  (defun my/vterm-wheel-up (event)
    "Freeze the terminal in copy mode, then scroll up."
    (interactive "e")
    (unless vterm-copy-mode (vterm-copy-mode 1))
    (mwheel-scroll event))
  (defun my/vterm-wheel-down (event)
    "Scroll down; leave copy mode once the bottom of the terminal is visible."
    (interactive "e")
    (mwheel-scroll event)
    (when (and vterm-copy-mode
               (pos-visible-in-window-p (point-max) (posn-window (event-start event))))
      (vterm-copy-mode -1)))
  (defun my/vterm-copy-mode-type ()
    "Leave copy mode and send the typed key to the terminal."
    (interactive)
    (vterm-copy-mode -1)
    (vterm--self-insert))
  (dolist (prefix '("" "double-" "triple-"))
    (define-key vterm-mode-map (vector (intern (concat prefix "wheel-up"))) #'my/vterm-wheel-up)
    (define-key vterm-mode-map (vector (intern (concat prefix "wheel-down"))) #'my/vterm-wheel-down))
  (define-key vterm-copy-mode-map [remap self-insert-command] #'my/vterm-copy-mode-type)
  ;; Copy mode drops vterm's keymap, so Escape would become Emacs's Meta prefix
  ;; and never reach the program (such as Claude Code's Esc to go back)
  (define-key vterm-copy-mode-map [escape] #'my/vterm-copy-mode-type))

;;;; Remote Revise watcher (revise-sync.el lives in ~/.emacs.d/lisp/)
(add-to-list 'load-path (locate-user-emacs-file "lisp"))
(use-package revise-sync
  :ensure nil                         ; host and projects are set in local.el
  :custom
  ;; %h = host, %p = project directory, %n = project name
  (revise-sync-command (list (locate-user-emacs-file "bin/revise-watch.sh") "%h" "%p"))
  :config
  (revise-sync-mode 1))

;;;; Agents: each campfire agent in its own buffer (lisp/agents.el, design in agents-design.md)
;; F2 opens the agents menu; F8 shows or hides the sidebar, Treemacs with the agents pane below it
(use-package agents
  :ensure nil                         ; hosts are set in local.el
  :demand t                           ; poll from startup, so status is current before F2
  :bind (("<f2>" . agents-menu)
         ("<f8>" . agents-sidebar-toggle))
  :config
  (agents-start))

;;;; Layouts: F3 arranges the editing area, optionally over a tile for agents (lisp/layouts.el)
(use-package layouts
  :ensure nil
  :demand t                           ; its display rule must be in place before any agent opens
  :bind ("<f3>" . layouts-menu))

;;;; Notes: F4.  Denote files in ~/Notes, titled and tagged by the local model
(use-package denote :defer t)
(use-package gptel :defer t)
(use-package notes
  :ensure nil
  :demand t                           ; its find-file hook covers notes opened any way
  :bind ("<f4>" . notes-menu))

;;;; Quality of life
(setq inhibit-startup-screen t)
(tool-bar-mode -1)
(menu-bar-mode -1)                    ; F10 still opens the menus when needed
(global-display-line-numbers-mode 1)
(advice-add 'display-line-numbers--turn-on :before-until ; not in terminals, where
            (lambda () (derived-mode-p 'vterm-mode)))   ; they cost the screen columns
;; Symbols the default font lacks otherwise fall back to fonts such as Noto Sans
;; Symbols2, whose lines are half again as tall.  Every line with one (Claude
;; Code's ⏺ and ⏵) grows, and full-screen programs no longer fit their window.
;; Use JuliaMono for them when it is installed, scaled to fit the default lines.
(defun my/symbol-fallback-font (family)
  "Draw symbols missing from the default font with FAMILY, no taller than it."
  (when-let* (((display-graphic-p))
              (entity (find-font (font-spec :family family)))
              (default (font-info (face-font 'default)))
              (info (font-info (open-font entity (aref default 2)))))
    ;; font-info: 2 is the pixel size, 8 the ascent and 9 the descent
    (add-to-list 'face-font-rescale-alist
                 (cons (regexp-quote family)
                       (min 1.0 (/ (float (aref default 8)) (aref info 8))
                            (/ (float (aref default 9)) (aref info 9)))))
    (set-fontset-font t '(#x2000 . #x2BFF) family nil 'append)
    ;; Math symbols would still prefer Noto Sans Math, which is taller too
    (dolist (range '((#x20D0 . #x20FF) (#x27C0 . #x27FF) (#x2900 . #x2AFF)))
      (set-fontset-font t range family nil 'prepend))))
(my/symbol-fallback-font "JuliaMono")
(column-number-mode 1)
(setq custom-file (locate-user-emacs-file "custom.el"))
(load custom-file 'noerror)           ; keep Customize output out of init.el

;;;; Mode toggle: F7 flips the current buffer's main display option
(defun my/mode-toggle ()
  "Toggle Markdown's rendered view, or inline type hints in a language server buffer."
  (interactive)
  (cond ((derived-mode-p 'markdown-view-mode 'gfm-view-mode) (my/markdown-edit))
        ((derived-mode-p 'markdown-mode) (my/markdown-view)) ; after the view modes, which derive from it
        ((bound-and-true-p eglot--managed-mode) (call-interactively #'eglot-inlay-hints-mode))
        (t (user-error "F7 has no toggle in %s" major-mode))))
(global-set-key (kbd "<f7>") #'my/mode-toggle)

;;;; Cheat sheet: F9 opens it, F9 again returns to the previous buffer
(defun my/toggle-cheatsheet ()
  "Show the Emacs cheat sheet, or leave it if it is already showing."
  (interactive)
  (let ((file (locate-user-emacs-file "EMACS_CHEATSHEET.md")))
    (if (equal (buffer-file-name) (expand-file-name file))
        (switch-to-buffer (other-buffer (current-buffer) t))
      (find-file file))))
(global-set-key (kbd "<f9>") #'my/toggle-cheatsheet)

;;;; Personal menu: F1 lists sessions and custom commands (a Magit-style Transient menu)
(use-package transient
  :bind (("<f1>" . my/menu)               ; F1 replaces the help prefix; C-h still opens help
         ("C-c m" . my/menu))             ; C-c <letter> is reserved for user bindings
  :config
  (defun my/menu--sessions (_children)
    "Menu entries for the sessions in `my/vterm-sessions' that have a :menu key."
    (transient-parse-suffixes
     'my/menu
     (mapcar (lambda (s)
               (list (plist-get s :menu) (plist-get s :title) (my/vterm-session-command s)))
             (seq-filter (lambda (s) (plist-get s :menu)) my/vterm-sessions))))
  (transient-define-prefix my/menu ()
    "Personal command menu."
    [["Sessions" :class transient-column :setup-children my/menu--sessions]
     ["Terminal"
      ("t" "Project terminal" my/project-vterm)
      ("T" "New project terminal" (lambda () (interactive) (my/project-vterm t)))
      ("M" "Toggle mouse forwarding" tui-mouse-mode
       :if (lambda () (derived-mode-p 'vterm-mode)))]]
    [["Buffers"
      ("b" "Switch buffer" consult-buffer)
      ("B" "Buffer list by project" ibuffer)]
     ["Project"
      ("p" "Switch project" project-switch-project)
      ("f" "Find file in project" project-find-file)
      ("g" "Magit status" magit-status)]
     ["View"
      ("s" "Toggle sidebar" agents-sidebar-toggle)
      ("i" "Toggle type hints" eglot-inlay-hints-mode
       :if (lambda () (bound-and-true-p eglot--managed-mode)))
      ("c" "Cheat sheet" my/toggle-cheatsheet)]
     ["Revise"
      ("r" "Watcher status" revise-sync-status)
      ("R" "Restart watcher" revise-sync-restart)]]))

;;; init.el ends here
