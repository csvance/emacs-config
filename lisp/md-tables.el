;;; md-tables.el --- Draw Markdown tables with box lines in the rendered view -*- lexical-binding: t; -*-

;;; Commentary:

;; In the rendered Markdown view (F7), each pipe table is shown as a grid:
;; columns padded to a common width and aligned as the delimiter row says
;; (:--, :-:, --:), the header in bold, and box-drawing lines in place of
;; the pipes and dashes.  Cells keep their styling, with markup hidden as in
;; the rest of the view.  Columns too wide for the window are narrowed and
;; their cells wrapped, and the tables are redrawn when the window changes
;; width.  The drawing is an overlay; the file is untouched, and leaving the
;; view removes it.

;;; Code:

(require 'cl-lib)
(require 'markdown-mode)
(require 'seq)

(defconst md-tables--delimiter-re
  "^[ \t]*|?[ \t]*:?-+:?[ \t]*\\(?:|[ \t]*:?-+:?[ \t]*\\)*|?[ \t]*$"
  "A table's delimiter row, such as |---|:--:|.")

(defun md-tables--cells (beg end)
  "Bounds (START . END) of the cells in the table row from BEG to END.
Pipes inside code spans or escaped as \\| do not split cells."
  (let (cells start code)
    (save-excursion
      (goto-char beg)
      (skip-chars-forward " \t" end)
      (when (eq (char-after) ?|) (forward-char 1))
      (setq start (point))
      (while (< (point) end)
        (pcase (char-after)
          (?\\ (forward-char 1))
          (?` (setq code (not code)))
          ((and ?| (guard (not code)))
           (push (cons start (point)) cells)
           (setq start (1+ (point)))))
        (forward-char (min 1 (- end (point)))))
      ;; Text after the last pipe is a cell; nothing after a closing pipe is not
      (unless (and cells (string-blank-p (buffer-substring-no-properties start end)))
        (push (cons start end) cells))
      (mapcar (lambda (cell)
                (goto-char (car cell))
                (skip-chars-forward " \t" (cdr cell))
                (let ((s (point)))
                  (goto-char (cdr cell))
                  (skip-chars-backward " \t" s)
                  (cons s (point))))
              (nreverse cells)))))

(defun md-tables--visible (beg end)
  "The text from BEG to END as the view shows it.
Faces are kept and hidden markup is dropped."
  (let ((pos beg) (parts nil))
    (while (< pos end)
      (let ((next (next-single-char-property-change pos 'invisible nil end)))
        (unless (invisible-p pos)
          (push (buffer-substring pos next) parts))
        (setq pos next)))
    (replace-regexp-in-string "\\\\|" "|" (apply #'concat (nreverse parts)) t t)))

(defun md-tables--align (spec)
  "The alignment a delimiter cell SPEC such as :-: asks for."
  (let ((left (string-prefix-p ":" spec))
        (right (string-suffix-p ":" spec)))
    (cond ((and left right) 'center) (right 'right) (t 'left))))

(defun md-tables--pad (text width align)
  "TEXT padded with spaces to WIDTH columns, placed as ALIGN says."
  (let* ((gap (max 0 (- width (string-width text))))
         (before (pcase align ('right gap) ('center (/ gap 2)) (_ 0))))
    (concat (make-string before ?\s) text (make-string (- gap before) ?\s))))

(defun md-tables--rule (widths left mid right)
  "A horizontal line over columns of WIDTHS, joined by LEFT, MID and RIGHT."
  (propertize (concat left
                      (mapconcat (lambda (w) (make-string (+ w 2) ?─)) widths mid)
                      right)
              'face 'shadow))

(defcustom md-tables-min-column-width 10
  "Narrowest a column is squeezed to so a table fits the window."
  :type 'integer
  :group 'markdown)

(defun md-tables--fit-widths (widths available)
  "WIDTHS capped so their sum fits in AVAILABLE columns, widest first.
No column is capped below `md-tables-min-column-width', so a table with
many columns may still be wider than AVAILABLE."
  (let ((cap (apply #'max widths)))
    (while (and (> cap md-tables-min-column-width)
                (> (apply #'+ (mapcar (lambda (w) (min w cap)) widths)) available))
      (setq cap (1- cap)))
    (mapcar (lambda (w) (min w cap)) widths)))

(defun md-tables--chars-fitting (text width)
  "How many characters of TEXT fit in WIDTH columns, at least one."
  (let ((n 0))
    (while (and (< n (length text))
                (<= (string-width text 0 (1+ n)) width))
      (setq n (1+ n)))
    (max n 1)))

(defun md-tables--wrap (text width)
  "TEXT broken into lines of at most WIDTH columns, at spaces where possible."
  (let ((lines nil) (line ""))
    (dolist (word (split-string text " +" t))
      (while (> (string-width word) width) ; too long for any line: break it
        (unless (string-empty-p line)
          (push line lines)
          (setq line ""))
        (let ((n (md-tables--chars-fitting word width)))
          (push (substring word 0 n) lines)
          (setq word (substring word n))))
      (cond ((string-empty-p line) (setq line word))
            ((<= (+ (string-width line) 1 (string-width word)) width)
             (setq line (concat line " " word)))
            (t (push line lines)
               (setq line word))))
    (nreverse (cons line lines))))

(defun md-tables--draw (indent header aligns rows max-width)
  "The drawn table: HEADER and ROWS are lists of cell strings, ALIGNS per column.
Each line starts with INDENT.  Columns are narrowed and their cells
wrapped so the table fits in MAX-WIDTH columns."
  (let* ((ncols (length header))
         (fit (lambda (row) (seq-take (append row (make-list ncols "")) ncols)))
         (header (mapcar (lambda (c)
                           (let ((c (copy-sequence c)))
                             (add-face-text-property 0 (length c) 'bold t c)
                             c))
                         header))
         (rows (mapcar fit rows))
         (aligns (funcall fit aligns))
         (natural (apply #'cl-mapcar
                         (lambda (&rest cells) (apply #'max 1 (mapcar #'string-width cells)))
                         header rows))
         ;; Each column costs its width plus " │ "; the row adds one more bar
         (widths (md-tables--fit-widths
                  natural (- max-width (string-width indent) (* 3 ncols) 1)))
         (wrapped nil)
         (bar (propertize "│" 'face 'shadow))
         (row-lines
          (lambda (cells)
            (let* ((parts (cl-mapcar #'md-tables--wrap cells widths))
                   (height (apply #'max (mapcar #'length parts))))
              (when (> height 1) (setq wrapped t))
              (mapcar (lambda (i)
                        (concat indent bar " "
                                (mapconcat #'identity
                                           (cl-mapcar (lambda (part w align)
                                                        (md-tables--pad (or (nth i part) "") w align))
                                                      parts widths aligns)
                                           (concat " " bar " "))
                                " " bar))
                      (number-sequence 0 (1- height))))))
         (head (funcall row-lines header))
         (body (mapcar row-lines rows))
         (rule (lambda (l m r) (concat indent (md-tables--rule widths l m r)))))
    (mapconcat #'identity
               (append (list (funcall rule "┌" "┬" "┐"))
                       head
                       (list (funcall rule "├" "┼" "┤"))
                       ;; Wrapped rows need lines between them to tell them apart
                       (apply #'append
                              (cdr (mapcan (lambda (lines)
                                             (list (if wrapped (list (funcall rule "├" "┼" "┤")) nil)
                                                   lines))
                                           body)))
                       (list (funcall rule "└" "┴" "┘")))
               "\n")))

(defun md-tables--row-p ()
  "Non-nil if the line at point can continue a table."
  (and (not (eobp))
       (looking-at-p "^.*|")
       (not (looking-at-p "^[ \t]*$"))))

(defvar-local md-tables--width nil
  "Window width the tables were last drawn for, while they are drawn.")

(defun md-tables--width ()
  "Columns available to a table in the window showing this buffer."
  (let ((window (or (get-buffer-window nil t) (selected-window))))
    (1- (window-body-width window))))   ; the last column would wrap the line

(defun md-tables--resized (_window)
  "Redraw the tables when the window showing them changes width."
  (when (and md-tables--width (/= md-tables--width (md-tables--width)))
    (md-tables-render)))

(defun md-tables-render ()
  "Draw every pipe table in this buffer as a grid that fits its window."
  (interactive)
  (remove-overlays (point-min) (point-max) 'md-table t)
  (setq md-tables--width (md-tables--width))
  (add-hook 'window-size-change-functions #'md-tables--resized nil t)
  (add-hook 'after-revert-hook #'md-tables-render nil t) ; a reload replaces the text drawn over
  (font-lock-ensure)                    ; hidden markup is marked by fontification
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward md-tables--delimiter-re nil t)
      (let ((delim-beg (line-beginning-position))
            (delim-end (line-end-position)))
        (when (and (string-search "|" (buffer-substring-no-properties delim-beg delim-end))
                   (not (markdown-code-block-at-pos delim-beg))
                   (save-excursion
                     (forward-line -1)
                     (and (/= (line-beginning-position) delim-beg) (md-tables--row-p))))
          (let* ((beg (save-excursion (forward-line -1) (point)))
                 (indent (save-excursion
                           (goto-char beg)
                           (buffer-substring-no-properties
                            beg (progn (skip-chars-forward " \t") (point)))))
                 (cells (lambda (lb le)
                          (mapcar (lambda (c) (md-tables--visible (car c) (cdr c)))
                                  (md-tables--cells lb le))))
                 (header (funcall cells beg (save-excursion (goto-char beg) (line-end-position))))
                 (aligns (mapcar (lambda (c)
                                   (md-tables--align
                                    (buffer-substring-no-properties (car c) (cdr c))))
                                 (md-tables--cells delim-beg delim-end)))
                 (rows nil)
                 (end delim-end))
            (forward-line 1)
            (while (md-tables--row-p)
              (push (funcall cells (point) (line-end-position)) rows)
              (setq end (line-end-position))
              (forward-line 1))
            (let ((ov (make-overlay beg end)))
              (overlay-put ov 'md-table t)
              (overlay-put ov 'evaporate t)
              (overlay-put ov 'display
                           (md-tables--draw indent header aligns (nreverse rows)
                                            md-tables--width)))))))))

(defun md-tables-clear ()
  "Remove the drawn tables, showing the Markdown source again."
  (interactive)
  (remove-hook 'window-size-change-functions #'md-tables--resized t)
  (remove-hook 'after-revert-hook #'md-tables-render t)
  (setq md-tables--width nil)
  (remove-overlays (point-min) (point-max) 'md-table t))

(provide 'md-tables)
;;; md-tables.el ends here
