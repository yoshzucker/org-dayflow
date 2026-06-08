;;; org-dayflow.el --- Simple day-flowing timeline for Org -*- lexical-binding: t; -*-

;; Author: yoshzucker
;; Maintainer: yoshzucker
;; Version: 0.2
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
(require 'org)

(defgroup org-dayflow nil
  "Simple flowing timeline view for Org."
  :group 'org)

(defcustom org-dayflow-unit-format "%02d "
  "Format string used to display each unit (day/month/year) in the timeline."
  :type 'string
  :group 'org-dayflow)

(defcustom org-dayflow-units-length 30
  "Number of units (days/months/years) to show in the timeline."
  :type 'integer
  :group 'org-dayflow)

(defcustom org-dayflow-scales '(ten-min hour day week month year decade)
  "List of available scales in order from most detailed to most general."
  :type '(repeat (choice (const ten-min)
                         (const hour)
                         (const day)
                         (const week)
                         (const month)
                         (const year)
                         (const decade)))
  :group 'org-dayflow)

(defcustom org-dayflow-default-scale 'day
  "Default scale for org-dayflow view."
  :type `(choice ,@(mapcar (lambda (s)
                             `(const :tag ,(capitalize (symbol-name s)) ,s))
                           org-dayflow-scales))
  :group 'org-dayflow)

(defcustom org-dayflow-default-offsets
  '((ten-min . -6)
    (hour    . -2)
    (day     . -7)
    (week    . -3)
    (month   . -1)
    (year    . -10)
    (decade  . -2))
  "Default offsets from today for each scale in org-dayflow view."
  :type '(alist :key-type (choice (const ten-min)
                                  (const hour)
                                  (const day)
                                  (const week)
                                  (const month)
                                  (const year)
                                  (const decade))
                :value-type integer)
  :group 'org-dayflow)

(defcustom org-dayflow-initial-query '((or (scheduled) (deadline) (regexp org-ts-regexp)))
  "Default S-expression query for org-dayflow when no filters are applied.
The query language is a subset of what org-ql supports and is evaluated
internally using only Org primitives."
  :type 'sexp
  :group 'org-dayflow)

(defcustom org-dayflow-saved-queries nil
  "Alist of saved org-dayflow queries.
Each entry is a cons cell of the form (LABEL . QUERY)."
  :type '(alist :key-type string :value-type sexp)
  :group 'org-dayflow
  :safe t)

(defcustom org-dayflow-histogram-char-alist
  '((deadline  . "#")
    (active    . "*")
    (scheduled . "+"))
  "Symbols used to represent different types of tasks in the vertical bar graph."
  :type '(alist :key-type (choice (const deadline) (const active) (const scheduled))
                :value-type string)
  :group 'org-dayflow)

(defcustom org-dayflow-histogram-face-alist
  '((deadline        . org-dayflow-histogram-deadline-face)
    (active          . org-dayflow-histogram-active-face)
    (scheduled       . org-dayflow-histogram-scheduled-face)
    (deadline-done   . org-dayflow-histogram-deadline-done-face)
    (active-done     . org-dayflow-histogram-active-done-face)
    (scheduled-done  . org-dayflow-histogram-scheduled-done-face))
  "Faces used to colorize task bars in the vertical bar graph.
Keys ending in `-done` are used for completed tasks."
  :type '(alist :key-type (symbol) :value-type face)
  :group 'org-dayflow)

(defcustom org-dayflow-high-density nil
  "If non-nil, render with less vertical padding:
- no blank line after the query line
- no blank line between histogram and titles."
  :type 'boolean
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

(defface org-dayflow-today-face
  '((t (:inherit org-agenda-structure :weight bold :slant italic)))
  "Face for today's date in org-dayflow."
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

(defface org-dayflow-title-bar-face
  '((t (:strike-through t)))
  "Face for org-dayflow bar overlays.")

(defface org-dayflow-title-done-face
  '((t (:inherit org-headline-done)))
  "Face for DONE or CANCELLED task titles."
  :group 'org-dayflow)

(defvar-local org-dayflow--current-scale nil
  "Current scale in the org-dayflow buffer.")

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

(defvar org-dayflow--query-session nil
  "List of queries built during this session (not saved persistently).")

(defvar org-dayflow-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "q") #'org-dayflow-quit)
    (define-key map (kbd "RET") #'org-dayflow-switch-to)
    (define-key map (kbd "TAB") #'org-dayflow-goto)
    (define-key map (kbd "r") #'org-dayflow-refresh)
    (define-key map (kbd "-") #'org-dayflow-scale-zoom-out)
    (define-key map (kbd "+") #'org-dayflow-scale-zoom-in)
    (define-key map (kbd "Z") #'org-dayflow-scale)
    (define-key map (kbd "n") #'org-dayflow-next-item)
    (define-key map (kbd "p") #'org-dayflow-previous-item)
    (define-key map (kbd "j") #'org-dayflow-next-item)
    (define-key map (kbd "k") #'org-dayflow-previous-item)
    (define-key map (kbd "<") #'org-dayflow-offset-backward)
    (define-key map (kbd ">") #'org-dayflow-offset-forward)
    (define-key map (kbd ".") #'org-dayflow-offset-reset)
    (define-key map (kbd "h") #'org-dayflow-scroll-right)
    (define-key map (kbd "l") #'org-dayflow-scroll-left)
    (define-key map (kbd "]") #'org-dayflow-filter-dispatch)
    (define-key map (kbd "f") #'org-dayflow-toggle-follow)
    (define-key map (kbd "s") #'org-dayflow-schedule)
    (define-key map (kbd "d") #'org-dayflow-deadline)
    (define-key map (kbd "t") #'org-dayflow-todo)
    (define-key map (kbd "e") #'org-dayflow-echo-info)
    map)
  "Keymap for `org-dayflow-mode`.")

;;; Utility commands
(defun org-dayflow--unit-char-width ()
  "Return the width (in characters) of one unit based on `org-dayflow-unit-format`."
  (length (format org-dayflow-unit-format 1)))

(defun org-dayflow--label-safe-pos (pos positions)
  "Return the first position >= POS that does not overlap the last entry in POSITIONS.
POSITIONS is a list of (pos label-string) in reverse-push order."
  (if (null positions)
      pos
    (max pos (+ (caar positions) (length (cadr (car positions)))))))

(defun org-dayflow--render-label-positions (positions total-width)
  "Render POSITIONS (sorted list of (pos label-string)) into a padded line of TOTAL-WIDTH chars."
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
  "Return the start date/datetime considering the current offset and scale."
  (let ((today (org-dayflow--datetime-now))
        (x org-dayflow--current-offset))
    (pcase org-dayflow--current-scale
      ('ten-min (let* ((now-min (org-dayflow--datetime-to-minutes (org-dayflow--datetime-now)))
                       (aligned (* (/ now-min 10) 10)))
                  (org-dayflow--minutes-to-datetime (+ aligned (* x 10)))))
      ('hour    (let* ((now-min (org-dayflow--datetime-to-minutes (org-dayflow--datetime-now)))
                       (aligned (* (/ now-min 60) 60)))
                  (org-dayflow--minutes-to-datetime (+ aligned (* x 60)))))
      ('day     (org-dayflow--date+ today (list 0 x 0)))
      ('week    (org-dayflow--date+ today (list 0 (* x 7) 0)))
      ('month   (org-dayflow--date+ today (list x 0 0)))
      ('year    (org-dayflow--date+ today (list 0 0 x)))
      ('decade  (org-dayflow--date+ today (list 0 0 (* x 10))))
      (_        (org-dayflow--date+ today (list 0 x 0))))))

(defun org-dayflow--day- (&rest dates)
  "Return the number of days between the first date and each of the rest."
  (cl-reduce #'- (mapcar #'calendar-absolute-from-gregorian dates)))

(defun org-dayflow--month- (date1 date2)
  "Return the number of whole months between DATE1 and DATE2 (month day year ...) lists."
  (cl-destructuring-bind (m1 _d1 y1 . _r1) date1
    (cl-destructuring-bind (m2 _d2 y2 . _r2) date2
      (+ (* (- y1 y2) 12) (- m1 m2)))))

(defun org-dayflow--datetime-now ()
  "Return current time as (month day year hour minute)."
  (cl-destructuring-bind (_sec min hour day month year . _rest) (decode-time (current-time))
    (list month day year hour min)))

(defun org-dayflow--datetime-timestamp (timestamp)
  "Convert Org TIMESTAMP to (month day year hour minute), or nil if TIMESTAMP is nil."
  (when timestamp
    (cl-destructuring-bind (_sec min hour day month year . _rest) (org-parse-time-string timestamp)
      (list month day year (or hour 0) (or min 0)))))

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
(defun org-dayflow--buffer-name (&optional scale)
  "Return Org Dayflow buffer name."
  (format "*Org Dayflow(%s)*" (symbol-name (or scale org-dayflow-default-scale))))

(defun org-dayflow--scale-set (scale)
  "Set current scale and reset offset based on default."
  (setq org-dayflow--current-scale scale)
  (setq org-dayflow--current-offset (or (alist-get scale org-dayflow-default-offsets) 0)))

(defun org-dayflow--day-scale-labels (start days)
  "Generate a line of month name labels for DAY scale."
  (let* ((start-abs (calendar-absolute-from-gregorian start))
         (unit-char-width (org-dayflow--unit-char-width))
         (positions '()))
    (dotimes (d days)
      (cl-destructuring-bind (month day year)
          (calendar-gregorian-from-absolute (+ start-abs d))
        (let* ((label (format-time-string "%B" (encode-time 0 0 0 day month year))))
          (unless (equal label (cadr (car positions)))
            (push (list (org-dayflow--label-safe-pos (* d unit-char-width) positions) label)
                  positions)))))
    (org-dayflow--render-label-positions (nreverse positions) (* days unit-char-width))))

(defun org-dayflow--day-scale-units (start days)
  "Generate a line of dates starting from START date for DAYS days."
  (let ((start-abs (calendar-absolute-from-gregorian start))
        (today-abs (calendar-absolute-from-gregorian (org-dayflow--datetime-now)))
        (day-width (org-dayflow--unit-char-width))
        (line ""))
    (dotimes (d days (string-trim-right line))
      (let* ((date (calendar-gregorian-from-absolute (+ start-abs d)))
             (dow (calendar-day-of-week date)) ;; 0=Sunday, 6=Saturday
             (face (cond
                    ((= (+ start-abs d) today-abs) 'org-dayflow-today-face)
                    ((or (= dow 0) (= dow 6)) 'org-dayflow-weekend-face)
                    (t 'org-dayflow-weekday-face)))
             (text (propertize (format org-dayflow-unit-format (nth 1 date)) 'face face)))
        (setq line (concat line text))))))

(defun org-dayflow--week-scale-labels (start weeks)
  "Generate a line of year labels for WEEK scale."
  (let* ((start-abs (calendar-absolute-from-gregorian start))
         (unit-char-width (org-dayflow--unit-char-width))
         (positions '()))
    (dotimes (w weeks)
      (let* ((label (format "%d" (nth 2 (calendar-gregorian-from-absolute (+ start-abs (* w 7)))))))
        (unless (equal label (cadr (car positions)))
          (push (list (org-dayflow--label-safe-pos (* w unit-char-width) positions) label)
                positions))))
    (org-dayflow--render-label-positions (nreverse positions) (* weeks unit-char-width))))

(defun org-dayflow--week-scale-units (start weeks)
  "Generate a line of ISO week numbers starting from START for WEEKS weeks."
  (let ((start-abs (calendar-absolute-from-gregorian start))
        (today-abs (calendar-absolute-from-gregorian (org-dayflow--datetime-now)))
        (line ""))
    (dotimes (w weeks (string-trim-right line))
      (let* ((week-start-abs (+ start-abs (* w 7)))
             (date (calendar-gregorian-from-absolute week-start-abs))
             (iso (calendar-iso-from-absolute week-start-abs))
             (iso-week (car iso))
             (face (if (and (<= week-start-abs today-abs)
                            (< today-abs (+ week-start-abs 7)))
                       'org-dayflow-today-face
                     'org-dayflow-units-face)))
        (setq line (concat line (propertize (format "%02d " iso-week) 'face face)))))
    line))

(defun org-dayflow--month-scale-labels (start months)
  "Generate a line of year labels for MONTH scale."
  (let* ((unit-char-width (org-dayflow--unit-char-width))
         (year (nth 2 start))
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
      (setq pos (+ pos unit-char-width)))
    (org-dayflow--render-label-positions (nreverse positions) (* months unit-char-width))))

(defun org-dayflow--month-scale-units (start months)
  "Generate a line of month numbers for MONTH scale."
  (cl-destructuring-bind (month _d1 year . _r1) start
    (cl-destructuring-bind (today-month _d2 today-year . _r2) (org-dayflow--datetime-now)
      (let ((line ""))
        (dotimes (_i months)
          (let* ((face (if (and (= month today-month) (= year today-year))
                           'org-dayflow-today-face
                         'org-dayflow-units-face)))
            (setq line (concat line
                               (propertize (format org-dayflow-unit-format month)
                                           'face face))))
          (setq month (1+ month))
          (when (> month 12)
            (setq month 1)
            (setq year (1+ year))))
        (string-trim-right line)))))

(defun org-dayflow--year-scale-units (start years)
  "Generate a line of year numbers for YEAR scale."
  (let ((start-year (nth 2 start))
        (today-year (nth 2 (org-dayflow--datetime-now)))
        (line ""))
    (dotimes (y years)
      (let ((year (+ start-year y))
            (face (if (= (+ start-year y) today-year)
                      'org-dayflow-today-face
                    'org-dayflow-units-face)))
        (setq line (concat line
                           (propertize (format org-dayflow-unit-format year) 'face face)))))
    (string-trim-right line)))

(defun org-dayflow--decade-scale-labels (start decades)
  "Generate a line of century labels for DECADE scale."
  (let* ((unit-char-width (org-dayflow--unit-char-width))
         (start-decade (* (/ (nth 2 start) 10) 10))
         (positions '())
         (pos 0))
    (dotimes (d decades)
      (let* ((decade (+ start-decade (* d 10))))
        (when (or (null positions) (= (% decade 100) 0))
          (push (list (org-dayflow--label-safe-pos pos positions)
                      (format "%4d" (* (/ decade 100) 100)))
                positions))
        (setq pos (+ pos unit-char-width))))
    (org-dayflow--render-label-positions (nreverse positions) (* decades unit-char-width))))

(defun org-dayflow--decade-scale-units (start decades)
  "Generate a line of decade labels for DECADE scale."
  (let* ((start-decade (* (/ (nth 2 start) 10) 10))
         (today-decade (* (/ (nth 2 (org-dayflow--datetime-now)) 10) 10))
         (line ""))
    (dotimes (d decades)
      (let* ((decade (+ start-decade (* d 10)))
             (face (if (= decade today-decade)
                       'org-dayflow-today-face
                     'org-dayflow-units-face)))
        (setq line (concat line
                           (propertize (format org-dayflow-unit-format (% decade 100))
                                       'face face)))))
    (string-trim-right line)))

(defun org-dayflow--hour-scale-labels (start hours)
  "Generate date labels (e.g. \"Jun 7\") for HOUR scale."
  (let* ((start-abs-min (org-dayflow--datetime-to-minutes start))
         (unit-char-width (org-dayflow--unit-char-width))
         (positions '()))
    (dotimes (h hours)
      (cl-destructuring-bind (month day year . _)
          (org-dayflow--minutes-to-datetime (+ start-abs-min (* h 60)))
        (let* ((label (format-time-string "%b %d" (encode-time 0 0 0 day month year))))
          (unless (equal label (cadr (car positions)))
            (push (list (org-dayflow--label-safe-pos (* h unit-char-width) positions) label)
                  positions)))))
    (org-dayflow--render-label-positions (nreverse positions) (* hours unit-char-width))))

(defun org-dayflow--hour-scale-units (start hours)
  "Generate hour number labels (00–23) for HOUR scale. START is (month day year hour minute)."
  (let* ((start-abs-min  (org-dayflow--datetime-to-minutes start))
         (now-min        (org-dayflow--datetime-to-minutes (org-dayflow--datetime-now)))
         (now-hour-start (* (/ now-min 60) 60))
         (line ""))
    (dotimes (h hours (string-trim-right line))
      (let* ((abs-min (+ start-abs-min (* h 60)))
             (dt      (org-dayflow--minutes-to-datetime abs-min))
             (face    (if (= abs-min now-hour-start)
                          'org-dayflow-today-face
                        'org-dayflow-units-face)))
        (setq line (concat line
                           (propertize (format org-dayflow-unit-format (nth 3 dt))
                                       'face face)))))
    line))

(defun org-dayflow--ten-min-scale-labels (start units)
  "Generate hour labels for TEN-MIN scale.
First label uses \"Jun 07 HH\" form; subsequent labels show only \"HH\"."
  (let* ((start-abs-min (org-dayflow--datetime-to-minutes start))
         (unit-char-width (org-dayflow--unit-char-width))
         (positions '())
         (prev-hour-str nil))
    (dotimes (u units)
      (cl-destructuring-bind (month day year hour minute)
          (org-dayflow--minutes-to-datetime (+ start-abs-min (* u 10)))
        (let* ((hour-str (format-time-string "%b %d %H" (encode-time 0 minute hour day month year))))
          (unless (equal hour-str prev-hour-str)
            (let* ((label (if positions
                              (format-time-string "%H" (encode-time 0 minute hour day month year))
                            hour-str)))
              (push (list (org-dayflow--label-safe-pos (* u unit-char-width) positions) label)
                    positions)
              (setq prev-hour-str hour-str))))))
    (org-dayflow--render-label-positions (nreverse positions) (* units unit-char-width))))

(defun org-dayflow--ten-min-scale-units (start units)
  "Generate 10-minute labels (00,10,...,50) for TEN-MIN scale. START is (month day year hour minute)."
  (let* ((start-abs-min   (org-dayflow--datetime-to-minutes start))
         (now-min         (org-dayflow--datetime-to-minutes (org-dayflow--datetime-now)))
         (now-ten-start   (* (/ now-min 10) 10))
         (line ""))
    (dotimes (u units (string-trim-right line))
      (let* ((abs-min (+ start-abs-min (* u 10)))
             (dt      (org-dayflow--minutes-to-datetime abs-min))
             (face    (if (= abs-min now-ten-start)
                          'org-dayflow-today-face
                        'org-dayflow-units-face)))
        (setq line (concat line
                           (propertize (format org-dayflow-unit-format (nth 4 dt))
                                       'face face)))))
    line))

(defun org-dayflow--scale-lines (scale start units)
  "Generate label and unit lines based on SCALE."
  (let* ((label-fn (intern-soft (format "org-dayflow--%s-scale-labels" scale)))
         (unit-fn  (intern-soft (format "org-dayflow--%s-scale-units" scale)))
         (label    (when (fboundp label-fn)
                     (funcall label-fn start units)))
         (unit     (when (fboundp unit-fn)
                     (funcall unit-fn start units))))
    (if unit
        (list label unit)
      (error "No unit function found for scale: %s" scale))))

(defun org-dayflow--earliest-active-timestamp ()
  "Return the earliest active timestamp string from title and body of current Org entry."
  (let ((timestamps nil))
    (let ((ts (org-entry-get (point) "TIMESTAMP")))
      (when ts (push ts timestamps)))
    (let ((element (org-element-at-point)))
      (org-element-map element 'timestamp
        (lambda (el)
          (when (eq (org-element-property :type el) 'active)
            (push (org-element-property :raw-value el) timestamps)))))
    (car (sort timestamps #'string<))))

(defun org-dayflow--title-unit (start task-date)
  "Return the position (unit offset) for TASK-DATE from START depending on current scale."
  (pcase org-dayflow--current-scale
    ('ten-min (/ (- (org-dayflow--datetime-to-minutes task-date)
                    (org-dayflow--datetime-to-minutes start))
                 10))
    ('hour    (/ (- (org-dayflow--datetime-to-minutes task-date)
                    (org-dayflow--datetime-to-minutes start))
                 60))
    ('day     (org-dayflow--day- task-date start))
    ('week    (/ (org-dayflow--day- task-date start) 7))
    ('month   (org-dayflow--month- task-date start))
    ('year    (- (nth 2 task-date) (nth 2 start)))
    ('decade  (- (/ (nth 2 task-date) 10) (/ (nth 2 start) 10)))
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

(defun org-dayflow--follow ()
  "If follow mode is on, display the Org heading at point in another window without switching focus."
  (let ((marker (get-text-property (point) 'org-marker)))
    (when (and marker (marker-buffer marker))
      (display-buffer (marker-buffer marker))
      (with-selected-window (get-buffer-window (marker-buffer marker))
        (goto-char marker)
        (org-show-entry)))))

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

(defun org-dayflow--select-entries (query)
  "Return a list of task plists matching QUERY across `org-agenda-files'.
QUERY is an S-expression understood by `org-dayflow--query-matches-p'."
  (let (tasks)
    (dolist (file (org-agenda-files))
      (when (file-exists-p file)
        (with-current-buffer (find-file-noselect file)
          ;; Ensure Org's keyword and tag caches are populated for this buffer.
          (org-set-regexps-and-options nil)
          (org-map-entries
           (lambda ()
             (when (org-dayflow--query-matches-p query)
               (push (org-dayflow--extract-task) tasks)))
           nil 'file))))
    (nreverse tasks)))

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

(defun org-dayflow--query-atom-matches-p (atom)
  "Return non-nil if the atomic query form ATOM matches the heading at point."
  (pcase atom
    (`(scheduled) (not (null (org-entry-get nil "SCHEDULED"))))
    (`(deadline)  (not (null (org-entry-get nil "DEADLINE"))))
    (`(tags ,tag) (member tag (org-get-tags)))
    (`(todo ,kw)  (string= (org-get-todo-state) kw))
    (`(property ,prop ,val)
     (string= (org-entry-get nil prop) val))
    (`(category ,cat)
     (string= (org-get-category) cat))
    (`(regexp ,re)
     (let ((case-fold-search t)
           (re (if (stringp re) re (prin1-to-string re))))
       (save-excursion
         (org-back-to-heading t)
         (let ((end (save-excursion (or (outline-next-heading) (point-max)))))
           (re-search-forward re end t)))))
    (_ nil)))

(defun org-dayflow--read-filter-char (type)
  "Prompt for a filter command: +, -, TAB to select filter type, \\ to clear, . to filter at point, q to quit."
  (let ((prompt (format "Filter[%s] %s: [TAB]select [.]point [\\]off [q]uit"
                        (if org-dayflow--filter-exclude "-" "+") type)))
    (read-char-exclusive prompt)))

(defun org-dayflow--filter-by (label candidates builder &optional immediate actions)
  "Generic filter for org-dayflow.
LABEL is a string shown in prompt.
CANDIDATES is a list of strings for completion.
BUILDER is a function that takes a string and returns a query S-expression.
ACTIONS is an alist of extra keybindings like ((?. . fn))."
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
                (funcall (cdr (assoc char actions)))
                (when new-query (throw 'quit nil)))
               (t (message "Invalid key: %s" (single-key-description char)))))))))
    (when new-query
      (setq org-dayflow--current-query
            (org-dayflow--build-query org-dayflow--current-query new-query))
      (unless (member org-dayflow--current-query org-dayflow--query-session)
        (push org-dayflow--current-query org-dayflow--query-session))
      (org-dayflow-refresh))))

(defun org-dayflow--collect-todo-keywords ()
  "Return a flat list of all TODO keywords from `org-todo-keywords`, stripping parens."
  (let (result)
    (dolist (seq org-todo-keywords (nreverse result))
      (dolist (kw (cdr seq))
        (unless (string= kw "|")
          (push (replace-regexp-in-string "(.*)" "" kw) result))))))

(defun org-dayflow--collect-properties ()
  "Collect all unique property names from org-agenda-files."
  (let (props)
    (dolist (file (org-agenda-files))
      (with-current-buffer (find-file-noselect file)
        (org-map-entries
         (lambda ()
           (let ((entry-props (org-entry-properties nil 'standard)))
             (dolist (prop entry-props)
               (push (car prop) props)))))))
    (delete-dups props)))

(defun org-dayflow--collect-property-candidates (prop)
  "Return allowed values for PROP, considering global and buffer-local settings."
  (let ((marker (get-text-property (point) 'org-marker)))
    (when (and marker (marker-buffer marker))
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
  "Collect all unique categories from org-agenda-files."
  (let (categories)
    (dolist (file (org-agenda-files))
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
  (let ((marker (get-text-property (point) 'org-marker)))
    (unless marker (user-error "No task at point"))
    (org-with-remote-undo (marker-buffer marker)
      (with-current-buffer (marker-buffer marker)
        (widen)
        (goto-char (marker-position marker))
        (let ((result (funcall func nil)))
          (org-dayflow-refresh)
          (message "%s" result))))))

(defun org-dayflow--task-type (task)
  "Return the type symbol of TASK: 'deadline, 'scheduled, or 'active."
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

(defun org-dayflow--char-type (char &optional done)
  "Return task type symbol for CHAR. If DONE is non-nil, return '-done' variant."
  (let ((base (car (rassoc char org-dayflow-histogram-char-alist))))
    (if (and base done)
        (intern (format "%s-done" base))
      base)))

(defun org-dayflow--insert-histogram (tasks start units unit-char-width)
  "Insert a 2-column histogram per unit: left = incomplete, right = complete."
  (let ((incomplete-stacks (make-vector units nil))
        (complete-stacks (make-vector units nil)))
    (dolist (task tasks)
      (let* ((unit (org-dayflow--title-position task start units))
             (type (org-dayflow--task-type task))
             (done (org-dayflow--task-done-p task))
             (char (alist-get type org-dayflow-histogram-char-alist)))
        (when unit
          (let ((stacks (if done complete-stacks incomplete-stacks)))
            (aset stacks unit (cons char (aref stacks unit)))))))
    (let ((height (cl-loop for i below units
                           maximize (max 1
                                         (length (aref incomplete-stacks i))
                                         (length (aref complete-stacks i))))))
      (dotimes (row height)
        (dotimes (unit units)
          (let ((stack (aref incomplete-stacks unit)))
            (if stack
                (let ((char (car stack)))
                  (insert (propertize char
                                      'face (alist-get (org-dayflow--char-type char nil)
                                                       org-dayflow-histogram-face-alist)))
                  (aset incomplete-stacks unit (cdr stack)))
              (insert " ")))
          (let ((stack (aref complete-stacks unit)))
            (if stack
                (let ((char (car stack)))
                  (insert (propertize char
                                      'face (alist-get (org-dayflow--char-type char t)
                                                       org-dayflow-histogram-face-alist)))
                  (aset complete-stacks unit (cdr stack)))
              (insert " ")))
          (insert (make-string (- unit-char-width 2) ?\s)))
        (insert "\n")))))

(defun org-dayflow--extract-task ()
  "Create a task plist from the current Org heading."
  (save-excursion
    (org-back-to-heading t)
    (let ((marker (point-marker))
          (title (org-get-heading t t t t))
          (todo (org-no-properties (org-get-todo-state)))
          (deadline (org-entry-get (point) "DEADLINE"))
          (scheduled (org-entry-get (point) "SCHEDULED"))
          (active (org-dayflow--earliest-active-timestamp)))
      `(:title ,title :marker ,marker :todo ,todo
               :scheduled ,scheduled :deadline ,deadline :active ,active))))

(defun org-dayflow--title-position (task start units)
  "Return the unit offset where the task's title should appear, or nil if out of range."
  (cl-destructuring-bind (&key scheduled deadline active &allow-other-keys) task
    (let* ((chosen (or deadline active scheduled))
           (date (org-dayflow--datetime-timestamp chosen)))
      (when date
        (let ((offset (org-dayflow--title-unit start date)))
          (when (and (<= 0 offset) (< offset units))
            offset))))))

(defun org-dayflow--insert-title (task offset unit-char-width)
  "Insert the task title at the given unit OFFSET."
  (cl-destructuring-bind (&key title marker &allow-other-keys) task
    (let* ((prefix (make-string (* offset unit-char-width) ?\s))
           (done (org-dayflow--task-done-p task))
           (line (propertize
                  (concat prefix "* " title)
                  'org-marker marker
                  'face (if done
                            'org-dayflow-title-done-face
                          (with-current-buffer (marker-buffer marker)
                            (save-excursion
                              (goto-char marker)
                              (org-dayflow--get-heading-face)))))))
      (insert line "\n"))))

(defun org-dayflow--bar-region (task start units unit-char-width)
  "Return (START-POS . END-POS) of the bar for TASK, or nil if outside view."
  (cl-destructuring-bind (&key scheduled deadline active &allow-other-keys) task
    (let* ((scheduled-date (org-dayflow--datetime-timestamp scheduled))
           (deadline-date  (org-dayflow--datetime-timestamp deadline))
           (start-dates    (delq nil (list scheduled-date deadline-date)))
           (end-dates      (delq nil (list deadline-date)))
           (active-date    (org-dayflow--datetime-timestamp active)))
      (when active-date
        (setq start-dates (append start-dates (list active-date)))
        (setq end-dates (append end-dates (list active-date))))
      (when (and start-dates end-dates)
        (let* ((start-date   (org-dayflow--datetime-min start-dates))
               (end-date     (org-dayflow--datetime-max end-dates))
               (start-offset (org-dayflow--title-unit start start-date))
               (end-offset   (org-dayflow--title-unit start end-date))
               (bar-start    (max 0 start-offset))
               (bar-end      (min units end-offset)))
          (when (> bar-end bar-start)
            (let* ((line-start    (line-beginning-position 0))
                   (bar-pos-start (+ line-start (* bar-start unit-char-width)))
                   (bar-pos-end   (+ line-start (* bar-end unit-char-width))))
              (cons bar-pos-start bar-pos-end))))))))

(defun org-dayflow--draw-bar (region)
  "Insert a timeline bar overlay for TASK if within view."
  (when region
    (let ((ov (make-overlay (car region) (cdr region))))
      (overlay-put ov 'face 'org-dayflow-title-bar-face))))

(defun org-dayflow--render ()
  "Render the timeline contents in the current buffer."
  (let* ((start (org-dayflow--date-start))
         (units org-dayflow-units-length)
         (unit-char-width (org-dayflow--unit-char-width))
         (label-lines (org-dayflow--scale-lines org-dayflow--current-scale start units))
         (tasks (org-dayflow--select-entries
                 (org-dayflow--build-query org-dayflow--current-query))))
    (let ((inhibit-read-only t))
      (rename-buffer (org-dayflow--buffer-name org-dayflow--current-scale) t)
      (erase-buffer)
      (insert (propertize
               (format "query: %s"
                       (prin1-to-string (or org-dayflow--current-query
                                            org-dayflow-initial-query)))
               'face 'org-dayflow-query-face))
      (insert (if org-dayflow-high-density "\n" "\n\n"))
      (dolist (line label-lines)
        (when line (insert line "\n")))
      (org-dayflow--insert-histogram tasks start units unit-char-width)
      (unless org-dayflow-high-density (insert "\n"))
      (dolist (task tasks)
        (let ((offset (org-dayflow--title-position task start units)))
          (when offset
            (org-dayflow--insert-title task offset unit-char-width)))
        (let ((region (org-dayflow--bar-region task start units unit-char-width)))
          (org-dayflow--draw-bar region)))
      (goto-char (point-min)))))

;;; User commands
(defun org-dayflow-refresh ()
  "Refresh the current org-dayflow buffer."
  (interactive)
  (when (derived-mode-p 'org-dayflow-mode)
    (org-dayflow--render)))

(defun org-dayflow-scale-zoom-out ()
  "Increase org-dayflow scale (zoom out) by moving to the next broader unit."
  (interactive)
  (let* ((scales org-dayflow-scales)
         (current org-dayflow--current-scale)
         (pos (cl-position current scales)))
    (when (and pos (< (1+ pos) (length scales)))
      (org-dayflow--scale-set (nth (1+ pos) scales))
      (org-dayflow-refresh))))

(defun org-dayflow-scale-zoom-in ()
  "Decrease org-dayflow scale (zoom in) by moving to the next finer unit."
  (interactive)
  (let* ((scales org-dayflow-scales)
         (current org-dayflow--current-scale)
         (pos (cl-position current scales)))
    (when (and pos (> pos 0))
      (org-dayflow--scale-set (nth (1- pos) scales))
      (org-dayflow-refresh))))

(defun org-dayflow-scale (scale)
  "Switch to SCALE, selected via minibuffer completion."
  (interactive
   (list (intern (completing-read
                  (format "Scale (current: %s): " org-dayflow--current-scale)
                  (mapcar #'symbol-name org-dayflow-scales)
                  nil t))))
  (org-dayflow--scale-set scale)
  (org-dayflow-refresh))

(defun org-dayflow-next-item (n)
  "Move to the next N-th item in the org-dayflow buffer."
  (interactive "p")
  (dotimes (_ n)
    (forward-line 1)
    (while (and (not (eobp))
                (not (get-text-property (point) 'org-marker)))
      (forward-line 1)))
  (org-dayflow--move-to-title)
  (org-dayflow-echo-info)
  (when org-dayflow--follow-mode
    (let ((marker (get-text-property (point) 'org-marker)))
      (org-dayflow--follow)
      (org-dayflow--highlight-current-heading marker))))

(defun org-dayflow-previous-item (n)
  "Move to the previous N-th item in the org-dayflow buffer."
  (interactive "p")
  (dotimes (_ n)
    (forward-line -1)
    (while (and (not (bobp))
                (not (get-text-property (point) 'org-marker)))
      (forward-line -1)))
  (org-dayflow--move-to-title)
  (org-dayflow-echo-info)
  (when org-dayflow--follow-mode
    (let ((marker (get-text-property (point) 'org-marker)))
      (org-dayflow--follow)
      (org-dayflow--highlight-current-heading marker))))

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
  "Reset the timeline view to the default offset for the current scale."
  (interactive)
  (setq org-dayflow--current-offset
        (alist-get org-dayflow--current-scale org-dayflow-default-offsets 0))
  (org-dayflow-refresh))

(defun org-dayflow-switch-to ()
  "Jump to the Org heading at point."
  (interactive)
  (let ((marker (get-text-property (point) 'org-marker)))
    (if (and marker (marker-buffer marker))
        (progn
          (switch-to-buffer (marker-buffer marker))
          (goto-char marker)
          (org-show-entry))
      (message "No task at point."))))

(defun org-dayflow-goto ()
  "Jump to the Org heading at point and open in other window."
  (interactive)
  (let ((marker (get-text-property (point) 'org-marker)))
    (if (and marker (marker-buffer marker))
        (progn
          (pop-to-buffer (marker-buffer marker))
          (goto-char marker)
          (org-show-entry))
      (message "No task at point."))))

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
  "Echo the Org path, todo state, tags, properties, and scheduling info of the current item."
  (interactive)
  (let ((marker (get-text-property (point) 'org-marker)))
    (when (and marker (marker-buffer marker))
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
            (message "%s/%s%s%s%s%s"
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
  (let ((new-query (read query)))
    (setq org-dayflow--current-query
          (org-dayflow--build-query org-dayflow--current-query new-query))
    (unless (member org-dayflow--current-query org-dayflow--query-session)
      (push org-dayflow--current-query org-dayflow--query-session))
    (org-dayflow-refresh)))

(defun org-dayflow-filter-by-tag (&optional immediate)
  "Filter org-dayflow by TAG. If IMMEDIATE is non-nil, enter completing-read immediately."
  (interactive "P")
  (org-dayflow--filter-by
   "Tag"
   (org-global-tags-completion-table)
   (lambda (tag) `(tags ,tag))
   immediate
   `((?. . ,(lambda ()
              (let ((marker (get-text-property (point) 'org-marker)))
                (if (and marker (marker-buffer marker))
                    (with-current-buffer (marker-buffer marker)
                      (goto-char marker)
                      (let ((tags (org-get-tags)))
                        (if (null tags)
                            (message "No tags found at point.")
                          (setq new-query
                                (mapcar (lambda (tag)
                                          (if org-dayflow--filter-exclude
                                              `(not (tags ,tag))
                                            `(tags ,tag)))
                                        tags)))))
                  (message "No task at point."))))))))

(defun org-dayflow-filter-by-todo (&optional immediate)
  "Filter org-dayflow by TODO keywords. If IMMEDIATE is non-nil, enter completing-read immediately."
  (interactive "P")
  (org-dayflow--filter-by
   "Todo"
   (org-dayflow--collect-todo-keywords)
   (lambda (kw) `(todo ,kw))
   immediate))

(defun org-dayflow-filter-by-property (&optional immediate)
  "Filter org-dayflow by PROPERTY. If IMMEDIATE is non-nil, enter completing-read immediately."
  (interactive "P")
  (org-dayflow--filter-by
   "Property"
   (org-dayflow--collect-properties)
   (org-dayflow--property-filter-builder)
   immediate))

(defun org-dayflow-filter-by-category (&optional immediate)
  "Filter org-dayflow by CATEGORY. If IMMEDIATE is non-nil, enter completing-read immediately."
  (interactive "P")
  (org-dayflow--filter-by
   "Category"
   (org-dayflow--collect-categories)
   (lambda (cat) `(category ,cat))
   immediate))

(defun org-dayflow-filter-by-regexp (&optional immediate)
  "Filter org-dayflow by REGEXP. If IMMEDIATE is non-nil, enter completing-read immediately."
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

(defun org-dayflow-select-query ()
  "Select a query from saved and session history. "
  (interactive)
  (let* ((saved org-dayflow-saved-queries)
         (session org-dayflow--query-session)
         (saved-labeled
          (mapcar (lambda (e)
                    (let ((label (car e)))
                      (cons (format "[saved]: %s" label) (cons 'saved e))))
                  saved))
         (session-labeled
          (mapcar (lambda (q)
                    (cons (format "[session]: %s" (prin1-to-string q)) (cons 'session q)))
                  session))
         (all-entries (append saved-labeled session-labeled))
         (choice (completing-read
                  "Select query to act on: "
                  (mapcar #'car all-entries)
                  nil t nil nil nil 'org-dayflow-query))
         (entry (cdr (assoc choice all-entries)))
         (kind (car entry))
         (payload (cdr entry))
         (action (read-key "Action: RET=apply  d=delete  s=save")))
    (pcase action
      (?\r
       (setq org-dayflow--current-query (if (eq kind 'saved) (cdr payload) payload))
       (org-dayflow-refresh))
      (?s
       (let ((query (if (eq kind 'saved) (cdr payload) payload))
             (label (prin1-to-string (if (eq kind 'saved) (cdr payload) payload))))
         (unless (assoc label org-dayflow-saved-queries)
           (add-to-list 'org-dayflow-saved-queries (cons label query))
           (customize-save-variable 'org-dayflow-saved-queries org-dayflow-saved-queries)
           (message "Saved query: %s" label))))
      (?d
       (when (eq kind 'saved)
         (let ((label (car payload)))
           (setq org-dayflow-saved-queries
                 (assoc-delete-all label org-dayflow-saved-queries))
           (customize-save-variable 'org-dayflow-saved-queries org-dayflow-saved-queries)
           (message "Deleted saved query: %s" label))))
      (_ (message "Unknown action")))))

(defun org-dayflow-filter-dispatch ()
  "Interactively apply a filter to the dayflow view and exit after selection."
  (interactive)
  (catch 'dispatch-quit
    (cl-labels
        ((read-filter ()
           (let* ((face 'font-lock-keyword-face)
                  (prompt (concat
                           (format "Filter[%s]: " (if org-dayflow--filter-exclude "-" "+"))
                           (propertize "[TAB]" 'face face) " manual " "("
                           (propertize "[t]" 'face face) "ag " "to"
                           (propertize "[d]" 'face face) "o "
                           (propertize "[p]" 'face face) "roperty "
                           (propertize "[c]" 'face face) "ategory "
                           (propertize "[r]" 'face face) "egexp): "
                           (propertize "[b]" 'face face) "uild "
                           (propertize "[s]" 'face face) "elect "
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
                             '("tag" "todo" "property" "category" "regexp")
                             nil t)))
               (_   (message "Invalid key: %s" (single-key-description char))
                    (read-filter))))))
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
          ('build    (org-dayflow-filter)
                     (throw 'dispatch-quit nil))
          ('select   (org-dayflow-select-query)
                     (throw 'dispatch-quit nil))
          ('remove   (org-dayflow-remove-filter)
                     (throw 'dispatch-quit nil))
          ('quit     (throw 'dispatch-quit nil))
          (_         (message "Invalid key: %s" (single-key-description char))))))))

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
      (pop-to-buffer-same-window buf))))

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
(defun org-dayflow-display (&optional scale)
  "Display Org Dayflow buffer for SCALE or default."
  (interactive)
  (let* ((scale (or scale org-dayflow-default-scale))
         (bufname (org-dayflow--buffer-name scale))
         (buf (get-buffer bufname))
         (wconf (unless (get-buffer-window buf)
                  (current-window-configuration))))
    (unless buf
      (setq buf (get-buffer-create bufname))
      (with-current-buffer buf
        (org-dayflow-mode)
        (org-dayflow--scale-set scale)
        (org-dayflow--render)))
    (when wconf
      (setq org-dayflow-pre-window-conf wconf))
    (org-dayflow-prepare-window buf)))

;;;###autoload
(defun org-dayflow ()
  "Prompt for a view scale and display org-dayflow timeline accordingly."
  (interactive)
  (let ((key (read-key "org-dayflow: [f]default [t]en-min [h]our [d]ay [w]eek [m]onth [y]ear [D]ecade")))
    (pcase key
      (?f (org-dayflow-display))
      (?t (org-dayflow-display 'ten-min))
      (?h (org-dayflow-display 'hour))
      (?d (org-dayflow-display 'day))
      (?w (org-dayflow-display 'week))
      (?m (org-dayflow-display 'month))
      (?y (org-dayflow-display 'year))
      (?D (org-dayflow-display 'decade))
      (_ (message "Unknown key: %c" key)))))

(define-derived-mode org-dayflow-mode special-mode "Org-Dayflow"
  "Major mode for viewing Org tasks in a dayflow timeline."
  :keymap org-dayflow-mode-map
  (setq-local truncate-lines t))

(provide 'org-dayflow)

;;; org-dayflow.el ends here
