(in-package :autobench)

(defun schema-has-migration-p (name)
  (with-db-connection ()
    (handler-case (not (zerop (query (:select (:count 'name)
                                              :from 'schema_version
                                              :where (:= 'name name))
                                     :single)))
      (database-error ()
        (format *debug-io* "No table schema_version found, creating...")
        (with-transaction (setup-schema-version)
          (query (:create-table "schema_version" ((name :type string :primary-key))))
          nil)))))

(defparameter *migrations* nil)

(defun perform-missing-migrations ()
  (dolist (migration (sort (remove-if #'schema-has-migration-p *migrations* :key #'string) #'string<))
    (format *debug-io* "Migrating ~A~%" migration)
    (with-db-connection ()
      (with-transaction ()
        (funcall migration)
        (query (:insert-into 'schema-version :set 'name (string migration)))))))

(defmacro defmigration (name &body body)
  `(pushnew (defun ,name ()
              (macrolet
                  ((run-query (&body args)
                     `(progn
                        (format *debug-io* "Performing ~A..." (first ',args))
                        (force-output *debug-io*)
                        (let ((start (get-internal-real-time)))
                          (query ,@args)
                          (format *debug-io* "done(~fs)~%" (/ (- (get-internal-real-time) start)
                                                              internal-time-units-per-second))))))
                ,@body))
            *migrations*))

;;;; Migrations for boinkmarks:

(defmigration 0-use-surrogate-keys
    "Use surrogate keys for builds: should speed up accesses to results."
  (run-query "cluster version using version_release_date_idx")
  (run-query "alter table version add version_id serial")

  ;; recreate tables with good names:
  (run-query "create table benchmarks as select name as benchmark_name, unit as unit from benchmark")
  (run-query "create table machines as select name as machine_name, type as machine_type from machine")
  (run-query "create table implementations as select name as implementation_name from impl")
  (run-query "create table versions as 
               select version_id, i_name as implementation_name, version as version_number, is_release, 
                      from_universal_time(release_date) as release_date, belongs_to_release
                 from version")
  (run-query "create table builds as 
               select version_id, mode
                 from build join version on v_name=i_name and v_version=version")
  (run-query "create table results as 
               select version_id, mode, m_name as machine_name, b_name as benchmark_name, 
                      from_universal_time(date) as result_date, seconds
                 from result join version on v_name=i_name and v_version=version")

  ;; Create indexes/PK constraints now:  
  (run-query "alter table builds add primary key (version_id, mode)")
  (run-query "alter table versions add primary key (version_id)")
  (run-query "create unique index version_uniqueness_idx on versions(implementation_name, version_number)")
  (run-query "alter table results add primary key (version_id, mode, result_date, benchmark_name)")
  (run-query "alter table implementations add primary key (implementation_name)")
  (run-query "alter table benchmarks add primary key (benchmark_name)")
  (run-query "alter table machines add primary key (machine_name)")

  ;; FK constraints, and we're done:
  (run-query "alter table versions add constraint versions_implementations_fk foreign key (implementation_name)
                    references implementations(implementation_name)")
  (run-query "alter table versions alter implementation_name set not null, alter version_number set not null")
  (run-query "alter table builds add constraint builds_versions_fk foreign key (version_id)
                    references versions(version_id)")
  (run-query "alter table results add constraint results_builds_fk foreign key (version_id, mode)
                    references builds(version_id, mode)")
  (run-query "alter table results add constraint results_benchmarks_fk foreign key (benchmark_name)
                    references benchmarks(benchmark_name)")
  (run-query "alter table results add constraint results_machines_fk foreign key (machine_name)
                    references machines(machine_name)")
  (run-query "alter table results alter seconds set not null, alter machine_name set not null")
    
  ;; Now drop the irrelevant tables 
  (run-query "drop table machine, impl, benchmark, build, result, version, impl_support, machine_support cascade"))