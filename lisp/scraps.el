;;; scraps.el --- Short-lived blocks of text, kept as tabs until you close them -*- lexical-binding: t; -*-

;;; Commentary:

;; A scrap is a block of text kept for reference until you close it: a command,
;; a path, a reply to copy back out.  Each is a buffer backed by a file in
;; `scraps-directory', saved as you type, so scraps survive a restart, and a tab
;; line across the top of a scrap's window lists them all.  F3 opens a menu: a
;; new scrap from the latest kill (so whatever a program copied), visit one by
;; number, copy one out, close one or close them all.  Closing deletes the file
;; (to the trash); the title, from the local model (lisp/local-llm.el), is kept
;; in the file name.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)
(require 'tab-line)

(declare-function local-llm-available-p "local-llm")
(declare-function local-llm-request "local-llm")

(defgroup scraps nil
  "Short-lived blocks of text, kept as tabs until you close them."
  :group 'convenience)

(defcustom scraps-directory (locate-user-emacs-file "scraps/")
  "Directory of the scraps' files."
  :type 'directory)

(defcustom scraps-auto-title t
  "Whether the local model titles a scrap from its text."
  :type 'boolean)

(defcustom scraps-title-context 4000
  "Characters from the start of a scrap that the model sees."
  :type 'integer)

;;;; Files: TIMESTAMP.txt, or TIMESTAMP--TITLE.txt once titled

(defun scraps--files ()
  "The scraps' files, oldest first."
  (when (file-directory-p scraps-directory)
    (directory-files scraps-directory t "\\`[0-9]\\{8\\}T[0-9]\\{6\\}.*\\.txt\\'")))

(defun scraps--file-p (file)
  "Non-nil if FILE is a scrap's file."
  (and file (file-in-directory-p file scraps-directory)
       (string-suffix-p ".txt" file)))

(defun scraps--file-title (file)
  "The title in FILE's name, or nil if it has none yet."
  (let ((base (file-name-base file)))
    (when (string-match "--\\(.+\\)\\'" base) (match-string 1 base))))

(defun scraps--stamp (file)
  "The timestamp that starts FILE's name."
  (substring (file-name-base file) 0 15))

;;;; Buffers

(defvar-local scraps--pending nil
  "Non-nil while a title request for this scrap is out.")

(defvar-local scraps--save-timer nil
  "Timer that saves this scrap once you pause typing.")

(defun scraps--buffers ()
  "Every scrap's buffer, oldest first, loading the files not open yet."
  (mapcar (lambda (file) (or (get-file-buffer file) (find-file-noselect file)))
          (scraps--files)))

(defun scraps--first-line ()
  "The current scrap's first line with text, shortened, or \"empty\"."
  (save-excursion
    (goto-char (point-min))
    (skip-chars-forward " \t\n")
    (let ((line (string-trim (buffer-substring-no-properties (point) (line-end-position)))))
      (if (string-empty-p line) "empty" (truncate-string-to-width line 24 nil nil "…")))))

(defun scraps--label (buffer)
  "What BUFFER's tab and menu entry say: its title, else its first line."
  (with-current-buffer buffer
    (or (scraps--file-title buffer-file-name) (scraps--first-line))))

(defun scraps--save-soon ()
  "Save this scrap after a pause, without a message."
  (when (timerp scraps--save-timer) (cancel-timer scraps--save-timer))
  (let ((buf (current-buffer)))
    (setq scraps--save-timer
          (run-with-idle-timer 1 nil (lambda ()
                                       (when (buffer-live-p buf)
                                         (with-current-buffer buf (scraps--save))))))))

(defun scraps--save ()
  "Save this scrap now, if it changed."
  (when (and (buffer-modified-p) buffer-file-name)
    (let ((inhibit-message t)) (save-buffer))))

(defun scraps--save-all ()
  "Save every open scrap (on exit, so nothing waits on a timer)."
  (dolist (buf (buffer-list))
    (when (buffer-local-value 'scraps-mode buf)
      (with-current-buffer buf (scraps--save)))))

(add-hook 'kill-emacs-hook #'scraps--save-all)

(defun scraps--tab-name (buffer &optional _buffers)
  "Tab name of BUFFER: its number, for F3, and its label."
  (format " %d %s " (1+ (or (cl-position buffer (scraps--buffers)) 0)) (scraps--label buffer)))

(defvar-keymap scraps-mode-map
  "<remap> <kill-buffer>" #'scraps-close
  "<remap> <kill-current-buffer>" #'scraps-close)

(define-minor-mode scraps-mode
  "A scrap: saved as you type, listed in a tab line, deleted when you close it."
  :lighter " Scrap"
  (when scraps-mode
    (setq-local tab-line-tabs-function #'scraps--buffers
                tab-line-tab-name-function #'scraps--tab-name
                tab-line-close-tab-function #'scraps-close
                tab-line-new-tab-choice #'scraps-new
                buffer-offer-save nil)
    (tab-line-mode 1)
    (add-hook 'after-change-functions (lambda (&rest _) (scraps--save-soon)) nil t)
    (rename-buffer (generate-new-buffer-name
                    (format "*scrap: %s*" (or (scraps--file-title buffer-file-name)
                                              (scraps--stamp buffer-file-name)))))))

(defun scraps--maybe-enable ()
  "Turn on `scraps-mode' in a scrap's file."
  (when (scraps--file-p buffer-file-name) (scraps-mode 1)))

(add-hook 'find-file-hook #'scraps--maybe-enable)

;;;; Commands

(defun scraps--create (text)
  "Make a scrap holding TEXT, show it, and return its buffer."
  (make-directory scraps-directory t)
  (let* ((time (current-time))
         file
         (stamp (format-time-string "%Y%m%dT%H%M%S" time)))
    ;; Each scrap's timestamp is its own, titled or not, even for two in one second
    (while (directory-files scraps-directory nil (concat "\\`" stamp))
      (setq time (time-add time 1)
            stamp (format-time-string "%Y%m%dT%H%M%S" time)))
    (setq file (expand-file-name (concat stamp ".txt") scraps-directory))
    (write-region text nil file nil 'silent)
    (let ((buf (find-file-noselect file)))
      (when (window-parameter nil 'window-side)
        (when-let* ((win (get-mru-window nil nil nil t))) (select-window win)))
      (switch-to-buffer buf)
      (goto-char (point-max))
      buf)))

(defun scraps-new ()
  "Open a new, empty scrap."
  (interactive)
  (scraps--create ""))

(defun scraps-from-kill ()
  "Open a new scrap holding the latest kill.
That includes text another program copied, such as a TUI that copies on select."
  (interactive)
  (let ((text (or (ignore-errors (current-kill 0)) (user-error "Nothing has been copied"))))
    (scraps-title (scraps--create (substring-no-properties text)))))

(defun scraps-append-kill ()
  "Add the latest kill to the end of this scrap, on a line of its own."
  (interactive)
  (unless scraps-mode (user-error "Not in a scrap"))
  (let ((text (or (ignore-errors (current-kill 0)) (user-error "Nothing has been copied"))))
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (insert (substring-no-properties text))))

(defun scraps-visit (n)
  "Visit scrap number N (from 1), as the tab line numbers them."
  (let ((buf (nth (1- n) (scraps--buffers))))
    (unless buf (user-error "No scrap %d" n))
    (when (window-parameter nil 'window-side)
      (when-let* ((win (get-mru-window nil nil nil t))) (select-window win)))
    (switch-to-buffer buf)))

(defun scraps-copy (&optional buffer)
  "Copy BUFFER's scrap (this one, interactively) whole, to paste elsewhere."
  (interactive)
  (let ((buf (or buffer (current-buffer))))
    (unless (buffer-local-value 'scraps-mode buf) (user-error "Not in a scrap"))
    (with-current-buffer buf
      (kill-new (string-trim (buffer-substring-no-properties (point-min) (point-max)))))
    (message "Copied scrap: %s" (scraps--label buf))))

(defun scraps-copy-number (n)
  "Copy scrap number N (from 1) whole, as the tab line numbers them."
  (scraps-copy (or (nth (1- n) (scraps--buffers)) (user-error "No scrap %d" n))))

(defun scraps-close (&optional buffer)
  "Close BUFFER's scrap (this one, interactively): kill it and trash its file."
  (interactive)
  (let ((buf (or buffer (current-buffer))))
    (unless (buffer-local-value 'scraps-mode buf) (user-error "Not a scrap"))
    (let* ((file (buffer-file-name buf))
           (all (scraps--buffers))
           (others (remq buf all))
           ;; The scrap after this one takes its place, else the one before
           (next (nth (min (or (cl-position buf all) 0) (1- (length others))) others))
           (wins (get-buffer-window-list buf nil t)))
      (with-current-buffer buf
        (when (timerp scraps--save-timer) (cancel-timer scraps--save-timer))
        (set-buffer-modified-p nil))
      ;; Show the next scrap in its place, so closing several in a row stays among them
      (dolist (win wins)
        (if next (set-window-buffer win next)
          (with-selected-window win (switch-to-prev-buffer win 'kill))))
      (kill-buffer buf)
      (when (and file (file-exists-p file))
        (let ((delete-by-moving-to-trash t)) (delete-file file t))))))

(defun scraps-close-all ()
  "Close every scrap, after one confirmation."
  (interactive)
  (let ((bufs (scraps--buffers)))
    (unless bufs (user-error "No scraps"))
    (when (yes-or-no-p (format "Close all %d scraps? " (length bufs)))
      (mapc #'scraps-close bufs)
      (message "Closed %d scrap%s (moved to the trash)"
               (length bufs) (if (cdr bufs) "s" "")))))

;;;; Titles: the local model names a scrap from its text

(defconst scraps--title-schema
  '(:type "object"
    :properties (:title (:type "string" :maxLength 40))
    :required ["title"]
    :additionalProperties :json-false)
  "Shape of the model's reply.")

(defconst scraps--title-prompt
  "You title short blocks of text kept for reference: commands, paths, logs, replies,
snippets of code or config. Reply with a title of two to five words that says what the
text is, such as \"kubectl pod listing\" or \"Comet API key steps\". If there is too little
text to tell, reply with an empty title."
  "Instructions for the model.")

(defun scraps--retitle-file (buffer title)
  "Put TITLE in BUFFER's file name and buffer name."
  (with-current-buffer buffer
    (let* ((clean (string-trim (replace-regexp-in-string "[/\\\\\n\t:*?\"<>|]+" " " title)))
           (new (expand-file-name (format "%s--%s.txt" (scraps--stamp buffer-file-name) clean)
                                  scraps-directory)))
      (unless (or (string-empty-p clean) (equal new buffer-file-name))
        (scraps--save)
        (rename-file buffer-file-name new t)
        (set-visited-file-name new t t)
        (rename-buffer (generate-new-buffer-name (format "*scrap: %s*" clean)))
        (force-mode-line-update t)))))

(defun scraps-title (&optional buffer)
  "Ask the local model to title BUFFER's scrap (this one, interactively).
The request runs in the background; the title goes in the file and buffer names."
  (interactive)
  (let ((buf (or buffer (current-buffer))))
    (with-current-buffer buf
      (unless scraps-mode (user-error "Not a scrap"))
      (let ((text (string-trim (buffer-substring-no-properties
                                (point-min) (min (point-max) (+ (point-min) scraps-title-context))))))
        (when (and scraps-auto-title (not scraps--pending)
                   (not (string-empty-p text))
                   (require 'local-llm nil t) (local-llm-available-p))
          (setq scraps--pending t)
          (local-llm-request
           text scraps--title-prompt scraps--title-schema
           (lambda (data problem)
             (when (buffer-live-p buf)
               (with-current-buffer buf (setq scraps--pending nil))
               (let ((title (string-trim (or (plist-get data :title) ""))))
                 (cond (problem (message "Could not title the scrap: %s" problem))
                       ;; Too little to tell yet: try again the next time you leave it
                       ((string-empty-p title))
                       (t (scraps--retitle-file buf title))))))))))
    buf))

(defvar scraps--current nil
  "The buffer of the selected window, as of the last window change.")

(defun scraps--note-leaving (&rest _)
  "Title the scrap you just left, if it has no title yet."
  (let ((buf (window-buffer (selected-window))))
    (unless (or (eq buf scraps--current) (minibufferp buf))
      (let ((left scraps--current))
        (setq scraps--current buf)
        (when (and (buffer-live-p left)
                   (buffer-local-value 'scraps-mode left)
                   (not (scraps--file-title (buffer-file-name left))))
          (scraps-title left))))))

(add-hook 'window-selection-change-functions #'scraps--note-leaving)
(add-hook 'window-buffer-change-functions #'scraps--note-leaving)

;;;; F3 menu

(defun scraps--numbered (prefix action)
  "Entries 1 to 9 of menu PREFIX, one per scrap, calling ACTION with its number."
  (transient-parse-suffixes
   prefix
   (cl-loop for buf in (scraps--buffers)
            for i from 1 to 9
            collect (let ((i i))
                      (list (number-to-string i) (scraps--label buf)
                            (lambda () (interactive) (funcall action i)))))))

(defun scraps--menu-scraps (_children)
  "Entries that visit a scrap."
  (scraps--numbered 'scraps-menu #'scraps-visit))

(defun scraps--copy-menu-scraps (_children)
  "Entries that copy a scrap."
  (scraps--numbered 'scraps-copy-menu #'scraps-copy-number))

(defun scraps--in-scrap-p ()
  "Non-nil in a scrap's buffer."
  (bound-and-true-p scraps-mode))

(transient-define-prefix scraps-copy-menu ()
  "Copy a scrap whole, without visiting it."
  [["Copy" :class transient-column :setup-children scraps--copy-menu-scraps]]
  [("c" "This scrap" scraps-copy :if scraps--in-scrap-p)])

(transient-define-prefix scraps-menu ()
  "Scraps: short-lived blocks of text."
  [["Scraps" :class transient-column :setup-children scraps--menu-scraps]]
  [["New"
    ("y" "From the latest copy" scraps-from-kill)
    ("n" "Empty" scraps-new)]
   ["Copy"
    ("c" "Copy a scrap..." scraps-copy-menu)]
   ["This scrap"
    ("a" "Append the latest copy" scraps-append-kill :if scraps--in-scrap-p)
    ("t" "Retitle" scraps-title :if scraps--in-scrap-p)
    ("k" "Close" scraps-close :if scraps--in-scrap-p)]
   ["All"
    ("K" "Close all scraps" scraps-close-all)]])

(provide 'scraps)
;;; scraps.el ends here
