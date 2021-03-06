;-*- lisp -*-
;---
;; Copyright (c) 2010 - 2020, Matthew Love.
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; The program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with the program.  If not, see <http://www.gnu.org/licenses/>.
;---

;;;; Dependencies
;---
(load "ieee-floats")
;---

(defun string->list (instring)
  "Return a list of characters present
   in the given string"
  (if (> (length instring) 0)
      (cons (subseq instring 0 1)
	    (string->list (subseq instring 1)))))

(defun extend-string-with-null (in-string amount)
  "Return a string of '(+ in-string amount) length by appending 
null charactors to the end of the in-string. The 'amount value 
should be the number of null charactors to append to the in-string.
For example, in the LAS file header, the value 'generating-software
is represented as a 32 charactor string. Most of the time, the name
of the generating software is much smaller than that, this function
will help to fill the necesarry charactors for las-file writing.
'(extend-string-with-null 'cl-las 0.1.6' (- 32 (length 'cl-las 0.1.6')) 
will output 'cl-las 0.1.6                    '"
  (if (not (= amount 0))
      (extend-string-with-null
       (concatenate 'string in-string (string #\Null))
       (- amount 1))
      in-string))

(defun coerce-array->list (in-array)
  "Return a list of the elements in the given array."
   (loop for i below (array-total-size in-array)
         collect (row-major-aref in-array i)))

;;
;; Binary I/O

(defun read-chars-from-file (in byte-length)
  "Reads byte-len bytes from a file object (in) and 
returns the chars they may represent (as a list)."
  (if (> byte-length 0)
	(cons (code-char (read-byte in)) 
	      (read-chars-from-file in (- byte-length 1)))))

(defun char-list->string (char-list)
  "Returns a string from a list of #\chars 
'(? there is probably a built-in function for this)"
  (if (not (null char-list))
      (concatenate 'string (string (car char-list)) 
		   (char-list->string (cdr char-list)))))

(defun read-string-file (in byte-length)
  "Reads a byte-len bytes string from a file object (in)"
  (char-list->string (read-chars-from-file in byte-length)))

(defun read-bin-file (in in-bytes)
  "Reads in-bytes from a file object (in) and 
returns a list of their values - defaults to little endian"
  (let ((out-b 0))
    (loop for i from 0 to (- in-bytes 1)
	  do (setf (ldb (byte 8 (* 8 i)) out-b) (read-byte in)))
    out-b))

(defun write-bin-file (out value out-bytes)
  "Write a numeric value to a binary stream."
  (loop for i from 0 to (- out-bytes 1)
       do (write-byte (ldb (byte 8 (* 8 i)) value) out)))

(defun write-string-file (out in-string)
  "Write a string to a binary stream."
  (let ((char-list (coerce-array->list in-string)))
    (loop for i from 0 to (- (length char-list) 1)
       do (write-byte (char-code (nth i char-list)) out))))

(defgeneric read-value (type stream &key)
  (:documentation "Read a value of the given type from the stream."))

(defmethod read-value ((type (eql 'string)) in &key length)
  (read-string-file in length))

(defmethod read-value ((type (eql 'int)) in &key length)
  (read-bin-file in length))

(defmethod read-value ((type (eql 'float)) in &key length)
  ;;(ieee-floats:decode-float64 (read-bin-file in length)))
  (float (read-bin-file in length)))

(defmethod read-value ((type (eql 'int-list)) in &key length int-size)
  (let ((out-value '()))
    (dotimes (n length)
      (push (read-bin-file in int-size) out-value))
    (reverse out-value)))

(defgeneric write-value (type stream value &key)
  (:documentation "Write a value as the given type to the stream."))

(defmethod write-value ((type (eql 'string)) out value &key length)
  (if (> (length value) length)
      (write-string-file out (subseq value 0 length))
      (write-string-file out (extend-string-with-null value (- length (length value))))))

(defmethod write-value ((type (eql 'int)) out value &key length)
  (write-bin-file out value length))

(defmethod write-value ((type (eql 'float)) out value &key length)
  (write-bin-file out (ieee-floats:encode-float64 value) length))

(defmethod write-value ((type (eql 'int-list)) out value &key length int-size)
  (dotimes (i length)
    (write-bin-file out (nth i value) int-size)))

;;
;; Generic

(defun as-keyword (sym) (intern (string sym) :keyword))

(defun mklist (x) (if (listp x) x (list x)))

(defun normalize-slot-spec (spec)
  (list (first spec) (mklist (second spec))))

(defun slot->defclass-slot (spec)
  (let ((name (first spec)))
    `(,name :initarg ,(as-keyword name) :accessor ,name)))

(defun slot->read-value (spec stream)
  (destructuring-bind (name (type &rest args)) (normalize-slot-spec spec)
    `(setf ,name (read-value ',type ,stream ,@args))))

(defun slot->write-value (spec stream)
  (destructuring-bind (name (type &rest args)) (normalize-slot-spec spec)
    `(write-value ',type ,stream ,name ,@args)))

(defun las-header-version->class-list (version)
  "Generate a las-header class slot list based on the desired version
pair, which should be formatted thus: '(1 . 0), you may also use the
returned value of (las-file-version las-file-path)"
  (let* ((version (eval version))
	 (file-sig '((file-signature (string :length 4))))
	 (vh-head
	  (cond
	    ((and (= (car version) 1) (= (cdr version) 0))
	     '((reserved (int :length 4))))
	    ((and (= (car version) 1) (= (cdr version) 1))
	     (list '(file-source-id (int :length 2))
		   '(reserved (int :length 2))))
	    ((or (and (= (car version) 1) (= (cdr version) 2))
		 (and (= (car version) 1) (= (cdr version) 3))
		 (and (= (car version) 1) (= (cdr version) 4)))
	     (list '(file-source-id (int :length 2))
		   '(global-encoding (int :length 2))))))
	 (vh-tail
	  (cond
	   ((and (= (car version) 1) (= (cdr version) 3))
	    '((waveform (int :length 8))))
	   ((and (= (car version) 1) (= (cdr version) 4))
	    (list '(waveform (int :length 8))
		  '(extended-vlr (int :length 8))
		  '(number-extended-vlr (int :length 4))
		  '(number-point-records14 (int :length 8))
		  '(number-point-return14 (int :length 8))))))
	 (vh-body 
	  (list '(guid1 (int :length 4)) '(guid2 (int :length 2))
		'(guid3 (int :length 2)) '(guid4 (int-list :length 8 :int-size 1))
		'(version-major (int :length 1)) '(version-minor (int :length 1))
		'(system-id (string :length 32))
		'(generating-software (string :length 32))
		'(file-day (int :length 2)) '(file-year (int :length 2))
		'(header-size (int :length 2))
		'(offset (int :length 4))
		'(number-variable-length-records (int :length 4))
		'(point-format (int :length 1))
		'(point-record-length (int :length 2))
		'(number-point-records (int :length 4))
		'(number-point-return (int-list :length 5 :int-size 4))
		'(x-scale (float :length 8)) '(y-scale (float :length 8)) '(z-scale (float :length 8))
		'(x-offset (float :length 8)) '(y-offset (float :length 8)) '(z-offset (float :length 8))
		'(x-max (float :length 8)) '(x-min (float :length 8))
		'(y-max (float :length 8)) '(y-min (float :length 8))
		'(z-max (float :length 8)) '(z-min (float :length 8)))))
    (append file-sig vh-head vh-body vh-tail)))

(defun las-point-version->class-list (version)
  (let ((version (eval version))
	(core0
	 (list '(x (int :length 4)) '(y (int :length 4)) '(z (int :length 4)) 
	       '(intensity (int :length 2))
	       '(return-info (int :length 1))
	       '(classification (int :length 1))
	       '(scan-rank (int :length 1))
	       '(user-data (int :length 1))
	       '(psrc-id (int :length 2))))
	(core6
	 (list '(x (int :length 4)) '(y (int :length 4)) '(z (int :length 4))
	       '(intensity (int :length 2))
	       '(return-info (int :length 2))
	       '(classification (int :length 1))
	       '(scan-angle (int :length 2))
	       '(psrc-id (int :length 2))
	       '(gps-time (float :length 8))))
	(gps
	 (list '(gps-time (float :length 8))))
	(rgb
	 (list '(red (int :length 2)) '(green (int :length 2)) '(blue (int :length 2))))
	(waves
	 (list '(wave-desc (int :length 1))
	       '(wave-offset (int :length 8))
	       '(wave-size (int :length 4))
	       '(wave-return (float :length 4))
	       '(x-t (float :length 4)) '(y-t (float :length 4)) '(z-t (float :length 4)))))
    (case version
      ((0) core0)
      ((1) (append core0 gps))
      ((2) (append core0 rgb))
      ((3) (append core0 gps rgb))
      ((4) (append core0 gps waves))
      ((5) (append core0 gps rgb waves))
      ((6) core6))))
	
;; (defun las-point-version->class-list (version)
;;   "Generate a las-point class slot list, which should be an
;; integer between 0 and 10.  You may also use the return value 
;; of (las-point-version las-path-name)"
;;   (let* ((version (eval version))
;; 	 (v-base
;; 	  (list '(x (int :length 4))
;; 		'(y (int :length 4))
;; 		'(z (int :length 4))
;; 		'(intensity (int :length 2))
;; 		'(return-info (int :length 1))
;; 		'(classification (int :length 1))
;; 		'(scan-rank (int :length 1))
;; 		'(user-data (int :length 1))
;; 		'(psrc-id (int :length 2))))
;; 	 (v-expand
;; 	  (cond 
;; 	   ((= version 1)
;; 	    (list '(gps-time (float :length 8))))
;; 	   ((= version 2)
;; 	    (list '(red (int :length 2))
;; 		  '(green (int :length 2))
;; 		  '(blue (int :length 2))))
;; 	   ((= version 3)
;; 	    (list '(gps-time (float :length 8))
;; 		  '(red (int :length 2))
;; 		  '(green (int :length 2))
;; 		  '(blue (int :length 2))))
;; 	   ((= version 4)
;; 	    (list '(gps-time (float :length 8))
;; 		  '(wave-desc (int :length 1))
;; 		  '(wave-offset (int :length 8))
;; 		  '(wave-size (int :length 4))
;; 		  '(wave-return (float :length 4))
;; 		  '(x-t (float :length 4))
;; 		  '(y-t (float :length 4))
;; 		  '(z-t (float :length 4))))
;; 	   ((= version 5)
;; 	    (list '(gps-time (float :length 8))
;; 		  '(red (int :length 2))
;; 		  '(green (int :length 2))
;; 		  '(blue (int :length 2))
;; 		  '(wave-desc (int :length 1))
;; 		  '(wave-offset (int :length 8))
;; 		  '(wave-size (int :length 4))
;; 		  '(wave-return (float :length 4))
;; 		  '(x-t (float :length 4))
;; 		  '(y-t (float :length 4))
;; 		  '(z-t (float :length 4))))
;; 	   (else '()))))
;;     (append v-base v-expand)))
;---

;;
;; Macros

(defmacro con-gensyms ((&rest names) &body body)
  `(let ,(loop for n in names collect `(,n (gensym)))
     ,@body))

(defmacro define-binary-class (name slots)
  (con-gensyms (typevar objectvar streamvar)
    `(progn
       (defclass ,name ()
	  ,(mapcar #'slot->defclass-slot slots))
       (defmethod read-value ((,typevar (eql ',name)) ,streamvar &key)
         (let ((,objectvar (make-instance ',name)))
           (with-slots ,(mapcar #'first slots) ,objectvar
             ,@(mapcar #'(lambda (x) (slot->read-value x streamvar)) slots))
           ,objectvar))
       (defmethod write-value ((,typevar (eql ',name)) ,streamvar ,objectvar &key)
         (with-slots ,(mapcar #'first slots) ,objectvar
           ,@(mapcar #'(lambda (x) (slot->write-value x streamvar)) slots))))))

(defmacro with-las-file (file-spec &body body)
  (let ((streamvar (car file-spec))
	(pathvar (cadr file-spec))
	(dirvar (cddr file-spec)))
    `(progn
       (let ((,streamvar (open ,pathvar ,@dirvar :element-type '(unsigned-byte 8))))
	 ,@body))))

(defmacro make-las-binary-class (hversion pversion)
  `(progn
     (define-binary-class las-header
	 ,(las-header-version->class-list hversion))
     (define-binary-class las-point
	 ,(las-point-version->class-list pversion))))

(defmacro make-las-variable-length-header ()
  `(progn
     (define-binary-class las-variable-length-header
	 ((reserved (int :length 2))
	  (user-id (string :length 16))
	  (record-id (int :length 2))
	  (record-length-post-header (int :length 2))
	  (description (string :length 32))))))

;;
;; Public functions

(defun las-file-p (path-name)
  "Quickly check a file for the lasf mark designating 
it as an LAS binary file. The first 4 bytes of an LAS 
file should be the charectors 'LASF'."
  (with-open-file (in path-name 
		      :direction :input 
		      :element-type '(unsigned-byte 8) 
		      :if-does-not-exist :error)
		  (if (string= (read-string-file in 4) "LASF")
		      t ())))

(defun las-file-version-stream (stream)
  "Return a cons representing the major and minor version 
of the given input file, which can be used as input for 
the generation of a 'las-header."
  (let ((start-position (file-position stream))
	(las-version 'nil))
    (file-position stream 24)
    (setf las-version (cons (read-bin-file stream 1) (read-bin-file stream 1)))
    (file-position stream start-position)
    las-version))

(defun las-point-version-stream (stream)
  "Return an integer representing the point version used
in the given input las-stream, which can be used as input for 
the generation of a 'las-point-class."
  (let ((start-position (file-position stream))
	(las-pversion 'nil))
    (file-position stream 104)
    (setq las-pversion (read-bin-file stream 1))
    (file-position stream start-position)
    las-pversion))

(defmacro las-file-version (path-name)
  "Return the LAS file version. Will return 
'((major-version . minor-version) point-version)'"
  (con-gensyms (in)
    `(progn
       (if (las-file-p ,path-name)
	   (with-open-file (,in ,path-name
			       :direction :input
			       :element-type '(unsigned-byte 8)
			       :if-does-not-exist :error)
	     (list (las-file-version-stream ,in) (las-point-version-stream ,in)))
	   (error "The input file: ~a is not a properly formatted LAS 1.x file." ,path-name)))))

(defmacro print-las-header (path-name)
  "Print the LAS header."
  (con-gensyms (hv pv this-header stream)
    `(progn
       (setq ,hv ',(car (las-file-version path-name)))
       (setq ,pv ,(cadr (las-file-version path-name)))
       (make-las-binary-class ,hv ,pv)
       (with-las-file (,stream ,path-name)
	 (let ((,this-header (read-value 'las-header ,stream)))
	   (loop for slot in (sb-mop:class-slots (class-of ,this-header))
	      do (format t "~s:~T~s~%" (sb-mop:slot-definition-name slot) (slot-value ,this-header (sb-mop:slot-definition-name slot)))))))))

(defmacro print-las-variable-length-headers (path-name)
  "Print the LAS variable-length headers."
  (con-gensyms (hv pv this-header this-vlr stream)
    `(progn
       (setq ,hv ',(car (las-file-version path-name)))
       (setq ,pv ,(cadr (las-file-version path-name)))
       (make-las-binary-class ,hv ,pv)
       (make-las-variable-length-header)
       (with-las-file (,stream ,path-name)
	 (let ((,this-header (read-value 'las-header ,stream)))
	   (file-position ,stream (header-size ,this-header))
	   (dotimes (n (number-variable-length-records ,this-header))
	     (let ((,this-vlr (read-value 'las-variable-length-header ,stream)))
	       (loop for slot in (sb-mop:class-slots (class-of ,this-vlr))
		  do (format t "~s:~T~s~%" (sb-mop:slot-definition-name slot) (slot-value ,this-vlr (sb-mop:slot-definition-name slot))))
	       (file-position ,stream (+ (file-position ,stream) (record-length-post-header ,this-vlr)))
	       (format t "--~%"))))))))

(defmacro format-las-points (formatter path-name delimiter)
  "format the LAS points as ASCII."
  (con-gensyms (hv pv this-point this-header point-row stream)
    (let ((path-name (eval path-name)))
    `(progn
       (defvar ,hv ',(car (las-file-version path-name)))
       (defvar ,pv ,(cadr (las-file-version path-name)))
       (make-las-binary-class ,hv ,pv)
       (with-las-file (,stream ,path-name)
	 (let ((,this-header (read-value 'las-header ,stream)))
	   (file-position ,stream (offset ,this-header))
	   (dotimes (n (max (number-point-records ,this-header) (number-point-records14 ,this-header)))
	     (let ((,point-row '())
		   (,this-point (read-value 'las-point ,stream)))
	       (loop for slot in (sb-mop:class-slots (class-of ,this-point))
		  do (push (slot-value ,this-point (sb-mop:slot-definition-name slot)) ,point-row))
	       (las-format-points ,formatter (reverse ,point-row) ,delimiter)))))))))

(defun las-format-points (formatter point-list delimiter)
  ;;(format formatter (concatenate 'string "~{~5,2A~#[~:;" delimiter "~]~}~%") point-list))
  (format formatter "~{~A~^ ~}~%" point-list))

(defmacro las->xyz (las-path-name xyz-path-name delimiter)
  "convert LAS file to ASCII xyz file"
  `(progn
     (defvar out (open ,xyz-path-name :direction :output :if-exists :supersede :if-does-not-exist :create))
     (format-las-points out ,las-path-name ,delimiter)
     (close out)))

;---END
