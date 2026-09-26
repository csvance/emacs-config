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
Each has :name (buffer *NAME*), :title (label in the F5 menu), :command, and
optionally :key (a global key) and :menu (its key in the F5 menu).  Opening a
session switches to its buffer if open, else starts COMMAND in a new terminal.
When COMMAND exits, the buffer closes.")
(load (locate-user-emacs-file "local.el") 'noerror)

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
  :custom
  (markdown-fontify-code-blocks-natively t)) ; highlight fenced code in its own language

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
  :bind (:map eglot-mode-map
         ("<f7>" . eglot-inlay-hints-mode)) ; toggle inline type hints
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
  (defun my/project-open-readme ()
    "Open the current project's README, or its root directory if it has none."
    (interactive)
    (let* ((root (project-root (project-current t)))
           (readme (seq-find #'file-regular-p
                             (mapcar (lambda (f) (expand-file-name f root))
                                     '("README.md" "readme.md" "README.org"
                                       "README.rst" "README.txt" "README")))))
      (if readme (find-file readme) (project-dired))))
  :custom
  (project-switch-commands #'my/project-open-readme) ; no action menu
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
  :bind ("<f8>" . treemacs)
  :hook (emacs-startup . my/treemacs-at-startup)
  :init
  (defun my/treemacs-at-startup ()
    "Open the sidebar at startup but leave the cursor in the editor."
    (unless (daemonp)
      (save-selected-window (treemacs))))
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
  ;; Keep these for Emacs instead of sending them to the terminal program
  (vterm-keymap-exceptions (append '("C-c" "C-x" "C-u" "C-g" "C-h" "C-l" "M-x" "M-o" "C-y" "M-y"
                                     "<f5>" "<f8>" "<f9>" "<f12>")
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
          (vterm (if new (generate-new-buffer-name name) name)))))))

;;;; Remote Revise watcher (revise-sync.el lives in ~/.emacs.d/lisp/)
(add-to-list 'load-path (locate-user-emacs-file "lisp"))
(use-package revise-sync
  :ensure nil                         ; host and projects are set in local.el
  :custom
  ;; %h = host, %p = project directory, %n = project name
  (revise-sync-command (list (locate-user-emacs-file "bin/revise-watch.sh") "%h" "%p"))
  :config
  (revise-sync-mode 1))

;;;; Quality of life
(setq inhibit-startup-screen t)
(tool-bar-mode -1)
(menu-bar-mode -1)                    ; F10 still opens the menus when needed
(global-display-line-numbers-mode 1)
(column-number-mode 1)
(setq custom-file (locate-user-emacs-file "custom.el"))
(load custom-file 'noerror)           ; keep Customize output out of init.el

;;;; Cheat sheet: F9 opens it, F9 again returns to the previous buffer
(defun my/toggle-cheatsheet ()
  "Show the Emacs cheat sheet, or leave it if it is already showing."
  (interactive)
  (let ((file (locate-user-emacs-file "EMACS_CHEATSHEET.md")))
    (if (equal (buffer-file-name) (expand-file-name file))
        (switch-to-buffer (other-buffer (current-buffer) t))
      (find-file file))))
(global-set-key (kbd "<f9>") #'my/toggle-cheatsheet)

;;;; Personal menu: F5 lists sessions and custom commands (a Magit-style Transient menu)
(use-package transient
  :bind ("<f5>" . my/menu)
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
    [["Sessions" :setup-children my/menu--sessions]
     ["Terminal"
      ("t" "Project terminal" my/project-vterm)
      ("T" "New project terminal" (lambda () (interactive) (my/project-vterm t)))]]
    [["Buffers"
      ("b" "Switch buffer" consult-buffer)
      ("B" "Buffer list by project" ibuffer)]
     ["Project"
      ("p" "Switch project" project-switch-project)
      ("f" "Find file in project" project-find-file)
      ("g" "Magit status" magit-status)]
     ["View"
      ("s" "Toggle sidebar" treemacs)
      ("h" "Toggle type hints" eglot-inlay-hints-mode
       :if (lambda () (bound-and-true-p eglot--managed-mode)))
      ("c" "Cheat sheet" my/toggle-cheatsheet)]
     ["Revise"
      ("r" "Watcher status" revise-sync-status)
      ("R" "Restart watcher" revise-sync-restart)]]))

;;; init.el ends here
