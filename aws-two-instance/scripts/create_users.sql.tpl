-- Copyright IBM Corp. 2017, 2026

-- Rendered by Terraform templatefile(). DEFINE OFF stops SQL*Plus expanding "&"
-- in the password. The password only appears inside the PL/SQL block, so an
-- error never makes SQL*Plus echo it. It must not contain a double quote
-- (enforced by the vault_db_password validation).
SET DEFINE OFF
WHENEVER SQLERROR EXIT FAILURE
alter session set container=XEPDB1;
DECLARE
  n NUMBER;
BEGIN
  SELECT COUNT(*) INTO n FROM dba_users WHERE username = UPPER('${vault_db_username}');
  EXECUTE IMMEDIATE CASE WHEN n = 0 THEN 'CREATE' ELSE 'ALTER' END
    || ' USER ${vault_db_username} IDENTIFIED BY "${replace(vault_db_password, "'", "''")}"';
  -- Vault rotates staticvault's password, so never reset it on re-runs.
  SELECT COUNT(*) INTO n FROM dba_users WHERE username = 'STATICVAULT';
  IF n = 0 THEN
    EXECUTE IMMEDIATE 'CREATE USER staticvault IDENTIFIED BY test';
  END IF;
END;
/
ALTER USER ${vault_db_username} DEFAULT TABLESPACE USERS QUOTA UNLIMITED ON USERS;
GRANT CREATE SESSION, RESOURCE, UNLIMITED TABLESPACE, DBA TO ${vault_db_username};
ALTER USER staticvault DEFAULT TABLESPACE USERS QUOTA UNLIMITED ON USERS;
GRANT CREATE SESSION, RESOURCE, UNLIMITED TABLESPACE, DBA TO staticvault;
exit;
