-- ======================================================
--  OLLAMA INTEGRATION PACKAGE INSTALLATION SCRIPT
-- ======================================================
--  This script installs the following components:
--    1. ollama_audit_log table
--    2. pkg_ollama package specification
--    3. pkg_ollama package body
-- ======================================================

SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT SQL.SQLCODE

PROMPT ========================================
PROMPT Installing OLLAMA Integration Components
PROMPT ========================================

-- Create the audit log table
PROMPT Creating table: OLLAMA_AUDIT_LOG ...
@ollama_audit_log.sql
PROMPT Table created.

-- Create the package specification
PROMPT Creating package specification: PKG_OLLAMA ...
@pkg_ollama.sql
PROMPT Package specification created.

-- 3Create the package body
PROMPT Creating package body: PKG_OLLAMA ...
@pkg_ollama.plb
PROMPT Package body created.


SHOW ERRORS

PROMPT ========================================
PROMPT OLLAMA Integration Installed Successfully
PROMPT ========================================

