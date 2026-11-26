-- Copyright IBM Corp. 2017, 2026

SET HEADING OFF FEEDBACK OFF
alter session set container=XEPDB1;
SELECT 'USER_OK:' || username FROM all_users WHERE username = UPPER('${vault_db_username}');
exit;
