;;; agents.el --- Campfire agents in Emacs, one buffer each -*- lexical-binding: t; -*-

;; Every Claude Code agent of a campfire session gets its own Emacs buffer: a vterm attached to
;; the agent's herdr pane.  A status pane below Treemacs lists the agents by project, and F2 opens
;; a menu to visit, start and stop them.  Everything goes through `campfire herdr ARGS', over SSH
;; for remote hosts, so the session itself (sandbox, herdr server, persistence) stays campfire's.
;; Design: agents-design.md in this directory.

(require 'cl-lib)
(require 'subr-x)
(require 'project)
(require 'transient)

(defvar vterm-shell)                    ; bound around `vterm', which is loaded on demand
(declare-function vterm "vterm")
(declare-function treemacs "treemacs")
(declare-function treemacs-current-visibility "treemacs")
(declare-function treemacs-get-local-window "treemacs")

(defgroup agents nil
  "Campfire agents, one Emacs buffer each."
  :group 'tools)

(defcustom agents-hosts nil
  "Hosts running a campfire session, as a list of plists.
Each has :name (a short label) and optionally :ssh (the SSH destination;
omit it for this machine), :profile (the sandbox profile, to use a
session other than the one the host's campfire profile names) and
:campfire (the command words that run campfire there, when it is not
`campfire' on the PATH)."
  :type '(repeat plist))

(defcustom agents-poll-interval 3
  "Seconds between status polls of a host whose event stream is down."
  :type 'number)

(defcustom agents-stream-poll-interval 30
  "Seconds between full refreshes of a host whose event stream is up.
The stream carries status changes as they happen; this catches the rest,
such as agents' titles."
  :type 'number)

(defcustom agents-pane-height 0.3
  "Height of the status pane below Treemacs, as a fraction of the frame."
  :type 'number)

(defcustom agents-command "claude-sandbox"
  "Command a new agent's pane runs."
  :type 'string)

;;;; Transport

(defun agents--control-path ()
  "SSH control socket path, on local disk rather than the NFS home."
  (expand-file-name "agents-ssh-%C" (or (getenv "XDG_RUNTIME_DIR") temporary-file-directory)))

(defun agents--campfire-argv (host args)
  "Command words running `campfire ARGS' for HOST's session."
  (append (when-let* ((profile (plist-get host :profile)))
            (list "env" (concat "HERDR_SANDBOX_PROFILE=" profile)))
          (or (plist-get host :campfire) '("campfire"))
          args))

(defun agents--command (host words &optional tty)
  "Local command list that runs WORDS (a list, or a shell string) on HOST.
With TTY non-nil, the remote side gets a terminal (for `agent attach')."
  (if-let* ((dest (plist-get host :ssh)))
      (append (list "ssh" "-o" "ControlMaster=auto"
                    "-o" (concat "ControlPath=" (agents--control-path))
                    "-o" "ControlPersist=10m")
              (if tty '("-t") '("-o" "BatchMode=yes"))
              (list dest (if (stringp words) words (mapconcat #'shell-quote-argument words " "))))
    (if (stringp words) (list shell-file-name "-c" words) words)))

(defun agents--run (host words callback)
  "Run WORDS on HOST asynchronously; call CALLBACK with OK, STDOUT and STDERR."
  (let ((out (generate-new-buffer " *agents-out*"))
        (err (generate-new-buffer " *agents-err*")))
    (make-process
     :name "agents" :buffer out :stderr err :noquery t :connection-type 'pipe
     :command (agents--command host words)
     :sentinel (lambda (proc _event)
                 (unless (process-live-p proc)
                   (let ((ok (zerop (process-exit-status proc)))
                         (stdout (with-current-buffer out (buffer-string)))
                         (stderr (with-current-buffer err (buffer-string))))
                     (kill-buffer out)
                     (let ((errproc (get-buffer-process err)))
                       (when errproc (delete-process errproc)))
                     (kill-buffer err)
                     (funcall callback ok stdout stderr)))))))

(defun agents--herdr (host args callback)
  "Run `campfire herdr ARGS' on HOST; call CALLBACK with OK, RESULT and ERROR.
RESULT is the response's `result' object as a plist, or nil for verbs that
answer nothing."
  (agents--run host (agents--campfire-argv host (cons "herdr" args))
               (lambda (ok stdout stderr)
                 (let* ((line (car (last (seq-filter (lambda (l) (string-prefix-p "{" l))
                                                     (split-string stdout "\n" t)))))
                        (json (and line (ignore-errors
                                          (json-parse-string line :object-type 'plist
                                                             :array-type 'list
                                                             :null-object nil :false-object nil)))))
                   (funcall callback ok (plist-get json :result)
                            (unless ok (string-trim (if (string-empty-p (string-trim stderr))
                                                        stdout stderr))))))))

(defun agents--id-p (id)
  "Non-nil when ID is safe to put in a command (herdr pane and workspace IDs)."
  (and (stringp id) (string-match-p "\\`[A-Za-z0-9:_-]+\\'" id)))

;;;; Paths

;; Agents report paths as the sandbox sees them.  `campfire info' says how those map to paths
;; on the host (the checkout is /campfire inside); every other path is the same on both sides.

(defvar agents--path-maps (make-hash-table :test 'equal)
  "Host name -> list of (INSIDE . OUTSIDE) directory pairs, from `campfire info'.")
(defvar agents--path-maps-tried (make-hash-table :test 'equal)
  "Host name -> `float-time' of the last attempt to read its path mapping.")

(defun agents--fetch-path-map (host)
  "Read HOST's path mapping from `campfire info', unless known or just tried."
  (let ((name (plist-get host :name)))
    (unless (or (gethash name agents--path-maps)
                (< (- (float-time) (gethash name agents--path-maps-tried 0)) 60))
      (puthash name (float-time) agents--path-maps-tried)
      (agents--run host (agents--campfire-argv host '("info"))
                   (lambda (ok stdout _stderr)
                     (when-let* ((info (and ok (ignore-errors
                                                 (json-parse-string
                                                  (string-trim stdout) :object-type 'plist
                                                  :array-type 'list :null-object nil)))))
                       (puthash name
                                (mapcar (lambda (m)
                                          (cons (directory-file-name (plist-get m :inside))
                                                (directory-file-name (plist-get m :outside))))
                                        (plist-get info :paths))
                                agents--path-maps)
                       (agents--schedule-redraw)))))))

(defun agents--map-path (host path from to)
  "Map PATH on HOST with the first pair whose FROM side (car or cdr) contains it."
  (let ((path (directory-file-name path)))
    (or (seq-some (lambda (pair)
                    (let ((src (funcall from pair)))
                      (cond ((equal path src) (funcall to pair))
                            ((string-prefix-p (concat src "/") path)
                             (concat (funcall to pair) (substring path (length src)))))))
                  (gethash (plist-get host :name) agents--path-maps))
        path)))

(defun agents--local-path (host path)
  "Map PATH as HOST's sandbox reports it to the path outside the sandbox."
  (agents--map-path host path #'car #'cdr))

(defun agents--sandbox-path (host path)
  "Map PATH outside HOST's sandbox to the path the sandbox sees."
  (agents--map-path host (expand-file-name path) #'cdr #'car))

;;;; Registry

(cl-defstruct (agents-agent (:constructor agents--make-agent) (:copier nil))
  host key pane workspace dir status seq title session)

(defvar agents--registry (make-hash-table :test 'equal)
  "Key \"HOST PANE\" -> `agents-agent'.")
(defvar agents--buffers (make-hash-table :test 'equal)
  "Key -> the agent's buffer, while it has one.")
(defvar agents--host-errors (make-hash-table :test 'equal)
  "Host name -> the error from its last failed poll.")
(defvar agents--polling (make-hash-table :test 'equal)
  "Host names with a poll in flight.")
(defvar agents--last-poll (make-hash-table :test 'equal)
  "Host name -> `float-time' of its last poll.")
(defvar agents--timer nil)

(defun agents--host (name)
  "The `agents-hosts' entry named NAME."
  (seq-find (lambda (h) (equal (plist-get h :name) name)) agents-hosts))

(defun agents--agents ()
  "All known agents."
  (hash-table-values agents--registry))

;;;; Seen: whether you have looked at an agent since it finished
;; herdr reports `done' for a finished agent until someone looks at its pane,
;; then `idle', but only its own UI counts as looking.  So Emacs keeps its own
;; record: selecting a finished agent's window marks it seen, and it shows as
;; idle until its status changes again.  Polls supply the agent's
;; `state_change_seq', which tells a later finish from the one you saw;
;; status-change events do not, so an event clears the mark instead.

(defvar agents--seen (make-hash-table :test 'equal)
  "Key -> the agent's seq when you looked at it finished (nil if not known yet).")

(defun agents--seen-p (agent)
  "Non-nil if you have looked at AGENT since it last finished."
  (let ((seen (gethash (agents-agent-key agent) agents--seen 'never)))
    (and (not (eq seen 'never))
         (or (null seen) (null (agents-agent-seq agent)) (equal seen (agents-agent-seq agent))))))

(defun agents--status (agent)
  "AGENT's status as shown: a `done' you have already looked at shows as `idle'."
  (let ((status (agents-agent-status agent)))
    (if (and (eq status 'done) (agents--seen-p agent)) 'idle status)))

(defun agents--note-looking (&rest _)
  "Mark the agent in the selected window seen, if it has finished."
  (when-let* ((key (buffer-local-value 'agents--key (window-buffer (selected-window))))
              (agent (gethash key agents--registry))
              ((eq (agents-agent-status agent) 'done))
              ((not (agents--seen-p agent))))
    (puthash key (agents-agent-seq agent) agents--seen)
    (agents--schedule-redraw)))

(defun agents--reconcile-seen (agent)
  "Update AGENT's seen mark from a poll: fill in its seq, or drop it after a change."
  (let* ((key (agents-agent-key agent))
         (seen (gethash key agents--seen 'never)))
    (cond ((eq seen 'never))
          ((not (eq (agents-agent-status agent) 'done)) (remhash key agents--seen))
          ((null seen) (puthash key (agents-agent-seq agent) agents--seen))
          ((not (equal seen (agents-agent-seq agent))) (remhash key agents--seen)))))

;; Looking means selecting the agent's window, or showing it in the selected one
(add-hook 'window-selection-change-functions #'agents--note-looking)
(add-hook 'window-buffer-change-functions #'agents--note-looking)

(defun agents--update-host (host agents)
  "Replace HOST's entries in the registry with AGENTS, a parsed `agent list'."
  (let ((name (plist-get host :name)))
    (maphash (lambda (key agent)
               (when (equal (agents-agent-host agent) name) (remhash key agents--registry)))
             agents--registry)
    (dolist (a agents)
      (let ((pane (plist-get a :pane_id)))
        (when (agents--id-p pane)
          (let* ((key (concat name " " pane))
                 (agent (agents--make-agent
                         :host name :key key :pane pane
                         :workspace (plist-get a :workspace_id)
                         :dir (agents--local-path host (or (plist-get a :cwd) "~"))
                         :status (intern (or (plist-get a :agent_status) "unknown"))
                         :seq (plist-get a :state_change_seq)
                         :title (plist-get a :terminal_title_stripped)
                         :session (plist-get (plist-get a :agent_session) :value))))
            (puthash key agent agents--registry)
            (agents--reconcile-seen agent)))))
    (agents--note-looking)))

(defun agents--poll (host)
  "Refresh HOST's agents, unless a poll of it is already running."
  (let ((name (plist-get host :name)))
    (unless (gethash name agents--polling)
      (agents--fetch-path-map host)
      (puthash name t agents--polling)
      (puthash name (float-time) agents--last-poll)
      (agents--herdr host '("agent" "list")
                     (lambda (ok result err)
                       (remhash name agents--polling)
                       (if ok
                           (progn (remhash name agents--host-errors)
                                  (agents--update-host host (plist-get result :agents)))
                         (puthash name (or err "unreachable") agents--host-errors)
                         (dolist (agent (agents--agents))
                           (when (equal (agents-agent-host agent) name)
                             (setf (agents-agent-status agent) 'unknown))))
                       (agents--schedule-redraw))))))

(defun agents-refresh ()
  "Poll every host now."
  (interactive)
  (mapc #'agents--poll agents-hosts))

;;;; Event streams: status changes as they happen, from `campfire events'

(defvar agents--streams (make-hash-table :test 'equal)
  "Host name -> its `campfire events' process.")
(defvar agents--soon (make-hash-table :test 'equal)
  "Host name -> pending timer for a poll soon after an event.")

(defun agents--stream-live-p (name)
  "Non-nil when host NAME's event stream is running and subscribed."
  (let ((proc (gethash name agents--streams)))
    (and (process-live-p proc) (process-get proc 'subscribed))))

(defun agents--poll-soon (host)
  "Poll HOST shortly, once, however many events ask for it."
  (let ((name (plist-get host :name)))
    (unless (timerp (gethash name agents--soon))
      (puthash name (run-with-timer 0.3 nil (lambda ()
                                              (remhash name agents--soon)
                                              (agents--poll host)))
               agents--soon))))

(defun agents--stream-event (host event)
  "Apply EVENT, a parsed line from HOST's event stream."
  (let ((data (plist-get event :data)))
    (pcase (plist-get event :event)
      ("pane.agent_status_changed"
       (let* ((pane (plist-get data :pane_id))
              (agent (gethash (concat (plist-get host :name) " " pane) agents--registry)))
         (if (not agent)
             (agents--poll-soon host)
           (setf (agents-agent-status agent)
                 (intern (or (plist-get data :agent_status) "unknown"))
                 ;; A new status: the old seq no longer describes it, and any
                 ;; finish you saw is over (unless you are looking right now)
                 (agents-agent-seq agent) nil)
           (remhash (agents-agent-key agent) agents--seen)
           (agents--note-looking)
           (when-let* ((title (plist-get data :title)))
             (setf (agents-agent-title agent) title))
           (agents--schedule-redraw))))
      ;; Panes came or went, or the stream (re)subscribed: refresh the whole view
      (_ (agents--poll-soon host)))))

(defun agents--stream-filter (host)
  "Process filter for HOST's event stream: handle each complete line."
  (lambda (proc output)
    (let ((lines (split-string (concat (process-get proc 'pending) output) "\n")))
      (process-put proc 'pending (car (last lines)))
      (dolist (line (butlast lines))
        (when-let* ((event (ignore-errors
                             (json-parse-string line :object-type 'plist :array-type 'list
                                                :null-object nil :false-object nil))))
          (when (equal (plist-get event :event) "subscribed")
            (process-put proc 'subscribed t)
            (process-put proc 'retry nil))
          (agents--stream-event host event))))))

(defun agents--stream-start (host &optional retry)
  "Start HOST's event stream; RETRY is the delay before the next restart."
  (let* ((name (plist-get host :name))
         (retry (or retry 2))
         (proc (make-process
                :name (concat "agents-events-" name) :noquery t :connection-type 'pipe
                :command (agents--command host (agents--campfire-argv host '("events")))
                :filter (agents--stream-filter host)
                :stderr (get-buffer-create (format " *agents-events-%s*" name))
                :sentinel (lambda (proc _event)
                            (unless (process-live-p proc)
                              (when (eq (gethash name agents--streams) proc)
                                ;; Poll until the stream is back, retrying with backoff
                                (let ((delay (or (process-get proc 'retry) retry)))
                                  (run-with-timer delay nil
                                                  (lambda ()
                                                    (when (eq (gethash name agents--streams) proc)
                                                      (agents--stream-start
                                                       host (min 60 (* 2 delay)))))))))))))
    (process-put proc 'retry retry)
    (puthash name proc agents--streams)))

(defun agents--stream-stop-all ()
  "Stop every event stream."
  (maphash (lambda (_name proc) (when (process-live-p proc) (delete-process proc))) agents--streams)
  (clrhash agents--streams))

(defun agents--tick ()
  "Poll each host that is due: often while its stream is down, rarely when up."
  (dolist (host agents-hosts)
    (let* ((name (plist-get host :name))
           (interval (if (agents--stream-live-p name)
                         agents-stream-poll-interval
                       agents-poll-interval)))
      (when (>= (- (float-time) (gethash name agents--last-poll 0)) interval)
        (agents--poll host)))))

(defun agents-start ()
  "Watch `agents-hosts': an event stream per host, with polling as a fallback."
  (interactive)
  (when (timerp agents--timer) (cancel-timer agents--timer))
  (agents--stream-stop-all)
  (mapc #'agents--stream-start agents-hosts)
  (setq agents--timer (and agents-hosts
                           (run-with-timer 0 agents-poll-interval #'agents--tick))))

;;;; Presentation

(defun agents--project-root (agent)
  "Project root of AGENT's directory, else the directory itself."
  (let ((dir (agents-agent-dir agent)))
    (or (and (file-directory-p dir)
             (when-let* ((proj (project-current nil dir))) (project-root proj)))
        (file-name-as-directory dir))))

(defun agents--project-name (agent)
  "Short name of AGENT's project."
  (file-name-nondirectory (directory-file-name (agents--project-root agent))))

(defun agents--glyph (status)
  "Glyph and face for STATUS."
  (pcase status
    ('working '("◐" font-lock-keyword-face))
    ('blocked '("●" warning))
    ('done    '("✓" success))
    ('idle    '("○" shadow))
    (_        '("?" shadow))))

(defun agents--label (agent)
  "One-line description of AGENT: glyph, status and title."
  (pcase-let ((`(,glyph ,face) (agents--glyph (agents--status agent))))
    (concat (propertize (format "%s %-8s" glyph (agents--status agent)) 'face face)
            (or (agents-agent-title agent) (agents-agent-pane agent))
            (if (cdr agents-hosts)
                (propertize (concat "  " (agents-agent-host agent)) 'face 'shadow)
              ""))))

(defun agents--attention-p (agent)
  "Non-nil when AGENT is waiting for you."
  (memq (agents--status agent) '(blocked done)))

(defun agents--sorted ()
  "Agents grouped by project, most recently used first; blocked first in each."
  (let* ((recent (buffer-list))
         (rank (lambda (root)
                 (or (cl-position-if (lambda (b)
                                       (let ((dir (buffer-local-value 'default-directory b)))
                                         (and dir (string-prefix-p root (expand-file-name dir)))))
                                     recent)
                     most-positive-fixnum)))
         (roots (make-hash-table :test 'equal)))
    (dolist (agent (agents--agents))
      (puthash (agents-agent-key agent) (agents--project-root agent) roots))
    (sort (agents--agents)
          (lambda (a b)
            (let ((ra (gethash (agents-agent-key a) roots))
                  (rb (gethash (agents-agent-key b) roots)))
              (if (equal ra rb)
                  (let ((ba (eq (agents-agent-status a) 'blocked))
                        (bb (eq (agents-agent-status b) 'blocked)))
                    (if (eq ba bb) (string< (agents-agent-pane a) (agents-agent-pane b)) ba))
                (let ((ka (funcall rank ra)) (kb (funcall rank rb)))
                  (if (= ka kb) (string< ra rb) (< ka kb)))))))))

;;;; Agent buffers

(defvar-local agents--key nil
  "Registry key of the agent this buffer is attached to.")

(defun agents--mode-line ()
  "Mode line status of the current agent buffer."
  (when-let* ((agent (gethash agents--key agents--registry)))
    (pcase-let ((`(,glyph ,face) (agents--glyph (agents--status agent))))
      (propertize (format " %s %s" glyph (agents--status agent)) 'face face))))

(defun agents-visit (agent)
  "Switch to AGENT's buffer, attaching to the agent if it has none."
  (let ((buf (gethash (agents-agent-key agent) agents--buffers)))
    (if (buffer-live-p buf)
        (pop-to-buffer-same-window buf)   ; follows `display-buffer-alist', as vterm does for a new one
      (require 'vterm)
      (let* ((host (agents--host (agents-agent-host agent)))
             (key (agents-agent-key agent))
             (dir (agents-agent-dir agent))
             (default-directory (if (file-directory-p dir) (file-name-as-directory dir) "~/"))
             (vterm-shell (mapconcat #'shell-quote-argument
                                     (agents--command host (agents--campfire-argv
                                                            host (list "herdr" "agent" "attach"
                                                                       (agents-agent-pane agent)))
                                                      t)
                                     " ")))
        (vterm (generate-new-buffer-name
                (format "*agent: %s (%s)*" (agents--project-name agent) (agents-agent-pane agent))))
        (setq agents--key key)
        (setq mode-line-process '(:eval (agents--mode-line)))
        (puthash key (current-buffer) agents--buffers)
        ;; Killing the buffer only detaches; the agent keeps running in herdr
        (add-hook 'kill-buffer-hook (lambda () (remhash key agents--buffers)) nil t)))))

(defun agents--read-agent (prompt)
  "The agent of this buffer or the pane line at point, else one read with PROMPT."
  (or (and agents--key (gethash agents--key agents--registry))
      (when-let* ((key (get-text-property (point) 'agents-key)))
        (gethash key agents--registry))
      (let* ((agents (agents--sorted))
             (choices (mapcar (lambda (a)
                                (cons (format "%s: %s" (agents--project-name a)
                                              (substring-no-properties (agents--label a)))
                                      a))
                              agents)))
        (unless choices (user-error "No agents"))
        (cdr (assoc (completing-read prompt choices nil t) choices)))))

(defun agents-visit-agent (agent)
  "Visit AGENT, read from the minibuffer when called interactively."
  (interactive (list (agents--read-agent "Visit agent: ")))
  (agents-visit agent))

(defun agents-next-attention ()
  "Visit the next agent waiting for you, blocked ones first."
  (interactive)
  (let* ((waiting (seq-filter #'agents--attention-p (agents--sorted)))
         (waiting (append (seq-filter (lambda (a) (eq (agents-agent-status a) 'blocked)) waiting)
                          (seq-remove (lambda (a) (eq (agents-agent-status a) 'blocked)) waiting)))
         (next (seq-find (lambda (a) (not (equal (agents-agent-key a) agents--key))) waiting)))
    (if next (agents-visit next) (message "No agent is waiting for you"))))

(defun agents-stop (agent)
  "Stop AGENT by closing its herdr pane, after confirmation."
  (interactive (list (agents--read-agent "Stop agent: ")))
  (when (yes-or-no-p (format "Stop agent %s in %s? " (agents-agent-pane agent)
                             (agents--project-name agent)))
    (agents--herdr (agents--host (agents-agent-host agent))
                   (list "pane" "close" (agents-agent-pane agent))
                   (lambda (ok _result err)
                     (if ok (message "Stopped agent %s" (agents-agent-pane agent))
                       (message "Could not stop agent: %s" err))
                     (agents-refresh)))))

(defun agents--read-host ()
  "The only host, else one read from the minibuffer."
  (cond ((null agents-hosts) (user-error "No hosts in `agents-hosts'"))
        ((null (cdr agents-hosts)) (car agents-hosts))
        (t (agents--host (completing-read "Host: " (mapcar (lambda (h) (plist-get h :name))
                                                           agents-hosts)
                                          nil t)))))

(defun agents-new (host root)
  "Start an agent on HOST in project ROOT, then visit it.
Interactively, ROOT is the current project; with a prefix argument, read it."
  (interactive (list (agents--read-host)
                     (if current-prefix-arg
                         (project-prompt-project-dir)
                       (project-root (project-current t)))))
  (let ((label (file-name-nondirectory (directory-file-name root))))
    (message "Starting an agent in %s..." label)
    (agents--herdr host '("workspace" "list")
                   (agents--step "workspace list"
                                 (lambda (result)
                                   (agents--new-pane host root label result))))))

(defun agents--step (what next)
  "An `agents--herdr' callback: NEXT gets the result, or WHAT is reported failed."
  (lambda (ok result err)
    (if ok (funcall next result)
      (message "Could not start agent (%s): %s" what err))))

(defun agents--new-pane (host root label workspaces)
  "Open a pane for a new agent: a tab in LABEL's workspace, or a new workspace.
WORKSPACES is the parsed `workspace list'."
  (let* ((cwd (agents--sandbox-path host root))
         (ws (seq-find (lambda (w) (equal (plist-get w :label) label))
                       (plist-get workspaces :workspaces)))
         (id (plist-get ws :workspace_id)))
    (agents--herdr
     host (if (agents--id-p id)
              (list "tab" "create" "--workspace" id "--cwd" cwd "--no-focus")
            (list "workspace" "create" "--cwd" cwd "--label" label "--no-focus"))
     (agents--step "new pane"
                   (lambda (result)
                     (let ((pane (plist-get (plist-get result :root_pane) :pane_id)))
                       (if (agents--id-p pane)
                           (agents--new-agent host pane)
                         (message "Could not start agent: herdr named no pane"))))))))

(defun agents--new-agent (host pane)
  "Run `agents-command' in PANE on HOST, wait for herdr to see the agent, visit it."
  (agents--herdr host (list "pane" "run" pane agents-command)
                 (agents--step agents-command
                               (lambda (_) (agents--await host pane (+ (float-time) 60))))))

(defun agents--await (host pane deadline)
  "Visit the agent in PANE on HOST once herdr detects it, polling until DEADLINE.
`agent wait' cannot do this: it fails at once while the pane has no agent yet."
  (agents--herdr
   host '("agent" "list")
   (agents--step
    "agent list"
    (lambda (result)
      (agents--update-host host (plist-get result :agents))
      (agents--schedule-redraw)
      (let ((agent (gethash (concat (plist-get host :name) " " pane) agents--registry)))
        (cond (agent (agents-visit agent))
              ((< (float-time) deadline)
               (run-with-timer 1 nil #'agents--await host pane deadline))
              (t (message "Could not start agent: herdr did not detect one in %s" pane))))))))

;;;; Status pane

(defconst agents--pane-name "*agents*")

(defvar-keymap agents-pane-mode-map
  :parent special-mode-map
  "RET" #'agents-pane-visit
  "<mouse-1>" #'agents-pane-visit
  "k" #'agents-stop
  "n" #'agents-new
  "a" #'agents-next-attention
  "g" #'agents-refresh)

(define-derived-mode agents-pane-mode special-mode "Agents"
  "Status of the campfire agents, grouped by project."
  (setq-local truncate-lines t)
  (setq-local cursor-type nil)
  (setq-local mode-line-format nil))

(defun agents-pane-visit (&optional event)
  "Visit the agent on this line (or where EVENT clicked)."
  (interactive (list last-nonmenu-event))
  (when (mouse-event-p event) (posn-set-point (event-start event)))
  (let ((agent (gethash (get-text-property (point) 'agents-key) agents--registry)))
    (unless agent (user-error "No agent on this line"))
    ;; Show the agent in the most recent ordinary window, not in the sidebar
    (when-let* ((win (get-mru-window nil nil nil t)))
      (select-window win))
    (agents-visit agent)))

(defun agents--pane-buffer ()
  "The status pane's buffer, created on first use."
  (or (get-buffer agents--pane-name)
      (with-current-buffer (get-buffer-create agents--pane-name)
        (agents-pane-mode)
        (display-line-numbers-mode -1)  ; after the mode, which the global mode hooks
        (agents--redraw)
        (current-buffer))))

(defun agents--redraw ()
  "Redraw the status pane, keeping point on the same agent."
  (when-let* ((buf (get-buffer agents--pane-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (key (get-text-property (point) 'agents-key))
            (project nil))
        (erase-buffer)
        (insert (propertize "Agents" 'face 'bold) "\n")
        (maphash (lambda (host err)
                   (insert (propertize (format "%s: %s\n" host (car (split-string err "\n")))
                                       'face 'error)))
                 agents--host-errors)
        (unless agents-hosts
          (insert (propertize "No hosts in `agents-hosts'\n" 'face 'shadow)))
        (dolist (agent (agents--sorted))
          (let ((name (agents--project-name agent)))
            (unless (equal name project)
              (setq project name)
              (insert (propertize name 'face 'font-lock-function-name-face) "\n")))
          (insert (propertize (concat "  " (agents--label agent) "\n")
                              'agents-key (agents-agent-key agent)
                              'mouse-face 'highlight
                              'help-echo "mouse-1: visit this agent")))
        (goto-char (point-min))
        (when-let* ((pos (and key (text-property-any (point-min) (point-max) 'agents-key key))))
          (goto-char pos))))))

(defvar agents--redraw-timer nil)

(defun agents--schedule-redraw ()
  "Redraw the views once Emacs is idle."
  (unless (timerp agents--redraw-timer)
    (setq agents--redraw-timer
          (run-with-idle-timer 0.1 nil (lambda ()
                                         (setq agents--redraw-timer nil)
                                         (agents--redraw)
                                         (force-mode-line-update t))))))

(defun agents-pane-show ()
  "Show the status pane in the left side column, below Treemacs."
  (interactive)
  (let ((win (display-buffer-in-side-window
              (agents--pane-buffer)
              `((side . left) (slot . 1) (window-height . ,agents-pane-height)
                (window-parameters . ((no-other-window . t)
                                      (no-delete-other-windows . t)))))))
    (set-window-dedicated-p win t)
    win))

(defun agents-sidebar-toggle ()
  "Show or hide the sidebar: Treemacs, with the status pane below it."
  (interactive)
  (require 'treemacs)
  (let ((pane (get-buffer-window agents--pane-name)))
    (if (or pane (eq (treemacs-current-visibility) 'visible))
        (progn
          (when pane (delete-window pane))
          (when (eq (treemacs-current-visibility) 'visible)
            (delete-window (treemacs-get-local-window))))
      (save-selected-window (treemacs))
      (when agents-hosts (agents-pane-show)))))

;;;; F2 menu

(defun agents--menu-agents (_children)
  "Menu entries 1 to 9, one per agent."
  (transient-parse-suffixes
   'agents-menu
   (cl-loop for agent in (agents--sorted)
            for i from 1 to 9
            collect (let ((agent agent))
                      (list (number-to-string i)
                            (format "%-14s %s" (agents--project-name agent) (agents--label agent))
                            (lambda () (interactive) (agents-visit agent)))))))

(transient-define-prefix agents-menu ()
  "Campfire agents."
  [["Agents" :class transient-column :setup-children agents--menu-agents]]
  [["Actions"
    ("a" "Next agent waiting for you" agents-next-attention)
    ("v" "Visit an agent" agents-visit-agent)
    ("n" "New agent in this project" agents-new)
    ("k" "Stop an agent" agents-stop)]
   ["View"
    ("l" "Toggle sidebar" agents-sidebar-toggle)
    ("g" "Refresh" agents-refresh)]])

(provide 'agents)
;;; agents.el ends here
