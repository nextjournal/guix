;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2017 Ricardo Wurmus <rekado@elephly.net>
;;; Copyright © 2017 Ludovic Courtès <ludo@gnu.org>
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

(define-module (guix docker)
  #:use-module (guix hash)
  #:use-module (guix base16)
  #:use-module ((guix build utils)
                #:select (delete-file-recursively
                          with-directory-excursion))
  #:use-module (guix build store-copy)
  #:use-module (srfi srfi-19)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 match)
  #:export (build-docker-image))

;; Load Guile-JSON at run time to simplify the job of 'imported-modules' & co.
(module-use! (current-module) (resolve-interface '(json)))

;; Generate a 256-bit identifier in hexadecimal encoding for the Docker image
;; containing the closure at PATH.
(define docker-id
  (compose bytevector->base16-string sha256 string->utf8))

(define (layer-diff-id layer)
  "Generate a layer DiffID for the given LAYER archive."
  (string-append "sha256:" (bytevector->base16-string (file-sha256 layer))))

;; This is the semantic version of the JSON metadata schema according to
;; https://github.com/docker/docker/blob/master/image/spec/v1.2.md
;; It is NOT the version of the image specification.
(define schema-version "1.0")

(define (image-description id time)
  "Generate a simple image description."
  `((id . ,id)
    (created . ,time)
    (container_config . #nil)))

(define (generate-tag path)
  "Generate an image tag for the given PATH."
  (match (string-split (basename path) #\-)
    ((hash name . rest) (string-append name ":" hash))))

(define (manifest path id)
  "Generate a simple image manifest."
  `(((Config . "config.json")
     (RepoTags . (,(generate-tag path)))
     (Layers . (,(string-append id "/layer.tar"))))))

;; According to the specifications this is required for backwards
;; compatibility.  It duplicates information provided by the manifest.
(define (repositories path id)
  "Generate a repositories file referencing PATH and the image ID."
  `((,(generate-tag path) . ((latest . ,id)))))

;; See https://github.com/opencontainers/image-spec/blob/master/config.md
(define (config layer time arch)
  "Generate a minimal image configuration for the given LAYER file."
  ;; "architecture" must be values matching "platform.arch" in the
  ;; runtime-spec at
  ;; https://github.com/opencontainers/runtime-spec/blob/v1.0.0-rc2/config.md#platform
  `((architecture . ,arch)
    (comment . "Generated by GNU Guix")
    (created . ,time)
    (config . #nil)
    (container_config . #nil)
    (os . "linux")
    (rootfs . ((type . "layers")
               (diff_ids . (,(layer-diff-id layer)))))))

(define* (build-docker-image image path
                             #:key closure compressor
                             (creation-time (current-time time-utc)))
  "Write to IMAGE a Docker image archive from the given store PATH.  The image
contains the closure of PATH, as specified in CLOSURE (a file produced by
#:references-graphs).  Use COMPRESSOR, a command such as '(\"gzip\" \"-9n\"),
to compress IMAGE.  Use CREATION-TIME, a SRFI-19 time-utc object, as the
creation time in metadata."
  (let ((directory "/tmp/docker-image")           ;temporary working directory
        (closure (canonicalize-path closure))
        (id (docker-id path))
        (time (date->string (time-utc->date creation-time) "~4"))
        (arch (match (utsname:machine (uname))
                ("x86_64" "amd64")
                ("i686"   "386")
                ("armv7l" "arm")
                ("mips64" "mips64le"))))
    ;; Make sure we start with a fresh, empty working directory.
    (mkdir directory)

    (and (with-directory-excursion directory
           ;; Add symlink from /bin to /gnu/store/.../bin
           (symlink (string-append path "/bin") "bin")

           (mkdir id)
           (with-directory-excursion id
             (with-output-to-file "VERSION"
               (lambda () (display schema-version)))
             (with-output-to-file "json"
               (lambda () (scm->json (image-description id time))))

             ;; Wrap it up
             (let ((items (call-with-input-file closure
                            read-reference-graph)))
               (and (zero? (apply system* "tar" "-cf" "layer.tar"
                                  (cons "../bin" items)))
                    (delete-file "../bin"))))

           (with-output-to-file "config.json"
             (lambda ()
               (scm->json (config (string-append id "/layer.tar")
                                  time arch))))
           (with-output-to-file "manifest.json"
             (lambda ()
               (scm->json (manifest path id))))
           (with-output-to-file "repositories"
             (lambda ()
               (scm->json (repositories path id)))))

         (and (zero? (apply system* "tar" "-C" directory "-cf" image
                            `(,@(if compressor
                                    (list "-I" (string-join compressor))
                                    '())
                              ".")))
              (begin (delete-file-recursively directory) #t)))))
