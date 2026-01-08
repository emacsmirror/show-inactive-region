;;; show-inactive-region.el --- Highlight the inactive region -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2014 Ian Kelling

;; Maintainer: Campbell Barton <ideasman42@gmail.com>

;; URL: https://codeberg.org/ideasman42/emacs-show-inactive-region
;; Keywords: convenience faces
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Minor mode to highlight the inactive region (between point and mark).
;;
;; Example installation:
;;
;; 1. Put this file in Emacs's load-path
;;
;; 2. Add to your init file
;; (require 'show-inactive-region)
;; (add-hook 'prog-mode-hook #'show-inactive-region-mode)

;;; Code:

(require 'color)

(defgroup show-inactive-region nil
  "Show the inactive region."
  :group 'convenience)

;; ---------------------------------------------------------------------------
;; Public Custom Variables

(defcustom show-inactive-region-face-dynamic t
  "When non-nil, dynamically calculate the inactive region background.
The color is interpolated between the default background and the active
region background, controlled by `show-inactive-region-face-dynamic-factor'."
  :type 'boolean)

(defcustom show-inactive-region-face-dynamic-factor 0.5
  "Factor for dynamic face color interpolation.
0.0 means use default background, 1.0 means use region background."
  :type '(number :tag "Factor"))

(defcustom show-inactive-region-fade t
  "When non-nil, fade out the inactive region after a delay."
  :type 'boolean)

(defcustom show-inactive-region-fade-idle t
  "When non-nil, only start fading after Emacs has been idle."
  :type 'boolean)

(defcustom show-inactive-region-fade-delay 1.0
  "Seconds before fading out the inactive region."
  :type 'number)

(defcustom show-inactive-region-fade-out 0.5
  "Seconds to take until the inactive region is faded out entirely."
  :type 'number)

(defcustom show-inactive-region-fade-steps 10
  "Number of increments to update during fade out."
  :type 'integer)

(defcustom show-inactive-region-overlay-priority nil
  "Priority of the inactive region overlay, nil for no priority."
  :type '(choice (const :tag "None" nil) (integer :tag "Priority")))

(defface show-inactive-region-face
  '((((type tty) (class color))
     (:background "gray" :foreground "black" :extend t))
    (((type tty) (class mono)) (:inverse-video t :extend t))
    (((class color) (background dark)) (:background "gray30" :extend t))
    (((class color) (background light)) (:background "grey90" :extend t))
    (t (:background "gray" :extend t)))
  "Face for the inactive region (between point and mark when region is inactive)."
  :group 'show-inactive-region)

;; ---------------------------------------------------------------------------
;; Internal Variables

(defvar show-inactive-region--overlay nil
  "The overlay used to display the inactive region between point and mark.")

(defvar show-inactive-region--fade-timer nil
  "Timer for the fade effect.")

(defvar show-inactive-region--overlay-point-and-mark nil
  "Cons cell of (point . mark) used to detect movement.")

(defconst show-inactive-region--local-variables
  '(show-inactive-region--overlay
    show-inactive-region--fade-timer
    show-inactive-region--overlay-point-and-mark)
  "List of buffer-local variables used by the mode.")

;; ---------------------------------------------------------------------------
;; Internal Utilities

(defun show-inactive-region--locals-create ()
  "Create buffer-local bindings for mode variables."
  (dolist (var show-inactive-region--local-variables)
    (make-local-variable var)))

(defun show-inactive-region--locals-clear ()
  "Remove buffer-local bindings for mode variables."
  (dolist (var show-inactive-region--local-variables)
    (kill-local-variable var)))

(defun show-inactive-region--blend-colors (color1 color2 factor)
  "Blend COLOR1 and COLOR2 by FACTOR.
FACTOR 0.0 returns COLOR1, 1.0 returns COLOR2."
  (let ((rgb1 (color-name-to-rgb color1))
        (rgb2 (color-name-to-rgb color2)))
    (when (and rgb1 rgb2)
      (pcase-let ((`(,r1 ,g1 ,b1) rgb1)
                  (`(,r2 ,g2 ,b2) rgb2)
                  (factor-inv (- 1 factor)))
        (color-rgb-to-hex
         (+ (* r1 factor-inv) (* r2 factor))
         (+ (* g1 factor-inv) (* g2 factor))
         (+ (* b1 factor-inv) (* b2 factor))
         2)))))

(defun show-inactive-region--dynamic-background ()
  "Return dynamically calculated background color, or nil if unavailable."
  (let ((bg-default (face-background 'default nil t))
        (bg-region (face-background 'region nil t)))
    (when (and bg-default bg-region)
      (show-inactive-region--blend-colors
       bg-default bg-region show-inactive-region-face-dynamic-factor))))

;; Note: colors are recomputed each call, so theme changes take effect
;; when the overlay is next reset (on point/mark movement).
(defun show-inactive-region--overlay-face ()
  "Return the face for the inactive region overlay."
  (let ((dynamic-bg
         (and show-inactive-region-face-dynamic (show-inactive-region--dynamic-background))))
    (cond
     (dynamic-bg
      `(:background ,dynamic-bg :extend t))
     (t
      'show-inactive-region-face))))

(defun show-inactive-region--fade-cancel ()
  "Cancel any running fade timer."
  (when show-inactive-region--fade-timer
    (cancel-timer show-inactive-region--fade-timer)
    (setq show-inactive-region--fade-timer nil)))

(defun show-inactive-region--fade-update-face (fade-step base-bg default-bg)
  "Update the overlay face based on FADE-STEP.
BASE-BG is the starting color, DEFAULT-BG is the fade target."
  (cond
   ((< fade-step show-inactive-region-fade-steps)
    (let* ((fade-factor (/ (float fade-step) show-inactive-region-fade-steps))
           (faded-bg (show-inactive-region--blend-colors base-bg default-bg fade-factor)))
      (overlay-put show-inactive-region--overlay 'face `(:background ,faded-bg :extend t))))
   (t
    ;; Fully faded, hide the overlay.
    (delete-overlay show-inactive-region--overlay))))

(defun show-inactive-region--fade-step-fn (buf fade-step-cell base-bg default-bg step-interval)
  "Perform one fade step in buffer BUF.
FADE-STEP-CELL is a cons cell holding the current step in its car.
BASE-BG and DEFAULT-BG are the cached colors for blending.
STEP-INTERVAL is the precomputed time between steps."
  (cond
   ((or (not (buffer-live-p buf)) ;; Buffer is dead, timer ends.
        (not (buffer-local-value 'show-inactive-region-mode buf))) ;; Mode disabled, timer ends.
    nil)
   (t
    (with-current-buffer buf
      (setcar fade-step-cell (1+ (car fade-step-cell)))
      (show-inactive-region--fade-update-face (car fade-step-cell) base-bg default-bg)
      (cond
       ((< (car fade-step-cell) show-inactive-region-fade-steps)
        (setq show-inactive-region--fade-timer
              (run-at-time step-interval nil #'show-inactive-region--fade-step-fn
                           buf
                           fade-step-cell
                           base-bg
                           default-bg
                           step-interval)))
       (t
        ;; Clear so `show-inactive-region--fade-cancel' knows there's nothing to cancel.
        (setq show-inactive-region--fade-timer nil)))))))

(defun show-inactive-region--fade-start ()
  "Start the fade timer after the delay."
  (show-inactive-region--fade-cancel)
  (when show-inactive-region-fade
    (let ((base-bg
           (or (and show-inactive-region-face-dynamic (show-inactive-region--dynamic-background))
               (face-background 'show-inactive-region-face nil t)))
          (default-bg (face-background 'default nil t))
          (step-interval
           (/ (float show-inactive-region-fade-out) show-inactive-region-fade-steps)))
      (when (and base-bg default-bg)
        (setq show-inactive-region--fade-timer
              (funcall (cond
                        (show-inactive-region-fade-idle
                         #'run-with-idle-timer)
                        (t
                         #'run-at-time))
                       show-inactive-region-fade-delay
                       nil
                       #'show-inactive-region--fade-step-fn
                       (current-buffer)
                       (cons 0 nil) ;; Fade step cell.
                       base-bg
                       default-bg
                       step-interval))))))

(defun show-inactive-region--overlay-update ()
  "Update the inactive region overlay between point and mark."
  (let ((mark-pos (mark t))
        (pt (point)))
    (cond
     ;; Hide when region is active (Emacs already shows it) or no mark.
     ((or mark-active (null mark-pos) (= pt mark-pos))
      ;; Skip if already hidden.
      (when show-inactive-region--overlay-point-and-mark
        (show-inactive-region--fade-cancel)
        (delete-overlay show-inactive-region--overlay)
        (setq show-inactive-region--overlay-point-and-mark nil)))
     (t
      ;; Update overlay if point or mark changed.
      (cond
       ((and show-inactive-region--overlay-point-and-mark
             (eq pt (car show-inactive-region--overlay-point-and-mark))
             (eq mark-pos (cdr show-inactive-region--overlay-point-and-mark)))
        ;; No change.
        nil)
       (t
        ;; Reset to full color and restart fade timer.
        (setq show-inactive-region--overlay-point-and-mark (cons pt mark-pos))
        (show-inactive-region--fade-cancel)
        (overlay-put show-inactive-region--overlay 'face (show-inactive-region--overlay-face))
        (show-inactive-region--fade-start)
        (move-overlay show-inactive-region--overlay pt mark-pos)))))))

(defun show-inactive-region--turn-on ()
  "Enable inactive region highlighting in the current buffer."
  ;; Clear first to ensure not stale, then create.
  (show-inactive-region--locals-clear)
  (show-inactive-region--locals-create)
  (setq show-inactive-region--overlay (make-overlay (point-min) (point-min)))
  (when show-inactive-region-overlay-priority
    (overlay-put show-inactive-region--overlay 'priority show-inactive-region-overlay-priority))
  (add-hook 'post-command-hook #'show-inactive-region--overlay-update nil t))

(defun show-inactive-region--turn-off ()
  "Disable inactive region highlighting in the current buffer."
  (show-inactive-region--fade-cancel)
  ;; Guard needed: `delete-overlay' errors on nil.
  (when show-inactive-region--overlay
    (delete-overlay show-inactive-region--overlay))
  (show-inactive-region--locals-clear)
  (remove-hook 'post-command-hook #'show-inactive-region--overlay-update t))

;; ---------------------------------------------------------------------------
;; Public Functions

;;;###autoload
(define-minor-mode show-inactive-region-mode
  "Minor mode to highlight the inactive region in the buffer."
  :lighter nil

  (cond
   (show-inactive-region-mode
    (show-inactive-region--turn-on))
   (t
    (show-inactive-region--turn-off))))

;;;###autoload
(defun show-inactive-region-suspend ()
  "Temporarily suspend inactive region highlighting in the current buffer.
This is useful for modal editors to disable highlighting during insert mode.
Use `show-inactive-region-resume' to re-enable.
Does nothing if `show-inactive-region-mode' is not enabled."
  (when show-inactive-region-mode
    (show-inactive-region--turn-off)))

;;;###autoload
(defun show-inactive-region-resume ()
  "Resume inactive region highlighting after `show-inactive-region-suspend'.
This is useful for modal editors to re-enable highlighting after insert mode.
Does nothing if `show-inactive-region-mode' is not enabled."
  (when show-inactive-region-mode
    (show-inactive-region--turn-on)))

;; Local Variables:
;; fill-column: 99
;; indent-tabs-mode: nil
;; elisp-autofmt-format-quoted: nil
;; End:
(provide 'show-inactive-region)
;;; show-inactive-region.el ends here
