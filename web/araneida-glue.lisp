(in-package :autobench-web)


(eval-when (:compile-toplevel :load-toplevel :execute)
  (set-dispatch-macro-character #\# #\h #'read-tag))

(defparameter *site-name* "sbcl.boinkor.net")

(defparameter *prefab-base* #p"/home/autobench/space/autobench/+prefab/")
(defparameter *ploticus-binary* "/usr/bin/ploticus")

(defparameter *localhost-name* "localhost")
(defparameter *external-port* 80)

(defparameter *base-url* (merge-url
			  (make-url :scheme "http"
				    :host *site-name*
				    :port *external-port*)
			  "/bench/"))

(defparameter *internal-base-url* (let ((fwd-url (copy-url *base-url*)))
                                    (setf (url-port fwd-url) (+ 1024 (url-port *base-url*)))
                                    (setf (url-host fwd-url) *localhost-name*)
                                    fwd-url))

(defparameter *webserver-url* (merge-url (make-url :scheme "http"
                                                   :host *site-name*
                                                   :port 80)
                                         "/prefab/"))

(defparameter *index-url* *base-url*)
(defparameter *atom-url* (merge-url *base-url* "atom/")) ; see syndication.lisp

(defparameter *bench-listener* (make-instance #+sbcl #+sb-thread 'threaded-reverse-proxy-listener
                                              #+sbcl #-sb-thread 'araneida:serve-event-reverse-proxy-listener
                                              #-sbcl 'threaded-reverse-proxy-listener
                                              :address #(127 0 0 1)
                                              :port (araneida:url-port *internal-base-url*)
                                              :translations nil
                                               ;; `((,(urlstring *base-url*) ,(urlstring *internal-base-url*)))
                                              ))

(defvar *latest-result*) ; latest result entry's date in the DB

(defvar *dbconn*)

(defclass index-handler (handler) ())
(defclass atom-handler (handler) ())

(setf araneida::*handler-timeout* 240) ; XXX: make this thing faster (;

(defun last-version ()
  (second (pg-result (pg-exec *dbconn*
                              (translate* `(select (i_name version)
                                                   (limit
                                                    (order-by version
                                                              (release_date)
                                                              :desc)
                                                    :start 0 :end 1))))
                     :tuple 0)))

(defun filesys-escape-name (name)
  "Escape name so that it is safe as a file name under unixoids and DOSoids."
  (declare (string name))
  (let ((output (make-array (length name) :fill-pointer 0 :element-type 'character :adjustable t)))
    (with-output-to-string (s output)
      (iterate (for c in-vector name)
               (if (or (alphanumericp c) (member c '(#\- #\.)))
                   (write-char c s)
                   (progn (write-char #\_ s) (princ (char-code c) s)))))
    output))

(defun implementation-spec-impl (impl-spec)
  (subseq impl-spec 0 (position #\, impl-spec)))

(defun implementation-spec-mode (impl-spec)
  (subseq impl-spec (1+ (position #\, impl-spec))))

(defun emit-where-clause (&key benchmark implementations only-release host earliest latest &allow-other-keys)
  `(where
    (join (join (as result r)
                (as build b)
                :on (and (= r.v-name b.v-name) (= r.v-version b.v-version) (= r.mode b.mode)))
          (as version v)
          :on (and (= r.v-name v.i-name) (= r.v-version v.version)))
    (and (= r.b-name ,benchmark)
         ,(if only-release
              `(and (>= v.release-date ,earliest)
                    (<= v.release-date ,latest))
              `(or (= v.belongs_to_release v.version)
                   (>= v.release-date ,latest)))
         (in m-name ',host)
         (in b.v-name ',(mapcar #'implementation-spec-impl implementations))
         (in b.mode ',(mapcar #'implementation-spec-mode implementations)))))



(defun file-name-for (&key benchmark implementations only-release host &allow-other-keys)
  (make-pathname :directory `(:relative ,(filesys-escape-name
                                          (md5-pathname-component
                                           (prin1-to-string implementations)))
                                        ,(filesys-escape-name
                                          (md5-pathname-component
                                           (prin1-to-string host)))
                                        ,(if only-release only-release "all"))
                 :name (filesys-escape-name benchmark)))

(defun make-offset-table (&rest conditions)
  (let ((table (make-hash-table :test #'equal)))
    (values table
            (iterate (for (impl host) in-relation
                  (translate*
                   `(distinct (select ((++ b.v-name "," b.mode) r.m-name)
                                      (order-by
                                       ,(apply #'emit-where-clause conditions)
                                       ((++ b.v-name "," b.mode)) :desc))))
                  on-connection *dbconn*
                  cursor-name offset-cursor)
             (for offset from 0)
             (maximizing offset)
             (setf (gethash (list impl host) table) offset)))))

(defun ploticus-offset-args (offset-table)
  (iterate (for ((impl host) offset) in-hashtable offset-table)
           (for pl-s = (if (= offset 0) "" (+ 2 (truncate offset 2))))
           ;; "name=SBCL" "y=2" "err=3" "name2=CMU Common Lisp" "y2=4" "err2=5"
           (collect (format nil "name~A=~A/~A" pl-s host (pprint-impl-and-mode impl)))
           (collect (format nil "y~A=~A" pl-s (+ 2 (* 2 offset))))
           (collect (format nil "err~A=~A" pl-s (+ 3 (* 2 offset))))))

(defun generate-image-for (&rest conditions &key unit &allow-other-keys)
  (declare (optimize (speed 0) (space 0)
                     (debug 2)))
  (multiple-value-bind (offset-table max-offset) (apply #'make-offset-table conditions)
    (let ((filename (merge-pathnames (apply #'file-name-for conditions) *prefab-base*)))

      (with-open-file (f (ensure-directories-exist filename) :direction :output
                         :if-exists :supersede :if-does-not-exist :create)
        (iterate (for (date host name version mean stderr) in-relation
                      (translate* `(select (v.release-date r.m-name (++ b.v-name "," b.mode) v.version
                                                           (avg r.seconds) (/ (stddev r.seconds) (sqrt (count r.seconds))))
                                           (order-by
                                            (group-by ,(apply #'emit-where-clause conditions)
                                                      (v.release-date r.m-name (++ b.v-name "," b.mode) v.version))
                                            (v.release-date))))
                      on-connection *dbconn*
                      cursor-name timing-values-cursor)
                 (for offset = (gethash (list name host) offset-table))
                 (format f "~A~A~f~A~f~A~%"
                         version
                         (make-string (1+ (* 2 offset)) :initial-element #\Tab)
                         mean
                         #\tab
                         stderr
                         (make-string (* 2 (- max-offset offset)) :initial-element #\Tab))))
      (autobench::invoke-logged-program "gen-image" *ploticus-binary*
                                        `("-png" "-o" ,(namestring (make-pathname :type "png" :defaults filename)) "-prefab" "lines"
                                                 ,(format nil "data=~A" (namestring filename)) "delim=tab" "x=1"
                                                 "ygrid=yes" "xlbl=version" ,(format nil "ylbl=~A" unit) "cats=yes" "-pagesize" "15,8" "autow=yes"
                                                 "yrange=0"
                                                 "ylog=log"
                                                 ;; "ynearest=0.5" ; works better with linear scale.
                                                 "stubvert=yes"
                                                 ,@(ploticus-offset-args offset-table))))))

(defun unix-time-to-universal-time (unix-time)
  (declare (integer unix-time))
  (+ 2208988800 ; difference in seconds 1970-01-01 0:00 and 1900-01-01 0:00
     unix-time))

(defun ensure-image-file-exists (&rest conditions)
  (let ((filename (merge-pathnames (apply #'file-name-for conditions) *prefab-base*)))
    (unless (and (probe-file filename)
                 (probe-file (make-pathname :type "png" :defaults filename))
                 (>= (file-write-date filename) *latest-result*))
      (apply #'generate-image-for conditions))))

(defun url-for-image (&rest conditions)
  (let* ((filename (make-pathname :type "png"
                                  :defaults (apply #'file-name-for conditions)))
         (absolute-filename (merge-pathnames filename *prefab-base*)))
    (values (urlstring (merge-url *webserver-url* (namestring filename)))
          absolute-filename)))

(defun date-boundaries (&rest conditions &key host only-release &allow-other-keys)
  (declare (ignore conditions))
  (destructuring-bind (i-name first last-unreleased)
      (pg-result
       (pg-exec *dbconn*
                (translate*
                 `(select (version.i-name (min release-date) (max release-date))
                          (group-by (where (join version result
                                                 :on (and (= result.v-name version.i-name) (= v-version version)))
                                           (and (in m-name ',host)
                                                ,(if only-release
                                                     `(= ,only-release version.belongs-to-release)
                                                     t)))
                                    (version.i-name)))))
       :tuple 0)
    (cond
      (only-release
       (destructuring-bind (&optional last-released)
           (pg-result
            (pg-exec *dbconn*
                     (translate*
                      `(select (release-date)
                               (limit
                                (order-by (where (join version result
                                                       :on (and (= result.v-name version.i-name) (= v-version version)))
                                                 (and (in m-name ',host)
                                                      (= i-name ,i-name)
                                                      (> release-date ,last-unreleased)))
                                          (release-date))
                                :end 1))))
            :tuple 0)
         (list first (or last-released last-unreleased))))
      (t (list first last-unreleased)))))

(defun pprint-impl-and-mode (impl-string)
  (let ((impl (implementation-spec-impl impl-string))
        (mode (implementation-spec-mode impl-string)))
    (destructuring-bind (&key arch features) (let ((*read-eval* nil))
                                               (read-from-string mode))
      (format nil "~A:~A" impl
              (string-downcase (format nil "~A~@[/~S~]" arch features))))))

(defun emit-image-index (s &rest args &key earliest latest host only-release implementations &allow-other-keys)
  (let ((benchmarks (pg-result (pg-exec *dbconn*
                                        (translate*
                                         `(select (name unit)
                                                  (where benchmark
                                                         (exists
                                                          (limit
                                                           (select (*)
                                                                   (where result
                                                                          (and (= result.b_name benchmark.name)
                                                                               (in result.m-name ',host))))
                                                           :end 1))))))
                               :tuples)))
    (iterate (for (benchmark unit) in benchmarks)
             (apply #'ensure-image-file-exists
                    :unit unit
                    :benchmark benchmark
                    :earliest earliest
                    :latest latest
                    args))
    (let  ((*default-tag-stream* s))
      #h('(html :xmlns "http://www.w3.org/1999/xhtml" :lang "en" :|xml:lang| "en")
          (html-stream s
                       `(head (title "Automated common lisp implementation benchmarks")
                              ((|link| :rel "stylesheet" :title "Style Sheet" :type "text/css" :href "/bench.css"))
                              (js-script
                               (setf dj-config (create :is-debug nil)))
                              ((script :type "text/javascript" :src "/js/dojo/dojo.js"))
                              ((script :type "text/javascript" :src "/js/callbacks.js"))
                              (js-script
                               (dojo.require "dojo.io.*")
                               (dojo.require "dojo.event.*")
                               (dojo.require "dojo.widget.*")
                               (defun impl-selected ()
                                 (dojo.io.bind
                                  (create :url "ajax/releases/"
                                          :handler impl-callback
                                          :content (create
                                                    :implementations (selected-values
                                                                      (dojo.by-id "IMPLEMENTATIONS"))
                                                    :host (selected-values (dojo.by-id "HOST"))))))
                               (defun host-selected ()
                                 (dojo.io.bind
                                  (create :url "ajax/implementations/"
                                          :handler host-callback
                                          :content (create :host (selected-values (dojo.by-id "HOST"))))))
                               (defun init-boinkmarks ()
                                 (setf (slot-value (dojo.by-id "IMPLEMENTATIONS") 'onchange) impl-selected)
                                 (setf (slot-value (dojo.by-id "HOST") 'onchange) host-selected))
                               (dojo.add-on-load init-boinkmarks))))
          
          #h(body
             (html-stream s
                          `((div :id "banner")
                            ((div :class "last")
                             "Last result: " ,(net.telent.date:universal-time-to-rfc2822-date *latest-result*))
                            (h1 ((a :href ,(urlstring *index-url*))
                                 "Automated common lisp implementation benchmarks"))
                            (h2 "Displaying " ,(if only-release (format nil "release ~A. " only-release) "all releases. "))))
             (html-stream
              s
              `((div :id "sidebar")
                ((form :method "get" :action ,(urlstring *index-url*))
                 (h2 "Machine")
                 (p
                  ,(make-multi-select :host host
                                      (iterate (for (machine arch) in-relation
                                                    (translate* `(distinct (select (m-name type) (join result machine
                                                                                                       :on (= result.m-name machine.name)))))
                                                    on-connection *dbconn*
                                                    cursor-name machine-cursor)
                                               (collect `(,machine ,(format nil "~A | ~A" machine arch))))))
                 (h2 "Implementations")
                 (p
                  ,(make-multi-select :implementations implementations
                                      (mapcar (lambda (impl) (list impl (pprint-impl-and-mode impl))) (all-implementations-of-host host))))
                 (h2 "Release")
                 (p
                  ,(make-select :only-release only-release
                                (tested-releases-for-implementations host implementations)))
                 (p
                  ((|input| :type "submit" :value "Graph")))
                 (h2 "Syndicate (atom 1.0)")
                 (ul
                  ,@(iterate (for (machine impl mode) in-relation
                                  (translate*
                                   `(distinct
                                     (select (machine-support.m-name build.v-name build.mode)
                                             (order-by
                                              (where
                                               (join build
                                                     machine-support
                                                     :on (and (= machine-support.i-name build.v-name) (= machine-support.mode build.mode)))
                                               (exists
                                                (limit
                                                 (select (*)
                                                         (where result
                                                                (and (= machine-support.i-name result.v-name) (= build.v-version result.v-version)
                                                                     (= machine-support.m-name result.m-name) (= build.mode result.mode))))
                                                 :end 1)))
                                              (m-name v-name mode)))))
                                  on-connection *dbconn*
                                  cursor-name syndication-cursor)
                             (collect `(li
                                        ((a :href ,(format nil "~A?~{HOST=~A&amp;IMPLEMENTATION=~A,~A~}" (urlstring *atom-url*) (mapcar #'urlstring-escape (list machine impl mode))))
                                         ,(format nil "~A/~A" machine (pprint-impl-and-mode (format nil "~A,~A" impl mode)))))))))))
             #h('(div :id "content")
                 (iterate (for (benchmark unit) in benchmarks)
                          (for (values image-url filename) = (apply #'url-for-image
                                                                    :benchmark benchmark
                                                                    :earliest earliest
                                                                    :latest latest
                                                                    args))
                          (for (values width height) = (decode-width-and-height-of-png-file filename))
                          #h('(div :class "entry")
                              #h(`(a :name ,(html-escape (substitute-if #\_
                                                                        (lambda (c)
                                                                          (member c '(#\/ #\+)))
                                                                        benchmark))))
                              #h('(div :class "entry-head")
                                  #h(h2 (princ benchmark s))
                                  #h('(div :class "entry-date")
                                      #h(`(a :href ,(substitute-if #\_
                                                                   (lambda (c)
                                                                     (member c '(#\/ #\+)))
                                                                   (format nil "#~A" benchmark)))
                                          (format s "#"))))
                              #h('(div :class "entry-text")
                                  #h(`(img :src ,image-url
                                           ,@(if width `(:width ,width))
                                           ,@(if height `(:height ,height))
                                           :alt ,benchmark))))
                          (terpri s)))))))
  t)

(defun tested-releases-for-implementations (host implementations)
  `((nil "All releases")
    ,@(iterate (for (version date steps) in-relation
                    (translate*
                     `(select (version release-date n-revisions)
                              (order-by
                               (join
                                ;; find out number of sub-revisions for every release;
                                (alias
                                 (select ((as (count *) n-revisions) (as ver.belongs-to-release release))
                                         (having
                                          (group-by (where (as version ver)
                                                           (in ver.belongs-to-release
                                                               (distinct
                                                                (select (version)
                                                                        (where (join version result
                                                                                     :on (and (= v-version version)
                                                                                              (= v-name i-name)))
                                                                               (and (= version.version
                                                                                       version.belongs-to-release)
                                                                                    (in m-name ',host)
                                                                                    (in (++ v-name "," mode) ',implementations)))))))
                                                    (ver.belongs-to-release))
                                          (> (count *) 1)))
                                 releasecount)
                                (alias
                                 (select (version release-date)
                                         version)
                                 version-date)
                                :on (= version release))
                               (release-date))))
                    on-connection *dbconn*
                    cursor-name release-cursor)
               (collect `(,version ,(format nil "~A (~A)" version steps))))))

(defun enteredp (param)
  (and param (not (equal "" param))))

(defmacro param-bind ((&rest args) request &body body)
  (with-gensyms (unhandled-part params argstring)
    `(let* ((,unhandled-part (request-unhandled-part ,request))
            (,argstring (subseq ,unhandled-part (mismatch ,unhandled-part "?")))
            (,params (mapcar (lambda (pp) (mapcar #'urlstring-unescape (split-sequence:split-sequence #\= pp)))
                             (split-sequence:split-sequence #\& ,argstring)))
            ,@(loop for (arg default-value is-list) in args
                    collect `(,arg ,(if is-list
                                        `(mapcar #'second
                                                 (remove-if-not (lambda (name)
                                                                  (string-equal name ,(symbol-name arg)))
                                                                ,params
                                                                :key #'first))
                                        `(second (assoc ,(symbol-name arg) ,params :test #'string-equal))))))
       ,@(loop for (arg default) in args
               collect `(cond
                          ((not (enteredp ,arg))
                           (setf ,arg ,default))
                          ((equal ,arg "NIL")
                           (setf ,arg nil))))
       ,@body)))

(defun all-implementations-of-host (host &optional preferred-only)
  (iterate (for (impl mode) in-relation
                (translate* `(distinct
                              (select (i-name mode)
                                      (where machine-support
                                             (and (in m-name ',host)
                                                  (exists
                                                   (limit
                                                    (select (*)
                                                            (where result
                                                                   (and (= result.m-name machine-support.m-name)
                                                                        (= result.v-name machine-support.i-name)
                                                                        (= result.mode machine-support.mode))))
                                                    :end 1))
                                                  ,@(if preferred-only
                                                        '(preferred)
                                                        nil))))))
                on-connection *dbconn*
                cursor-name all-host-implementations-cursor)
           (collect (concatenate 'string impl "," mode))))

(defmacro with-db-connection (connection &body body)
  `(let ((,connection (autobench:connect-to-database)))
     (unwind-protect (progn ,@body)
       (pg-disconnect ,connection))))

(defmethod handle-request-response ((handler index-handler) method request)
  (handler-bind ((sb-ext:timeout #'(lambda (c)
                                     (format *debug-io* "Caught timeout ~A. continuing...~%" c)
                                     (invoke-restart (find-restart 'continue c)))))
    (with-db-connection *dbconn*
      (param-bind ((host (list "baker") t)
                   (only-release nil)
                   (implementations (all-implementations-of-host host t) t)) request
            
        (let* ((date-boundaries (date-boundaries :host host :only-release only-release))
               (earliest (first date-boundaries))
               (latest (second date-boundaries))
               (*latest-result* (first (pg-result (pg-exec *dbconn*
                                                           (translate*
                                                            `(select ((max date))
                                                                     (where (join result version
                                                                                  :on (and (= version v-version) (= i-name v-name)))
                                                                            (and (in v-name
                                                                                     ',(mapcar
                                                                                        (lambda (impl)
                                                                                          (subseq impl 0 (position #\, impl)))
                                                                                        implementations))
                                                                                 (< release-date ,latest)
                                                                                 (> release-date ,earliest))))))
                                                  :tuple 0))))
          (request-send-headers request
                                :expires  (+ 1200 (get-universal-time))
                                :content-type "application/xhtml+xml; charset=utf-8"
                                :last-modified (or *latest-result* 0)
                                :conditional t) 
          (let ((s (request-stream request)))
            ;; (format s "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01 Transitional//EN\" \"http://www.w3.org/TR/html4/loose.dtd\">")
            (format s "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Strict//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd\">~%")
            ;; (format s "<?xml version=\"1.0\" encoding=\"UTF-8\"?>~%")
            (emit-image-index s
                              :implementations implementations
                              :only-release only-release
                              :host host
                              :earliest earliest
                              :latest latest)))))))

(defun make-select (name default options)
  `((select :name ,name :id ,name)
    ,@(make-select-options default options)))

(defun make-multi-select (name default options &key (size (length options)))
  `((select :name ,name :id ,name :multiple "multiple" :size ,size)
    ,@(make-select-options default options :multi-select-p t)))

(defun make-select-options (default options &key multi-select-p)
  (loop for (op text) in options
        if (if multi-select-p
               (member op default :test #'string-equal)
               (string-equal default op))
          collect `((option :value ,op :selected "selected") ,text)
        else
          collect `((option :value ,op) ,text)))

;;;; ajaxy stuff
(defclass release-handler (handler) ())
(defclass implementation-handler (handler) ())

(defmethod handle-request-response ((handler release-handler) method request)
  (with-db-connection *dbconn*
    (param-bind ((host (list "baker") t)
                 (implementations nil t)) request
      (when (and host implementations)
        (mapcar (lambda (elt) (html-stream (request-stream request) elt))
                (make-select-options nil
                                     (tested-releases-for-implementations
                                      host implementations)))))))

(defmethod handle-request-response ((handler implementation-handler) method request)
  (with-db-connection *dbconn*
    (param-bind ((host (list "baker") t)) request
      (when host
        (mapcar (lambda (elt) (html-stream (request-stream request) elt))
                (make-select-options nil
                                     (mapcar (lambda (impl) (list impl (pprint-impl-and-mode impl))) (all-implementations-of-host host))))))))
 
;;;; The sitemap.
(araneida:attach-hierarchy (http-listener-handler *bench-listener*) *internal-base-url* *base-url*
  ("/" index-handler)
  ("/ajax/releases/" release-handler)
  ("/ajax/implementations/" implementation-handler)
  ("/atom/"  atom-handler))
