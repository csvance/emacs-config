;;; revise-sync.el --- Run a remote Revise watcher for selected projects -*- lexical-binding: t; -*-

;;; Commentary:
;; When you open a file under one of `revise-sync-projects', this starts your
;; watcher script for that project (once per project, asynchronously).  When
;; the last buffer from that project is closed, the watcher is stopped.
;;
;; Commands:
;;   M-x revise-sync-status     show running watchers
;;   M-x revise-sync-restart    restart the watcher for the current project
;;   M-x revise-sync-stop-all   stop every watcher

;;; Code:

(require 'cl-lib)
(require 'format-spec)
(require 'subr-x)

(defgroup revise-sync nil
  "Run a remote Revise.jl watcher for selected projects."
  :group 'tools)

(defcustom revise-sync-command '("~/bin/revise-watch.sh" "%h" "%p")
  "Program and arguments used to start a watcher.
Placeholders: %h remote host, %p absolute project directory,
%n project name (last directory component)."
  :type '(repeat string))

(defcustom revise-sync-default-host nil
  "Remote host used for projects that do not name their own."
  :type '(choice (const :tag "None" nil) string))

(defcustom revise-sync-projects nil
  "Projects that get a watcher.
Each element is either a directory, or (DIRECTORY . HOST) to override
`revise-sync-default-host' for that project."
  :type '(repeat (choice directory (cons directory string))))

(defcustom revise-sync-stop-when-unused t
  "When non-nil, stop a watcher once no buffers from its project remain."
  :type 'boolean)

(defvar revise-sync--processes (make-hash-table :test #'equal)
  "Map from project root to its watcher process.")

(defvar-local revise-sync--root nil
  "Project root this buffer belongs to, if any.")

(defun revise-sync--normalize (dir)
  "Return DIR as an absolute, symlink-resolved directory name."
  (file-name-as-directory (file-truename (expand-file-name dir))))

(defun revise-sync--project-for (file)
  "Return (ROOT . HOST) for the most specific project containing FILE."
  (let ((true (file-truename file))
        best)
    (dolist (entry revise-sync-projects best)
      (let* ((dir  (if (consp entry) (car entry) entry))
             (host (or (and (consp entry) (cdr entry)) revise-sync-default-host))
             (root (revise-sync--normalize dir)))
        (when (and (string-prefix-p root true)
                   (or (null best) (> (length root) (length (car best)))))
          (setq best (cons root host)))))))

(defun revise-sync--command (root host)
  "Build the watcher command for ROOT on HOST."
  (let* ((dir  (directory-file-name root))
         (spec `((?h . ,host) (?p . ,dir) (?n . ,(file-name-nondirectory dir))))
         (args (mapcar (lambda (a) (format-spec a spec)) revise-sync-command))
         (prog (car args)))
    (cons (if (string-prefix-p "~" prog) (expand-file-name prog) prog)
          (cdr args))))

(defun revise-sync--running-p (root)
  "Return non-nil if a watcher for ROOT is alive."
  (let ((proc (gethash root revise-sync--processes)))
    (and proc (process-live-p proc))))

(defun revise-sync--sentinel (proc event)
  "Clean up after watcher PROC exits, reporting EVENT."
  (unless (process-live-p proc)
    (let ((root (process-get proc 'revise-sync-root)))
      (when (eq (gethash root revise-sync--processes) proc)
        (remhash root revise-sync--processes))
      (message "revise-sync: watcher for %s %s" root (string-trim event)))))

(defun revise-sync-start (root host)
  "Start the watcher for project ROOT on HOST unless already running."
  (unless (revise-sync--running-p root)
    (let* ((name (format "revise-sync:%s"
                         (file-name-nondirectory (directory-file-name root))))
           (default-directory root)
           (proc (make-process
                  :name name
                  :buffer (get-buffer-create (format "*%s*" name))
                  :command (revise-sync--command root host)
                  :noquery t
                  :sentinel #'revise-sync--sentinel)))
      (process-put proc 'revise-sync-root root)
      (puthash root proc revise-sync--processes)
      (message "revise-sync: started watcher for %s on %s" root host))))

(defun revise-sync-stop (root)
  "Stop the watcher for project ROOT, if any."
  (let ((proc (gethash root revise-sync--processes)))
    (remhash root revise-sync--processes)
    (when (and proc (process-live-p proc))
      ;; Ask politely so the script's cleanup traps run; force it if needed.
      (signal-process proc 'TERM)
      (run-at-time 3 nil (lambda ()
                           (when (process-live-p proc)
                             (delete-process proc)))))))

(defun revise-sync--maybe-start ()
  "Start a watcher if the current buffer's file is in a configured project."
  (when-let* ((file buffer-file-name)
              ((not (file-remote-p file)))
              (proj (revise-sync--project-for file)))
    (setq revise-sync--root (car proj))
    (if (cdr proj)
        (revise-sync-start (car proj) (cdr proj))
      (message "revise-sync: no host configured for %s" (car proj)))))

(defun revise-sync--maybe-stop ()
  "Stop the watcher if this is the last open buffer from its project."
  (when (and revise-sync-stop-when-unused revise-sync--root)
    (let ((root revise-sync--root)
          (me (current-buffer)))
      (unless (cl-some (lambda (b)
                         (and (not (eq b me))
                              (equal (buffer-local-value 'revise-sync--root b) root)))
                       (buffer-list))
        (revise-sync-stop root)))))

(defun revise-sync-status ()
  "Show which watchers are running."
  (interactive)
  (let (running)
    (maphash (lambda (root proc)
               (when (process-live-p proc) (push root running)))
             revise-sync--processes)
    (message (if running
                 (concat "revise-sync running: " (string-join running ", "))
               "revise-sync: no watchers running"))))

(defun revise-sync-restart ()
  "Restart the watcher for the current buffer's project."
  (interactive)
  (let ((proj (and buffer-file-name (revise-sync--project-for buffer-file-name))))
    (unless proj (user-error "This file is not in a revise-sync project"))
    (unless (cdr proj) (user-error "No host configured for %s" (car proj)))
    (revise-sync-stop (car proj))
    (revise-sync-start (car proj) (cdr proj))))

(defun revise-sync-stop-all ()
  "Stop every running watcher."
  (interactive)
  (dolist (root (hash-table-keys revise-sync--processes))
    (revise-sync-stop root)))

;;;###autoload
(define-minor-mode revise-sync-mode
  "Run a remote Revise watcher for files in `revise-sync-projects'."
  :global t
  (if revise-sync-mode
      (progn
        (add-hook 'find-file-hook #'revise-sync--maybe-start)
        (add-hook 'kill-buffer-hook #'revise-sync--maybe-stop)
        (dolist (buf (buffer-list))       ; pick up buffers already open
          (with-current-buffer buf (revise-sync--maybe-start))))
    (remove-hook 'find-file-hook #'revise-sync--maybe-start)
    (remove-hook 'kill-buffer-hook #'revise-sync--maybe-stop)
    (revise-sync-stop-all)))

(provide 'revise-sync)
;;; revise-sync.el ends here
