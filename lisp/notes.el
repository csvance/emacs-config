;;; notes.el --- Notes in ~/Git/notes, titled and tagged by a local model -*- lexical-binding: t; -*-

;;; Commentary:

;; Notes are Denote files: Markdown with YAML front matter, named
;; ID--title__tag1_tag2.md, so any tool can find them.  A new note starts
;; untitled; type and save.  On save, an untitled, untagged note goes to the
;; local model (vLLM on aidevnfs1, key in secrets/authinfo) in the background,
;; and its reply renames the file and fills in the front matter.  A title or
;; tags you set yourself are never replaced.  F4 opens the menu.

;;; Code:

(require 'denote)
(require 'gptel)
(require 'transient)

(declare-function consult-ripgrep "consult")

(defgroup notes nil
  "Notes titled and tagged by a local model."
  :group 'files)

(defcustom notes-min-length 40
  "Characters of text a note needs before the model is asked to title it."
  :type 'integer)

(setq denote-directory (expand-file-name "~/Git/notes/")
      denote-file-type 'markdown-yaml
      denote-prompts nil               ; a new note asks nothing
      denote-known-keywords nil)       ; tags come only from your notes

(defconst notes--host "aidevnfs1.medicalmetrics.local:18405"
  "The model server, also the machine name of its key in secrets/authinfo.")

(defvar notes-backend
  (gptel-make-openai "vLLM"
    :host notes--host
    :key (lambda () (gptel-api-key-from-auth-source notes--host))
    :protocol "https"
    :endpoint "/v1/chat/completions"
    :stream nil
    :models (list (intern "Qwen3.8-27B-FP8 (No Thinking)")))
  "The local model that titles and tags notes.")

(defconst notes--schema
  '(:type "object"
    :properties (:title (:type "string")
                 :tags (:type "array" :items (:type "string") :minItems 1 :maxItems 3))
    :required ["title" "tags"]
    :additionalProperties :json-false)
  "Shape of the model's reply.")

(defun notes--prompt ()
  "Instructions for the model, naming the tags already in use."
  (format "You title and tag personal technical notes. Reply with a title of at most
eight words that says what the note is about, and one to three short lowercase tags
(single words, no spaces). Reuse existing tags when they fit. Existing tags: %s"
          (or (string-join (denote-keywords) ", ") "none yet")))

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

(defun notes--apply (buffer file reply)
  "Rename FILE, shown in BUFFER, from the model's REPLY."
  (let* ((data (json-parse-string reply :object-type 'plist :array-type 'list))
         (title (string-trim (plist-get data :title)))
         (tags (seq-take (seq-remove #'string-empty-p
                                     (mapcar #'denote-sluggify-keyword (plist-get data :tags)))
                         3)))
    (with-current-buffer buffer
      (let ((denote-rename-confirmations nil)
            (denote-save-buffers t))
        (denote-rename-file file title tags 'keep-current 'keep-current 'keep-current))
      (message "Note titled: %s" title))))

(defun notes-title (&optional force)
  "Ask the local model to title and tag this note, in the background.
On save this runs only for an untitled, untagged note; with FORCE
\(interactively, always), retitle it anyway."
  (interactive (list t))
  (let ((file buffer-file-name)
        (buffer (current-buffer)))
    (when (and file (denote-file-is-in-denote-directory-p file)
               (denote-file-has-denoted-filename-p file)
               (or force (notes--untitled-p file))
               (not notes--pending)
               (>= (length (notes--body)) notes-min-length))
      (setq notes--pending t)
      (let ((gptel-backend notes-backend)
            (gptel-model (car (gptel-backend-models notes-backend)))
            (gptel-use-tools nil))
        (gptel-request (notes--body)
          :system (notes--prompt)
          :schema notes--schema
          :callback
          (lambda (reply info)
            (when (buffer-live-p buffer)
              (with-current-buffer buffer (setq notes--pending nil))
              (if (stringp reply)
                  (condition-case err
                      (notes--apply buffer (buffer-file-name buffer) reply)
                    (error (message "Could not title the note: %s" (error-message-string err))))
                (message "Could not title the note: %s" (plist-get info :status))))))))))

(defun notes--maybe-title ()
  "On save, title an untitled note in the background."
  (notes-title))

(add-hook 'after-save-hook #'notes--maybe-title)

(defun notes-new ()
  "Start an untitled note.  Saving it asks the model for a title and tags."
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
  "Notes in ~/Git/notes."
  [["Notes"
    ("n" "New note" notes-new)
    ("f" "Find a note" notes-find)
    ("s" "Search note text" notes-search)]
   ["This note"
    ("t" "Title and tag it now" notes-title)
    ("r" "Rename it yourself" denote-rename-file)]
   ["Folder"
    ("d" "Open ~/Git/notes" (lambda () (interactive) (dired denote-directory)))]])

(provide 'notes)
;;; notes.el ends here
