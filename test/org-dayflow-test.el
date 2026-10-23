;;; org-dayflow-test.el --- Tests for org-dayflow  -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Run from the package root:
;;
;;   emacs --batch -Q -L . -L test -l test/org-dayflow-test.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; The first tests this package has, and they cover the two things that were
;; wrong rather than the whole of it: the arithmetic that decides how much of
;; a period is on the screen, and the filter keys that answered with an
;; error.  Every test here was checked against a deliberately broken
;; implementation before being kept.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org-dayflow)

;;;; How much of a period is on the screen

(ert-deftest org-dayflow-test-a-month-packs-its-days ()
  "A month is drawn a day to a column, packed three characters wide."
  (should (eq 'day (org-dayflow--span-unit 'month)))
  (should (= 3 (org-dayflow--unit-char-width 'month 80)))
  (should (= 26 (org-dayflow--units-length 'month 80))))

(ert-deftest org-dayflow-test-nothing-shorter-than-a-month ()
  "The days of a week and the hours of a day are the agenda's."
  (should (eq 'month (car (car org-dayflow-spans))))
  (should-not (assq 'week org-dayflow-spans))
  (should-not (assq 'day org-dayflow-spans)))

(ert-deftest org-dayflow-test-every-period-fits-eighty-columns ()
  "None of them runs off the edge of the narrowest window worth drawing for."
  (dolist (span (mapcar #'car org-dayflow-spans))
    (let ((used (* (org-dayflow--units-length span 80)
                   (org-dayflow--unit-char-width span 80))))
      (should (<= used 80))
      ;; and none of them wastes more than a column of it
      (should (> used (- 80 (org-dayflow--unit-char-width span 80)))))))

(ert-deftest org-dayflow-test-a-wider-window-shows-more ()
  "The window is what decides, so a wide one is not eighty columns of grid
and forty of nothing."
  (should (> (* (org-dayflow--units-length 'month 120)
                (org-dayflow--unit-char-width 'month 120))
             100)))

(ert-deftest org-dayflow-test-a-narrow-window-keeps-the-digits ()
  "A column narrower than the number in it cannot be read, so the floor is
what the unit needs and the count gives way instead."
  (dolist (span (mapcar #'car org-dayflow-spans))
    (let* ((unit (org-dayflow--span-unit span))
           (digits (alist-get unit org-dayflow-unit-digits 2)))
      (should (>= (org-dayflow--unit-char-width span 40) (1+ digits))))))

;;;; What goes in a column

(ert-deftest org-dayflow-test-a-year-is-four-digits-wide ()
  "`%02d' pads to two and does not truncate, so a year drawn with the day's
format was four characters in a three-character column -- and the year row
came out a column wider than the grid under it."
  (let* ((width (org-dayflow--unit-char-width 'decade 80))
         (cell (format (org-dayflow--unit-format 'year width) 2026)))
    (should (= width (length cell)))
    (should (string-prefix-p "2026" cell))))

(ert-deftest org-dayflow-test-a-unit-row-is-as-wide-as-the-grid ()
  "Every row drawn under the header has to agree with it about where a
column is.  The week row used to carry its own hardcoded format."
  (let* ((start (org-dayflow--datetime-now)))
    (dolist (span (mapcar #'car org-dayflow-spans))
      (let* ((width (org-dayflow--unit-char-width span 80))
             (units (org-dayflow--units-length span 80))
             (unit (org-dayflow--span-unit span))
             (fn (intern (format "org-dayflow--%s-scale-units" unit)))
             (line (funcall fn start units width)))
        ;; trailing blanks are trimmed, so the last cell may be short
        (should (<= (length line) (* units width)))
        (should (> (length line) (* (1- units) width)))))))

;;;; Where the view starts

(ert-deftest org-dayflow-test-the-past-keeps-its-share ()
  "The offset is a share of the period, not a count of columns: the count
follows the window, so a fixed one would put the past off the left edge of a
wide window and swallow a narrow one."
  (let ((org-dayflow-default-offsets '((quarter . -0.5) (month . -0.5))))
    (org-dayflow--span-set 'quarter)
    (should (= -7 org-dayflow--current-offset))   ; 0.5 of fourteen
    (org-dayflow--span-set 'month)
    (should (= -13 org-dayflow--current-offset)))) ; 0.5 of twenty-six

;;;; The filter keys

(ert-deftest org-dayflow-test-build-asks-for-its-query ()
  "`b' reads a query from the minibuffer, so it has to be called the way a
command is.  Called as a function it was one argument short, and pressing it
answered with `wrong-number-of-arguments'.

Asserted on the call rather than on the answer, because the reading is done
by the interactive spec and there is no minibuffer here to do it in."
  (let ((keys (list ?b))
        called)
    (cl-letf (((symbol-function 'read-char-exclusive)
               (lambda (&rest _) (pop keys)))
              ((symbol-function 'call-interactively)
               (lambda (fn &rest _) (setq called fn)))
              ((symbol-function 'org-dayflow-refresh) #'ignore))
      (org-dayflow-filter-dispatch))
    (should (eq called #'org-dayflow-filter))
    ;; and it is still the one-argument command that has to be called that way
    (should (commandp 'org-dayflow-filter))
    (should (equal '(1 . 1) (func-arity 'org-dayflow-filter)))))

(ert-deftest org-dayflow-test-an-action-hands-back-its-query ()
  "An action lives in another function and cannot reach the local this one
collects into.  The one that tried set a global of the same name instead,
and the filter it built went nowhere."
  (let ((org-dayflow--current-query nil)
        (org-dayflow--filter-exclude nil)
        ;; `q' after it, so a build that hands nothing back still ends the
        ;; loop rather than reading keys that are not coming.
        (keys (list ?. ?q)))
    (cl-letf (((symbol-function 'org-dayflow--read-filter-char)
               (lambda (&rest _) (pop keys)))
              ((symbol-function 'org-dayflow-refresh) #'ignore))
      (org-dayflow--filter-by
       "Test" nil (lambda (s) `(regexp ,s)) nil
       (list (cons ?. (lambda () '(tags "handed-back"))))))
    (should (string-match-p "handed-back"
                            (prin1-to-string org-dayflow--current-query)))))

(ert-deftest org-dayflow-test-an-action-with-nothing-to-give-is-quiet ()
  "Nothing at point is not a filter of nothing."
  (let ((org-dayflow--current-query nil)
        (keys (list ?. ?q)))
    (cl-letf (((symbol-function 'org-dayflow--read-filter-char)
               (lambda (&rest _) (pop keys)))
              ((symbol-function 'org-dayflow-refresh)
               (lambda () (error "refreshed for nothing"))))
      (org-dayflow--filter-by
       "Test" nil (lambda (s) `(regexp ,s)) nil
       (list (cons ?. (lambda () nil)))))
    (should-not org-dayflow--current-query)))

(ert-deftest org-dayflow-test-the-default-is-a-month ()
  "A month: where each piece of work runs and where it is due."
  (should (eq 'month org-dayflow-default-span))
  (should (string-match-p "month" (org-dayflow--buffer-name))))

(ert-deftest org-dayflow-test-d-is-the-default ()
  "`d' opens the default period, now that there is no day to give it to."
  (let (shown)
    (cl-letf (((symbol-function 'read-key) (lambda (&rest _) ?d))
              ((symbol-function 'org-dayflow-display)
               (lambda (&optional span) (setq shown (or span 'default)))))
      (org-dayflow))
    (should (eq 'default shown))))

;;;; The demo

(require 'org-dayflow-demo)

(defmacro org-dayflow-test--with-demo (&rest body)
  "Run BODY with the demo written to a directory of its own."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "dfdemo" t)))
          (org-dayflow-demo-directory dir))
     (unwind-protect (progn ,@body)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b)
                    (string-prefix-p dir (buffer-file-name b)))
           (with-current-buffer b (set-buffer-modified-p nil))
           (kill-buffer b)))
       (delete-directory dir t))))

(ert-deftest org-dayflow-test-the-demo-is-dated-from-today ()
  "A fixture with dates written into it is right on the day it was written
and misleading forever after.  A timeline is a picture of where today sits
among what is coming, and it cannot be drawn from a file that thinks today
was last spring."
  (org-dayflow-test--with-demo
    (org-dayflow-demo-regenerate)
    (let ((text (with-temp-buffer
                  (insert-file-contents
                   (expand-file-name "work.org" org-dayflow-demo-directory))
                  (buffer-string))))
      (should (string-match-p (regexp-quote (format-time-string "%Y-%m-%d"))
                              text))
      ;; and the whole of it moves: something behind today, something ahead
      (should (string-match-p
               (regexp-quote (format-time-string
                              "%Y-%m-%d" (time-add nil (days-to-time -4))))
               text))
      (should (string-match-p
               (regexp-quote (format-time-string
                              "%Y-%m-%d" (time-add nil (days-to-time 5))))
               text)))))

(defun org-dayflow-test--rows (span)
  "Return how many task rows SPAN draws from the current agenda files."
  (with-temp-buffer
    (org-dayflow-mode)
    (org-dayflow--span-set span)
    (setq org-dayflow--current-query nil)
    (org-dayflow--render)
    (length (org-dayflow-test--row-titles))))

(defun org-dayflow-test--row-titles ()
  "Return the rows of the current Dayflow buffer as trimmed strings."
  (let (rows)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when (get-text-property (line-beginning-position) 'org-marker)
          (push (string-trim (buffer-substring-no-properties
                              (line-beginning-position) (line-end-position)))
                rows))
        (forward-line 1)))
    (nreverse rows)))

(ert-deftest org-dayflow-test-a-longer-period-shows-more ()
  "The demo reaches past the month it opens on.

A longer view that shows the same rows as a shorter one demonstrates
nothing, so the generated data has to have work beyond the month."
  (org-dayflow-test--with-demo
    (let ((org-agenda-files (org-dayflow-demo-regenerate))
          (org-todo-keywords '((sequence "NEXT" "ONGO" "|" "DONE" "CANCEL")
                               (sequence "WAIT" "|" "DELEG"))))
      (let ((month (org-dayflow-test--rows 'month))
            (quarter (org-dayflow-test--rows 'quarter))
            (year (org-dayflow-test--rows 'year)))
        (should (> month 0))
        (should (> quarter month))
        (should (> year quarter))))))

(ert-deftest org-dayflow-test-the-demo-puts-everything-back ()
  "The buffer is named for its period and not for where its rows came from,
so a demo left on the screen is a week nobody could tell from their own."
  (org-dayflow-test--with-demo
    (let ((org-agenda-files '("/nowhere/real.org"))
          (org-todo-keywords org-todo-keywords)
          (org-dayflow-category-faces '(("mine" . default))))
      (cl-letf (((symbol-function 'org-dayflow-display) #'ignore))
        (org-dayflow-demo-mode 1)
        (should (equal (org-dayflow-demo-files) org-agenda-files))
        (org-dayflow-demo-mode -1))
      (should (equal '("/nowhere/real.org") org-agenda-files))
      (should (equal '(("mine" . default)) org-dayflow-category-faces))
      (should (= 0 (cl-count-if
                    (lambda (b) (string-prefix-p "*Org Dayflow(" (buffer-name b)))
                    (buffer-list)))))))

;;;; Parents drawn across their children

(defun org-dayflow-test--day (offset)
  "Return \"YYYY-MM-DD Day\" OFFSET days from today."
  (format-time-string "%Y-%m-%d %a" (time-add nil (days-to-time offset))))

(defmacro org-dayflow-test--with-outline (text &rest body)
  "Run BODY in a month view over an agenda file holding TEXT.
`%N' in TEXT is replaced by the date N days from today."
  (declare (indent 1))
  `(let* ((file (make-temp-file "dfoutline" nil ".org"))
          (org-agenda-files (list file))
          (org-todo-keywords '((sequence "NEXT" "|" "DONE"))))
     (unwind-protect
         (progn
           (with-temp-file file
             (insert (replace-regexp-in-string
                      "%\\(-?[0-9]+\\)"
                      (lambda (m)
                        (org-dayflow-test--day
                         (string-to-number (substring m 1))))
                      ,text t t)))
           (with-temp-buffer
             (org-dayflow-mode)
             (org-dayflow--span-set 'month)
             (cl-letf (((symbol-function 'org-dayflow--view-width)
                        (lambda () 100)))
               (org-dayflow--render)
               ,@body)))
       (when-let ((buf (get-file-buffer file)))
         (with-current-buffer buf (set-buffer-modified-p nil))
         (kill-buffer buf))
       (delete-file file))))

(defconst org-dayflow-test--meeting
  "* 執行会議付議
** DONE 論点を洗い出す
SCHEDULED: <%-3>
** NEXT 資料の骨子
SCHEDULED: <%1>
** NEXT 修正版の提出
SCHEDULED: <%5> DEADLINE: <%8>
* 生活
** 散歩
"
  "A piece of work written the usual way: dates on the steps, none on the
heading, and a deadline on the last step only.  Then a heading with
nothing dated under it.")

(ert-deftest org-dayflow-test-a-heading-comes-with-its-match ()
  "The heading carries no date and so matches nothing, but a step does,
and a step drawn without the work it belongs to is a row nobody can place.
A heading with nothing matching under it stays out."
  (org-dayflow-test--with-outline org-dayflow-test--meeting
    (let ((rows (org-dayflow-test--row-titles)))
      (should (string-prefix-p "▾執行会議付議" (car rows)))
      (should (member "*資料の骨子" rows))
      (should-not (cl-some (lambda (r) (string-match-p "生活\\|散歩" r)) rows)))))

(ert-deftest org-dayflow-test-a-parent-spans-what-is-done-too ()
  "The default query leaves done steps out, but the heading's line starts
where the work did: otherwise it would shrink each time a step was done,
and a month would show work starting today that started last week."
  (org-dayflow-test--with-outline org-dayflow-test--meeting
    (should-not (member "*論点を洗い出す" (org-dayflow-test--row-titles)))
    (let* ((node (org-dayflow--node-at-point))
           (start (org-dayflow--node-start node)))
      (should (equal "執行会議付議"
                     (plist-get (org-dayflow--node-task node) :title)))
      (should (equal (format-time-string
                      "%Y-%m-%d" (time-add nil (days-to-time -3)))
                     (format "%04d-%02d-%02d"
                             (nth 2 start) (nth 0 start) (nth 1 start)))))))

(ert-deftest org-dayflow-test-folded-the-deadline-stays ()
  "Folding drops the steps and keeps what a month is read for: where the
work runs, and the ◆ of the deadline written on its last step.  Open, the
step shows its own date and the heading's line does not repeat it."
  (org-dayflow-test--with-outline org-dayflow-test--meeting
    (should-not (string-match-p "◆" (car (org-dayflow-test--row-titles))))
    (org-dayflow-toggle-fold)
    (let ((rows (org-dayflow-test--row-titles)))
      (should (equal 1 (length rows)))
      (should (string-match-p "\\`▸執行会議付議 ─*◆" (car rows))))
    ;; and the cursor is still on the row it folded
    (should (string-match-p "執行会議付議"
                            (buffer-substring (line-beginning-position)
                                              (line-end-position))))
    (org-dayflow-toggle-fold)
    (should (member "*資料の骨子" (org-dayflow-test--row-titles)))))

(ert-deftest org-dayflow-test-depth-one-is-the-headings ()
  "S-TAB from the default two levels shows the whole outline here -- it is
only two deep -- and then starts again at the top level alone."
  (org-dayflow-test--with-outline org-dayflow-test--meeting
    (org-dayflow-cycle-depth)
    (should (= 1 org-dayflow--visible-depth))
    (should (equal 1 (length (org-dayflow-test--row-titles))))
    (org-dayflow-cycle-depth)
    (should (= 2 org-dayflow--visible-depth))
    (should (= 3 (length (org-dayflow-test--row-titles))))))

(ert-deftest org-dayflow-test-the-load-is-the-steps ()
  "A heading is its steps added up, so counting it in the sparkline as well
would count the same work twice."
  (org-dayflow-test--with-outline org-dayflow-test--meeting
    (let ((spark (save-excursion
                   (goto-char org-dayflow--grid-start)
                   (buffer-substring-no-properties
                    (point) (line-end-position)))))
      (should (= 2 (cl-count-if (lambda (c) (memq c (string-to-list
                                                     org-dayflow-spark-chars)))
                                spark))))))

;;;; What is drawn

(defconst org-dayflow-test--dated
  "* 案件
** NEXT 長い作業
SCHEDULED: <%-40> DEADLINE: <%60>
** NEXT 期限切れ
DEADLINE: <%-20>
** NEXT 来月が期限
SCHEDULED: <%2> DEADLINE: <%45>
** NEXT 週次
SCHEDULED: <%-30 +1w>
** DONE 済んだ
DEADLINE: <%-20>
"
  "Tasks whose one date is off the screen though their work is on it.")

(ert-deftest org-dayflow-test-every-task-in-view-is-drawn ()
  "A task is drawn when any of its range is in view.  Placed by its
deadline alone, all four of these were left out of a month: one running
across it, one overdue, one due after it, and one whose repeater date is
behind it."
  (org-dayflow-test--with-outline org-dayflow-test--dated
    (let ((rows (org-dayflow-test--row-titles)))
      (dolist (title '("*長い作業" "*期限切れ" "*来月が期限" "*週次"))
        (should (member title rows))))))

(ert-deftest org-dayflow-test-a-title-starts-where-the-work-does ()
  "Scheduled in two days and due in forty-five: the title is at the
schedule, not pushed off the right edge by the deadline."
  (org-dayflow-test--with-outline org-dayflow-test--dated
    (goto-char (point-min))
    (search-forward "*来月が期限")
    (goto-char (match-beginning 0))
    (should (= (* (- 2 org-dayflow--current-offset)
                  (org-dayflow--unit-char-width))
               (current-column)))))

(ert-deftest org-dayflow-test-tasks-are-not-repeats ()
  "Two projects each with a step of the same name have two steps."
  (org-dayflow-test--with-outline
      "* A\n** NEXT 資料作成\nSCHEDULED: <%1>\n* B\n** NEXT 資料作成\nSCHEDULED: <%3>\n"
    (should (= 2 (cl-count "*資料作成" (org-dayflow-test--row-titles)
                           :test #'equal)))))

(ert-deftest org-dayflow-test-excluded-files-are-not-read ()
  "A file named in `org-dayflow-exclude-files', by name or by a function
returning it, stays out of the timeline and nowhere else."
  (let* ((a (make-temp-file "dfa" nil ".org"))
         (b (make-temp-file "dfb" nil ".org"))
         (org-agenda-files (list a b)))
    (unwind-protect
        (progn
          (let ((org-dayflow-exclude-files (list b)))
            (should (equal (list a) (org-dayflow--files))))
          (let ((org-dayflow-exclude-files (list (lambda () b))))
            (should (equal (list a) (org-dayflow--files))))
          (let ((org-dayflow-exclude-files '(no-such-function)))
            (should (equal (list a b) (org-dayflow--files)))))
      (delete-file a)
      (delete-file b))))

(provide 'org-dayflow-test)

;;; org-dayflow-test.el ends here
