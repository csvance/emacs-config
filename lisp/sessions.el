;;; sessions.el --- Terminal sessions in Emacs, listed below the agents pane -*- lexical-binding: t; -*-

;; Each session is a vterm buffer `*NAME*' running one command, usually SSH.  Two kinds:
;; the persistent ones in `my/vterm-sessions' (local.el), listed whether or not they are
;; running, and ones started on the spot with `sessions-new', listed while they run.
;; A pane in the sidebar, below the agents pane, lists them all by host.  The first time you
;; leave an ad-hoc session, the local model (lisp/local-llm.el) titles it from what it shows.

(require 'cl-lib)
(require 'subr-x)
(require 'agents)                       ; the sidebar this pane joins

(defvar vterm-shell)                    ; bound around `vterm', which is loaded on demand
(defvar my/vterm-sessions)              ; init.el, set in local.el
(declare-function vterm "vterm")
(declare-function local-llm-available-p "local-llm")
(declare-function local-llm-request "local-llm")

(defgroup sessions nil
  "Terminal sessions, listed below the agents pane."
  :group 'tools)

(defcustom sessions-pane-height 0.2
  "Height of the sessions pane in the sidebar, as a fraction of the frame."
  :type 'number)

(defcustom sessions-hosts nil
  "SSH destinations `sessions-new' offers first, such as \"user@host\".
Sessions opened to them are listed only while they run."
  :type '(repeat string))

(defcustom sessions-shells nil
  "Shell `sessions-new' starts on each host, as an alist of (HOST . SHELL).
HOST is a host name without the user, such as \"netai01\"; it also matches
that host's full name, such as netai01.medicalmetrics.local.  On other hosts,
and on a host where SHELL is missing, the session runs the login shell."
  :type '(alist :key-type string :value-type string))

(defcustom sessions-auto-title t
  "Whether to title an ad-hoc session with the local model when you first leave it."
  :type 'boolean)

(defcustom sessions-title-context 6000
  "Characters from the end of a session's terminal that the model sees."
  :type 'integer)

(defvar sessions--adhoc nil
  "Sessions started with `sessions-new', newest first.
Plists like the entries of `my/vterm-sessions'.")

(defvar sessions--host-history nil
  "Destinations read by `sessions-new'.")

(defun sessions--entries ()
  "Every session: the configured ones, then the ad-hoc ones."
  (append my/vterm-sessions (reverse sessions--adhoc)))

(defun sessions--buffer (session)
  "SESSION's live buffer, if it is running."
  (get-buffer (format "*%s*" (plist-get session :name))))

;; Options of ssh that take an argument, so the destination is not mistaken for one
(defconst sessions--ssh-arg-options
  '("-B" "-b" "-c" "-D" "-E" "-e" "-F" "-I" "-i" "-J" "-L" "-l" "-m" "-O" "-o" "-p" "-Q" "-R"
    "-S" "-W" "-w"))

(defun sessions--destination (session)
  "The SSH destination in SESSION's command (such as user@host), or nil."
  (when-let* ((words (ignore-errors (split-string-and-unquote (plist-get session :command))))
              (rest (cdr (member "ssh" words))))
    (while (and rest (string-prefix-p "-" (car rest)))
      (setq rest (if (member (car rest) sessions--ssh-arg-options) (cddr rest) (cdr rest))))
    (car rest)))

(defun sessions--host (session)
  "Host label of SESSION: its :host, else its SSH host, else \"local\"."
  (or (plist-get session :host)
      (when-let* ((dest (sessions--destination session)))
        (car (last (split-string dest "@"))))
      "local"))

;;;; Opening and closing

(defun sessions-open (session)
  "Switch to SESSION's buffer, starting its command in a new terminal if needed."
  (if-let* ((buf (sessions--buffer session)))
      (switch-to-buffer buf)
    (require 'vterm)
    (let ((vterm-shell (plist-get session :command))
          (default-directory (expand-file-name "~/")))
      (vterm (format "*%s*" (plist-get session :name))))
    ;; The buffer closes when the command exits (`vterm-kill-buffer-on-exit')
    (add-hook 'kill-buffer-hook
              (lambda ()
                (setq sessions--adhoc (delq session sessions--adhoc))
                (sessions--schedule-redraw))
              nil t)
    (sessions--schedule-redraw)))

(defun sessions-toggle (session)
  "Open SESSION, or from inside its buffer go back to the previous buffer."
  (if (eq (current-buffer) (sessions--buffer session))
      (switch-to-buffer (other-buffer (current-buffer) t))
    (sessions-open session)))

(defun sessions--read-destination ()
  "Read an SSH destination, offering the ones this config already uses."
  (completing-read "SSH to: "
                   (delete-dups (delq nil (append sessions-hosts
                                                  (mapcar #'sessions--destination (sessions--entries))
                                                  (mapcar (lambda (h) (plist-get h :ssh))
                                                          (bound-and-true-p agents-hosts)))))
                   nil nil nil 'sessions--host-history))

(defun sessions--remote-dir (dir)
  "DIR quoted for the remote shell, keeping a leading ~/ for it to expand."
  (if (string-prefix-p "~/" dir)
      (concat "~/" (shell-quote-argument (substring dir 2)))
    (shell-quote-argument dir)))

(defun sessions--shell (dest)
  "The shell `sessions-shells' names for DEST's host, or nil."
  (let ((host (car (last (split-string dest "@")))))
    (cdr (seq-find (lambda (entry)
                     (or (equal host (car entry))
                         (string-prefix-p (concat (car entry) ".") host)))
                   sessions-shells))))

(defun sessions--remote-command (dest dir)
  "What the remote side runs for DEST: cd to DIR, then DEST's shell.
Nil when there is neither, so ssh starts the login shell itself."
  (let ((shell (sessions--shell dest)))
    (when (or dir shell)
      (concat (when dir (format "cd %s && " (sessions--remote-dir dir)))
              (if shell
                  ;; Fall back to the login shell where SHELL is not installed
                  (format "if command -v %s >/dev/null; then exec %s -l; else exec $SHELL -l; fi"
                          (shell-quote-argument shell) (shell-quote-argument shell))
                "exec $SHELL -l")))))

(defun sessions--free-name (name)
  "NAME, or NAME <N> for the first N whose buffer *NAME <N>* does not exist."
  (cl-loop for n from 1
           for candidate = (if (= n 1) name (format "%s <%d>" name n))
           unless (get-buffer (format "*%s*" candidate)) return candidate))

(defun sessions-new (dest &optional dir)
  "Open an SSH session to DEST in a new terminal, listed in the sessions pane.
With a prefix argument, also read a remote directory DIR to start in."
  (interactive (let ((dest (sessions--read-destination)))
                 (list dest (when current-prefix-arg (read-string (format "Directory on %s: " dest))))))
  (when (string-empty-p (string-trim dest)) (user-error "No destination"))
  (let* ((dir (and dir (not (string-empty-p dir)) dir))
         (remote (sessions--remote-command dest dir))
         (command (concat "ssh -t " (shell-quote-argument dest)
                          (when remote (concat " " (shell-quote-argument remote)))))
         (label (if dir (format "%s:%s" dest dir) dest))
         (session (list :name (sessions--free-name (concat "ssh: " label))
                        :title label :command command :dest dest :titled nil :pending nil)))
    (push session sessions--adhoc)
    (when (window-parameter nil 'window-side)
      (when-let* ((win (get-mru-window nil nil nil t))) (select-window win)))
    (sessions-open session)
    (unless (get-buffer-window "*sessions*") (sessions-pane-show))))

(defun sessions--read-session (prompt &optional running)
  "The session on this pane line or of this buffer, else one read with PROMPT.
With RUNNING non-nil, offer only the running ones."
  (or (get-text-property (point) 'sessions-session)
      (seq-find (lambda (s) (eq (sessions--buffer s) (current-buffer))) (sessions--entries))
      (let ((choices (mapcar (lambda (s) (cons (plist-get s :title) s))
                             (if running (seq-filter #'sessions--buffer (sessions--entries))
                               (sessions--entries)))))
        (unless choices (user-error "No sessions"))
        (cdr (assoc (completing-read prompt choices nil t) choices)))))

(defun sessions-visit (session)
  "Visit SESSION, read from the minibuffer when called interactively."
  (interactive (list (sessions--read-session "Visit session: ")))
  (sessions-open session))

(defun sessions-close (session)
  "End SESSION by killing its terminal, after confirmation."
  (interactive (list (sessions--read-session "Close session: " t)))
  (let ((buf (sessions--buffer session)))
    (unless buf (user-error "%s is not running" (plist-get session :title)))
    (when (yes-or-no-p (format "Close %s? " (plist-get session :title)))
      (let ((kill-buffer-query-functions nil)) ; already confirmed
        (kill-buffer buf)))))

;;;; Titles: the local model names an ad-hoc session the first time you leave it

(defconst sessions--title-schema
  '(:type "object"
    :properties (:title (:type "string" :maxLength 40))
    :required ["title"]
    :additionalProperties :json-false)
  "Shape of the model's reply.")

(defconst sessions--title-prompt
  "You title terminal sessions. Given the recent contents of an SSH terminal, reply
with a title of two to five words that says what the session is being used for, such
as \"Bazel test run\" or \"GPU usage watch\". Leave out the host name. If the terminal
shows only a login banner and a prompt, with nothing done yet, reply with an empty title."
  "Instructions for the model.")

(defun sessions--terminal-text (buffer)
  "The last `sessions-title-context' characters of BUFFER, without blank lines."
  (with-current-buffer buffer
    (let ((text (buffer-substring-no-properties
                 (max (point-min) (- (point-max) sessions-title-context)) (point-max))))
      (string-join (seq-remove (lambda (l) (string-blank-p l))
                               (mapcar #'string-trim-right (split-string text "\n")))
                   "\n"))))

(defun sessions--apply-title (session title)
  "Show SESSION as TITLE, in the pane and in its buffer's name."
  (let ((buf (sessions--buffer session))
        (name (sessions--free-name (format "ssh: %s: %s"
                                            ;; Sessions opened before titling existed have no :dest
                                            (or (plist-get session :dest)
                                                (sessions--destination session))
                                            title))))
    (when buf
      (with-current-buffer buf (rename-buffer (format "*%s*" name))))
    (plist-put session :name name)
    (plist-put session :title title)
    (plist-put session :titled t)
    (sessions--schedule-redraw)))

(defun sessions-title (session)
  "Ask the local model to title SESSION from what its terminal shows.
The request runs in the background.  Only ad-hoc sessions are titled."
  (interactive (list (seq-find (lambda (s) (or (eq (sessions--buffer s) (current-buffer))
                                                (eq s (get-text-property (point) 'sessions-session))))
                               sessions--adhoc)))
  (unless session (user-error "Not an ad-hoc session"))
  (let ((buf (sessions--buffer session)))
    (when (and buf (not (plist-get session :pending))
               (require 'local-llm nil t) (local-llm-available-p))
      (plist-put session :pending t)
      (local-llm-request
       (format "Host: %s\n\n%s" (sessions--host session) (sessions--terminal-text buf))
       sessions--title-prompt sessions--title-schema
       (lambda (data problem)
         (plist-put session :pending nil)
         (let ((title (string-trim (or (plist-get data :title) ""))))
           (cond (problem (message "Could not title the session: %s" problem))
                 ;; Nothing done in it yet: try again the next time you leave it
                 ((string-empty-p title))
                 ((sessions--buffer session) (sessions--apply-title session title)))))))))

(defvar sessions--current nil
  "The buffer of the selected window, as of the last window change.")

(defun sessions--note-leaving (&rest _)
  "Title the ad-hoc session you just left, if it has no title yet."
  (let ((buf (window-buffer (selected-window))))
    (unless (or (eq buf sessions--current) (minibufferp buf))
      (when-let* ((sessions-auto-title)
                  (left sessions--current)
                  ((buffer-live-p left))
                  (session (seq-find (lambda (s) (eq (sessions--buffer s) left)) sessions--adhoc))
                  ((not (plist-get session :titled))))
        (sessions-title session))
      (setq sessions--current buf))))

(add-hook 'window-selection-change-functions #'sessions--note-leaving)
(add-hook 'window-buffer-change-functions #'sessions--note-leaving)

;;;; Pane

(defconst sessions--pane-name "*sessions*")

(defvar-keymap sessions-pane-mode-map
  :parent special-mode-map
  "RET" #'sessions-pane-visit
  "<mouse-1>" #'sessions-pane-visit
  "n" #'sessions-new
  "k" #'sessions-close
  "t" #'sessions-title
  "g" #'sessions--redraw)

(define-derived-mode sessions-pane-mode special-mode "Sessions"
  "Terminal sessions, grouped by host."
  (setq-local truncate-lines t)
  (setq-local cursor-type nil)
  (setq-local mode-line-format nil)
  ;; A bar across the top of the pane, marking where the agents pane above it ends
  (setq-local header-line-format (agents-sidebar-bar "Sessions")))

(defun sessions-pane-visit (&optional event)
  "Visit the session on this line (or where EVENT clicked), starting it if needed."
  (interactive (list last-nonmenu-event))
  (when (mouse-event-p event) (posn-set-point (event-start event)))
  (let ((session (get-text-property (point) 'sessions-session)))
    (unless session (user-error "No session on this line"))
    ;; Show the session in the most recent ordinary window, not in the sidebar
    (when-let* ((win (get-mru-window nil nil nil t)))
      (select-window win))
    (sessions-open session)))

(defun sessions--pane-buffer ()
  "The pane's buffer, created on first use."
  (or (get-buffer sessions--pane-name)
      (with-current-buffer (get-buffer-create sessions--pane-name)
        (sessions-pane-mode)
        (display-line-numbers-mode -1)  ; after the mode, which the global mode hooks
        (sessions--redraw)
        (current-buffer))))

(defun sessions--redraw ()
  "Redraw the pane, keeping point on the same session."
  (interactive)
  (when-let* ((buf (get-buffer sessions--pane-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (here (get-text-property (point) 'sessions-session))
            (hosts nil))
        (erase-buffer)
        (dolist (s (sessions--entries))
          (cl-pushnew (sessions--host s) hosts :test #'equal))
        (unless hosts
          (insert (propertize "None: n opens an SSH session\n" 'face 'shadow)))
        (dolist (host (nreverse hosts))
          (insert (propertize host 'face 'font-lock-function-name-face) "\n")
          (dolist (s (sessions--entries))
            (when (equal (sessions--host s) host)
              (let ((live (sessions--buffer s)))
                (insert (propertize (concat "  " (if live (propertize "●" 'face 'success) "○")
                                            " " (plist-get s :title) "\n")
                                    'face (unless live 'shadow)
                                    'sessions-session s
                                    'mouse-face 'highlight
                                    'help-echo (if live "mouse-1: visit this session"
                                                 "mouse-1: start this session")))))))
        (goto-char (point-min))
        (when-let* ((pos (and here (text-property-any (point-min) (point-max)
                                                      'sessions-session here))))
          (goto-char pos))))))

(defvar sessions--redraw-timer nil)

(defun sessions--schedule-redraw ()
  "Redraw the pane once Emacs is idle."
  (unless (timerp sessions--redraw-timer)
    (setq sessions--redraw-timer
          (run-with-idle-timer 0.1 nil (lambda ()
                                         (setq sessions--redraw-timer nil)
                                         (sessions--redraw))))))

(defun sessions-pane-show ()
  "Show the pane in the left side column, below the agents pane."
  (interactive)
  (let ((win (display-buffer-in-side-window
              (sessions--pane-buffer)
              `((side . left) (slot . 2) (window-height . ,sessions-pane-height)
                (window-parameters . ((no-other-window . t)
                                      (no-delete-other-windows . t)))))))
    (set-window-dedicated-p win t)
    win))

(defun sessions--sidebar-pane ()
  "Show the pane with the sidebar, when there are sessions to list."
  (when (sessions--entries) (sessions-pane-show)))

(add-hook 'agents-sidebar-panes #'sessions--sidebar-pane)

(provide 'sessions)
;;; sessions.el ends here
