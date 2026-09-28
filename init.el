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
                                     "<f1>" "<f2>" "<f8>" "<f9>" "<f12>")
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
  ;; vterm never passes the mouse to programs, so full-screen TUIs (agents,
  ;; multiplexers) cannot see clicks.  Watch the program's output for the
  ;; sequences that turn mouse reporting on and off, and while it is on, report
  ;; clicks, drags and the wheel as SGR sequences, as a real terminal would.
  ;; Elsewhere, such as at a shell prompt, the mouse keeps its Emacs behavior.
  (defvar-local my/vterm--mouse-modes nil
    "Mouse reporting modes the program has turned on (1000, 1002, 1003, 1006).")
  (defvar-local my/vterm--output-tail ""
    "End of the previous output, in case a mode sequence was split across two.")
  (defvar-local my/vterm--rows nil
    "Height of the terminal screen in rows.")
  (defun my/vterm--track-mouse-modes (process output)
    "Record the mouse reporting modes that OUTPUT from PROCESS turns on or off."
    (when-let* ((buf (process-buffer process))
                ((buffer-live-p buf)))
      (with-current-buffer buf
        (let ((text (concat my/vterm--output-tail output))
              (start 0))
          ;; DECSET/DECRST (ESC [ ? N h, ESC [ ? N l) or a full reset (ESC c)
          (while (string-match "\e\\(?:\\[\\?\\([0-9;]+\\)\\([hl]\\)\\|c\\)" text start)
            (if (not (match-beginning 1))
                (setq my/vterm--mouse-modes nil)
              (dolist (mode (mapcar #'string-to-number (split-string (match-string 1 text) ";")))
                (when (memq mode '(1000 1002 1003 1006))
                  (setq my/vterm--mouse-modes (delq mode my/vterm--mouse-modes))
                  (when (equal (match-string 2 text) "h")
                    (push mode my/vterm--mouse-modes)))))
            (setq start (match-end 0)))
          (setq my/vterm--output-tail (substring output (max 0 (- (length output) 16))))))))
  (advice-add 'vterm--filter :before #'my/vterm--track-mouse-modes)
  (defun my/vterm--record-size (resize process windows)
    "Call RESIZE with PROCESS and WINDOWS, remembering the screen height it sets."
    (let ((size (funcall resize process windows)))
      (when (and size (processp process) (buffer-live-p (process-buffer process)))
        (with-current-buffer (process-buffer process)
          (setq my/vterm--rows (cdr size))))
      size))
  (advice-add 'vterm--window-adjust-process-window-size :around #'my/vterm--record-size)
  (defun my/vterm--screen-start ()
    "Position of the terminal screen's top row in the current vterm buffer.
The screen is the last `my/vterm--rows' lines, followed by one empty line;
everything above it is scrollback."
    (save-excursion
      (goto-char (point-max))
      (forward-line (- (or my/vterm--rows (window-body-height))))
      (point)))
  (defun my/vterm-mouse--active-p ()
    "Non-nil when the program in this terminal wants SGR mouse reports."
    (and (bound-and-true-p my/vterm-mouse-mode)
         (not vterm-copy-mode)
         (memq 1006 my/vterm--mouse-modes)
         (seq-some (lambda (mode) (memq mode my/vterm--mouse-modes)) '(1000 1002 1003))))
  (defun my/vterm-mouse--cell (posn)
    "Return the 1-based terminal (COLUMN . ROW) under mouse position POSN.
Counts buffer lines and columns rather than pixels, since lines drawn with a
fallback font can be taller or narrower than the rest."
    (with-current-buffer (window-buffer (posn-window posn))
      (save-excursion
        (goto-char (or (posn-point posn) (point-max)))
        (let ((row (- (line-number-at-pos) (line-number-at-pos (my/vterm--screen-start)) -1))
              ;; Past the end of a line there is no text; count cells from the pixels
              (col (if (and (eolp) (> (car (posn-col-row posn t)) (current-column)))
                       (- (car (posn-col-row posn t)) (vterm--get-margin-width))
                     (current-column))))
          (cons (1+ col)
                (max 1 (min row (or my/vterm--rows row))))))))
  (defun my/vterm-mouse--send (button posn final)
    "Report mouse BUTTON at POSN to the program; FINAL is ?M (press) or ?m (release)."
    (let ((cell (my/vterm-mouse--cell posn)))
      (with-current-buffer (window-buffer (posn-window posn))
        ;; One write, so the program cannot mistake the leading ESC for the Escape key
        (process-send-string vterm--process (format "\e[<%d;%d;%d%c" button
                                                    (car cell) (cdr cell) final)))))
  (defun my/vterm-mouse--press (button)
    "Return a command that reports a press of BUTTON, the drag, then the release."
    (lambda (event)
      (interactive "e")
      (let* ((posn (event-start event))
             (win (posn-window posn))
             (cell (my/vterm-mouse--cell posn))
             ev)
        (select-window win)
        (my/vterm-mouse--send button posn ?M)
        ;; Report motion while the button is held, for dragging pane borders or
        ;; selecting text, if the program asked for it (modes 1002 and 1003)
        (track-mouse
          (while (mouse-movement-p (setq ev (read-event)))
            (let ((pos (event-start ev)))
              (when (and (eq (posn-window pos) win)
                         (seq-some (lambda (mode) (memq mode my/vterm--mouse-modes)) '(1002 1003))
                         (not (equal cell (my/vterm-mouse--cell pos))))
                (setq posn pos
                      cell (my/vterm-mouse--cell pos))
                (my/vterm-mouse--send (+ 32 button) pos ?M)))))
        (if (and (memq (event-basic-type ev) '(mouse-1 mouse-2 mouse-3))
                 (not (memq 'down (event-modifiers ev))))
            (my/vterm-mouse--send button (if (eq (posn-window (event-end ev)) win)
                                             (event-end ev)
                                           posn)
                                  ?m)
          ;; Something other than the release (a key): release here, then handle it
          (my/vterm-mouse--send button posn ?m)
          (push ev unread-command-events)))))
  (defun my/vterm-mouse--wheel (button)
    "Return a command that reports wheel BUTTON (64 up, 65 down)."
    (lambda (event)
      (interactive "e")
      (my/vterm-mouse--send button (event-start event) ?M)))
  (defun my/vterm-mouse--filter (command)
    "Return COMMAND while the program wants mouse reports, else nil (Emacs handles it)."
    (and (my/vterm-mouse--active-p) command))
  (define-minor-mode my/vterm-mouse-mode
    "Forward the mouse to the program in this terminal whenever it asks for it.
On in every terminal; turn it off to select a TUI's text with the Emacs mouse."
    :lighter (:eval (when (my/vterm-mouse--active-p) " Mouse"))
    :keymap
    (let ((map (make-sparse-keymap)))
      (cl-flet ((bind (event command)
                  (define-key map (vector event)
                              `(menu-item "" ,command :filter my/vterm-mouse--filter))))
        (pcase-dolist (`(,n . ,button) '((1 . 0) (2 . 1) (3 . 2)))
          (dolist (prefix '("" "double-" "triple-"))
            (bind (intern (format "%sdown-mouse-%d" prefix n)) (my/vterm-mouse--press button))
            ;; The press command already reported the release
            (bind (intern (format "%smouse-%d" prefix n)) #'ignore))
          (bind (intern (format "drag-mouse-%d" n)) #'ignore))
        ;; Fast scrolling sends double-/triple- wheel events; forward those too
        (dolist (prefix '("" "double-" "triple-"))
          (bind (intern (concat prefix "wheel-up")) (my/vterm-mouse--wheel 64))
          (bind (intern (concat prefix "wheel-down")) (my/vterm-mouse--wheel 65))))
      map))
  (add-hook 'vterm-mode-hook
            (lambda ()
              (setq my/vterm--rows (window-body-height)) ; the size vterm starts with
              ;; Box-drawing characters (TUI borders) draw slightly past their line,
              ;; so Emacs takes the cursor's line for cut off and scrolls one line,
              ;; hiding the screen's top row (such as a tab bar)
              (setq-local make-cursor-line-fully-visible nil)
              (my/vterm-mouse-mode 1)))
  ;; When the program is not asking for the mouse, the wheel scrolls the
  ;; scrollback in Emacs, but the program's redraws keep jumping the view back
  ;; to the bottom.  Scrolling up freezes the terminal in copy mode; scrolling
  ;; back to the bottom, or typing, resumes it.
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
    "Leave copy mode and send the typed character to the terminal."
    (interactive)
    (vterm-copy-mode -1)
    (vterm--self-insert))
  (dolist (prefix '("" "double-" "triple-"))
    (define-key vterm-mode-map (vector (intern (concat prefix "wheel-up"))) #'my/vterm-wheel-up)
    (define-key vterm-mode-map (vector (intern (concat prefix "wheel-down"))) #'my/vterm-wheel-down))
  (define-key vterm-copy-mode-map [remap self-insert-command] #'my/vterm-copy-mode-type))

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
      ("M" "Toggle mouse forwarding" my/vterm-mouse-mode
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
