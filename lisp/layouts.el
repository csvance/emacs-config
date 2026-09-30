;;; layouts.el --- Window layouts next to the sidebar, with a tile for agents -*- lexical-binding: t; -*-

;;; Commentary:

;; Three layouts of the editing area, the part of the frame beside the sidebar
;; (Treemacs and the agents pane, which are left side windows):
;;
;;   single   one window
;;   stacked  one window over the agent tile
;;   split    two windows side by side over the agent tile, the right one
;;            Magit's status for the left one's project
;;
;; The agent tile is a bottom side window, so C-x 1, C-x 2 and C-x 3 in the
;; editing area leave it alone.  While a layout has one, every Claude Code
;; agent buffer (`*agent: ...*', from lisp/agents.el) opens there, however it
;; is visited: F2, the agents pane, or C-x b.  F3 picks the layout.

;;; Code:

(require 'seq)
(require 'transient)

(defgroup layouts nil
  "Window layouts next to the sidebar, with a tile for agents."
  :group 'windows)

(defcustom layouts-agent-height 0.4
  "Height of the agent tile, as a fraction of the frame."
  :type 'number)

(defvar layouts--current 'single
  "The current layout: `single', `stacked' or `split'.")

(defconst layouts--names
  '((single . "One window")
    (stacked . "One window over an agent")
    (split . "Editor and Magit over an agent"))
  "Each layout's description in the F3 menu.")

;; Left side windows (the sidebar) take the full frame height, so the bottom
;; tile spans only the editing area rather than running under the sidebar.
(setq window-sides-vertical t)
;; C-x b follows `display-buffer-alist' too, so an agent chosen there goes to the tile.
(setq switch-to-buffer-obey-display-actions t)

(defun layouts--agent-buffer-p (buffer)
  "Non-nil if BUFFER (a buffer or its name) is a Claude Code agent buffer."
  (string-prefix-p "*agent: " (if (stringp buffer) buffer (buffer-name buffer))))

(defun layouts--display-agent (buffer alist)
  "Show agent BUFFER in the agent tile, creating the tile if needed."
  (display-buffer-in-side-window
   buffer (append `((side . bottom) (slot . 0)
                    (window-height . ,layouts-agent-height)
                    (preserve-size . (nil . t))
                    (window-parameters . ((no-delete-other-windows . t))))
                  alist)))

(add-to-list 'display-buffer-alist
             `(,(lambda (buffer _action)
                  (and (not (eq layouts--current 'single)) (layouts--agent-buffer-p buffer)))
               layouts--display-agent))

(defun layouts--agent-window ()
  "The agent tile, if it is showing."
  (window-with-parameter 'window-side 'bottom))

;;;; The Magit window of the split layout

(defun layouts--magit-window ()
  "The split layout's Magit window, if it is showing."
  (and (eq layouts--current 'split) (window-with-parameter 'layouts-magit t)))

(defun layouts--magit-status-p (buffer)
  "Non-nil if BUFFER (a buffer or its name) is a Magit status buffer."
  (with-current-buffer buffer (derived-mode-p 'magit-status-mode)))

(defun layouts--display-magit (buffer alist)
  "Show Magit status BUFFER in the split layout's Magit window."
  (when-let* ((win (layouts--magit-window)))
    (window--display-buffer buffer win 'reuse alist)))

(add-to-list 'display-buffer-alist
             `(,(lambda (buffer _action)
                  (and (layouts--magit-window) (layouts--magit-status-p buffer)))
               layouts--display-magit))

(defun layouts--project-root (buffer)
  "The root of BUFFER's project, or nil."
  (with-current-buffer buffer
    (when-let* ((project (project-current))) (expand-file-name (project-root project)))))

(defun layouts--show-magit (root)
  "Show Magit's status for ROOT in the Magit window, without selecting it."
  (require 'magit)
  (save-selected-window
    (let ((default-directory root))
      (if (magit-toplevel)
          (magit-status-setup-buffer root)
        (message "%s is not a Git repository; no Magit status" root)))))

(defun layouts--follow-project (_frame)
  "Keep the Magit window on the project of the editing window beside it."
  (when-let* ((magit (layouts--magit-window))
              (editor (seq-find (lambda (w) (not (or (window-parameter w 'window-side)
                                                     (eq w magit))))
                                (window-list nil 'nomini)))
              (root (layouts--project-root (window-buffer editor)))
              ((not (equal root (layouts--project-root (window-buffer magit))))))
    (layouts--show-magit root)))

(add-hook 'window-buffer-change-functions #'layouts--follow-project)

(defun layouts--editing-window ()
  "A window of the editing area: the selected one when it is one."
  (if (window-parameter nil 'window-side)
      (seq-find (lambda (w) (not (window-parameter w 'window-side))) (window-list nil 'nomini))
    (selected-window)))

(defun layouts--other-buffer (&rest except)
  "The most recent buffer to edit that is not an agent, the sidebar, or in EXCEPT."
  (or (seq-find (lambda (b)
                  (not (or (memq b except)
                           (layouts--agent-buffer-p b)
                           (string-prefix-p " " (buffer-name b))
                           (equal (buffer-name b) "*agents*"))))
                (buffer-list))
      (get-scratch-buffer-create)))

(defun layouts--arrange (layout)
  "Arrange the editing area in LAYOUT, keeping the buffer you are in."
  (let* ((tile (layouts--agent-window))
         (focus (window-buffer (if (window-parameter nil 'window-side)
                                   (or tile (layouts--editing-window))
                                 (selected-window))))
         (agent (seq-find #'layouts--agent-buffer-p
                          (append (and tile (list (window-buffer tile)))
                                  (list focus)
                                  (buffer-list))))
         (win (layouts--editing-window)))
    (setq layouts--current layout)
    (when tile (delete-window tile))
    (select-window win)
    (delete-other-windows)                ; the sidebar keeps its windows
    (if (eq layout 'single)
        (set-window-buffer win focus)
      ;; The editing area gets the buffers to edit; an agent goes below
      (let ((top (if (layouts--agent-buffer-p focus) (layouts--other-buffer) focus)))
        (set-window-buffer win top)
        (when (eq layout 'split)
          (let ((right (split-window-right)))
            (set-window-buffer right (layouts--other-buffer top))
            (set-window-parameter right 'layouts-magit t)
            (when-let* ((root (layouts--project-root top)))
              (layouts--show-magit root)))))
      (if agent
          (display-buffer agent)
        (message "No agent open yet: visit one (F2) and it opens below")))
    (select-window (if (and (layouts--agent-buffer-p focus) (layouts--agent-window))
                       (layouts--agent-window)
                     win))))

(defun layouts-single ()
  "One window next to the sidebar."
  (interactive)
  (layouts--arrange 'single))

(defun layouts-stacked ()
  "One window over the agent tile."
  (interactive)
  (layouts--arrange 'stacked))

(defun layouts-split ()
  "Two windows side by side over the agent tile."
  (interactive)
  (layouts--arrange 'split))

(defun layouts--label (layout)
  "LAYOUT's menu description, marked when it is the current one."
  (let ((name (alist-get layout layouts--names)))
    (if (eq layout layouts--current)
        (propertize (concat name "  (current)") 'face 'transient-value)
      name)))

(transient-define-prefix layouts-menu ()
  "Window layouts next to the sidebar."
  [["Layout"
    ("1" layouts-single :description (lambda () (layouts--label 'single)))
    ("2" layouts-stacked :description (lambda () (layouts--label 'stacked)))
    ("3" layouts-split :description (lambda () (layouts--label 'split)))]])

(provide 'layouts)
;;; layouts.el ends here
