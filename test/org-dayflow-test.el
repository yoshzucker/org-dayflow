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

(ert-deftest org-dayflow-test-a-week-fills-the-window ()
  "Ten days at eight columns each is what eighty columns of a week look like.

The period asks for ten columns and the window says how wide one may be, so
a week comes out spread across the page -- which is the point.  Titles start
at their own day and run right; a week packed into three-column cells piles
every title on top of the left edge."
  (should (= 8 (org-dayflow--unit-char-width 'week 80)))
  (should (= 10 (org-dayflow--units-length 'week 80))))

(ert-deftest org-dayflow-test-a-month-packs-its-days ()
  "The same unit as a week and three times as many of them.

`week' and `month' are both drawn a day to a column.  What separates them is
how many columns they ask for, which is the whole reason a period rather
than a unit is the thing being chosen."
  (should (eq 'day (org-dayflow--span-unit 'week)))
  (should (eq 'day (org-dayflow--span-unit 'month)))
  (should (= 3 (org-dayflow--unit-char-width 'month 80)))
  (should (= 26 (org-dayflow--units-length 'month 80))))

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
  (let ((org-dayflow-default-offsets '((week . -0.3) (month . -0.5))))
    (org-dayflow--span-set 'week)
    (should (= -3 org-dayflow--current-offset))   ; 0.3 of ten
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

(ert-deftest org-dayflow-test-the-default-is-a-week ()
  "A week and a bit is the horizon a day is planned against: far enough to
see what is coming, near enough that the days are still days."
  (should (eq 'week org-dayflow-default-span))
  (should (string-match-p "week" (org-dayflow--buffer-name))))

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
    (cl-count-if (lambda (l) (string-match-p "^ *\\*[^ ]" l))
                 (split-string (buffer-string) "\n"))))

(ert-deftest org-dayflow-test-a-longer-period-shows-more ()
  "The demo reaches past the week it opens on.

A longer view that shows the same rows as a shorter one demonstrates
nothing: what a month is *for* is the work that is not in this week, so the
generated data has to have some."
  (org-dayflow-test--with-demo
    (let ((org-agenda-files (org-dayflow-demo-regenerate))
          (org-todo-keywords '((sequence "NEXT" "ONGO" "|" "DONE" "CANCEL")
                               (sequence "WAIT" "|" "DELEG"))))
      (let ((week (org-dayflow-test--rows 'week))
            (month (org-dayflow-test--rows 'month))
            (quarter (org-dayflow-test--rows 'quarter))
            (year (org-dayflow-test--rows 'year)))
        (should (> week 0))
        (should (> month week))
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

(provide 'org-dayflow-test)

;;; org-dayflow-test.el ends here
