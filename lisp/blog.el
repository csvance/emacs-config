;;; blog.el --- The Quarto blog in ~/Git/csvance.github.io -*- lexical-binding: t; -*-

;;; Commentary:

;; Posts are Quarto files (.qmd): Markdown with YAML front matter and code
;; cells such as ```{julia}, which markdown-mode edits and highlights in their
;; own language.  F5 opens the menu: start a post, preview the one you are in
;; (Quarto serves it at a local URL and re-renders it each time it is saved),
;; render the whole site, or open the repository in Magit to publish.

;;; Code:

(require 'transient)

(declare-function magit-status "magit-status")

(defgroup blog nil
  "The Quarto blog."
  :group 'files)

(defcustom blog-directory (expand-file-name "~/Git/csvance.github.io/")
  "The blog's Quarto project: the directory holding _quarto.yml."
  :type 'directory)

(defun blog--root ()
  "The Quarto project holding this buffer's file, or else `blog-directory'."
  (or (and buffer-file-name (locate-dominating-file buffer-file-name "_quarto.yml"))
      blog-directory))

(defun blog--run (name &rest args)
  "Run quarto with ARGS from the project root, its output in *quarto NAME*."
  (let ((quarto (or (executable-find "quarto")
                    (user-error "Quarto is not on `exec-path'")))
        (default-directory (blog--root)))
    (with-current-buffer
        (compilation-start (mapconcat #'shell-quote-argument (cons quarto args) " ")
                           nil (lambda (_) (format "*quarto %s*" name)))
      (goto-address-mode 1))))          ; the preview URL is clickable

(defun blog-preview ()
  "Preview this post, or the whole site outside a post, in a browser.
Quarto re-renders the page each time it is saved; C-c C-k in the
*quarto preview* buffer stops it."
  (interactive)
  (if (and buffer-file-name (string-suffix-p ".qmd" buffer-file-name))
      (blog--run "preview" "preview" (file-relative-name buffer-file-name (blog--root)))
    (blog--run "preview" "preview")))

(defun blog-render ()
  "Render the whole site into _site."
  (interactive)
  (blog--run "render" "render"))

(defun blog-new-post (title)
  "Start a draft post titled TITLE in posts/DATE-SLUG/index.qmd."
  (interactive "sTitle: ")
  (let* ((date (format-time-string "%Y-%m-%d"))
         (slug (string-trim (replace-regexp-in-string "[^a-z0-9]+" "-" (downcase title))
                            "-+" "-+"))
         (file (expand-file-name (format "posts/%s-%s/index.qmd" date slug) blog-directory)))
    (when (string-empty-p slug)
      (user-error "The title needs a letter or digit"))
    (when (file-exists-p file)
      (user-error "%s already exists" (abbreviate-file-name file)))
    (make-directory (file-name-directory file) t)
    (find-file file)
    (insert (format "---\ntitle: %S\ndescription: \"\"\ndate: %s\ncategories: []\nengine: julia\ndraft: true\n---\n\n"
                    title date))))

(defun blog-find-post ()
  "Open a post, newest first."
  (interactive)
  (let* ((posts (expand-file-name "posts/" blog-directory))
         (dirs (and (file-directory-p posts)
                    (seq-filter (lambda (d) (file-exists-p (expand-file-name "index.qmd" d)))
                                (directory-files posts t "\\`[^._]"))))
         (names (mapcar #'file-name-nondirectory (reverse dirs))))
    (unless names
      (user-error "No posts yet: F5 n starts one"))
    (find-file (expand-file-name (concat (completing-read "Post: " names nil t) "/index.qmd")
                                 posts))))

(transient-define-prefix blog-menu ()
  "The Quarto blog."
  [["Posts"
    ("n" "New draft post" blog-new-post)
    ("f" "Find a post" blog-find-post)]
   ["Quarto"
    ("p" "Preview this post (or the site)" blog-preview)
    ("r" "Render the site" blog-render)]
   ["Repository"
    ("g" "Magit status, to publish" (lambda () (interactive) (magit-status blog-directory)))
    ("d" "Open the blog folder" (lambda () (interactive) (dired blog-directory)))]])

(provide 'blog)
;;; blog.el ends here
