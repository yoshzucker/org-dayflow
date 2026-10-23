;;; org-dayflow.el --- Simple day-flowing timeline for Org -*- lexical-binding: t; -*-

;; Author: yoshzucker
;; Maintainer: yoshzucker
;; Version: 0.3
;; Package-Requires: ((emacs "26.1") (org "9.1"))
;; Keywords: org, calendar, timeline
;; URL: https://github.com/yoshzucker/org-dayflow

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; org-dayflow provides a simple, flowing day-by-day timeline view for Org tasks.
;; It displays a fixed-width calendar line and aligns scheduled tasks under their dates,
;; emphasizing the day-by-day flow rather than traditional Gantt or agenda views.
;;
;; The package depends only on Org (and Emacs).  Query/filter logic is
;; implemented internally using Org primitives so that the package remains
;; self-contained, similar in spirit to how org-agenda works.

;;; Code:

(require 'cl-lib)
(require 'calendar)
(require 'org)
(require 'org-element)
;; `org-with-remote-undo' and the two variables it reads live in the agenda
;; even though this is not one.  Wanted while compiling, for the macro, and
;; while running by the single function that uses it -- which asks for it
;; itself.  Loading the agenda here would mean no timeline could be drawn
;; without one, and an agenda arrives with whatever a configuration has hung
;; off it.
(eval-when-compile (require 'org-agenda))

(defgroup org-dayflow nil
  "Simple flowing timeline view for Org."
  :group 'org)

(defcustom org-dayflow-spans
  '((month   day    26)
    (quarter week   14)
    (year    month  12)
    (decade  year   10))
  "The periods a view can show, each as (PERIOD UNIT CELLS).

What you pick is a period -- a month, a quarter, a year -- and the period
says what one column is and how many of them to aim for.  Nothing shorter
than a month: the hours of a day and the days of a week are what the agenda
is for, and a timeline drawn that close is a slower agenda.

CELLS is a target rather than a count.  The view fills the window, so a wide
one shows more; what CELLS decides is how wide a column gets, and through
that how much of the period is on the screen at eighty columns.

Ordered from shortest to longest, because that is the order the zoom keys
walk."
  :type '(alist :key-type symbol :value-type (list symbol integer))
  :group 'org-dayflow)

(defconst org-dayflow-unit-digits
  '((day . 2) (week . 2) (month . 2) (year . 4))
  "How many digits a unit needs in its own column.

A year is four and everything else is two.  Written down because a column
was built from one format string for every unit, and `%02d' on 2026 is not
two characters -- it is four, and the year row came out a column wider than
the grid it was supposed to line up with.")

(defcustom org-dayflow-min-cell-gap 1
  "Blank columns kept to the right of a unit\='s digits.
One is enough to read `06 07 08\=' as three numbers rather than one."
  :type 'integer
  :group 'org-dayflow)

(defcustom org-dayflow-max-cell-width 10
  "Widest a single column may become.

A period with few units would otherwise spread them across the whole window,
and a title starts at its own column: pushed far enough right, there is no
room left to read it in."
  :type 'integer
  :group 'org-dayflow)

(defcustom org-dayflow-default-span 'month
  "Period shown when none is asked for.

A month, with a week of it behind you: where each piece of work runs and
where it is due, which is what a timeline shows that a list does not."
  :type 'symbol
  :group 'org-dayflow)

(defcustom org-dayflow-default-offsets
  '((month   . -0.25)
    (quarter . -0.25)
    (year    . -0.2)
    (decade  . -0.2))
  "How much of each period is already behind you, as a share of it.

A share rather than a count of columns: the number of columns follows the
window, so a fixed count would put the past off the left edge of a wide
window and swallow the whole view on a narrow one.  A little of it is worth
keeping -- what happened yesterday is why today looks the way it does."
  :type '(alist :key-type symbol :value-type number)
  :group 'org-dayflow)

(defcustom org-dayflow-initial-query
  '((and (or (scheduled) (deadline) (regexp org-ts-regexp))
         (not (done))))
  "Default S-expression query for org-dayflow when no filters are applied.
The query language is a small subset evaluated with Org primitives.
Default hides done-type states via `(not (done))'; pick a preset
from query select (`/' then `s') to include DONE/CANCEL/DELEG."
  :type 'sexp
  :group 'org-dayflow)

(defcustom org-dayflow-exclude-files nil
  "Files left out of the timeline although `org-agenda-files' lists them.
Each element is a file name, or a function of no arguments returning
one or a list of them, for a file whose name is decided at run time.
A symbol that is not yet a function is skipped.

A timeline is read for where work runs and where it is due.  A
calendar mirrored into Org is something else: a weekly meeting drawn
as a Gantt chart is a row of the same mark, and a month of a working
calendar is more rows of meetings than there is work between them.
Those belong to the agenda, which still reads them."
  :type '(repeat (choice file function))
  :group 'org-dayflow)

(defcustom org-dayflow-column-bands t
  "If non-nil, shade weekend columns on the day scale (single subtle face).
Helps keep a sense of weekday vs weekend when the unit header has
scrolled out of view.  Other scales leave columns unshaded."
  :type 'boolean
  :group 'org-dayflow)

(defcustom org-dayflow-saved-queries nil
  "Alist of saved org-dayflow queries.
Each entry is a cons cell of the form (LABEL . QUERY)."
  :type '(alist :key-type string :value-type sexp)
  :group 'org-dayflow
  :safe t)

(defcustom org-dayflow-spark-chars "▁▂▃▄▅▆▇█"
  "Block glyphs (U+2581..U+2588) for the per-unit load sparkline.
Cell height encodes task count relative to the busiest unit in view.
Same family of characters used by typical Nerd Font / monospaced
sparklines (e.g. agenda embedded graphs)."
  :type 'string
  :group 'org-dayflow)

(defcustom org-dayflow-histogram-face-alist
  '((deadline        . org-dayflow-histogram-deadline-face)
    (active          . org-dayflow-histogram-active-face)
    (scheduled       . org-dayflow-histogram-scheduled-face)
    (deadline-done   . org-dayflow-histogram-deadline-done-face)
    (active-done     . org-dayflow-histogram-active-done-face)
    (scheduled-done  . org-dayflow-histogram-scheduled-done-face))
  "Faces used to colorize the load sparkline per unit.
Keys ending in `-done` are used when every task in that unit is done.
Otherwise the dominant incomplete type (deadline > active > scheduled)
selects the face."
  :type '(alist :key-type (symbol) :value-type face)
  :group 'org-dayflow)

(defcustom org-dayflow-category-faces nil
  "Alist mapping an entry's CATEGORY (a string) to a face for its title line.
When set, entries are colored by source (e.g. distinguishing calendars) rather
than only by time type.  Empty by default -- no category coloring -- so this is
a generic hook; populate it in your own configuration, not in the package."
  :type '(alist :key-type string :value-type face)
  :group 'org-dayflow)

(defcustom org-dayflow-high-density nil
  "If non-nil, render with less vertical padding:
- no blank line after the query line
- no blank line between the load sparkline and titles."
  :type 'boolean
  :group 'org-dayflow)

(defcustom org-dayflow-visible-depth 2
  "How many levels of the outline a new view shows.
A row with rows under it is drawn across the dates of its whole
subtree, so folding it keeps where its work falls and drops only
the detail.  1 shows the top-level headings alone, 2 those and
what is directly under them; nil shows everything.  `S-TAB' cycles
it and `TAB' folds one row."
  :type '(choice (const :tag "Everything" nil) integer)
  :group 'org-dayflow)

(defcustom org-dayflow-window-setup 'other-window
  "How the Dayflow buffer should be displayed.
The value is passed to `org-dayflow-prepare-window' and controls
whether the buffer is shown in the current window, another window,
a new frame, etc.  The possible values and their meaning are the
same as for `org-agenda-window-setup'."
  :group 'org-dayflow
  :type '(choice
          (const :tag "Current window" current-window)
          (const :tag "Other window" other-window)
          (const :tag "Other frame" other-frame)
          (const :tag "Other tab" other-tab)
          (const :tag "Only window" only-window)
          (const :tag "Reorganize frame" reorganize-frame)))

(defcustom org-dayflow-restore-windows-after-quit nil
  "Non-nil means restore the window configuration after quitting Dayflow.
This is only effective when `org-dayflow-window-setup' is not
`current-window'."
  :group 'org-dayflow
  :type 'boolean)

(defvar org-dayflow-pre-window-conf nil
  "Window configuration before Dayflow was displayed.
Used to restore the previous layout when quitting with
`org-dayflow-restore-windows-after-quit' non-nil.")

(defface org-dayflow-query-face
  '((t (:inherit org-agenda-structure)))
  "Face for displaying the current query in Org Dayflow."
  :group 'org-dayflow)

(defface org-dayflow-label-face
  '((t (:inherit org-agenda-structure)))
  "Face for labels (e.g., month or year names) in org-dayflow."
  :group 'org-dayflow)

(defface org-dayflow-units-face
  '((t (:inherit org-agenda-structure)))
  "Face for labels (e.g., month or year names) in org-dayflow."
  :group 'org-dayflow)

(defface org-dayflow-weekday-face
  '((t (:inherit org-agenda-structure)))
  "Face for weekdays in org-dayflow (only relevant for day scale)."
  :group 'org-dayflow)

(defface org-dayflow-weekend-face
  '((t (:inherit org-agenda-structure :weight bold)))
  "Face for weekends in org-dayflow (only relevant for day scale)."
  :group 'org-dayflow)

(defface org-dayflow-weekend-column-face
  '((((class color) (min-colors 88) (background light))
     :background "gray96" :extend t)
    (((class color) (min-colors 88) (background dark))
     ;; Soft fallback only; themes (e.g. gensho) should remap via mono/dim ramp.
     :background "gray16" :extend t)
    (t :extend t))
  "Subtle full-height column shade for weekend units on day scale.
Applied behind title / sparkline content so schedule stays readable.
Prefer theme-local remapping onto a one-step mono/dim ramp rather than
a high-contrast gray."
  :group 'org-dayflow)

(defface org-dayflow-now-unit-face
  '((t (:inherit calendar-today)))
  "Face for the unit label of the current time cell in org-dayflow.
Applied to the single cell in the unit-label row that corresponds
to `now' at the current scale (today on day scale, the current
week on week scale, the current year on year scale, and so on).
Also reused as the highlight face for the cursor column overlay."
  :group 'org-dayflow)

(defface org-dayflow-cursor-unit-face
  '((t (:inherit org-date-selected)))
  "Face for the unit label under the cursor in org-dayflow."
  :group 'org-dayflow)

(defface org-dayflow-histogram-deadline-face
  '((t (:inherit org-warning)))
  "Face used for deadline markers in dayflow bar graph."
  :group 'org-dayflow)

(defface org-dayflow-histogram-active-face
  '((t (:inherit font-lock-string-face)))
  "Face used for active time markers in dayflow bar graph."
  :group 'org-dayflow)

(defface org-dayflow-histogram-scheduled-face
  '((t (:inherit org-scheduled)))
  "Face used for scheduled task markers in dayflow bar graph."
  :group 'org-dayflow)

(defface org-dayflow-histogram-deadline-done-face
  '((t (:inherit org-headline-done)))
  "Face for completed deadline tasks."
  :group 'org-dayflow)

(defface org-dayflow-histogram-active-done-face
  '((t (:inherit org-headline-done)))
  "Face for completed active tasks."
  :group 'org-dayflow)

(defface org-dayflow-histogram-scheduled-done-face
  '((t (:inherit org-headline-done)))
  "Face for completed scheduled tasks."
  :group 'org-dayflow)

(defface org-dayflow-title-box-face
  '((t (:inherit font-lock-string-face
                 :box (:line-width (-1 . -1)))))
  "Face for the working-window box overlay in org-dayflow.
Applied to the SCHEDULED..DEADLINE range (or a single-point
SCHEDULED / DEADLINE).  Uses negative :line-width so the box is
drawn inside the character bounding box and calendar cell size
stays uniform."
  :group 'org-dayflow)

(defface org-dayflow-title-occupation-face
  '((t (:inherit font-lock-string-face :inverse-video t)))
  "Face for the occupation background overlay in org-dayflow.
Applied to active-timestamp time ranges (events / appointments)."
  :group 'org-dayflow)

(defface org-dayflow-now-column-face
  '((t (:inherit hl-line)))
  "Face for the vertical highlight of the current-time column.
Applied across histogram / task rows at the cell containing the
current time.  Merged into the `face' text property with APPEND
so title / occupation / box faces keep priority."
  :group 'org-dayflow)

(defface org-dayflow-cursor-column-face
  '((t (:inherit hl-line)))
  "Face for the vertical highlight of the cursor column.
Applied via overlay across histogram / task rows at the cell the
cursor currently sits on, and redrawn on every cursor movement."
  :group 'org-dayflow)

(defface org-dayflow-title-done-face
  '((t (:inherit org-headline-done :strike-through t)))
  "Face for done-state (DONE/CANCEL/DELEG) task titles."
  :group 'org-dayflow)

(defface org-dayflow-summary-face
  '((t (:weight bold)))
  "Face added to the title of a row that has rows under it.
Bold, so the headings a month is organised by stand out from the
tasks they are made of."
  :group 'org-dayflow)

(defface org-dayflow-milestone-face
  '((t (:inherit org-warning)))
  "Face for a deadline marked on a parent's line."
  :group 'org-dayflow)

(defface org-dayflow-milestone-done-face
  '((t (:inherit org-headline-done)))
  "Face for a met deadline marked on a parent's line."
  :group 'org-dayflow)

(defvar-local org-dayflow--current-span nil
  "Period the org-dayflow buffer is showing.")

(defvar-local org-dayflow--current-offset 0
  "Current offset from today for the dayflow timeline.")

(defvar-local org-dayflow--current-query nil
  "Current S-expression query used in the Dayflow buffer.")

(defvar-local org-dayflow--filter-exclude nil
  "Non-nil means the current filter is an exclusion filter in Org Dayflow.")

(defvar-local org-dayflow--follow-mode nil
  "Non-nil if Org Dayflow follow mode is enabled.")

(defvar-local org-dayflow--highlight-overlay nil
  "Overlay for highlighting the current org heading in follow mode.")

(defvar-local org-dayflow--unit-line-start nil
  "Buffer position of the beginning of the unit-label row.")

(defvar-local org-dayflow--grid-start nil
  "Buffer position where sparkline / task rows begin (after label rows).")

(defvar-local org-dayflow--body-start nil
  "Buffer position of the first task row (start of the scrollable body).")

(defvar-local org-dayflow--cursor-column-overlays nil
  "List of overlays highlighting the cursor's cell column across grid rows.")

(defvar-local org-dayflow--cursor-unit-overlay nil
  "Overlay highlighting the unit label under the cursor.")

(defvar-local org-dayflow--visible-depth nil
  "Levels shown in this buffer; starts as `org-dayflow-visible-depth'.")

(defvar-local org-dayflow--folds nil
  "Rows folded or opened by hand: node key -> `open' or `folded'.
Overrides `org-dayflow--visible-depth' for that row.")

(defvar-local org-dayflow--tree-depth 0
  "Levels in the outline last rendered, for `org-dayflow-cycle-depth'.")

(defvar org-dayflow--query-session nil
  "List of queries built during this session (not saved persistently).")

(defvar org-dayflow-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "q") #'org-dayflow-quit)
    (define-key map (kbd "RET") #'org-dayflow-switch-to)
    (define-key map (kbd "SPC") #'org-dayflow-show)
    (define-key map (kbd "TAB") #'org-dayflow-toggle-fold)
    (define-key map (kbd "<backtab>") #'org-dayflow-cycle-depth)
    (define-key map (kbd "r") #'org-dayflow-refresh)
    (define-key map (kbd "-") #'org-dayflow-span-zoom-out)
    (define-key map (kbd "+") #'org-dayflow-span-zoom-in)
    (define-key map (kbd "Z") #'org-dayflow-span)
    (define-key map (kbd "n") #'org-dayflow-next-item)
    (define-key map (kbd "p") #'org-dayflow-previous-item)
    (define-key map (kbd "j") #'org-dayflow-next-item)
    (define-key map (kbd "k") #'org-dayflow-previous-item)
    (define-key map (kbd "<") #'org-dayflow-offset-backward)
    (define-key map (kbd ">") #'org-dayflow-offset-forward)
    (define-key map (kbd ".") #'org-dayflow-offset-reset)
    (define-key map (kbd "h") #'org-dayflow-scroll-right)
    (define-key map (kbd "l") #'org-dayflow-scroll-left)
    ;; `/' matches org-agenda-filter; `]' kept as a legacy alias.
    (define-key map (kbd "/") #'org-dayflow-filter-dispatch)
    (define-key map (kbd "]") #'org-dayflow-filter-dispatch)
    (define-key map (kbd "f") #'org-dayflow-toggle-follow)
    (define-key map (kbd "s") #'org-dayflow-schedule)
    (define-key map (kbd "d") #'org-dayflow-deadline)
    (define-key map (kbd "t") #'org-dayflow-todo)
    (define-key map (kbd "e") #'org-dayflow-echo-info)
    map)
  "Keymap for `org-dayflow-mode`.")

;;; Utility commands
(defun org-dayflow--span-unit (&optional span)
  "Return the unit one column stands for in SPAN."
  (or (car (alist-get (or span org-dayflow--current-span) org-dayflow-spans))
      'day))

(defun org-dayflow--span-cells (&optional span)
  "Return the number of columns SPAN aims for."
  (or (cadr (alist-get (or span org-dayflow--current-span) org-dayflow-spans))
      26))

(defun org-dayflow--view-width ()
  "Return the columns available to the grid.

The window when the buffer is in one, and the frame otherwise -- which is
what a fresh buffer has before it is displayed, and what a batch test has
instead of a window."
  (let ((win (get-buffer-window (current-buffer) nil)))
    (if (window-live-p win) (window-body-width win) (frame-width))))

(defun org-dayflow--unit-char-width (&optional span width)
  "Return the width in characters of one column of SPAN in WIDTH columns.

The period asks for a number of columns and the window says how many
characters there are, so the width of one is the division of the two --
clamped below by what the unit\='s digits need and above by
`org-dayflow-max-cell-width\='."
  (let* ((span (or span org-dayflow--current-span))
         (width (or width (org-dayflow--view-width)))
         (unit (org-dayflow--span-unit span))
         (floor-w (+ (alist-get unit org-dayflow-unit-digits 2)
                     org-dayflow-min-cell-gap)))
    (max floor-w
         (min org-dayflow-max-cell-width
              (/ width (max 1 (org-dayflow--span-cells span)))))))

(defun org-dayflow--units-length (&optional span width)
  "Return how many columns of SPAN fit in WIDTH."
  (let ((width (or width (org-dayflow--view-width))))
    (max 1 (/ width (org-dayflow--unit-char-width span width)))))

(defun org-dayflow--unit-format (unit width)
  "Return the format string for one UNIT column WIDTH characters wide."
  (let ((digits (alist-get unit org-dayflow-unit-digits 2)))
    (format "%%0%dd%s" digits (make-string (max 1 (- width digits)) ?\s))))

(defun org-dayflow--label-safe-pos (pos positions)
  "Return the first position >= POS clear of the last entry in POSITIONS.
POSITIONS is a list of (pos label-string) in reverse-push order."
  (if (null positions)
      pos
    (max pos (+ (caar positions) (length (cadr (car positions)))))))

(defun org-dayflow--render-label-positions (positions total-width)
  "Render POSITIONS, sorted (POS LABEL) lists, as a line TOTAL-WIDTH wide."
  (let ((line ""))
    (dolist (entry positions)
      (setq line (concat line
                         (make-string (- (car entry) (length line)) ?\s)
                         (propertize (cadr entry) 'face 'org-dayflow-label-face))))
    (concat line (make-string (max 0 (- total-width (length line))) ?\s))))

(defun org-dayflow--date+ (base &rest adds)
  "Add all ADDS (month day year style) to BASE."
  (calendar-gregorian-from-absolute
   (calendar-absolute-from-gregorian
    (cl-reduce (lambda (a b) (cl-mapcar #'+ a b))
               adds
               :initial-value base))))

(defun org-dayflow--date-start ()
  "Return the date the view starts on, from today and the current offset."
  (org-dayflow--date+ (org-dayflow--datetime-now)
                      (org-dayflow--units-delta org-dayflow--current-offset)))

(defun org-dayflow--units-delta (n)
  "Return N units of the current period as a (MONTHS DAYS YEARS) delta."
  (pcase (org-dayflow--span-unit)
    ('week  (list 0 (* n 7) 0))
    ('month (list n 0 0))
    ('year  (list 0 0 n))
    (_      (list 0 n 0))))

(defun org-dayflow--day- (&rest dates)
  "Return the number of days between the first date and each of the rest."
  (cl-reduce #'- (mapcar #'calendar-absolute-from-gregorian dates)))

(defun org-dayflow--month- (date1 date2)
  "Return the whole months from DATE2 to DATE1, both (month day year ...)."
  (+ (* (- (nth 2 date1) (nth 2 date2)) 12)
     (- (nth 0 date1) (nth 0 date2))))

(defun org-dayflow--decoded-datetime (decoded)
  "Return DECODED, a `decode-time' list, as (month day year hour minute)."
  (list (nth 4 decoded) (nth 3 decoded) (nth 5 decoded)
        (or (nth 2 decoded) 0) (or (nth 1 decoded) 0)))

(defun org-dayflow--datetime-now ()
  "Return current time as (month day year hour minute)."
  (org-dayflow--decoded-datetime (decode-time)))

(defun org-dayflow--datetime-timestamp (timestamp)
  "Convert Org TIMESTAMP to (month day year hour minute), or nil if it is nil."
  (when timestamp
    (org-dayflow--decoded-datetime (org-parse-time-string timestamp))))

(defun org-dayflow--datetime-to-minutes (dt)
  "Convert (month day year hour minute) to absolute minutes."
  (cl-destructuring-bind (month day year hour minute) dt
    (+ (* (calendar-absolute-from-gregorian (list month day year)) 1440)
       (* hour 60)
       minute)))

(defun org-dayflow--minutes-to-datetime (abs-min)
  "Convert absolute minutes to (month day year hour minute)."
  (let* ((abs-days (/ abs-min 1440))
         (rem      (% abs-min 1440)))
    (cl-destructuring-bind (month day year) (calendar-gregorian-from-absolute abs-days)
      (list month day year (/ rem 60) (% rem 60)))))

(defun org-dayflow--datetime-next-day-start (dt)
  "Return DT bumped to 00:00 of the following day."
  (let* ((abs (calendar-absolute-from-gregorian
               (list (nth 0 dt) (nth 1 dt) (nth 2 dt))))
         (next (calendar-gregorian-from-absolute (1+ abs))))
    (list (nth 0 next) (nth 1 next) (nth 2 next) 0 0)))

(defun org-dayflow--datetime-day-start (dt)
  "Return DT with hour/minute stripped to 00:00 of the same day."
  (list (nth 0 dt) (nth 1 dt) (nth 2 dt) 0 0))

(defun org-dayflow--datetime< (&rest datetimes)
  "Return non-nil if DATETIMES are in strictly increasing order by absolute minute."
  (apply #'< (mapcar #'org-dayflow--datetime-to-minutes datetimes)))

(defun org-dayflow--datetime-min (datetimes)
  "Return the earliest datetime in DATETIMES."
  (car (sort (copy-sequence datetimes) #'org-dayflow--datetime<)))

(defun org-dayflow--datetime-max (datetimes)
  "Return the latest datetime in DATETIMES."
  (car (sort (copy-sequence datetimes)
             (lambda (a b) (not (org-dayflow--datetime< a b))))))

;;; Helper commands
(defun org-dayflow--buffer-name (&optional span)
  "Return Org Dayflow buffer name."
  (format "*Org Dayflow(%s)*" (symbol-name (or span org-dayflow-default-span))))

(defun org-dayflow--span-set (span)
  "Show SPAN, and put the view back at its default offset.

The offset is kept as a count of columns, worked out here from the share
the period asks for -- the period\='s own target rather than what the window
happens to be, so opening a view lands in the same place whatever size the
frame is."
  (setq org-dayflow--current-span span)
  (let ((share (or (alist-get span org-dayflow-default-offsets) 0)))
    (setq org-dayflow--current-offset
          (if (floatp share)
              (round (* share (org-dayflow--span-cells span)))
            share))))

(defun org-dayflow--unit-face (now-p)
  "Return the face for a unit cell: now variant if NOW-P is non-nil."
  (if now-p 'org-dayflow-now-unit-face 'org-dayflow-units-face))

(defun org-dayflow--day-scale-labels (start days width)
  "Generate a line of month name labels for DAY units, WIDTH columns each."
  (let* ((start-abs (calendar-absolute-from-gregorian start))
         (positions '()))
    (dotimes (d days)
      (cl-destructuring-bind (month day year)
          (calendar-gregorian-from-absolute (+ start-abs d))
        (let* ((label (format-time-string "%B" (encode-time 0 0 0 day month year))))
          (unless (equal label (cadr (car positions)))
            (push (list (org-dayflow--label-safe-pos (* d width) positions) label)
                  positions)))))
    (org-dayflow--render-label-positions (nreverse positions) (* days width))))

(defun org-dayflow--day-scale-units (start days width)
  "Generate a line of dates from START for DAYS days, WIDTH columns each."
  (let ((start-abs (calendar-absolute-from-gregorian start))
        (today-abs (calendar-absolute-from-gregorian (org-dayflow--datetime-now)))
        (fmt (org-dayflow--unit-format 'day width))
        (line ""))
    (dotimes (d days)
      (let* ((date (calendar-gregorian-from-absolute (+ start-abs d)))
             (dow (calendar-day-of-week date)) ;; 0=Sunday, 6=Saturday
             (face (cond
                    ((= (+ start-abs d) today-abs) 'org-dayflow-now-unit-face)
                    ((or (= dow 0) (= dow 6)) 'org-dayflow-weekend-face)
                    (t 'org-dayflow-weekday-face)))
             (text (propertize (format fmt (nth 1 date)) 'face face)))
        (setq line (concat line text))))
    (string-trim-right line)))

(defun org-dayflow--week-scale-labels (start weeks width)
  "Generate a line of year labels for WEEK units, WIDTH columns each."
  (let* ((start-abs (calendar-absolute-from-gregorian start))
         (positions '()))
    (dotimes (w weeks)
      (let* ((label (format "%d" (nth 2 (calendar-gregorian-from-absolute
                                         (+ start-abs (* w 7)))))))
        (unless (equal label (cadr (car positions)))
          (push (list (org-dayflow--label-safe-pos (* w width) positions) label)
                positions))))
    (org-dayflow--render-label-positions (nreverse positions) (* weeks width))))

(defun org-dayflow--week-scale-units (start weeks width)
  "Generate a line of ISO week numbers from START for WEEKS weeks."
  (let ((start-abs (calendar-absolute-from-gregorian start))
        (today-abs (calendar-absolute-from-gregorian (org-dayflow--datetime-now)))
        (fmt (org-dayflow--unit-format 'week width))
        (line ""))
    (dotimes (w weeks)
      (let* ((week-start-abs (+ start-abs (* w 7)))
             (iso (calendar-iso-from-absolute week-start-abs))
             (iso-week (car iso))
             (face (org-dayflow--unit-face
                    (and (<= week-start-abs today-abs)
                         (< today-abs (+ week-start-abs 7))))))
        (setq line (concat line (propertize (format fmt iso-week) 'face face)))))
    (string-trim-right line)))

(defun org-dayflow--month-scale-labels (start months width)
  "Generate a line of year labels for MONTH units, WIDTH columns each."
  (let* ((year (nth 2 start))
         (month (nth 0 start))
         (positions '())
         (pos 0))
    (dotimes (_ months)
      (when (or (null positions) (= month 1))
        (push (list (org-dayflow--label-safe-pos pos positions) (format "%4d" year))
              positions))
      (setq month (1+ month))
      (when (> month 12)
        (setq month 1)
        (setq year (1+ year)))
      (setq pos (+ pos width)))
    (org-dayflow--render-label-positions (nreverse positions) (* months width))))

(defun org-dayflow--month-scale-units (start months width)
  "Generate a line of month numbers for MONTH units, WIDTH columns each."
  (let* ((now (org-dayflow--datetime-now))
         (month (nth 0 start))
         (year (nth 2 start))
         (fmt (org-dayflow--unit-format 'month width))
         (line ""))
    (dotimes (_i months)
      (let ((face (org-dayflow--unit-face
                   (and (= month (nth 0 now)) (= year (nth 2 now))))))
        (setq line (concat line (propertize (format fmt month) 'face face))))
      (setq month (1+ month))
      (when (> month 12)
        (setq month 1)
        (setq year (1+ year))))
    (string-trim-right line)))

(defun org-dayflow--year-scale-units (start years width)
  "Generate a line of year numbers, WIDTH columns each.

Four digits, because that is what a year is.  Formatted with the grid\='s
own width rather than a shared format string: `%02d\=' pads to two and does
not truncate, so a year drawn that way was a column wider than every other
row on the page."
  (let ((start-year (nth 2 start))
        (today-year (nth 2 (org-dayflow--datetime-now)))
        (fmt (org-dayflow--unit-format 'year width))
        (line ""))
    (dotimes (y years)
      (let ((year (+ start-year y))
            (face (org-dayflow--unit-face (= (+ start-year y) today-year))))
        (setq line (concat line (propertize (format fmt year) 'face face)))))
    (string-trim-right line)))

(defun org-dayflow--year-scale-labels (start years width)
  "Generate a line of decade labels for YEAR units, WIDTH columns each."
  (let* ((start-year (nth 2 start))
         (positions '())
         (pos 0))
    (dotimes (y years)
      (let ((year (+ start-year y)))
        (when (or (null positions) (= (% year 10) 0))
          (push (list (org-dayflow--label-safe-pos pos positions)
                      (format "%4ds" (* (/ year 10) 10)))
                positions))
        (setq pos (+ pos width))))
    (org-dayflow--render-label-positions (nreverse positions) (* years width))))

(defun org-dayflow--scale-lines (span start units width)
  "Generate the label and unit lines for SPAN, WIDTH columns to a unit.
Named for the *unit*, not the period, which is what decides the drawing."
  (let* ((unit     (org-dayflow--span-unit span))
         (label-fn (intern-soft (format "org-dayflow--%s-scale-labels" unit)))
         (unit-fn  (intern-soft (format "org-dayflow--%s-scale-units" unit)))
         (label    (when (fboundp label-fn)
                     (funcall label-fn start units width)))
         (line     (when (fboundp unit-fn)
                     (funcall unit-fn start units width))))
    (if line
        (list label line)
      (error "No unit function found for unit: %s" unit))))

(defun org-dayflow--element-start-datetime (el)
  "Return (month day year hour minute) for the start of timestamp element EL.
Missing hour/minute default to 0."
  (list (org-element-property :month-start el)
        (org-element-property :day-start el)
        (org-element-property :year-start el)
        (or (org-element-property :hour-start el) 0)
        (or (org-element-property :minute-start el) 0)))

(defun org-dayflow--element-end-datetime (el)
  "Return (month day year hour minute) for the end of timestamp element EL.
For date-only timestamps (no :hour-start) the end is bumped to
00:00 of the following day so [START, END) covers the whole
occupied day(s)."
  (let ((month (org-element-property :month-end el))
        (day   (org-element-property :day-end el))
        (year  (org-element-property :year-end el)))
    (if (org-element-property :hour-start el)
        (list month day year
              (or (org-element-property :hour-end el) 0)
              (or (org-element-property :minute-end el) 0))
      (org-dayflow--datetime-next-day-start (list month day year 0 0)))))

(defun org-dayflow--parse-timestamp-string (ts-string)
  "Parse TS-STRING (e.g. \"<2026-07-14 Tue 10:00-11:00>\") to an org-element."
  (when ts-string
    (with-temp-buffer
      (insert ts-string)
      (goto-char (point-min))
      (org-element-timestamp-parser))))

(defun org-dayflow--earliest-active-datetime-range ()
  "Return (START . END) datetimes for the earliest active timestamp
of the current Org entry, or nil.

START and END are (month day year hour minute) lists forming a
half-open interval [START, END).

Uses the entry's special TIMESTAMP property, which resolves to
the first keyword-less active timestamp (body or heading)."
  (let* ((ts-string (org-entry-get (point) "TIMESTAMP"))
         (el (org-dayflow--parse-timestamp-string ts-string)))
    (when (and el
               (memq (org-element-property :type el)
                     '(active active-range)))
      (cons (org-dayflow--element-start-datetime el)
            (org-dayflow--element-end-datetime el)))))

(defun org-dayflow--title-unit (start task-date)
  "Return the cell, counted in the current unit from START, of TASK-DATE."
  (pcase (org-dayflow--span-unit)
    ('day     (org-dayflow--day- task-date start))
    ;; `floor', not `/': a date before START belongs to a cell left of the
    ;; view, and `/' truncates towards zero and would put it in cell 0.
    ('week    (floor (org-dayflow--day- task-date start) 7))
    ('month   (org-dayflow--month- task-date start))
    ('year    (- (nth 2 task-date) (nth 2 start)))
    (_        (org-dayflow--day- task-date start))))

(defun org-dayflow--get-heading-face ()
  "Get the appropriate Org heading face based on the heading level."
  (let ((level (org-current-level)))
    (intern (format "org-level-%d" (or level 1)))))

(defun org-dayflow--highlight-current-heading (marker)
  "Highlight the current heading at MARKER in its buffer."
  (when (and marker (marker-buffer marker))
    (with-current-buffer (marker-buffer marker)
      ;; Remove previous overlay if exists
      (org-dayflow--unhighlight)
      ;; Create new overlay
      (save-excursion
        (goto-char marker)
        (let ((start (line-beginning-position))
              (end (line-end-position)))
          (setq org-dayflow--highlight-overlay
                (make-overlay start end))
          (overlay-put org-dayflow--highlight-overlay 'face 'hl-line))))
    (unless (memq #'org-dayflow--maybe-unhighlight buffer-list-update-hook)
      (add-hook 'buffer-list-update-hook #'org-dayflow--maybe-unhighlight))))

(defun org-dayflow--unhighlight ()
  "Remove the current highlight overlay if it exists."
  (when (and org-dayflow--highlight-overlay (overlayp org-dayflow--highlight-overlay))
    (delete-overlay org-dayflow--highlight-overlay)
    (setq org-dayflow--highlight-overlay nil)))

(defun org-dayflow--maybe-unhighlight ()
  "Unhighlight if Org Dayflow buffer is not current."
  (unless (eq major-mode 'org-dayflow-mode)
    (org-dayflow--unhighlight)))

(defun org-dayflow--move-to-title ()
  "Move to the first non-whitespace character in the current line."
  (beginning-of-line)
  (skip-chars-forward " \t"))

(defun org-dayflow--marker-at-point ()
  "Return the Org marker of the row at point, or nil.
Read from the start of the line: the marker covers a row's title and
the blanks before it but not the padding after, and point past the
title is still on the row."
  (let ((marker (get-text-property (line-beginning-position) 'org-marker)))
    (and marker (marker-buffer marker) marker)))

(defun org-dayflow--arrive ()
  "Settle on the row just moved to: the title, its echo, and follow mode."
  (org-dayflow--move-to-title)
  (org-dayflow-echo-info)
  (when org-dayflow--follow-mode
    (org-dayflow--follow)
    (org-dayflow--highlight-current-heading (org-dayflow--marker-at-point))))

(defun org-dayflow--follow ()
  "Display the Org heading at point in another window, keeping focus here."
  (let ((marker (org-dayflow--marker-at-point)))
    (when marker
      (display-buffer (marker-buffer marker))
      (with-selected-window (get-buffer-window (marker-buffer marker))
        (goto-char marker)
        (org-fold-show-entry)))))

(defun org-dayflow--build-query (base-query &optional append-query)
  "Combine BASE-QUERY with APPEND-QUERY into a well-formed query.

- If BASE-QUERY is nil, use `org-dayflow-initial-query` as the base.
- Ensures the resulting query is wrapped with a top-level `and` form.
- If APPEND-QUERY is a list of queries, append each element.
- If APPEND-QUERY is a single query form, wrap and append it.
- If APPEND-QUERY is nil, return the well-formed BASE-QUERY as-is."
  (let* ((raw (or base-query org-dayflow-initial-query))
         (listed (if (and (listp raw) (listp (cadr raw)))
                     raw (list raw)))
         (wellformed (if (eq (car listed) 'and) listed (cons 'and listed))))
    (cond
     ((null append-query) wellformed)
     ((and (listp append-query)
           (listp (car append-query)))
      (append wellformed append-query))
     (t
      (append wellformed (list append-query))))))

(cl-defstruct (org-dayflow--node (:constructor org-dayflow--node-create)
                                 (:copier nil))
  "One heading, and what its subtree adds up to.

START and END bound every date in the subtree, MILESTONES are its
deadlines as (DATETIME . DONE) -- both over the whole subtree,
whether or not QUERY shows the rest of it, so a parent's line does
not shrink as its children are done.  SHOWN is whether the heading
or anything under it matches the query.  KEY names the heading
across renders: its file and its outline path, innermost first."
  task level key match children start end milestones shown)

(defun org-dayflow--task-milestones (task)
  "Return TASK's own deadline as a list of (DATETIME . DONE), or nil."
  (let ((dt (org-dayflow--datetime-timestamp (plist-get task :deadline))))
    (and dt (list (cons dt (and (org-dayflow--task-done-p task) t))))))

(defun org-dayflow--node-finish (node)
  "Put NODE's children in file order and add up its subtree."
  (let* ((task (org-dayflow--node-task node))
         (kids (nreverse (org-dayflow--node-children node)))
         (range (org-dayflow--task-range task))
         (starts (and range (list (car range))))
         (ends (and range (list (cdr range))))
         (milestones (org-dayflow--task-milestones task)))
    (setf (org-dayflow--node-children node) kids)
    (dolist (kid kids)
      (org-dayflow--node-finish kid)
      (when (org-dayflow--node-start kid)
        (push (org-dayflow--node-start kid) starts)
        (push (org-dayflow--node-end kid) ends))
      (setq milestones (append milestones (org-dayflow--node-milestones kid))))
    (setf (org-dayflow--node-start node)
          (and starts (org-dayflow--datetime-min starts))
          (org-dayflow--node-end node)
          (and ends (org-dayflow--datetime-max ends))
          (org-dayflow--node-milestones node) milestones
          (org-dayflow--node-shown node)
          (or (org-dayflow--node-match node)
              (cl-some #'org-dayflow--node-shown kids)))))

(defun org-dayflow--file-nodes (query)
  "Return the top-level nodes of the current buffer's outline.
Every heading becomes a node, matching QUERY or not: what a parent
spans is decided by all of its children."
  (let (roots stack)
    (org-map-entries
     (lambda ()
       (let ((level (org-outline-level))
             (task (org-dayflow--extract-task)))
         (while (and stack (>= (org-dayflow--node-level (car stack)) level))
           (pop stack))
         (let ((node (org-dayflow--node-create
                      :task task :level level
                      :match (org-dayflow--query-matches-p query)
                      :key (cons (buffer-file-name)
                                 (cons (plist-get task :title)
                                       (and stack (cdr (org-dayflow--node-key
                                                        (car stack)))))))))
           (if stack
               (push node (org-dayflow--node-children (car stack)))
             (push node roots))
           (push node stack))))
     nil 'file)
    (setq roots (nreverse roots))
    (mapc #'org-dayflow--node-finish roots)
    roots))

(defun org-dayflow--prune (nodes)
  "Keep the NODES that are shown, and the shown nodes under them."
  (cl-loop for node in nodes
           when (org-dayflow--node-shown node)
           do (setf (org-dayflow--node-children node)
                    (org-dayflow--prune (org-dayflow--node-children node)))
           and collect node))

(defun org-dayflow--excluded-files ()
  "Return the true names of the files `org-dayflow-exclude-files' names."
  (let (names)
    (dolist (entry org-dayflow-exclude-files)
      (let ((value (cond ((stringp entry) entry)
                         ((functionp entry) (funcall entry)))))
        (dolist (file (if (listp value) value (list value)))
          (when (stringp file)
            (push (file-truename file) names)))))
    names))

(defun org-dayflow--files ()
  "Return the files the timeline reads.
`org-agenda-files', less those in `org-dayflow-exclude-files'."
  (let ((excluded (org-dayflow--excluded-files)))
    (cl-remove-if (lambda (file) (member (file-truename file) excluded))
                  (org-agenda-files))))

(defun org-dayflow--select-tree (query)
  "Return the outline of `org-dayflow--files' as far as QUERY shows it.
A heading is kept when it or something under it matches, so a match
arrives with the headings it belongs to."
  (let (roots)
    (dolist (file (org-dayflow--files))
      (when (file-exists-p file)
        (with-current-buffer (find-file-noselect file)
          ;; Ensure Org's keyword and tag caches are populated for this buffer.
          (org-set-regexps-and-options nil)
          (setq roots (append roots (org-dayflow--file-nodes query))))))
    (org-dayflow--prune roots)))

(defun org-dayflow--leaf-tasks (nodes)
  "Return the tasks of the rows under NODES that have no rows under them.
These are the work; a parent row only adds its children up."
  (cl-loop for node in nodes
           append (if (org-dayflow--node-children node)
                      (org-dayflow--leaf-tasks (org-dayflow--node-children node))
                    (list (org-dayflow--node-task node)))))

(defun org-dayflow--tree-depth-of (nodes)
  "Return how many levels deep NODES go."
  (if nodes
      (1+ (apply #'max (mapcar (lambda (node)
                                 (org-dayflow--tree-depth-of
                                  (org-dayflow--node-children node)))
                               nodes)))
    0))

(defun org-dayflow--node-open-p (node depth)
  "Return non-nil if NODE, DEPTH levels down, shows its children."
  (pcase (and org-dayflow--folds
              (gethash (org-dayflow--node-key node) org-dayflow--folds))
    ('open t)
    ('folded nil)
    (_ (or (null org-dayflow--visible-depth)
           (< (1+ depth) org-dayflow--visible-depth)))))

(defun org-dayflow--query-matches-p (query)
  "Return non-nil if the Org heading at point satisfies QUERY.
QUERY is a (possibly nested) S-expression using the operators and/or/not
and the atomic forms understood by `org-dayflow--query-atom-matches-p'."
  (cond
   ((null query) t)
   ((eq (car-safe query) 'and)
    (cl-every #'org-dayflow--query-matches-p (cdr query)))
   ((eq (car-safe query) 'or)
    (cl-some #'org-dayflow--query-matches-p (cdr query)))
   ((eq (car-safe query) 'not)
    (not (org-dayflow--query-matches-p (cadr query))))
   ((listp query)
    ;; Top-level bare list or single atom: treat as implicit AND or single atom.
    (if (and (listp (car query)) (not (symbolp (caar query))))
        (cl-every #'org-dayflow--query-matches-p query)
      (org-dayflow--query-atom-matches-p query)))
   (t nil)))

(defun org-dayflow--timestamp-on-day-p (ts-string month day year)
  "Return non-nil if TS-STRING falls on calendar day MONTH/DAY/YEAR."
  (let ((dt (org-dayflow--datetime-timestamp ts-string)))
    (and dt
         (= (nth 0 dt) month)
         (= (nth 1 dt) day)
         (= (nth 2 dt) year))))

(defun org-dayflow--entry-on-day-p (month day year)
  "Return non-nil if the heading at point is dated on MONTH/DAY/YEAR.
Matches SCHEDULED, DEADLINE, or the first active TIMESTAMP day."
  (or (org-dayflow--timestamp-on-day-p
       (org-entry-get nil "SCHEDULED") month day year)
      (org-dayflow--timestamp-on-day-p
       (org-entry-get nil "DEADLINE") month day year)
      (org-dayflow--timestamp-on-day-p
       (org-entry-get nil "TIMESTAMP") month day year)))

(defun org-dayflow--query-atom-matches-p (atom)
  "Return non-nil if the atomic query form ATOM matches the heading at point."
  (pcase atom
    (`(scheduled) (not (null (org-entry-get nil "SCHEDULED"))))
    (`(deadline)  (not (null (org-entry-get nil "DEADLINE"))))
    (`(done)
     ;; Mirror `org-dayflow--task-done-p' / Org done keywords for the
     ;; heading at point (covers DONE, CANCEL, DELEG, etc.).
     (let* ((todo (org-get-todo-state))
            (done-kws (or (bound-and-true-p org-done-keywords-for-agenda)
                          (bound-and-true-p org-done-keywords))))
       (and todo done-kws (member todo done-kws))))
    (`(on-day ,month ,day ,year)
     (org-dayflow--entry-on-day-p month day year))
    (`(tags ,tag) (member tag (org-get-tags)))
    (`(todo ,kw)  (string= (org-get-todo-state) kw))
    (`(property ,prop ,val)
     (string= (org-entry-get nil prop) val))
    (`(category ,cat)
     (string= (org-get-category) cat))
    (`(regexp ,re)
     (let* ((case-fold-search t)
            (re (cond
                 ((stringp re) re)
                 ((and (symbolp re) (boundp re) (stringp (symbol-value re)))
                  (symbol-value re))
                 (t (prin1-to-string re)))))
       (save-excursion
         (org-back-to-heading t)
         (let ((end (save-excursion (or (outline-next-heading) (point-max)))))
           (re-search-forward re end t)))))
    (_ nil)))

(defun org-dayflow--unit-index-to-datetime (unit)
  "Return (month day year hour minute) for UNIT index in the current view."
  (append (org-dayflow--date+ (org-dayflow--date-start)
                              (org-dayflow--units-delta unit))
          '(0 0)))

(defun org-dayflow--format-datetime-short (dt)
  "Format DT (month day year ...) as \"YYYY-MM-DD Day\"."
  (when dt
    (let* ((month (nth 0 dt))
           (day (nth 1 dt))
           (year (nth 2 dt))
           (dow (calendar-day-of-week (list month day year)))
           (name (aref calendar-day-name-array dow)))
      (format "%04d-%02d-%02d %s" year month day (substring name 0 3)))))

(defun org-dayflow--task-anchor-datetime (task)
  "Datetime used to place TASK on the timeline (deadline > active > scheduled)."
  (cl-destructuring-bind (&key scheduled deadline occupation-start
                               &allow-other-keys) task
    (or (org-dayflow--datetime-timestamp deadline)
        occupation-start
        (org-dayflow--datetime-timestamp scheduled))))

(defun org-dayflow--query-for-unit-at-point ()
  "Build a query restricting to the calendar day of the unit under point.
On day scale this is a true day filter; on coarser/finer scales it uses
the unit's start day via `on-day'."
  (let ((cell (org-dayflow--cursor-cell)))
    (unless cell
      (user-error "No unit under point"))
    (let* ((dt (org-dayflow--unit-index-to-datetime cell))
           (day-q `(on-day ,(nth 0 dt) ,(nth 1 dt) ,(nth 2 dt))))
      `(and (or (scheduled) (deadline) (regexp org-ts-regexp))
            ,day-q))))

(defun org-dayflow--builtin-query-presets ()
  "Alist of (LABEL . QUERY) built-in presets for query selection.
QUERY may also be the symbol `unit-at-point', resolved at apply time."
  (list
   (cons "[preset]: open + dated (default)"
         '((and (or (scheduled) (deadline) (regexp org-ts-regexp))
                (not (done)))))
   (cons "[preset]: all dated (include done)"
         '((or (scheduled) (deadline) (regexp org-ts-regexp))))
   (cons "[preset]: open only (any heading)"
         '((not (done))))
   (cons "[preset]: done only"
         '((done)))
   (cons "[preset]: unit at point"
         'unit-at-point)
   (cons "[preset]: scheduled"
         '((and (scheduled) (not (done)))))
   (cons "[preset]: deadline"
         '((and (deadline) (not (done)))))))

(defun org-dayflow--read-filter-char (type)
  "Read a filter key for TYPE: + or - include or exclude, TAB select,
\\ clear, . filter at point, q quit."
  (let ((prompt (format "Filter[%s] %s: [TAB]select [.]point [\\]off [q]uit"
                        (if org-dayflow--filter-exclude "-" "+") type)))
    (read-char-exclusive prompt)))

(defun org-dayflow--filter-by (label candidates builder &optional immediate actions)
  "Generic filter for org-dayflow.
LABEL is a string shown in prompt.
CANDIDATES is a list of strings for completion.
BUILDER is a function that takes a string and returns a query S-expression.
ACTIONS is an alist of extra keys, each a function that *returns* a query --
or a list of them -- and nil when it has nothing to give.  Returned rather
than assigned: an action written in another function cannot reach the local
this one is collecting into, and the one that tried set a global of the same
name instead and filtered nothing at all."
  (let (new-query)
    (catch 'quit
      (cl-flet ((filter-from (reader)
                  (let ((input (funcall reader)))
                    (unless (string-empty-p input)
                      (setq new-query
                            (if org-dayflow--filter-exclude
                                `(not ,(funcall builder input))
                              (funcall builder input))))))
                (completing-reader ()
                  (completing-read (format "%s: " label) candidates nil t))
                (string-reader ()
                  (read-string (format "%s: " label))))
        (if immediate
            (let ((reader (if candidates #'completing-reader #'string-reader)))
              (filter-from reader)
              (throw 'quit nil))
          (while t
            (let ((char (org-dayflow--read-filter-char label)))
              (cond
               ((eq char ?+) (setq org-dayflow--filter-exclude nil))
               ((eq char ?-) (setq org-dayflow--filter-exclude t))
               ((eq char ?\\) (org-dayflow-remove-filter) (throw 'quit nil))
               ((eq char ?q) (throw 'quit nil))
               ((eq char ?\t) 
                (let ((reader (if candidates #'completing-reader #'string-reader)))
                  (filter-from reader)
                  (throw 'quit nil)))
               ((assoc char actions)
                (setq new-query (funcall (cdr (assoc char actions))))
                (when new-query (throw 'quit nil)))
               (t (message "Invalid key: %s" (single-key-description char)))))))))
    (when new-query
      (org-dayflow--add-query new-query))))

(defun org-dayflow--use-query (query)
  "Show QUERY, remember it for this session, and redraw."
  (setq org-dayflow--current-query query)
  (unless (member query org-dayflow--query-session)
    (push query org-dayflow--query-session))
  (org-dayflow-refresh))

(defun org-dayflow--add-query (query)
  "Narrow the current query by QUERY, as `org-dayflow--use-query' does."
  (org-dayflow--use-query
   (org-dayflow--build-query org-dayflow--current-query query)))

(defun org-dayflow--collect-todo-keywords ()
  "Return every keyword in `org-todo-keywords', without its key in parens."
  (let (result)
    (dolist (seq org-todo-keywords (nreverse result))
      (dolist (kw (cdr seq))
        (unless (string= kw "|")
          (push (replace-regexp-in-string "(.*)" "" kw) result))))))

(defun org-dayflow--collect-properties ()
  "Collect all unique property names from `org-dayflow--files'."
  (let (props)
    (dolist (file (org-dayflow--files))
      (with-current-buffer (find-file-noselect file)
        (org-map-entries
         (lambda ()
           (let ((entry-props (org-entry-properties nil 'standard)))
             (dolist (prop entry-props)
               (push (car prop) props)))))))
    (delete-dups props)))

(defun org-dayflow--collect-property-candidates (prop)
  "Return allowed values for PROP, considering global and buffer-local settings."
  (let ((marker (org-dayflow--marker-at-point)))
    (when marker
      (with-current-buffer (marker-buffer marker)
        (org-with-wide-buffer
         (goto-char (point-min))
         (let ((allowed (org-property-get-allowed-values nil prop)))
           (when allowed
             (if (listp (car allowed))
                 (mapcar #'car allowed)
               allowed))))))))

(defun org-dayflow--property-filter-builder ()
  (lambda (prop)
    (let* ((candidates (org-dayflow--collect-property-candidates prop))
           (value (if candidates
                      (completing-read (format "Value for %s: " prop) candidates nil t)
                    (read-string (format "Value for %s: " prop)))))
      `(property ,prop ,value))))

(defun org-dayflow--collect-categories ()
  "Collect all unique categories from `org-dayflow--files'."
  (let (categories)
    (dolist (file (org-dayflow--files))
      (with-current-buffer (find-file-noselect file)
        (org-map-entries
         (lambda ()
           (let ((cat (org-get-category)))
             (push cat categories))))))
    (delete-dups categories)))

(defun org-dayflow--act-on-task (func)
  "Call FUNC (like `org-schedule`) on the task at point in org-dayflow buffer.
Display MESSAGE along with the timestamp."
  (interactive)
  (let ((marker (org-dayflow--marker-at-point)))
    (unless marker (user-error "No task at point"))
    ;; The agenda, for `org-with-remote-undo' and the two variables its
    ;; expansion reads.  Here rather than at the top of the file: this is the
    ;; only thing in the package that needs it.
    (require 'org-agenda)
    (org-with-remote-undo (marker-buffer marker)
      (with-current-buffer (marker-buffer marker)
        (widen)
        (goto-char (marker-position marker))
        (let ((result (funcall func nil)))
          (org-dayflow-refresh)
          (message "%s" result))))))

(defun org-dayflow--task-type (task)
  "Return the type symbol of TASK: `deadline', `scheduled', or `active'."
  (cond
   ((plist-get task :deadline) 'deadline)
   ((plist-get task :scheduled) 'scheduled)
   ((plist-get task :timestamp) 'active)
   (t 'active)))

(defun org-dayflow--task-done-p (task)
  "Return non-nil if TASK is marked as done (e.g., DONE, CANCEL, DELEG)."
  (let* ((todo (plist-get task :todo))
         (done-keywords (or (bound-and-true-p org-done-keywords-for-agenda)
                            (bound-and-true-p org-done-keywords)
                            (cl-loop for (_type . kws) in org-todo-keywords
                                     append
                                     (let ((sep (cl-position "|" kws :test #'equal)))
                                       (when sep
                                         (mapcar (lambda (kw)
                                                   (car (split-string kw "(")))
                                                 (cl-subseq kws (1+ sep)))))))))
    (and todo (member todo done-keywords))))

(defun org-dayflow--spark-char (frac)
  "Return a `org-dayflow-spark-chars' glyph for FRAC in [0.0, 1.0].
FRAC <= 0 yields nil (caller inserts a blank cell)."
  (when (> frac 0.0)
    (let ((n (1- (length org-dayflow-spark-chars))))
      (when (>= n 0)
        (aref org-dayflow-spark-chars
              (max 0 (min n (round (* frac n)))))))))

(defun org-dayflow--type-priority (type)
  "Lower number = higher priority for dominant-type selection."
  (pcase type
    ('deadline 0)
    ('active 1)
    ('scheduled 2)
    (_ 3)))

(defun org-dayflow--dominant-type (types)
  "Return the highest-priority type symbol in TYPES, or nil if empty."
  (car (cl-sort (copy-sequence types) #'< :key #'org-dayflow--type-priority)))

(defun org-dayflow--spark-face (incomplete-types done-types)
  "Face for a sparkline cell from incomplete/done type lists."
  (let* ((key (cond
               (incomplete-types (org-dayflow--dominant-type incomplete-types))
               (done-types
                (intern (format "%s-done"
                                (org-dayflow--dominant-type done-types))))
               (t nil))))
    (and key (alist-get key org-dayflow-histogram-face-alist))))

(defun org-dayflow--insert-sparkline (tasks start units unit-char-width)
  "Insert a one-line load sparkline: one block glyph per unit.

Height encodes how many tasks land on that unit (relative to the
busiest unit in view).  Face encodes dominant task type (incomplete
preferred; otherwise a done-face variant)."
  (let ((counts (make-vector units 0))
        (incomplete-types (make-vector units nil))
        (done-types (make-vector units nil)))
    (dolist (task tasks)
      (let ((unit (org-dayflow--anchor-cell task start units)))
        (when unit
          (aset counts unit (1+ (aref counts unit)))
          (let* ((type (org-dayflow--task-type task))
                 (done (org-dayflow--task-done-p task))
                 (bucket (if done done-types incomplete-types)))
            (aset bucket unit (cons type (aref bucket unit)))))))
    (let ((max-count (or (cl-loop for i below units
                                  maximize (aref counts i))
                         0)))
      (dotimes (unit units)
        (let* ((count (aref counts unit))
               (frac (if (and max-count (> max-count 0))
                         (/ (float count) max-count)
                       0.0))
               (glyph (org-dayflow--spark-char frac))
               (face (org-dayflow--spark-face
                      (aref incomplete-types unit)
                      (aref done-types unit)))
               (cell (if glyph
                         (let ((s (char-to-string glyph)))
                           (if face (propertize s 'face face) s))
                       " ")))
          (insert cell)
          (insert (make-string (max 0 (- unit-char-width 1)) ?\s))))
      (insert "\n"))))

(defun org-dayflow--extract-task ()
  "Create a task plist from the current Org heading.

Working-window range (:working-start .. :working-end) is derived
from SCHEDULED and DEADLINE, treated as whole-day extents
(half-open, ends at 00:00 of the day following DEADLINE).  An open
task whose window is already behind it is still owed, so its window
runs on to the end of today, as the agenda carries it forward.
Occupation range (:occupation-start .. :occupation-end) is
derived from the earliest active timestamp in the entry."
  (save-excursion
    (org-back-to-heading t)
    (let* ((marker (point-marker))
           (title (org-get-heading t t t t))
           (todo (org-no-properties (org-get-todo-state)))
           (deadline (org-entry-get (point) "DEADLINE"))
           (scheduled (org-entry-get (point) "SCHEDULED"))
           (deadline-dt  (org-dayflow--datetime-timestamp deadline))
           (scheduled-dt (org-dayflow--datetime-timestamp scheduled))
           (working-dts  (delq nil (list scheduled-dt deadline-dt)))
           (working-start (when working-dts
                            (org-dayflow--datetime-day-start
                             (org-dayflow--datetime-min working-dts))))
           (working-end   (when working-dts
                            (let ((end (org-dayflow--datetime-next-day-start
                                        (org-dayflow--datetime-max working-dts)))
                                  (tomorrow (org-dayflow--datetime-next-day-start
                                             (org-dayflow--datetime-now))))
                              (if (and todo
                                       (not (org-dayflow--task-done-p
                                             (list :todo todo)))
                                       (org-dayflow--datetime< end tomorrow))
                                  tomorrow
                                end))))
           (occ (org-dayflow--earliest-active-datetime-range)))
      `(:title ,title :marker ,marker :todo ,todo
               :category ,(org-entry-get (point) "CATEGORY")
               :scheduled ,scheduled :deadline ,deadline
               :working-start ,working-start :working-end ,working-end
               :occupation-start ,(car occ) :occupation-end ,(cdr occ)))))

(defun org-dayflow--anchor-cell (task start units)
  "Return the cell of TASK's one date (deadline > active > scheduled), or nil.
What the sparkline counts a task against: one cell per task, so the
load is not spread over every day a long task is open."
  (let ((date (org-dayflow--task-anchor-datetime task)))
    (when date
      (let ((offset (org-dayflow--title-unit start date)))
        (when (and (<= 0 offset) (< offset units))
          offset)))))

(defun org-dayflow--task-range (task)
  "Return (START . END) over TASK's working window and occupation, or nil."
  (let ((starts (delq nil (list (plist-get task :working-start)
                                (plist-get task :occupation-start))))
        (ends (delq nil (list (plist-get task :working-end)
                              (plist-get task :occupation-end)))))
    (and starts ends
         (cons (org-dayflow--datetime-min starts)
               (org-dayflow--datetime-max ends)))))

(defun org-dayflow--range-cells (view-start start-dt end-dt)
  "Return (FIRST . LAST), the cells [START-DT, END-DT) touches from VIEW-START.
END-DT is exclusive, so LAST is the cell of the minute before it; a
range with no length touches the one cell it starts in."
  (let ((first (org-dayflow--title-unit view-start start-dt)))
    (cons first
          (max first
               (org-dayflow--title-unit
                view-start (org-dayflow--minutes-to-datetime
                            (1- (org-dayflow--datetime-to-minutes end-dt))))))))

(defun org-dayflow--title-position (task start units)
  "Return the cell where TASK's title starts, or nil if TASK misses the view.

A task is drawn whenever any of its range is in view, and its title
starts where the range enters it.  Placing it by one date instead
dropped every task whose date was off the screen: one running from
last month to next, one scheduled this week and due the next month,
one overdue and still open."
  (let ((range (org-dayflow--task-range task)))
    (when range
      (pcase-let ((`(,first . ,last)
                   (org-dayflow--range-cells start (car range) (cdr range))))
        (when (and (< first units) (>= last 0))
          (max 0 first))))))

(defun org-dayflow--category-face (task)
  "Face for TASK's category per `org-dayflow-category-faces', or nil."
  (let ((cat (plist-get task :category)))
    (and cat (cdr (assoc cat org-dayflow-category-faces)))))

(defun org-dayflow--title-face (task)
  "Face for TASK's title: done, else its category's, else its level's."
  (cond
   ((org-dayflow--task-done-p task) 'org-dayflow-title-done-face)
   ((org-dayflow--category-face task))
   (t (let ((marker (plist-get task :marker)))
        (with-current-buffer (marker-buffer marker)
          (save-excursion
            (goto-char marker)
            (org-dayflow--get-heading-face)))))))

(defun org-dayflow--summary-milestones (node open start units)
  "Return ((CELL . FACE) ...) for the deadlines NODE's row marks.
Folded, the row stands for its subtree and marks every deadline in
it; OPEN, the children show their own and the row marks only its
own.  START and UNITS are the view's."
  (let (cells)
    (pcase-dolist (`(,dt . ,done)
                   (if open
                       (org-dayflow--task-milestones (org-dayflow--node-task node))
                     (org-dayflow--node-milestones node)))
      (let ((cell (org-dayflow--title-unit start dt)))
        (when (and (<= 0 cell) (< cell units))
          (let ((face (if done 'org-dayflow-milestone-done-face
                        'org-dayflow-milestone-face))
                (old (assq cell cells)))
            ;; One that is still open outranks one met on the same cell.
            (cond ((not old) (push (cons cell face) cells))
                  ((not done) (setcdr old face)))))))
    cells))

(defun org-dayflow--insert-summary (node open start units unit-char-width)
  "Insert NODE's row as a line across the dates of its whole subtree.

The title starts where the subtree does, after a ▾ when OPEN and a
▸ when folded, and a rule runs on to where it ends, with a ◆ on
each deadline from `org-dayflow--summary-milestones'.  A deadline
that falls under the title is marked by colouring its cell instead.
Return nil, inserting nothing, when the subtree misses the view."
  (let ((s (org-dayflow--node-start node))
        (e (org-dayflow--node-end node)))
    (when (and s e)
      (pcase-let ((`(,first . ,last) (org-dayflow--range-cells start s e)))
        (when (and (< first units) (>= last 0))
          (let* ((task (org-dayflow--node-task node))
                 (face (org-dayflow--title-face task))
                 (end-col (* (min units (1+ last)) unit-char-width))
                 (milestones (org-dayflow--summary-milestones
                              node open start units))
                 (bol (point))
                 label-end)
            (insert (make-string (* (max 0 first) unit-char-width) ?\s))
            (insert (propertize (concat (if open "▾" "▸") (plist-get task :title))
                                'face (list 'org-dayflow-summary-face face)))
            (setq label-end (current-column))
            (when (< label-end end-col) (insert " "))
            (while (< (current-column) end-col)
              (let ((ms (assq (/ (current-column) unit-char-width) milestones)))
                (if (not ms)
                    (insert (propertize "─" 'face face))
                  (insert (propertize "◆" 'face (cdr ms)))
                  (setq milestones (delq ms milestones)))))
            (pcase-dolist (`(,cell . ,ms-face) milestones)
              (let ((left (org-dayflow--pos-at-column (* cell unit-char-width)))
                    (right (org-dayflow--pos-at-column
                            (* (1+ cell) unit-char-width))))
                (when (< left right)
                  (add-face-text-property left right ms-face))))
            (add-text-properties bol (point)
                                 (list 'org-marker (plist-get task :marker)
                                       'org-dayflow-node node
                                       'org-dayflow-open open))
            (insert "\n")
            t))))))

(defun org-dayflow--insert-task (node start units unit-char-width)
  "Insert NODE's row: its title where its range enters the view.
The working window is boxed and the occupation filled on the line.
Padding left of the title has no face, so a done title's
strike-through does not run into empty columns; `org-marker' covers
the whole line, so the row is found from any column.  Insert nothing
when the range misses the view."
  (let* ((task (org-dayflow--node-task node))
         (offset (org-dayflow--title-position task start units)))
    (when offset
      (let ((bol (point)))
        (insert (make-string (* offset unit-char-width) ?\s))
        (insert (propertize (concat "*" (plist-get task :title))
                            'face (org-dayflow--title-face task)))
        (add-text-properties bol (point)
                             (list 'org-marker (plist-get task :marker)
                                   'org-dayflow-node node))
        (insert "\n"))
      ;; Painted on the line just inserted.
      (org-dayflow--draw-occupation-background
       (org-dayflow--occupation-region task start units unit-char-width))
      (org-dayflow--draw-working-box
       (org-dayflow--working-region task start units unit-char-width)))))

(defun org-dayflow--insert-nodes (nodes depth start units unit-char-width)
  "Insert a row for each of NODES, DEPTH levels down, and the open ones' children.
A row with rows under it is a summary line; a row without is a task,
drawn when its range is in view."
  (dolist (node nodes)
    (let ((kids (org-dayflow--node-children node)))
      (if (not kids)
          (org-dayflow--insert-task node start units unit-char-width)
        (let ((open (org-dayflow--node-open-p node depth)))
          (when (and (org-dayflow--insert-summary
                      node open start units unit-char-width)
                     open)
            (org-dayflow--insert-nodes kids (1+ depth)
                                       start units unit-char-width)))))))

(defun org-dayflow--range-region (start-dt end-dt view-start units unit-char-width)
  "Return (BAR-POS-START . BAR-POS-END) of the character span covering
the datetime range [START-DT, END-DT) on the current title line, or
nil if outside view.

Any cell that the range touches at all is included, as is in
`org-dayflow--range-cells'."
  (when (and start-dt end-dt)
    (let* ((cells (org-dayflow--range-cells view-start start-dt end-dt))
           (bar-start (max 0 (car cells)))
           (bar-end   (min units (1+ (cdr cells)))))
      (when (> bar-end bar-start)
        (save-excursion
          (forward-line -1)
          (beginning-of-line)
          (move-to-column (* bar-start unit-char-width) t)
          (let ((left (point)))
            (move-to-column (* bar-end unit-char-width) t)
            (cons left (point))))))))

(defun org-dayflow--working-region (task view-start units unit-char-width)
  "Return the character region for TASK's working-window range, or nil."
  (cl-destructuring-bind (&key working-start working-end &allow-other-keys) task
    (org-dayflow--range-region working-start working-end
                               view-start units unit-char-width)))

(defun org-dayflow--occupation-region (task view-start units unit-char-width)
  "Return the character region for TASK's active occupation range, or nil."
  (cl-destructuring-bind (&key occupation-start occupation-end &allow-other-keys) task
    (org-dayflow--range-region occupation-start occupation-end
                               view-start units unit-char-width)))

(defun org-dayflow--draw-working-box (region)
  "Apply the working-window box face to REGION as a text property."
  (when region
    (add-face-text-property (car region) (cdr region)
                            'org-dayflow-title-box-face)))

(defun org-dayflow--draw-occupation-background (region)
  "Apply the occupation background face to REGION as a text property."
  (when region
    (add-face-text-property (car region) (cdr region)
                            'org-dayflow-title-occupation-face)))

(defun org-dayflow--paint-column-face (grid-start unit units unit-char-width face)
  "Apply FACE to UNIT's cell on every grid row from GRID-START (APPEND).
No-op when UNIT is outside [0, UNITS)."
  (when (and (<= 0 unit) (< unit units))
    (let ((left-col  (* unit unit-char-width))
          (right-col (* (1+ unit) unit-char-width)))
      (save-excursion
        (goto-char grid-start)
        (while (not (eobp))
          (beginning-of-line)
          (move-to-column left-col t)
          (let ((start-pos (point)))
            (move-to-column right-col t)
            (add-face-text-property start-pos (point) face t))
          (forward-line 1))))))

(defun org-dayflow--draw-column-bands (grid-start view-start units unit-char-width)
  "Shade weekend columns on day scale when `org-dayflow-column-bands' is set.
Uses a single face (`org-dayflow-weekend-column-face') so the cue stays
simple: denser shade = Saturday/Sunday."
  (when (and org-dayflow-column-bands
             (eq (org-dayflow--span-unit) 'day))
    (let ((start-abs (calendar-absolute-from-gregorian view-start)))
      (dotimes (unit units)
        (let* ((date (calendar-gregorian-from-absolute (+ start-abs unit)))
               (dow (calendar-day-of-week date)))
          (when (or (= dow 0) (= dow 6))
            (org-dayflow--paint-column-face
             grid-start unit units unit-char-width
             'org-dayflow-weekend-column-face)))))))

(defun org-dayflow--draw-now-column (grid-start view-start units unit-char-width)
  "Paint the now-column face across every grid row from GRID-START.
No-op when the current time falls outside the view.

Uses `move-to-column' with FORCE = t so the highlight lands at the
correct display column even on lines containing multibyte characters,
and short / blank lines get padded with spaces to reach the column.
APPEND = t so any pre-existing face (title / occupation / box)
keeps priority in the merged `face' text property."
  (let ((now-cell (org-dayflow--title-unit
                   view-start (org-dayflow--datetime-now))))
    (org-dayflow--paint-column-face
     grid-start now-cell units unit-char-width
     'org-dayflow-now-column-face)))

(defun org-dayflow--cursor-cell ()
  "Return the unit cell index the cursor currently sits on, or nil if outside."
  (let* ((width (org-dayflow--unit-char-width))
         (cell (/ (current-column) width)))
    (when (and (<= 0 cell) (< cell (org-dayflow--units-length)))
      cell)))

(defun org-dayflow--pos-at-column (col)
  "Return buffer position on the current line at display column COL.
Wide (multi-column) characters are never split: when COL falls inside
one, returns the position just past it.  Never modifies the buffer.
If the line ends before COL, returns end-of-line.

`move-to-column' without FORCE does exactly this, in C.  It replaced a
loop of `forward-char' and `current-column' that ran twice for every
row on every keystroke, and was the lag felt on each cursor move."
  (save-excursion
    (beginning-of-line)
    (move-to-column col)
    (point)))

(defun org-dayflow--pad-line-to-column (col)
  "Pad the current line with plain spaces up to display column COL.
Inserted spaces have no text properties, so they do not inherit
face from surrounding text.  No-op when the line already reaches COL."
  (end-of-line)
  (let ((cur (current-column)))
    (when (< cur col)
      (let ((s (point)))
        (insert (make-string (- col cur) ?\s))
        (set-text-properties s (point) nil)))))

(defun org-dayflow--pad-grid-to-full-width (grid-start units unit-char-width)
  "Pad every grid row from GRID-START to full width UNITS * UNIT-CHAR-WIDTH.
Uses face-less spaces so the padding does not inherit any face
from the last real character on the line.  Called at render time
so that `org-dayflow--update-cursor-highlight' can position
overlays without ever modifying the read-only buffer."
  (let ((full (* units unit-char-width)))
    (save-excursion
      (goto-char grid-start)
      (while (not (eobp))
        (org-dayflow--pad-line-to-column full)
        (forward-line 1)))))

(defun org-dayflow--clear-cursor-highlight ()
  "Delete cursor-tracking overlays if any."
  (mapc (lambda (ov) (when (overlayp ov) (delete-overlay ov)))
        org-dayflow--cursor-column-overlays)
  (setq org-dayflow--cursor-column-overlays nil)
  (when (overlayp org-dayflow--cursor-unit-overlay)
    (delete-overlay org-dayflow--cursor-unit-overlay))
  (setq org-dayflow--cursor-unit-overlay nil))

(defun org-dayflow--update-cursor-highlight ()
  "Redraw cursor column / unit overlays for the current cursor position.
Assumes `org-dayflow--render' pre-padded every grid row and the
unit-label row to the full grid width, so this function never has
to modify the (read-only) buffer.  Uses `org-dayflow--pos-at-column'
to keep alignment correct on rows containing multi-column
characters."
  (when (derived-mode-p 'org-dayflow-mode)
    (org-dayflow--clear-cursor-highlight)
    (let ((cell (org-dayflow--cursor-cell))
          (grid org-dayflow--grid-start)
          (unit org-dayflow--unit-line-start))
      (when (and cell grid unit)
        (let* ((width (org-dayflow--unit-char-width))
               (left  (* cell width))
               (right (* (1+ cell) width)))
          (save-excursion
            (goto-char grid)
            (while (not (eobp))
              (let* ((s (org-dayflow--pos-at-column left))
                     (e (org-dayflow--pos-at-column right)))
                (when (< s e)
                  (let ((ov (make-overlay s e)))
                    (overlay-put ov 'face 'org-dayflow-cursor-column-face)
                    (overlay-put ov 'priority -20)
                    (push ov org-dayflow--cursor-column-overlays))))
              (forward-line 1)))
          (save-excursion
            (goto-char unit)
            (let* ((s (org-dayflow--pos-at-column left))
                   (e (org-dayflow--pos-at-column right)))
              (when (< s e)
                (let ((ov (make-overlay s e)))
                  (overlay-put ov 'face 'org-dayflow-cursor-unit-face)
                  (overlay-put ov 'priority 20)
                  (setq org-dayflow--cursor-unit-overlay ov))))))))))

(defun org-dayflow--render ()
  "Render the timeline contents in the current buffer."
  (let* ((start (org-dayflow--date-start))
         (unit-char-width (org-dayflow--unit-char-width))
         (units (org-dayflow--units-length))
         (label-lines (org-dayflow--scale-lines org-dayflow--current-span start units
                                                unit-char-width))
         (tree (org-dayflow--select-tree
                (org-dayflow--build-query org-dayflow--current-query)))
         ;; The load is the work, whatever is folded; parents only add up.
         (tasks (org-dayflow--leaf-tasks tree)))
    (setq org-dayflow--tree-depth (org-dayflow--tree-depth-of tree))
    (let ((inhibit-read-only t))
      (rename-buffer (org-dayflow--buffer-name org-dayflow--current-span) t)
      (erase-buffer)
      (insert (propertize
               (format "query: %s"
                       (prin1-to-string (or org-dayflow--current-query
                                            org-dayflow-initial-query)))
               'face 'org-dayflow-query-face))
      (insert (if org-dayflow-high-density "\n" "\n\n"))
      (org-dayflow--clear-cursor-highlight)
      (let (unit-line-start grid-start body-start)
        (dolist (line label-lines)
          (when line
            (setq unit-line-start (point))
            (insert line "\n")))
        (when unit-line-start
          (save-excursion
            (goto-char unit-line-start)
            (org-dayflow--pad-line-to-column (* units unit-char-width))))
        (setq grid-start (point))
        (org-dayflow--insert-sparkline tasks start units unit-char-width)
        (unless org-dayflow-high-density (insert "\n"))
        ;; A marker: padding the lines above to full width comes later, and
        ;; would leave a position on the blank line before the first row.
        (setq body-start (point-marker))
        (org-dayflow--insert-nodes tree 0 start units unit-char-width)
        (org-dayflow--pad-grid-to-full-width grid-start units unit-char-width)
        ;; Bands first (lowest visual priority), then now-column on top.
        (org-dayflow--draw-column-bands grid-start start units unit-char-width)
        (org-dayflow--draw-now-column grid-start start units unit-char-width)
        (setq org-dayflow--unit-line-start unit-line-start)
        (setq org-dayflow--grid-start grid-start)
        (setq org-dayflow--body-start body-start))
      (goto-char (or org-dayflow--body-start (point-min))))))

;;; User commands
(defun org-dayflow-refresh ()
  "Refresh the current org-dayflow buffer."
  (interactive)
  (when (derived-mode-p 'org-dayflow-mode)
    (org-dayflow--render)))

(defun org-dayflow--span-names ()
  "The periods, shortest first."
  (mapcar #'car org-dayflow-spans))

(defun org-dayflow-span-zoom-out ()
  "Show the next longer period."
  (interactive)
  (let* ((spans (org-dayflow--span-names))
         (pos (cl-position org-dayflow--current-span spans)))
    (when (and pos (< (1+ pos) (length spans)))
      (org-dayflow--span-set (nth (1+ pos) spans))
      (org-dayflow-refresh))))

(defun org-dayflow-span-zoom-in ()
  "Show the next shorter period."
  (interactive)
  (let* ((spans (org-dayflow--span-names))
         (pos (cl-position org-dayflow--current-span spans)))
    (when (and pos (> pos 0))
      (org-dayflow--span-set (nth (1- pos) spans))
      (org-dayflow-refresh))))

(defun org-dayflow-span (span)
  "Switch to SPAN, selected via minibuffer completion."
  (interactive
   (list (intern (completing-read
                  (format "Period (current: %s): " org-dayflow--current-span)
                  (mapcar #'symbol-name (org-dayflow--span-names))
                  nil t))))
  (org-dayflow--span-set span)
  (org-dayflow-refresh))

(defun org-dayflow-next-item (n)
  "Move to the next N-th item in the org-dayflow buffer."
  (interactive "p")
  (dotimes (_ n)
    (forward-line 1)
    (while (and (not (eobp))
                (not (org-dayflow--marker-at-point)))
      (forward-line 1)))
  (org-dayflow--arrive))

(defun org-dayflow-previous-item (n)
  "Move to the previous N-th item in the org-dayflow buffer.

At the first task, says so rather than moving anywhere."
  (interactive "p")
  (let ((moved nil))
    (dotimes (_ n)
      (let ((before (point)))
        (forward-line -1)
        (while (and (not (bobp))
                    (not (org-dayflow--marker-at-point)))
          (forward-line -1))
        (if (org-dayflow--marker-at-point)
            (setq moved t)
          (goto-char before))))
    (if moved
        (org-dayflow--arrive)
      (message "Beginning of dayflow"))))

(defun org-dayflow-scroll-left (n)
  "Scroll the current window left by N characters."
  (interactive "p")
  (scroll-left (* n 5)))

(defun org-dayflow-scroll-right (n)
  "Scroll the current window right by N characters."
  (interactive "p")
  (scroll-right (* n 5)))

(defun org-dayflow-offset-backward (n)
  "Move the timeline view backward by N units."
  (interactive "p")
  (setq org-dayflow--current-offset (- org-dayflow--current-offset n))
  (org-dayflow-refresh))

(defun org-dayflow-offset-forward (n)
  "Move the timeline view forward by N units."
  (interactive "p")
  (setq org-dayflow--current-offset (+ org-dayflow--current-offset n))
  (org-dayflow-refresh))

(defun org-dayflow-offset-reset ()
  "Reset the timeline view to the default offset for the current period."
  (interactive)
  (org-dayflow--span-set org-dayflow--current-span)
  (org-dayflow-refresh))

(defun org-dayflow--visit (display)
  "Show the Org heading at point with DISPLAY, a function of a buffer."
  (let ((marker (org-dayflow--marker-at-point)))
    (if (not marker)
        (message "No task at point.")
      (funcall display (marker-buffer marker))
      (goto-char marker)
      (org-fold-show-entry))))

(defun org-dayflow-switch-to ()
  "Jump to the Org heading at point."
  (interactive)
  (org-dayflow--visit #'switch-to-buffer))

(defun org-dayflow-goto ()
  "Jump to the Org heading at point and open in other window."
  (interactive)
  (org-dayflow--visit #'pop-to-buffer))

(defun org-dayflow-show ()
  "Show the Org heading at point in another window, staying here."
  (interactive)
  (let ((marker (org-dayflow--marker-at-point)))
    (if (not marker)
        (message "No task at point.")
      (org-dayflow--follow)
      (org-dayflow--highlight-current-heading marker))))

(defun org-dayflow--goto-key (key)
  "Move to the row of the heading named KEY, or of its nearest shown ancestor.
KEY is a node key: a file and an outline path, innermost first."
  (let (found)
    (while (and key (cdr key) (not found))
      (save-excursion
        (goto-char (or org-dayflow--body-start (point-min)))
        (while (and (not found) (not (eobp)))
          (let ((node (get-text-property (point) 'org-dayflow-node)))
            (if (and node (equal (org-dayflow--node-key node) key))
                (setq found (point))
              (forward-line 1)))))
      (setq key (cons (car key) (cddr key))))
    (when found
      (goto-char found)
      (org-dayflow--move-to-title))))

(defun org-dayflow--node-at-point ()
  "Return the node of the row at point, or nil."
  (get-text-property (line-beginning-position) 'org-dayflow-node))

(defun org-dayflow-toggle-fold ()
  "Fold the row at point into its line, or open it to show its children."
  (interactive)
  (let ((node (org-dayflow--node-at-point)))
    (unless (and node (org-dayflow--node-children node))
      (user-error "Nothing under this row to fold"))
    (unless org-dayflow--folds
      (setq org-dayflow--folds (make-hash-table :test #'equal)))
    (puthash (org-dayflow--node-key node)
             (if (get-text-property (line-beginning-position) 'org-dayflow-open)
                 'folded
               'open)
             org-dayflow--folds)
    (org-dayflow-refresh)
    (org-dayflow--goto-key (org-dayflow--node-key node))))

(defun org-dayflow-cycle-depth ()
  "Show one level more of the outline; after the deepest, the top level alone.
Forgets the rows folded or opened by hand, as Org's own cycling does."
  (interactive)
  (let ((node (org-dayflow--node-at-point))
        (depth (or org-dayflow--visible-depth org-dayflow--tree-depth)))
    (setq org-dayflow--visible-depth
          (if (>= depth org-dayflow--tree-depth) 1 (1+ depth)))
    (when org-dayflow--folds (clrhash org-dayflow--folds))
    (org-dayflow-refresh)
    (when node (org-dayflow--goto-key (org-dayflow--node-key node)))
    (message "Depth %d/%d" org-dayflow--visible-depth org-dayflow--tree-depth)))

(defun org-dayflow-bury-buffer ()
  "Bury the Dayflow buffer (simple variant of `org-dayflow-quit').
Use `q' which is bound to `org-dayflow-quit' for full window-restore support."
  (interactive)
  (org-dayflow--unhighlight)
  (quit-window))

(defun org-dayflow-toggle-follow ()
  "Toggle follow mode in Org Dayflow."
  (interactive)
  (setq org-dayflow--follow-mode (not org-dayflow--follow-mode))
  (message "Follow mode %s" (if org-dayflow--follow-mode "enabled" "disabled")))

(defun org-dayflow-echo-info ()
  "Echo the path, state, tags, properties and dates of the item at point.
Also prefixes the timeline column date under point when available."
  (interactive)
  (let* ((cell (org-dayflow--cursor-cell))
         (col-dt (and cell (org-dayflow--unit-index-to-datetime cell)))
         (col-str (when col-dt
                    (format "COL:%s  "
                            (org-dayflow--format-datetime-short col-dt))))
         (marker (org-dayflow--marker-at-point)))
    (if (not marker)
        (when col-str (message "%s" (string-trim-right col-str)))
      (with-current-buffer (marker-buffer marker)
        (save-excursion
          (goto-char marker)
          (let* ((path (org-get-outline-path t t))
                 (file (propertize
                        (file-name-nondirectory (buffer-file-name))
                        'face 'org-level-1))
                 (full-path (org-format-outline-path
                             path (frame-width) nil "/"))
                 (todo (org-get-todo-state))
                 (tags (org-get-tags))
                 (props (org-entry-properties))
                 (effort (cdr (assoc "EFFORT" props)))
                 (priority (org-entry-get (point) "PRIORITY"))
                 (scheduled (org-entry-get (point) "SCHEDULED"))
                 (deadline (org-entry-get (point) "DEADLINE"))
                 (timestamp (org-entry-get (point) "TIMESTAMP")))
            (when todo
              (setq todo (propertize todo 'face (org-get-todo-face todo))))
            (message "%s%s/%s%s%s%s%s"
                     (or col-str "")
                     file
                     full-path
                     (if todo (format "  TODO:%s" todo) "")
                     (if tags (format "  TAGS:%s" (string-join tags " ")) "")
                     (if (or effort priority)
                         (format "  PROPERTIES:%s"
                                 (string-join
                                  (delq nil
                                        (list
                                         (when effort (format "Effort=%s" effort))
                                         (when priority (format "Priority=%s" priority))))
                                  " | "))
                       "")
                     (if (or scheduled deadline timestamp)
                         (format "  STAMP:%s"
                                 (string-join
                                  (delq nil
                                        (list
                                         (when scheduled (format "Sched=%s" scheduled))
                                         (when deadline (format "Dead=%s" deadline))
                                         (when timestamp (format "Act=%s" timestamp))))
                                  " | "))
                       ""))))))))

(defun org-dayflow-filter (query)
  "Add a FILTER to the current Dayflow query interactively."
  (interactive "sAdd query (lisp, e.g., (tags \"work\")): ")
  (org-dayflow--add-query (read query)))

(defun org-dayflow-filter-by-tag (&optional immediate)
  "Filter org-dayflow by TAG.
If IMMEDIATE is non-nil, read the value at once."
  (interactive "P")
  (org-dayflow--filter-by
   "Tag"
   (org-global-tags-completion-table)
   (lambda (tag) `(tags ,tag))
   immediate
   `((?. . ,(lambda ()
              (let ((marker (org-dayflow--marker-at-point)))
                (cond
                 ((not marker)
                  (message "No task at point.")
                  nil)
                 (t
                  (let ((tags (org-with-point-at marker (org-get-tags))))
                    (if (null tags)
                        (progn (message "No tags found at point.") nil)
                      (mapcar (lambda (tag)
                                (if org-dayflow--filter-exclude
                                    `(not (tags ,tag))
                                  `(tags ,tag)))
                              tags)))))))))))

(defun org-dayflow-filter-by-todo (&optional immediate)
  "Filter org-dayflow by TODO keywords.
If IMMEDIATE is non-nil, read the value at once."
  (interactive "P")
  (org-dayflow--filter-by
   "Todo"
   (org-dayflow--collect-todo-keywords)
   (lambda (kw) `(todo ,kw))
   immediate))

(defun org-dayflow-filter-by-property (&optional immediate)
  "Filter org-dayflow by PROPERTY.
If IMMEDIATE is non-nil, read the value at once."
  (interactive "P")
  (org-dayflow--filter-by
   "Property"
   (org-dayflow--collect-properties)
   (org-dayflow--property-filter-builder)
   immediate))

(defun org-dayflow-filter-by-category (&optional immediate)
  "Filter org-dayflow by CATEGORY.
If IMMEDIATE is non-nil, read the value at once."
  (interactive "P")
  (org-dayflow--filter-by
   "Category"
   (org-dayflow--collect-categories)
   (lambda (cat) `(category ,cat))
   immediate))

(defun org-dayflow-filter-by-regexp (&optional immediate)
  "Filter org-dayflow by REGEXP.
If IMMEDIATE is non-nil, read the value at once."
  (interactive "P")
  (org-dayflow--filter-by
   "Regexp"
   nil
   (lambda (input) `(regexp ,input))
   immediate))

(defun org-dayflow-remove-filter ()
  "Reset all filters in the current Dayflow buffer."
  (interactive)
  (setq org-dayflow--current-query nil)
  (org-dayflow-refresh))

(defun org-dayflow--resolve-query-choice (kind payload)
  "Return the query S-expression for KIND/PAYLOAD from query selection."
  (pcase kind
    ('preset
     (if (eq payload 'unit-at-point)
         (org-dayflow--query-for-unit-at-point)
       payload))
    ('saved (cdr payload))
    ('session payload)
    (_ payload)))

(defun org-dayflow-select-query ()
  "Select and apply a query: built-in presets, saved queries, or session history.

Presets cover common views (open+dated, include done, unit at point).
Choosing a preset or session entry applies it immediately; saved
entries still offer apply / save / delete."
  (interactive)
  (let* ((presets
          (mapcar (lambda (e)
                    (cons (car e) (cons 'preset (cdr e))))
                  (org-dayflow--builtin-query-presets)))
         (saved-labeled
          (mapcar (lambda (e)
                    (cons (format "[saved]: %s" (car e))
                          (cons 'saved e)))
                  org-dayflow-saved-queries))
         (session-labeled
          (mapcar (lambda (q)
                    (cons (format "[session]: %s" (prin1-to-string q))
                          (cons 'session q)))
                  org-dayflow--query-session))
         (all-entries (append presets saved-labeled session-labeled))
         (choice (completing-read
                  "Select query: "
                  (mapcar #'car all-entries)
                  nil t nil nil (caar presets)))
         (entry (cdr (assoc choice all-entries)))
         (kind (car entry))
         (payload (cdr entry)))
    (if (memq kind '(preset session))
        (let ((query (org-dayflow--resolve-query-choice kind payload)))
          (org-dayflow--use-query query)
          (message "Query: %s" (prin1-to-string query)))
      ;; saved: keep apply / delete / save actions
      (let ((action (read-key "Action: RET=apply  d=delete  s=save")))
        (pcase action
          (?\r
           (org-dayflow--use-query
            (org-dayflow--resolve-query-choice kind payload)))
          (?s
           (let ((query (cdr payload))
                 (label (car payload)))
             (unless (assoc label org-dayflow-saved-queries)
               (add-to-list 'org-dayflow-saved-queries (cons label query))
               (customize-save-variable 'org-dayflow-saved-queries
                                        org-dayflow-saved-queries)
               (message "Saved query: %s" label))))
          (?d
           (let ((label (car payload)))
             (setq org-dayflow-saved-queries
                   (assoc-delete-all label org-dayflow-saved-queries))
             (customize-save-variable 'org-dayflow-saved-queries
                                      org-dayflow-saved-queries)
             (message "Deleted saved query: %s" label)))
          (_ (message "Unknown action")))))))

(defun org-dayflow-filter-dispatch ()
  "Interactively filter the dayflow view (org-agenda-like `/').

`s' opens query selection (presets include open/done/unit-at-point).
`\\' clears back to `org-dayflow-initial-query'."
  (interactive)
  (catch 'dispatch-quit
    (cl-labels
        ((read-filter ()
           (let* ((face 'font-lock-keyword-face)
                  (prompt (concat
                           (format "Filter[%s]: " (if org-dayflow--filter-exclude "-" "+"))
                           (propertize "[s]" 'face face) "elect presets "
                           "("
                           (propertize "[t]" 'face face) "ag "
                           (propertize "[d]" 'face face) "odo "
                           (propertize "[p]" 'face face) "rop "
                           (propertize "[c]" 'face face) "at "
                           (propertize "[r]" 'face face) "e) "
                           (propertize "[b]" 'face face) "uild "
                           (propertize "[\\]" 'face face) "off "
                           (propertize "[q]" 'face face) "uit"))
                  (char (read-char-exclusive prompt)))
             (pcase char
               (?+  'include)
               (?-  'exclude)
               (?t  'tag)
               (?d  'todo)
               (?p  'property)
               (?c  'category)
               (?r  'regexp)
               (?b  'build)
               (?s  'select)
               (?\\ 'remove)
               (?q  'quit)
               (?\t (intern (completing-read
                             "Select filter type: "
                             '("select" "tag" "todo" "property" "category" "regexp")
                             nil t)))
               (_   (message "Invalid key: %s" (single-key-description char))
                    (read-filter)))))
         ;; Every branch above returns a symbol this handles, so nothing
         ;; reaches here -- but `char' belongs to `read-filter' and naming it
         ;; out here was a void variable waiting for the day one did.
         (unknown (sym) (message "Invalid filter: %s" sym)))
      (while t
        (pcase (read-filter)
          ('include  (setq org-dayflow--filter-exclude nil))
          ('exclude  (setq org-dayflow--filter-exclude t))
          ('tag      (org-dayflow-filter-by-tag t)
                     (throw 'dispatch-quit nil))
          ('todo     (org-dayflow-filter-by-todo t)
                     (throw 'dispatch-quit nil))
          ('property (org-dayflow-filter-by-property t)
                     (throw 'dispatch-quit nil))
          ('category (org-dayflow-filter-by-category t)
                     (throw 'dispatch-quit nil))
          ('regexp   (org-dayflow-filter-by-regexp t)
                     (throw 'dispatch-quit nil))
          ;; `call-interactively', because the command reads its query from
          ;; the minibuffer.  Called as a function it was one argument short
          ;; and `b' answered with `wrong-number-of-arguments'.
          ('build    (call-interactively #'org-dayflow-filter)
                     (throw 'dispatch-quit nil))
          ('select   (org-dayflow-select-query)
                     (throw 'dispatch-quit nil))
          ('remove   (org-dayflow-remove-filter)
                     (throw 'dispatch-quit nil))
          ('quit     (throw 'dispatch-quit nil))
          (other     (unknown other)))))))

(defun org-dayflow-schedule ()
  (interactive)
  (org-dayflow--act-on-task #'org-schedule))

(defun org-dayflow-deadline ()
  (interactive)
  (org-dayflow--act-on-task #'org-deadline))

(defun org-dayflow-todo ()
  (interactive)
  (org-dayflow--act-on-task #'org-todo))

(defun org-dayflow-prepare-window (buf)
  "Setup Dayflow buffer BUF according to `org-dayflow-window-setup'.
Modeled after `org-agenda-prepare-window'."
  (let ((awin (get-buffer-window buf)))
    (cond
     ((equal (current-buffer) buf) nil)
     (awin (select-window awin))
     ((eq org-dayflow-window-setup 'current-window)
      (pop-to-buffer-same-window buf))
     ((eq org-dayflow-window-setup 'other-window)
      (switch-to-buffer-other-window buf))
     ((eq org-dayflow-window-setup 'other-frame)
      (switch-to-buffer-other-frame buf))
     ((eq org-dayflow-window-setup 'other-tab)
      (if (fboundp 'switch-to-buffer-other-tab)
          (switch-to-buffer-other-tab buf)
        (user-error "Your Emacs does not support tab bar")))
     ((eq org-dayflow-window-setup 'only-window)
      (pop-to-buffer buf '(org-display-buffer-full-frame)))
     ((eq org-dayflow-window-setup 'reorganize-frame)
      (pop-to-buffer buf '(org-display-buffer-split)))
     (t (pop-to-buffer buf)))
    (unless (equal (current-buffer) buf)
      (pop-to-buffer-same-window buf))
    buf))

(defun org-dayflow-quit ()
  "Exit the Dayflow buffer.
Respects `org-dayflow-restore-windows-after-quit' and the value of
`org-dayflow-window-setup', modeled after `org-agenda--quit'."
  (interactive)
  (let ((wconf org-dayflow-pre-window-conf)
        (buf (current-buffer)))
    (org-dayflow--unhighlight)
    (cond
     ((eq org-dayflow-window-setup 'other-frame)
      (delete-frame))
     ((eq org-dayflow-window-setup 'other-tab)
      (when (fboundp 'tab-bar-close-tab)
        (tab-bar-close-tab)))
     ((and org-dayflow-restore-windows-after-quit wconf)
      (setq org-dayflow-pre-window-conf nil)
      (set-window-configuration wconf))
     (t
      (and (not (eq org-dayflow-window-setup 'current-window))
           (not (one-window-p))
           (delete-window))))
    (bury-buffer buf)))

;;;###autoload
(defun org-dayflow-display (&optional span)
  "Display the Org Dayflow buffer for SPAN, or for the default period."
  (interactive)
  (let* ((span (or span org-dayflow-default-span))
         (bufname (org-dayflow--buffer-name span))
         (buf (get-buffer bufname))
         (wconf (unless (get-buffer-window buf)
                  (current-window-configuration))))
    (unless buf
      (setq buf (get-buffer-create bufname))
      (with-current-buffer buf
        (org-dayflow-mode)
        (org-dayflow--span-set span)
        (org-dayflow--render)))
    (when wconf
      (setq org-dayflow-pre-window-conf wconf))
    (org-dayflow-prepare-window buf)))

;;;###autoload
(defun org-dayflow ()
  "Prompt for a period and show the timeline over it."
  (interactive)
  (let ((key (read-key (concat "org-dayflow: [d]efault "
                               "[m]onth [q]uarter [y]ear [D]ecade"))))
    (pcase key
      ((or ?d ?\r ?\n) (org-dayflow-display))
      (?m (org-dayflow-display 'month))
      (?q (org-dayflow-display 'quarter))
      (?y (org-dayflow-display 'year))
      (?D (org-dayflow-display 'decade))
      (_ (message "Unknown key: %c" key)))))

(define-derived-mode org-dayflow-mode special-mode "Org-Dayflow"
  "Major mode for viewing Org tasks in a dayflow timeline."
  :keymap org-dayflow-mode-map
  (setq-local truncate-lines t)
  ;; Rows are lengthened with `move-to-column' to reach a range past their
  ;; end, and a tab there would make one character of several cells.
  (setq-local indent-tabs-mode nil)
  (setq org-dayflow--visible-depth org-dayflow-visible-depth
        org-dayflow--folds (make-hash-table :test #'equal))
  (add-hook 'post-command-hook #'org-dayflow--update-cursor-highlight nil t))

(provide 'org-dayflow)

;;; org-dayflow.el ends here
