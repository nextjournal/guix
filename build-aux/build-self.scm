;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2014, 2016, 2017 Ludovic Courtès <ludo@gnu.org>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; GNU Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

(define-module (build-self)
  #:use-module (gnu)
  #:use-module (guix)
  #:use-module (guix config)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-19)
  #:use-module (ice-9 match)
  #:export (build))

;;; Commentary:
;;;
;;; When loaded, this module returns a monadic procedure of at least one
;;; argument: the source tree to build.  It returns a derivation that
;;; builds it.
;;;
;;; This file uses modules provided by the already-installed Guix.  Those
;;; modules may be arbitrarily old compared to the version we want to
;;; build.  Because of that, it must rely on the smallest set of features
;;; that are likely to be provided by the (guix) and (gnu) modules, and by
;;; Guile itself, forever and ever.
;;;
;;; Code:


;; The dependencies.  Don't refer explicitly to the variables because they
;; could be renamed or shuffled around in modules over time.  Conversely,
;; 'find-best-packages-by-name' is expected to always have the same semantics.

(define libgcrypt
  (first (find-best-packages-by-name "libgcrypt" #f)))

(define zlib
  (first (find-best-packages-by-name "zlib" #f)))

(define gzip
  (first (find-best-packages-by-name "gzip" #f)))

(define bzip2
  (first (find-best-packages-by-name "bzip2" #f)))

(define xz
  (first (find-best-packages-by-name "xz" #f)))

(define (false-if-wrong-guile package)
  "Return #f if PACKAGE depends on the \"wrong\" major version of Guile (e.g.,
2.0 instead of 2.2), otherwise return PACKAGE."
  (let ((guile (any (match-lambda
                      ((label (? package? dep) _ ...)
                       (and (string=? (package-name dep) "guile")
                            dep)))
                    (package-direct-inputs package))))
    (and (or (not guile)
             (string-prefix? (effective-version)
                             (package-version guile)))
         package)))

(define (package-for-current-guile . names)
  "Return the package with one of the given NAMES that depends on the current
Guile major version (2.0 or 2.2), or #f if none of the packages matches."
  (let loop ((names names))
    (match names
      (()
       #f)
      ((name rest ...)
       (match (find-best-packages-by-name name #f)
         (()
          (loop rest))
         ((first _ ...)
          (or (false-if-wrong-guile first)
              (loop rest))))))))

(define guile-json
  (package-for-current-guile "guile-json"
                             "guile2.2-json"
                             "guile2.0-json"))

(define guile-ssh
  (package-for-current-guile "guile-ssh"
                             "guile2.2-ssh"
                             "guile2.0-ssh"))


;; The actual build procedure.

(define (top-source-directory)
  "Return the name of the top-level directory of this source tree."
  (and=> (assoc-ref (current-source-location) 'filename)
         (lambda (file)
           (string-append (dirname file) "/.."))))


(define (date-version-string)
  "Return the current date and hour in UTC timezone, for use as a poor
person's version identifier."
  ;; XXX: Replace with a Git commit id.
  (date->string (current-date 0) "~Y~m~d.~H"))

(define (guile-for-build)
  "Return a derivation for Guile 2.0 or 2.2, whichever matches the currently
running Guile."
  (package->derivation (cond-expand
                         (guile-2.2
                          (canonical-package
                           (specification->package "guile@2.2")))
                         (else
                          (canonical-package
                           (specification->package "guile@2.0"))))))

;; The procedure below is our return value.
(define* (build source
                #:key verbose? (version (date-version-string))
                #:allow-other-keys
                #:rest rest)
  "Return a derivation that unpacks SOURCE into STORE and compiles Scheme
files."
  ;; The '%xxxdir' variables were added to (guix config) in July 2016 so we
  ;; cannot assume that they are defined.  Try to guess their value when
  ;; they're undefined (XXX: we get an incorrect guess when environment
  ;; variables such as 'NIX_STATE_DIR' are defined!).
  (define storedir
    (if (defined? '%storedir) %storedir %store-directory))
  (define localstatedir
    (if (defined? '%localstatedir) %localstatedir (dirname %state-directory)))
  (define sysconfdir
    (if (defined? '%sysconfdir) %sysconfdir (dirname %config-directory)))
  (define sbindir
    (if (defined? '%sbindir) %sbindir (dirname %guix-register-program)))

  (define builder
    #~(begin
        (use-modules (guix build pull))

        (let ((json (string-append #$guile-json "/share/guile/site/"
                                   #$(effective-version))))
          (set! %load-path
            (cons* json
                   (string-append #$guile-ssh "/share/guile/site/"
                                  #$(effective-version))
                   %load-path))
          (set! %load-compiled-path
            (cons* json
                   (string-append #$guile-ssh "/lib/guile/"
                                  #$(effective-version)
                                  "/site-ccache")
                   %load-compiled-path)))

        ;; XXX: The 'guile-ssh' package prior to Guix commit 92b7258 was
        ;; broken: libguile-ssh could not be found.  Work around that.
        ;; FIXME: We want Guile-SSH 0.10.2 or later anyway.
        #$(if (string-prefix? "0.9." (package-version guile-ssh))
              #~(setenv "LTDL_LIBRARY_PATH" (string-append #$guile-ssh "/lib"))
              #t)

        (build-guix #$output #$source

                    #:system #$%system
                    #:storedir #$storedir
                    #:localstatedir #$localstatedir
                    #:sysconfdir #$sysconfdir
                    #:sbindir #$sbindir

                    #:package-name #$%guix-package-name
                    #:package-version #$version
                    #:bug-report-address #$%guix-bug-report-address
                    #:home-page-url #$%guix-home-page-url

                    #:libgcrypt #$libgcrypt
                    #:zlib #$zlib
                    #:gzip #$gzip
                    #:bzip2 #$bzip2
                    #:xz #$xz

                    ;; XXX: This is not perfect, enabling VERBOSE? means
                    ;; building a different derivation.
                    #:debug-port (if #$verbose?
                                     (current-error-port)
                                     (%make-void-port "w")))))

  (mlet %store-monad ((guile (guile-for-build)))
    (gexp->derivation "guix-latest" builder
                      #:modules '((guix build pull)
                                  (guix build utils)

                                  ;; Closure of (guix modules).
                                  (guix modules)
                                  (guix memoization)
                                  (guix sets))

                      ;; Arrange so that our own (guix build …) modules are
                      ;; used.
                      #:module-path (list (top-source-directory))

                      #:guile-for-build guile)))

;; This file is loaded by 'guix pull'; return it the build procedure.
build

;; Local Variables:
;; eval: (put 'with-load-path 'scheme-indent-function 1)
;; End:

;;; build-self.scm ends here
