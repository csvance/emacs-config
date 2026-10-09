;;; sessions.el --- Terminal sessions in Emacs, listed below the agents pane -*- lexical-binding: t; -*-

;; Each session is a vterm buffer `*NAME*' running one command, usually SSH.  Two kinds:
;; the persistent ones in `my/vterm-sessions' (local.el), listed whether or not they are
;; running, and ones started on the spot with `sessions-new', listed while they run.
;; A pane in the sidebar, below the agents pane, lists them all by host.

(require 'cl-lib)
(require 'subr-x)

(defvar vterm-shell)                    ; bound around `vterm', which is loaded on demand
(defvar my/vterm-sessions)              ; init.el, set in local.el
(defvar agents-hosts)
(defvar agents-sidebar-panes)
(declare-function vterm "vterm")

(defgroup sessions nil
  "Terminal sessions, listed below the agents pane."
  :group 'tools)

(defcustom sessions-pane-height 0.2
  "Height of the sessions pane in the sidebar, as a fraction of the frame."
  :type 'number)

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
                   (delete-dups (delq nil (append (mapcar #'sessions--destination (sessions--entries))
                                                  (mapcar (lambda (h) (plist-get h :ssh))
                                                          (bound-and-true-p agents-hosts)))))
                   nil nil nil 'sessions--host-history))

(defun sessions--remote-dir (dir)
  "DIR quoted for the remote shell, keeping a leading ~/ for it to expand."
  (if (string-prefix-p "~/" dir)
      (concat "~/" (shell-quote-argument (substring dir 2)))
    (shell-quote-argument dir)))

(defun sessions-new (dest &optional dir)
  "Open an SSH session to DEST in a new terminal, listed in the sessions pane.
With a prefix argument, also read a remote directory DIR to start in."
  (interactive (let ((dest (sessions--read-destination)))
                 (list dest (when current-prefix-arg (read-string (format "Directory on %s: " dest))))))
  (when (string-empty-p (string-trim dest)) (user-error "No destination"))
  (let* ((dir (and dir (not (string-empty-p dir)) dir))
         (command (concat "ssh -t " (shell-quote-argument dest)
                          (when dir
                            (concat " " (shell-quote-argument
                                         (format "cd %s && exec $SHELL -l"
                                                 (sessions--remote-dir dir)))))))
         (label (if dir (format "%s:%s" dest dir) dest))
         (name (cl-loop for n from 1
                        for name = (if (= n 1) (concat "ssh: " label) (format "ssh: %s <%d>" label n))
                        unless (get-buffer (format "*%s*" name)) return name))
         (session (list :name name :title label :command command)))
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

;;;; Pane

(defconst sessions--pane-name "*sessions*")

(defvar-keymap sessions-pane-mode-map
  :parent special-mode-map
  "RET" #'sessions-pane-visit
  "<mouse-1>" #'sessions-pane-visit
  "n" #'sessions-new
  "k" #'sessions-close
  "g" #'sessions--redraw)

(define-derived-mode sessions-pane-mode special-mode "Sessions"
  "Terminal sessions, grouped by host."
  (setq-local truncate-lines t)
  (setq-local cursor-type nil)
  (setq-local mode-line-format nil))

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
        (insert (propertize "Sessions" 'face 'bold) "\n")
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

(with-eval-after-load 'agents
  (add-hook 'agents-sidebar-panes #'sessions--sidebar-pane))

(provide 'sessions)
;;; sessions.el ends here
