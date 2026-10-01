;;; tui-mouse.el --- Forward the mouse to full-screen programs in vterm -*- lexical-binding: t; -*-

;;; Commentary:

;; vterm never passes the mouse to programs, so full-screen TUIs (agents,
;; multiplexers) cannot see clicks.  Watch the program's output for the
;; sequences that turn mouse reporting on and off, and while it is on, report
;; clicks, drags and the wheel as SGR sequences, as a real terminal would.
;; Elsewhere, such as at a shell prompt, the mouse keeps its Emacs behavior.
;;
;; `tui-mouse-mode' is on in every vterm buffer; turn it off (F1 M) to select a
;; TUI's text with the Emacs mouse instead.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'vterm)

(defvar-local tui-mouse--modes nil
  "Mouse reporting modes the program has turned on (1000, 1002, 1003, 1006).")

(defvar-local tui-mouse--output-tail ""
  "End of the previous output, in case a mode sequence was split across two.")

(defvar-local tui-mouse--rows nil
  "Height of the terminal screen in rows.")

(defun tui-mouse--track-modes (process output)
  "Record the mouse reporting modes that OUTPUT from PROCESS turns on or off."
  (when-let* ((buf (process-buffer process))
              ((buffer-live-p buf)))
    (with-current-buffer buf
      (let ((text (concat tui-mouse--output-tail output))
            (start 0))
        ;; DECSET/DECRST (ESC [ ? N h, ESC [ ? N l) or a full reset (ESC c)
        (while (string-match "\e\\(?:\\[\\?\\([0-9;]+\\)\\([hl]\\)\\|c\\)" text start)
          (if (not (match-beginning 1))
              (setq tui-mouse--modes nil)
            (dolist (mode (mapcar #'string-to-number (split-string (match-string 1 text) ";")))
              (when (memq mode '(1000 1002 1003 1006))
                (setq tui-mouse--modes (delq mode tui-mouse--modes))
                (when (equal (match-string 2 text) "h")
                  (push mode tui-mouse--modes)))))
          (setq start (match-end 0)))
        (setq tui-mouse--output-tail (substring output (max 0 (- (length output) 16))))))))

(advice-add 'vterm--filter :before #'tui-mouse--track-modes)

(defun tui-mouse--record-size (resize process windows)
  "Call RESIZE with PROCESS and WINDOWS, remembering the screen height it sets."
  (let ((size (funcall resize process windows)))
    (when (and size (processp process) (buffer-live-p (process-buffer process)))
      (with-current-buffer (process-buffer process)
        (setq tui-mouse--rows (cdr size))))
    size))

(advice-add 'vterm--window-adjust-process-window-size :around #'tui-mouse--record-size)

(defun tui-mouse--screen-start ()
  "Position of the terminal screen's top row in the current vterm buffer.
The screen is the last `tui-mouse--rows' lines, followed by one empty line;
everything above it is scrollback."
  (save-excursion
    (goto-char (point-max))
    (forward-line (- (or tui-mouse--rows (window-body-height))))
    (point)))

(defun tui-mouse--active-p ()
  "Non-nil when the program in this terminal wants SGR mouse reports."
  (and (bound-and-true-p tui-mouse-mode)
       (not vterm-copy-mode)
       (memq 1006 tui-mouse--modes)
       (seq-some (lambda (mode) (memq mode tui-mouse--modes)) '(1000 1002 1003))))

(defun tui-mouse--cell (posn)
  "Return the 1-based terminal (COLUMN . ROW) under mouse position POSN.
Counts buffer lines and columns rather than pixels, since lines drawn with a
fallback font can be taller or narrower than the rest."
  (with-current-buffer (window-buffer (posn-window posn))
    (save-excursion
      (goto-char (or (posn-point posn) (point-max)))
      (let ((row (- (line-number-at-pos) (line-number-at-pos (tui-mouse--screen-start)) -1))
            ;; Past the end of a line there is no text; count cells from the pixels
            (col (if (and (eolp) (> (car (posn-col-row posn t)) (current-column)))
                     (- (car (posn-col-row posn t)) (vterm--get-margin-width))
                   (current-column))))
        (cons (1+ col)
              (max 1 (min row (or tui-mouse--rows row))))))))

(defun tui-mouse--send (button posn final)
  "Report mouse BUTTON at POSN to the program; FINAL is ?M (press) or ?m (release)."
  (let ((cell (tui-mouse--cell posn)))
    (with-current-buffer (window-buffer (posn-window posn))
      ;; One write, so the program cannot mistake the leading ESC for the Escape key
      (process-send-string vterm--process (format "\e[<%d;%d;%d%c" button
                                                  (car cell) (cdr cell) final)))))

(defun tui-mouse--press (button)
  "Return a command that reports a press of BUTTON, the drag, then the release."
  (lambda (event)
    (interactive "e")
    (let* ((posn (event-start event))
           (win (posn-window posn))
           (cell (tui-mouse--cell posn))
           ev)
      (select-window win)
      (tui-mouse--send button posn ?M)
      ;; Report motion while the button is held, for dragging pane borders or
      ;; selecting text, if the program asked for it (modes 1002 and 1003)
      (track-mouse
        (while (mouse-movement-p (setq ev (read-event)))
          (let ((pos (event-start ev)))
            (when (and (eq (posn-window pos) win)
                       (seq-some (lambda (mode) (memq mode tui-mouse--modes)) '(1002 1003))
                       (not (equal cell (tui-mouse--cell pos))))
              (setq posn pos
                    cell (tui-mouse--cell pos))
              (tui-mouse--send (+ 32 button) pos ?M)))))
      (if (and (memq (event-basic-type ev) '(mouse-1 mouse-2 mouse-3))
               (not (memq 'down (event-modifiers ev))))
          (tui-mouse--send button (if (eq (posn-window (event-end ev)) win)
                                           (event-end ev)
                                         posn)
                                ?m)
        ;; Something other than the release (a key): release here, then handle it
        (tui-mouse--send button posn ?m)
        (push ev unread-command-events)))))

(defun tui-mouse--wheel (button)
  "Return a command that reports wheel BUTTON (64 up, 65 down)."
  (lambda (event)
    (interactive "e")
    (tui-mouse--send button (event-start event) ?M)))

(defun tui-mouse--filter (command)
  "Return COMMAND while the program wants mouse reports.
Else return nil, so Emacs handles the event."
  (and (tui-mouse--active-p) command))

(define-minor-mode tui-mouse-mode
  "Forward the mouse to the program in this terminal whenever it asks for it.
On in every terminal; turn it off to select a TUI's text with the Emacs mouse."
  :lighter (:eval (when (tui-mouse--active-p) " Mouse"))
  :keymap
  (let ((map (make-sparse-keymap)))
    (cl-flet ((bind (event command)
                (define-key map (vector event)
                            `(menu-item "" ,command :filter tui-mouse--filter))))
      (pcase-dolist (`(,n . ,button) '((1 . 0) (2 . 1) (3 . 2)))
        (dolist (prefix '("" "double-" "triple-"))
          (bind (intern (format "%sdown-mouse-%d" prefix n)) (tui-mouse--press button))
          ;; The press command already reported the release
          (bind (intern (format "%smouse-%d" prefix n)) #'ignore))
        (bind (intern (format "drag-mouse-%d" n)) #'ignore))
      ;; Fast scrolling sends double-/triple- wheel events; forward those too
      (dolist (prefix '("" "double-" "triple-"))
        (bind (intern (concat prefix "wheel-up")) (tui-mouse--wheel 64))
        (bind (intern (concat prefix "wheel-down")) (tui-mouse--wheel 65))))
    map))

(add-hook 'vterm-mode-hook
          (lambda ()
            (setq tui-mouse--rows (window-body-height)) ; the size vterm starts with
            (tui-mouse-mode 1)))

(provide 'tui-mouse)
;;; tui-mouse.el ends here
