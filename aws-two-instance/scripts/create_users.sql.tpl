-- Copyright IBM Corp. 2017, 2026

-- Rendered by Terraform templatefile(). The password is double-quoted, so it
-- must not contain a double quote. ALTER USER keeps re-runs in sync with tfvars.
alter session set container=XEPDB1;
CREATE USER ${vault_db_username} IDENTIFIED BY "${vault_db_password}";
ALTER USER ${vault_db_username} IDENTIFIED BY "${vault_db_password}";
ALTER USER ${vault_db_username} DEFAULT TABLESPACE USERS QUOTA UNLIMITED ON USERS;
GRANT CREATE SESSION, RESOURCE, UNLIMITED TABLESPACE, DBA TO ${vault_db_username};
CREATE USER staticvault IDENTIFIED BY test;
ALTER USER staticvault DEFAULT TABLESPACE USERS QUOTA UNLIMITED ON USERS;
GRANT CREATE SESSION, RESOURCE, UNLIMITED TABLESPACE, DBA TO staticvault;
exit;
