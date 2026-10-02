;;; notes.el --- Notes in ~/Notes, titled and tagged by a local model -*- lexical-binding: t; -*-

;;; Commentary:

;; Notes are Denote files: Markdown with YAML front matter, named
;; ID--title__tag1_tag2.md, so any tool can find them.  A new note starts
;; untitled; type, and it is titled when you save it with C-x C-s or leave it
;; unedited for `notes-title-idle-delay' seconds.  The saves that
;; `auto-save-visited-mode' makes every few seconds do not count, or a note
;; would be titled from its first sentence.  An untitled, untagged note goes
;; to the local model (lisp/local-llm.el) in the background, and its reply
;; renames the file and fills in the front matter.  A title or tags you set
;; yourself are never replaced.  F4 opens the menu; F4 u titles every note
;; that was closed before either happened.

;;; Code:

(require 'denote)
(require 'local-llm)
(require 'transient)

(declare-function consult-ripgrep "consult")

(defgroup notes nil
  "Notes titled and tagged by a local model."
  :group 'files)

(defcustom notes-min-length 40
  "Characters of text a note needs before the model is asked to title it."
  :type 'integer)

(setq denote-directory (expand-file-name "~/Notes/")
      denote-file-type 'markdown-yaml
      denote-prompts nil               ; a new note asks nothing
      denote-known-keywords nil)       ; tags come only from your notes

(defcustom notes-title-idle-delay 90
  "Seconds a note goes unedited before it is titled, if it is still untitled."
  :type 'integer)

(defcustom notes-prompt-tag-limit 40
  "How many of the most used tags the model is shown."
  :type 'integer)

(defconst notes--schema
  '(:type "object"
    :properties (:title (:type "string" :maxLength 80)
                 :tags (:type "array" :items (:type "string") :minItems 1 :maxItems 3))
    :required ["title" "tags"]
    :additionalProperties :json-false)
  "Shape of the model's reply.")

(defun notes--prompt ()
  "Instructions for the model, naming the tags already in use."
  (format "You title and tag personal technical notes. Reply with a title of at most
eight words that says what the note is about, and one to three short lowercase tags
(single words, no spaces). Reuse existing tags when they fit. Existing tags: %s"
          (if-let* ((tags (notes--common-tags))) (string-join tags ", ") "none yet")))

(defun notes--common-tags ()
  "The `notes-prompt-tag-limit' most used tags, most used first."
  (let ((counts (make-hash-table :test #'equal))
        pairs)
    (dolist (file (denote-directory-files nil nil t))
      (dolist (tag (denote-extract-keywords-from-path file))
        (puthash tag (1+ (gethash tag counts 0)) counts)))
    (maphash (lambda (tag n) (push (cons tag n) pairs)) counts)
    (seq-take (mapcar #'car (sort pairs (lambda (a b) (> (cdr a) (cdr b)))))
              notes-prompt-tag-limit)))

(defun notes--body ()
  "The note's text, without its front matter."
  (save-excursion
    (goto-char (point-min))
    (when (looking-at "---\n")
      (re-search-forward "^---\n" nil t 2))
    (string-trim (buffer-substring-no-properties (point) (point-max)))))

(defvar-local notes--pending nil
  "Non-nil while a request to title this note is in flight.")

(defun notes--untitled-p (file)
  "Non-nil if FILE has neither a title nor tags."
  (and (not (denote-retrieve-filename-title file))
       (not (denote-retrieve-filename-keywords file))))

(defun notes--clamp-title (title)
  "TITLE trimmed to eight words and 80 characters."
  (let ((short (string-join (seq-take (split-string (or title "")) 8) " ")))
    (truncate-string-to-width short 80)))

(defun notes--apply (buffer file data)
  "Rename FILE, shown in BUFFER, from the model's reply DATA."
  (let* ((title (notes--clamp-title (plist-get data :title)))
         (tags (seq-take (seq-remove #'string-empty-p
                                     (mapcar #'denote-sluggify-keyword (plist-get data :tags)))
                         3)))
    (when (string-empty-p title)
      (error "The model gave no title"))
    (with-current-buffer buffer
      (let ((denote-rename-confirmations nil)
            (denote-save-buffers t))
        (denote-rename-file file title tags 'keep-current 'keep-current 'keep-current))
      (message "Note titled: %s" title))))

(defun notes--request (buffer force &optional done)
  "Title the note in BUFFER in the background; non-nil if a request was sent.
Only an untitled, untagged note is sent, unless FORCE.  DONE, if given, is
called once the reply is handled, with non-nil if the note was renamed."
  (with-current-buffer buffer
    (let ((file buffer-file-name))
      (when (and (local-llm-available-p)
                 file (denote-file-is-in-denote-directory-p file)
                 (denote-file-has-denoted-filename-p file)
                 (or force (notes--untitled-p file))
                 (not notes--pending)
                 (>= (length (notes--body)) notes-min-length))
        (setq notes--pending t)
        (local-llm-request
         (notes--body) (notes--prompt) notes--schema
         (lambda (data problem)
           (let ((titled nil))
             (when (buffer-live-p buffer)
               (with-current-buffer buffer (setq notes--pending nil))
               (let ((file (buffer-file-name buffer)))
                 (cond
                  (problem (message "Could not title the note: %s" problem))
                  ;; A title or tags you set while the request was out are kept
                  ((and file (or force (notes--untitled-p file)))
                   (condition-case err
                       (progn (notes--apply buffer file data)
                              (setq titled t))
                     (error (message "Could not title the note: %s"
                                     (error-message-string err))))))))
             (when done (funcall done titled)))))
        t))))

(defun notes-title (&optional force)
  "Ask the local model to title and tag this note, in the background.
Without FORCE this runs only for an untitled, untagged note; with FORCE
\(interactively, always), retitle it anyway."
  (interactive (list t))
  (notes--request (current-buffer) force))

(defun notes-save ()
  "Save the note, then title it if it is still untitled."
  (interactive)
  (save-buffer)
  (notes-title))

(defvar-local notes--idle-timer nil
  "Timer that titles this note once it has gone unedited for a while.")

(defun notes--cancel-timer ()
  "Cancel this note's titling timer."
  (when (timerp notes--idle-timer)
    (cancel-timer notes--idle-timer)
    (setq notes--idle-timer nil)))

(defun notes--schedule (&rest _)
  "After an edit, restart this note's titling timer."
  (notes--cancel-timer)
  (setq notes--idle-timer
        (run-with-timer notes-title-idle-delay nil #'notes--idle-fire (current-buffer))))

(defun notes--idle-fire (buffer)
  "Title the note in BUFFER, which has gone unedited for a while."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq notes--idle-timer nil)
      (notes-title))))

(defvar notes-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap save-buffer] #'notes-save)
    map)
  "Keymap for `notes-mode': C-x C-s also titles an untitled note.")

(define-minor-mode notes-mode
  "Title this untitled note on C-x C-s or after it goes unedited for a while."
  :lighter " Note"
  (if notes-mode
      (progn (add-hook 'after-change-functions #'notes--schedule nil t)
             (add-hook 'kill-buffer-hook #'notes--cancel-timer nil t))
    (remove-hook 'after-change-functions #'notes--schedule t)
    (remove-hook 'kill-buffer-hook #'notes--cancel-timer t)
    (notes--cancel-timer)))

(defun notes--maybe-enable ()
  "Turn on `notes-mode' in a note."
  (when (and buffer-file-name
             (denote-file-is-in-denote-directory-p buffer-file-name)
             (denote-file-has-denoted-filename-p buffer-file-name))
    (notes-mode 1)))

(add-hook 'find-file-hook #'notes--maybe-enable)

(defun notes-title-untitled ()
  "Title every untitled note, one at a time, in the background."
  (interactive)
  (let ((files (seq-filter (lambda (f) (and (denote-file-has-denoted-filename-p f)
                                            (notes--untitled-p f)))
                           (denote-directory-files nil nil t))))
    (if files
        (progn (message "Titling %d untitled notes..." (length files))
               (notes--sweep files 0))
      (message "No untitled notes"))))

(defun notes--sweep (files count)
  "Title FILES one after another; COUNT have been titled so far."
  (if (null files)
      (message "Titled %d notes" count)
    (let* ((open (find-buffer-visiting (car files)))
           (buffer (or open (find-file-noselect (car files))))
           (next (lambda (titled)
                   ;; Close what the sweep opened, unless it has unsaved edits
                   (when (and (not open) (buffer-live-p buffer)
                              (not (buffer-modified-p buffer)))
                     (kill-buffer buffer))
                   (notes--sweep (cdr files) (if titled (1+ count) count)))))
      (unless (notes--request buffer nil next)
        (funcall next nil)))))

(defun notes-new ()
  "Start an untitled note.  The model titles and tags it when you save it."
  (interactive)
  (make-directory denote-directory t)
  (denote "" nil))

(defun notes-find ()
  "Open a note, narrowing by title and tags (type __tag to filter by a tag)."
  (interactive)
  (let* ((files (denote-directory-files nil nil t))
         (names (mapcar (lambda (f) (cons (file-name-nondirectory f) f)) (reverse files))))
    (if names
        (find-file (cdr (assoc (completing-read "Note: " names nil t) names)))
      (user-error "No notes yet: F4 n starts one"))))

(defun notes-search ()
  "Search the text of all notes."
  (interactive)
  (consult-ripgrep denote-directory))

(transient-define-prefix notes-menu ()
  "Notes in ~/Notes."
  [["Notes"
    ("n" "New note" notes-new)
    ("f" "Find a note" notes-find)
    ("s" "Search note text" notes-search)
    ("u" "Title untitled notes" notes-title-untitled)]
   ["This note"
    ("t" "Title and tag it now" notes-title)
    ("r" "Rename it yourself" denote-rename-file)]
   ["Folder"
    ("d" "Open ~/Notes" (lambda () (interactive) (dired denote-directory)))]])

(provide 'notes)
;;; notes.el ends here
