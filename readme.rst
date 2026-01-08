
####################
Show Inactive Region
####################

Emacs minor mode to highlight the inactive region (between point and mark).

When the region is deactivated, this mode displays a subtle overlay showing where
the region *would* be if it were active. The overlay fades out after a configurable delay.

This can be useful since some actions can use the region even when it's not active.

Available via `melpa <https://melpa.org/#/show-inactive-region>`__.

Installation
============

.. code:: elisp

   (require 'show-inactive-region)
   (add-hook 'prog-mode-hook #'show-inactive-region-mode)

Or with ``use-package``:

.. code:: elisp

   (use-package show-inactive-region
     :hook (prog-mode . show-inactive-region-mode))

Customization
=============

``show-inactive-region-face-dynamic`` (t)
   Dynamically calculate background color.

``show-inactive-region-face-dynamic-factor`` (0.5)
   Blend factor between default and region colors.

``show-inactive-region-fade`` (t)
   Enable fade out effect.

``show-inactive-region-fade-idle`` (t)
   Only start fading after Emacs has been idle.

``show-inactive-region-fade-delay`` (1.0)
   Seconds before fading starts.

``show-inactive-region-fade-out`` (0.5)
   Duration of fade animation.

``show-inactive-region-fade-steps`` (10)
   Number of fade steps.

``show-inactive-region-overlay-priority`` (nil)
   Priority of the inactive region overlay.

Functions
=========

Suspend and resume allows you to temporarily disable showing the inactive region.

This is especially useful for modal editing in "insert" mode where showing the inactive region can be distracting.

Using these functions has an advantage over toggling the mode as
they do nothing when ``show-inactive-region`` isn't active.
So they can be called from hooks without having to keep track of the prior mode state.

``show-inactive-region-suspend``
   Temporarily suspend inactive region highlighting in the current buffer.
   Useful for modal editors to disable highlighting during insert mode.

``show-inactive-region-resume``
   Resume inactive region highlighting after suspension.
   Useful for modal editors to re-enable highlighting after insert mode.
