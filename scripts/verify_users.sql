alter session set container=XEPDB1;
SELECT username FROM all_users WHERE username = 'VAULT';
exit;
