;;; stream.el --- Implementation of streams  -*- lexical-binding: t -*-

;; Copyright (C) 2016-2023 Free Software Foundation, Inc.

;; Author: Nicolas Petton <nicolas@petton.fr>
;; Keywords: stream, laziness, sequences
;; Version: 2.4.0
;; Package-Requires: ((emacs "25"))
;; Package: stream

;; Maintainer: nicolas@petton.fr

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

;; This library provides an implementation of streams. Streams are
;; implemented as delayed evaluation of cons cells.
;;
;; Functions defined in `seq.el' can also take a stream as input.
;;
;; streams could be created from any sequential input data:
;; - sequences, making operation on them lazy
;; - a set of 2 forms (first and rest), making it easy to represent infinite sequences
;; - buffers (by character)
;; - buffers (by line)
;; - buffers (by page)
;; - IO streams
;; - orgmode table cells
;; - ...
;;
;; All functions are prefixed with "stream-".
;; All functions are tested in tests/stream-tests.el
;;
;; Here is an example implementation of the Fibonacci numbers
;; implemented as in infinite stream:
;;
;; (defun fib (a b)
;;  (stream-cons a (fib b (+ a b))))
;; (fib 0 1)
;;
;; A note for developers: Please make sure to implement functions that
;; process streams (build new streams out of given streams) in a way
;; that no new elements in any argument stream are generated.  This is
;; most likely an error since it changes the argument stream.  For
;; example, a common error is to call `stream-empty-p' on an input
;; stream and build the stream to return depending on the result.
;; Instead, delay such tests until elements are requested from the
;; resulting stream.  A way to achieve this is to wrap such tests into
;; `stream-make' or `stream-delay'.  See the implementations of
;; `stream-append' or `seq-drop-while' for example.

;;; Code:

(eval-when-compile
  (require 'cl-lib)
  ;; Set safety to 0 to avoid checking the type of the argument multiple times
  ;; within `stream--force', which is used frequently.
  (cl-declaim (optimize (safety 0))))

(require 'seq)

(cl-defstruct (stream (:constructor stream--make-stream)
                      (:conc-name stream--)
                      (:predicate streamp)
                      :named)

  "A lazily evaluated sequence, compatible with the `seq' library's functions."

  (evaluated
   nil
   :type boolean
   :documentation "Whether the head and tail of the stream are accessible.

This value is set to t via the function `stream--force' after it
calls the updater function.")

  (first
   nil
   :type t
   :documentation "The first element of the stream.")

  (rest
   nil
   :type (or stream null)
   :documentation "The rest of the stream, which is itself a stream.")

  (empty
   nil
   :type boolean
   :documentation "Whether the evaluated stream is empty.

A stream is empty if the updater function returns nil when
`stream--force' evaluates the stream.")

  (updater
   nil
   :type (or function null)
   :documentation "Function that returns the head and tail of the stream when called.

The updater function returns the head and tail in a cons cell.
If it returns nil, then the stream is empty and `empty' is
set to t.  After this function is called, assuming no errors were signaled,
`evaluated' is set to t.

In the case of the canonical empty stream (see the variable `stream-empty'),
this slot is nil."))

(defmacro stream-make (&rest body)
  "Return a stream built from BODY.

BODY must return a cons cell whose car would be the head of a
stream and whose cdr would be the tail of a stream.  The cdr must
be a stream itself in order to be a valid tail.  Alternatively,
BODY may return nil, in which case the stream is marked empty
when the stream is evaluated."
  (declare (debug t))
  `(stream--make-stream :evaluated nil
                        :updater (lambda () ,@body)))

(defun stream--force (stream)
  "Evaluate and return the STREAM.

If the output of the updater function is nil, then STREAM is
marked as empty.  Otherwise, the output of the updater function
is used to set the head and the tail of the stream."
  ;; Check explicitly so that we can avoid checking
  ;; in accessors by setting safety to 0 via `cl-declaim'.
  (cl-check-type stream stream)
  (if (stream--evaluated stream)
      stream
    (pcase (funcall (stream--updater stream))
      (`(,head . ,tail)
       (setf (stream--first stream) head
             (stream--rest stream) tail))
      ((pred null)
       (setf (stream--empty stream) t))
      (bad-output
       (error "Bad output from stream updater: %S"
              bad-output)))
    (setf (stream--evaluated stream) t)
    stream))

(defmacro stream-cons (first rest)
  "Return a stream built from the cons of FIRST and REST.
FIRST and REST are forms and REST must return a stream."
  (declare (debug t))
  `(stream-make (cons ,first ,rest)))


;;; Convenient functions for creating streams

(cl-defgeneric stream (src)
  "Return a new stream from SRC.")

(cl-defmethod stream ((stream stream))
  "Return STREAM unmodified."
  stream)

(cl-defmethod stream ((seq sequence))
  "Return a stream built from the sequence SEQ.
SEQ can be a list, vector or string."
  (if (seq-empty-p seq)
      (stream-empty)
    (stream-cons
     (seq-elt seq 0)
     (stream (seq-subseq seq 1)))))

(cl-defmethod stream ((array array))
  "Return a stream built from the array ARRAY."
  (let ((len (length array)))
    (if (= len 0)
        (stream-empty)
      ;; This approach could avoid one level of indirection by setting
      ;; `stream--updater' directly, but using `funcall' makes for a
      ;; good example of how to use a custom updater function using the public
      ;; interface.
      (let ((idx 0))
        (cl-labels ((updater ()
                      (if (< idx len)
                          (prog1 (cons (aref array idx)
                                       (stream-make (funcall #'updater)))
                            (setq idx (1+ idx)))
                        nil)))
          (stream-make (funcall #'updater)))))))

(cl-defmethod stream ((list list))
  "Return a stream built from the list LIST."
  (if (null list)
      (stream-empty)
    (stream-cons
     (car list)
     (stream (cdr list)))))

(cl-defmethod stream ((buffer buffer) &optional pos thing)
  "Return a stream of the characters of the buffer BUFFER.
BUFFER may be a buffer or a string (buffer name).  The sequence
starts at POS if non-nil, `point-min' otherwise.  By default the
stream will consist of characters.  If THING is non-nil, it must
be a symbol supported by `thing-at-point' and `forward-thing'
that will be used to extract and navigate through things.
Examples include \\='line, \\='page, or \\='defun."
  (with-current-buffer buffer
    (unless pos (setq pos (point-min)))
    (cond
     ((>= pos (point-max))
      (stream-empty))
     ((not (null thing))
      (with-current-buffer buffer
        (let ((this (save-excursion
                      (save-restriction
                        (widen)
                        (goto-char pos)
                        (thing-at-point thing))))
              (next (save-excursion
                      (save-restriction
                        (widen)
                        (goto-char pos)
                        (forward-thing thing)
                        (point)))))
          (stream-cons this (stream buffer next thing)))))
     ((null thing)
      (stream-cons
       (with-current-buffer buffer
         (save-excursion
           (save-restriction
             (widen)
             (goto-char pos)
             (char-after (point)))))
       (stream buffer (1+ pos)))))))

(declare-function iter-next "generator")

(defun stream-from-iterator (iterator)
  "Return a stream generating new elements through ITERATOR.
ITERATOR is an iterator object in terms of the \"generator\"
package."
  (stream-make
   (condition-case nil
       (cons (iter-next iterator) (stream-from-iterator iterator))
     (iter-end-of-sequence nil))))

(defun stream-regexp (buffer regexp)
  (stream-make
   (let (match)
     (with-current-buffer buffer
       (setq match (re-search-forward regexp nil t)))
     (when match
       (cons (match-data) (stream-regexp buffer regexp))))))

(defun stream-range (&optional start end step)
  "Return a stream of the integers from START to END, stepping by STEP.
If START is nil, it defaults to 0. If STEP is nil, it defaults to
1.  START is inclusive and END is exclusive.  If END is nil, the
range is infinite."
  (unless start (setq start 0))
  (unless step (setq step 1))
  (if (equal start end)
      (stream-empty)
    (stream-cons
     start
     (stream-range (+ start step) end step))))


(defconst stream-empty
  (stream--make-stream :evaluated t
                       :first nil
                       :rest nil
                       :empty t
                       :updater nil)
  "The empty stream.")

(defun stream-empty ()
  "Return the empty stream."
  stream-empty)

(defun stream-empty-p (stream)
  "Return non-nil if STREAM is empty, nil otherwise."
  (stream--empty (stream--force stream)))

(defun stream-first (stream)
  "Return the first element of STREAM.
Return nil if STREAM is empty."
  (stream--first (stream--force stream)))

(defun \(setf\ stream-first\) (_store _stream)
  "Signal an error when trying to use `setf' on the head of a stream."
  (error "Streams are not mutable"))

(defun stream-rest (stream)
  "Return a stream of all but the first element of STREAM."
  (setq stream (stream--force stream))
  (if (stream--empty stream)
      (stream-empty)
    (stream--rest stream)))

(defun \(setf\ stream-rest\) (_store _stream)
  "Signal an error when trying to use `setf' on the tail of a stream."
  (error "Streams are not mutable"))

(defun stream-append (&rest streams)
  "Concatenate the STREAMS.
Requesting elements from the resulting stream will request the
elements in the STREAMS in order."
  (if (null streams)
      (stream-empty)
    (stream-make
     (let ((first (pop streams)))
       (while (and (stream-empty-p first) streams)
         (setq first (pop streams)))
       (if (stream-empty-p first)
           nil
         (cons (stream-first first)
               (if streams (apply #'stream-append (stream-rest first) streams)
                 (stream-rest first))))))))

(defmacro stream-pop (stream)
  "Return the first element of STREAM and set the value of STREAM to its rest."
  (unless (symbolp stream)
    (error "STREAM must be a symbol"))
  `(prog1
       (stream-first ,stream)
     (setq ,stream (stream-rest ,stream))))


;;; Implementation of seq.el generic functions

(cl-defmethod seqp ((_stream stream))
  t)

(cl-defmethod seq-empty-p ((stream stream))
  (stream-empty-p stream))

(cl-defmethod seq-elt ((stream stream) n)
  "Return the element of STREAM at index N."
  (while (> n 0)
    (setq stream (stream-rest stream))
    (setq n (1- n)))
  (stream-first stream))

(cl-defmethod (setf seq-elt) (_store (_sequence stream) _n)
  (error "Streams are not mutable"))

(cl-defmethod seq-length ((stream stream))
  "Return the length of STREAM.
This function will eagerly consume the entire stream."
  (let ((len 0))
    (while (not (stream-empty-p stream))
      (setq len (1+ len))
      (setq stream (stream-rest stream)))
    len))

(cl-defmethod seq-subseq ((stream stream) start &optional end)
  "Return a stream of elements of STREAM from START to END.

END is exclusive.  If END is omitted, include all elements from
START on.  Both START and END must be non-negative.  Since
streams are a delayed type of sequences, don't signal an error if
START or END are larger than the number of elements (the returned
stream will simply be accordingly shorter, or even empty)."
  (when (or (< start 0) (and end (< end 0)))
    (error "seq-subseq: only non-negative indexes allowed for streams"))
  (let ((stream-from-start (seq-drop stream start)))
    (if end (seq-take stream-from-start (- end start))
      stream-from-start)))

(cl-defmethod seq-into-sequence ((stream stream))
  "Convert STREAM into a sequence."
  (let ((list))
    (seq-doseq (elt stream)
      (push elt list))
    (nreverse list)))

(cl-defmethod seq-into ((stream stream) type)
  "Convert STREAM into a sequence of type TYPE."
  (seq-into (seq-into-sequence stream) type))

(cl-defmethod seq-into ((stream stream) (_type (eql stream)))
  stream)

(cl-defmethod seq-into ((seq sequence) (_type (eql stream)))
  (stream seq))

(cl-defmethod seq-take ((stream stream) n)
  "Return a stream of the first N elements of STREAM."
  (stream-make
   (if (or (zerop n)
           (stream-empty-p stream))
       nil
     (cons
      (stream-first stream)
      (seq-take (stream-rest stream) (1- n))))))

(cl-defmethod seq-drop ((stream stream) n)
  "Return a stream of STREAM without its first N elements."
  (stream-make
   (while (not (or (stream-empty-p stream) (zerop n)))
     (setq n (1- n))
     (setq stream (stream-rest stream)))
   (unless (stream-empty-p stream)
     (cons (stream-first stream)
           (stream-rest stream)))))

(cl-defmethod seq-take-while (pred (stream stream))
  "Return a stream of STREAM's successive elements for which PRED returns non-nil."
  (stream-make
   (when (funcall pred (stream-first stream))
     (cons (stream-first stream)
           (seq-take-while pred (stream-rest stream))))))

(cl-defmethod seq-drop-while (pred (stream stream))
  "Return a stream of STREAM's successive elements for which PRED returns nil."
  (stream-make
   (while (not (or (stream-empty-p stream)
                   (funcall pred (stream-first stream))))
     (setq stream (stream-rest stream)))
   (unless (stream-empty-p stream)
     (cons (stream-first stream)
           (stream-rest stream)))))

(cl-defmethod seq-map (function (stream stream))
    "Return a stream representing the mapping of FUNCTION over STREAM.
The elements of the produced stream are the results of the
applications of FUNCTION on each element of STREAM in succession."
  (stream-make
   (when (not (stream-empty-p stream))
     (cons (funcall function (stream-first stream))
           (seq-map function (stream-rest stream))))))

(cl-defmethod seq-mapn (function (stream stream) &rest streams)
  "Map FUNCTION over the STREAMS.

Example: this prints the first ten Fibonacci numbers:

  (letrec ((fibs (stream-cons
                  1
                  (stream-cons
                   1
                   (seq-mapn #\\='+ fibs (stream-rest fibs))))))
    (seq-do #\\='print (seq-take fibs 10)))

\(fn FUNCTION STREAMS...)"
  (if (not (seq-every-p #'streamp streams))
      (cl-call-next-method)
    (cl-labels ((do-mapn (f streams)
                         (stream-make
                          (unless (seq-some #'stream-empty-p streams)
                            (cons (apply f (mapcar #'stream-first streams))
                                  (do-mapn f (mapcar #'stream-rest streams)))))))
      (do-mapn function (cons stream streams)))))

(cl-defmethod seq-do (function (stream stream))
  "Evaluate FUNCTION for each element of STREAM eagerly, and return nil.

`seq-do' should never be used on infinite streams without some
kind of nonlocal exit."
  (while (not (stream-empty-p stream))
    (funcall function (stream-first stream))
    (setq stream (stream-rest stream))))

(cl-defmethod seq-filter (pred (stream stream))
  "Return a stream of the elements for which (PRED element) is non-nil in STREAM."
  (stream-make
   (while (not (or (stream-empty-p stream)
                   (funcall pred (stream-first stream))))
     (setq stream (stream-rest stream)))
   (if (stream-empty-p stream)
       nil
     (cons (stream-first stream)
           (seq-filter pred (stream-rest stream))))))

(defmacro stream-delay (expr)
  "Return a new stream to be obtained by evaluating EXPR.
EXPR will be evaluated once when an element of the resulting
stream is requested for the first time, and must return a stream.
EXPR will be evaluated in the lexical environment present when
calling this function."
  (let ((stream (make-symbol "stream")))
    `(stream-make (let ((,stream ,expr))
                    (if (stream-empty-p ,stream)
                        nil
                      (cons (stream-first ,stream)
                            (stream-rest ,stream)))))))

(cl-defmethod seq-copy ((stream stream))
  "Return a shallow copy of STREAM."
  (stream-delay stream))

(cl-defmethod seq-concatenate ((_type (eql stream)) &rest sequences)
  "Make a stream which concatenates each sequence in SEQUENCES."
  (apply #'stream-append (mapcar #'stream sequences)))



;;; More stream operations

(defun stream-scan (function init stream)
  "Return a stream of successive reduced values for STREAM.

If the elements of a stream s are s_1, s_2, ..., the elements
S_1, S_2, ... of the stream returned by \(stream-scan f init s\)
are defined recursively by

  S_1     = init
  S_(n+1) = (funcall f S_n s_n)

as long as s_n exists.

Example:

   (stream-scan #\\='* 1 (stream-range 1))

returns a stream of the factorials."
  (let ((res init))
    (stream-cons
     res
     (seq-map (lambda (el) (setq res (funcall function res el)))
              stream))))

(defun stream-flush (stream)
  "Request all elements from STREAM in order for side effects only."
  (while (not (stream-empty-p stream))
    (cl-callf stream-rest stream)))

(defun stream-iterate-function (function value)
  "Return a stream of repeated applications of FUNCTION to VALUE.
The returned stream starts with VALUE.  Any successive element
will be found by calling FUNCTION on the preceding element."
  (stream-cons
   value
   (stream-iterate-function function (funcall function value))))

(defun stream-concatenate (stream-of-streams)
  "Concatenate all streams in STREAM-OF-STREAMS and return the result.
All elements in STREAM-OF-STREAMS must be streams.  The result is
a stream."
  (stream-make
   (while (and (not (stream-empty-p stream-of-streams))
               (stream-empty-p (stream-first stream-of-streams)))
     (cl-callf stream-rest stream-of-streams))
   (if (stream-empty-p stream-of-streams)
       nil
     (cons
      (stream-first (stream-first stream-of-streams))
      (stream-concatenate
       (stream-cons (stream-rest (stream-first stream-of-streams))
                    (stream-rest stream-of-streams)))))))

(defun stream-of-directory-files-1 (directory &optional nosort recurse follow-links)
  "Helper for `stream-of-directory-files'."
  (stream-delay
   (if (file-accessible-directory-p directory)
       (let (files dirs (reverse-fun (if nosort #'identity #'nreverse)))
         (dolist (file (directory-files directory t nil nosort))
           (let ((is-dir (file-directory-p file)))
             (unless (and is-dir
                          (member (file-name-nondirectory (directory-file-name file))
                                  '("." "..")))
               (push file files)
               (when (and is-dir
                          (or follow-links (not (file-symlink-p file)))
                          (if (functionp recurse) (funcall recurse file) recurse))
                 (push file dirs)))))
         (apply #'stream-append
                (stream (funcall reverse-fun files))
                (mapcar
                 (lambda (dir) (stream-of-directory-files-1 dir nosort recurse follow-links))
                 (funcall reverse-fun dirs))))
     (stream-empty))))

(defun stream-of-directory-files (directory &optional full nosort recurse follow-links filter)
  "Return a stream of names of files in DIRECTORY.
Call `directory-files' to list file names in DIRECTORY and make
the result a stream.  Don't include files named \".\" or \"..\".
The arguments FULL and NOSORT are directly passed to
`directory-files'.

Third optional argument RECURSE non-nil means recurse on
subdirectories.  If RECURSE is a function, it should be a
predicate accepting one argument, an absolute file name of a
directory, and return non-nil when the returned stream should
recurse into that directory.  Any other non-nil value means
recurse into every readable subdirectory.

Even with recurse non-nil, don't descent into directories by
following symlinks unless FOLLOW-LINKS is non-nil.

If FILTER is non-nil, it should be a predicate accepting one
argument, an absolute file name.  It is used to limit the
resulting stream to the files fulfilling this predicate."
  (let* ((stream (stream-of-directory-files-1 directory nosort recurse follow-links))
         (filtered-stream (if filter (seq-filter filter stream) stream)))
    (if full filtered-stream
      (seq-map (lambda (file) (file-relative-name file directory)) filtered-stream))))

(provide 'stream)
;;; stream.el ends here
